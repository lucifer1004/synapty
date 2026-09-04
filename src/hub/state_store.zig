//! Durable hub state ([[ADR-0008]] stage 2, WI-2026-08-12-002).
//!
//! A hub that is meant to outlive the operator's laptop cannot keep its
//! mailboxes only in memory: every restart would silently discard mail
//! that senders were told was queued. This module persists exactly the
//! state that carries meaning across a restart, and NOTHING else.
//!
//! PERSISTED:
//!   - mailbox queues (the store-and-forward promise: an ack of
//!     "queued" must survive a restart, or it was a lie)
//!   - the durable-identity set (RFC-0008), so a returning agent's
//!     queued mail is still addressed to something the hub knows
//!
//! DELIBERATELY NOT PERSISTED, because each belongs to a WORKBENCH's
//! lifetime rather than the hub's, and restoring them would resurrect
//! claims about a world that no longer exists:
//!   - live connections and the routing table (a connection cannot be
//!     restored; pretending otherwise would route into the void)
//!   - registration generations (RFC-0004 scopes them to a connection)
//!   - wake candidates (RFC-0005: a generation change cancels them —
//!     "no inherited wake debt" applies across restarts too)
//!   - exec panes (RFC-0007: machine scratch space owned by a workbench
//!     that is gone; WI-2026-08-11-015 already excluded them from the
//!     session snapshot for the same reason)
//!   - presence status (merged from evidence that is no longer being
//!     observed; a restored "working" would be a claim with no witness)
//!
//! Recovery is honest: an unreadable, truncated, or version-mismatched
//! store starts EMPTY and says so. It never crashes the hub and never
//! restores a partially-decoded mailbox — half a queue is worse than
//! none, because it looks complete.

const std = @import("std");
const json = std.json;
const io_mod = @import("io");
const sys = @import("sys");
const log = @import("diag").scoped(.hub);

/// Bump when the on-disk shape changes incompatibly. A mismatch starts
/// empty rather than guessing at an older layout.
pub const format_version: i64 = 1;

/// Ceilings so a runaway or hostile store cannot exhaust memory on load.
/// The mailbox itself bounds queues at MailStore.max_per_queue; these
/// bound the FILE, which is a separate trust boundary.
pub const max_identities: usize = 4096;
pub const max_messages_per_identity: usize = 256;
pub const max_file_bytes: usize = 8 * 1024 * 1024;


pub fn statePath(buf: []u8) ?[]const u8 {
    // MACHINE-scoped: these are the mailboxes of agents on THIS box.
    return @import("paths").hub_state.path(buf);
}

/// One identity's persisted mail. Slices borrow the caller's arena.
pub const Mailbox = struct {
    id: []const u8,
    messages: []const []const u8,
};

/// One spooled message, held for a peer that could not take it yet.
/// [[RFC-0009]] C-DELIVERY: a `spooled` answer is a promise, so it is
/// written where the mailbox is written.
pub const SpooledMessage = struct {
    msg_id: []const u8,
    target: []const u8,
    raw: []const u8,
    /// WHEN it was spooled, not when it was restored. A fresh timestamp
    /// would extend every message's TTL by the restarting hub's uptime.
    enqueued_ms: i64,
    /// THE ID IT WAS ALREADY SENT UNDER, when it has been. It rides the
    /// snapshot for the same reason the message does: a retry after a
    /// RESTART would otherwise mint a fresh id and the peer would queue a
    /// second copy — the very duplication the id exists to prevent, just
    /// with a process boundary in the middle. Absent for a copy that has
    /// never gone out.
    forward_id: ?[]const u8 = null,
};

/// One peer's spool queue. FIFO, and the order is part of the promise.
pub const SpoolQueue = struct {
    peer: []const u8,
    messages: []const SpooledMessage,
};

pub const Snapshot = struct {
    mailboxes: []const Mailbox = &.{},
    durable_ids: []const []const u8 = &.{},
    spool: []const SpoolQueue = &.{},
};

// ---------------------------------------------------------------------------
// Serialize
// ---------------------------------------------------------------------------

/// Render a snapshot as the on-disk JSON document (arena-owned).
pub fn serialize(arena: std.mem.Allocator, snap: Snapshot) ![]const u8 {
    var root = json.ObjectMap.empty;
    try root.put(arena, "version", .{ .integer = format_version });

    var boxes = json.ObjectMap.empty;
    for (snap.mailboxes) |box| {
        if (box.messages.len == 0) continue; // empty queues carry nothing
        var arr = json.Array.init(arena);
        for (box.messages) |m| try arr.append(.{ .string = m });
        try boxes.put(arena, box.id, .{ .array = arr });
    }
    try root.put(arena, "mailboxes", .{ .object = boxes });

    var ids = json.Array.init(arena);
    for (snap.durable_ids) |id| try ids.append(.{ .string = id });
    try root.put(arena, "durable_ids", .{ .array = ids });

    var spool = json.ObjectMap.empty;
    for (snap.spool) |q| {
        if (q.messages.len == 0) continue; // an empty queue promises nothing
        var arr = json.Array.init(arena);
        for (q.messages) |m| {
            var obj = json.ObjectMap.empty;
            try obj.put(arena, "msg_id", .{ .string = m.msg_id });
            try obj.put(arena, "target", .{ .string = m.target });
            try obj.put(arena, "raw", .{ .string = m.raw });
            try obj.put(arena, "enqueued_ms", .{ .integer = m.enqueued_ms });
            // OMITTED WHEN THERE IS NONE, rather than written empty: a
            // copy that has never gone out and one sent under the empty
            // string are different, and only the first is real.
            if (m.forward_id) |f| try obj.put(arena, "forward_id", .{ .string = f });
            try arr.append(.{ .object = obj });
        }
        try spool.put(arena, q.peer, .{ .array = arr });
    }
    try root.put(arena, "spool", .{ .object = spool });

    return json.Stringify.valueAlloc(arena, json.Value{ .object = root }, .{});
}

/// Atomic write: a torn file after a crash mid-write would be exactly
/// the "half a mailbox" this module refuses to restore.
pub fn writeFile(path: []const u8, content: []const u8) !void {
    const io = io_mod.get();
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    var tmp_buf: [1100]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp.{d}", .{ path, std.c.getpid() });
    {
        // BORN PRIVATE. The file held presence and bindings for every
        // agent on the machine; a chmod after the rename left it
        // world-readable for the width of the write, which is the same
        // window the socket code had already closed ([[WI-2026-09-02-025]]).
        var out = try std.Io.Dir.cwd().createFile(io, tmp, .{ .permissions = .fromMode(0o600) });
        defer out.close(io);
        try out.writeStreamingAll(io, content);
    }
    var from_z: [1100]u8 = undefined;
    var to_z: [1100]u8 = undefined;
    const fz = try std.fmt.bufPrintZ(&from_z, "{s}", .{tmp});
    const tz = try std.fmt.bufPrintZ(&to_z, "{s}", .{path});
    if (std.c.rename(fz.ptr, tz.ptr) != 0) return error.RenameFailed;
}

// ---------------------------------------------------------------------------
// Parse (honest recovery)
// ---------------------------------------------------------------------------

pub const LoadOutcome = enum {
    /// No store on disk — a first run, not a failure.
    absent,
    /// Restored.
    loaded,
    /// Present but unusable; the hub starts empty and this is logged.
    rejected,
};

pub const LoadResult = struct {
    outcome: LoadOutcome,
    snapshot: Snapshot = .{},
    /// Why a store was rejected — surfaced, never swallowed.
    reason: ?[]const u8 = null,
};

/// Parse a store document. Returns `rejected` (never an error) for every
/// malformed shape, so a bad file can never take the hub down with it.
pub fn parse(arena: std.mem.Allocator, content: []const u8) LoadResult {
    if (content.len > max_file_bytes) {
        return .{ .outcome = .rejected, .reason = "state file exceeds the size ceiling" };
    }
    const parsed = json.parseFromSliceLeaky(json.Value, arena, content, .{}) catch {
        return .{ .outcome = .rejected, .reason = "state file is not valid JSON (truncated or corrupt)" };
    };
    if (parsed != .object) {
        return .{ .outcome = .rejected, .reason = "state file root is not an object" };
    }
    const root = parsed.object;

    const version_val = root.get("version") orelse {
        return .{ .outcome = .rejected, .reason = "state file has no version" };
    };
    if (version_val != .integer or version_val.integer != format_version) {
        return .{ .outcome = .rejected, .reason = "state file version mismatch" };
    }

    var boxes = std.ArrayList(Mailbox).empty;
    if (root.get("mailboxes")) |mb| {
        if (mb != .object) {
            return .{ .outcome = .rejected, .reason = "mailboxes is not an object" };
        }
        var it = mb.object.iterator();
        while (it.next()) |entry| {
            if (boxes.items.len >= max_identities) {
                return .{ .outcome = .rejected, .reason = "state file exceeds the identity ceiling" };
            }
            const v = entry.value_ptr.*;
            if (v != .array) continue; // a non-array queue is not half-restored
            var msgs = std.ArrayList([]const u8).empty;
            for (v.array.items) |m| {
                if (m != .string) continue;
                if (msgs.items.len >= max_messages_per_identity) break;
                msgs.append(arena, m.string) catch
                    return .{ .outcome = .rejected, .reason = "out of memory restoring mail" };
            }
            if (msgs.items.len == 0) continue;
            boxes.append(arena, .{ .id = entry.key_ptr.*, .messages = msgs.items }) catch
                return .{ .outcome = .rejected, .reason = "out of memory restoring mailboxes" };
        }
    }

    var ids = std.ArrayList([]const u8).empty;
    if (root.get("durable_ids")) |dv| {
        if (dv == .array) {
            for (dv.array.items) |v| {
                if (v != .string) continue;
                if (ids.items.len >= max_identities) break;
                ids.append(arena, v.string) catch
                    return .{ .outcome = .rejected, .reason = "out of memory restoring identities" };
            }
        }
    }

    var spool = std.ArrayList(SpoolQueue).empty;
    if (root.get("spool")) |sv| {
        if (sv != .object) {
            return .{ .outcome = .rejected, .reason = "spool is not an object" };
        }
        var it = sv.object.iterator();
        while (it.next()) |entry| {
            if (spool.items.len >= max_identities) {
                return .{ .outcome = .rejected, .reason = "state file exceeds the peer ceiling" };
            }
            const v = entry.value_ptr.*;
            if (v != .array) continue;
            var msgs = std.ArrayList(SpooledMessage).empty;
            for (v.array.items) |m| {
                if (m != .object) continue;
                if (msgs.items.len >= max_messages_per_identity) break;
                // EVERY FIELD OR NONE. A half-read message would be
                // spooled toward a target nobody named, or aged from a
                // timestamp nobody wrote — both worse than one that was
                // never restored, because both look like a live promise.
                const id = m.object.get("msg_id") orelse continue;
                const target = m.object.get("target") orelse continue;
                const raw = m.object.get("raw") orelse continue;
                const at = m.object.get("enqueued_ms") orelse continue;
                if (id != .string or target != .string or raw != .string or at != .integer) continue;
                // NOT PART OF "EVERY FIELD OR NONE": a message that has
                // never gone out legitimately has no forward id, so
                // requiring one would refuse to restore exactly the
                // messages spooled because the link was down.
                const fid: ?[]const u8 = if (m.object.get("forward_id")) |f|
                    (if (f == .string) f.string else null)
                else
                    null;
                msgs.append(arena, .{
                    .msg_id = id.string,
                    .target = target.string,
                    .raw = raw.string,
                    .enqueued_ms = at.integer,
                    .forward_id = fid,
                }) catch return .{ .outcome = .rejected, .reason = "out of memory restoring the spool" };
            }
            if (msgs.items.len == 0) continue;
            spool.append(arena, .{ .peer = entry.key_ptr.*, .messages = msgs.items }) catch
                return .{ .outcome = .rejected, .reason = "out of memory restoring the spool" };
        }
    }

    return .{
        .outcome = .loaded,
        .snapshot = .{
            .mailboxes = boxes.items,
            .durable_ids = ids.items,
            .spool = spool.items,
        },
    };
}

/// Read + parse the store at `path`. Absent is not an error.
pub fn load(arena: std.mem.Allocator, path: []const u8) LoadResult {
    const io = io_mod.get();
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return .{ .outcome = .absent };
    defer f.close(io);
    const buf = arena.alloc(u8, max_file_bytes) catch
        return .{ .outcome = .rejected, .reason = "out of memory reading state" };
    var reader = f.reader(io, buf);
    const n = reader.interface.readSliceShort(buf) catch
        return .{ .outcome = .rejected, .reason = "state file could not be read" };
    if (n == 0) return .{ .outcome = .absent };
    return parse(arena, buf[0..n]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "round-trips mailboxes and durable ids" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const snap = Snapshot{
        .mailboxes = &.{
            .{ .id = "claude-deadbeef", .messages = &.{ "{\"m\":1}", "{\"m\":2}" } },
            .{ .id = "codex-cafe1234", .messages = &.{"{\"m\":3}"} },
        },
        .durable_ids = &.{ "claude-deadbeef", "codex-cafe1234" },
    };
    const doc = try serialize(a, snap);
    const result = parse(a, doc);
    try std.testing.expectEqual(LoadOutcome.loaded, result.outcome);
    try std.testing.expectEqual(@as(usize, 2), result.snapshot.mailboxes.len);
    try std.testing.expectEqual(@as(usize, 2), result.snapshot.durable_ids.len);

    var total: usize = 0;
    for (result.snapshot.mailboxes) |b| total += b.messages.len;
    try std.testing.expectEqual(@as(usize, 3), total);
}

test "empty queues are not persisted (nothing to promise)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const doc = try serialize(a, .{
        .mailboxes = &.{.{ .id = "claude-empty", .messages = &.{} }},
        .durable_ids = &.{"claude-empty"},
    });
    const result = parse(a, doc);
    try std.testing.expectEqual(LoadOutcome.loaded, result.outcome);
    try std.testing.expectEqual(@as(usize, 0), result.snapshot.mailboxes.len);
    // The identity itself still survives — it is known, it just has no mail.
    try std.testing.expectEqual(@as(usize, 1), result.snapshot.durable_ids.len);
}

test "recovery is honest: corrupt, truncated and skewed stores start EMPTY" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Garbage.
    try std.testing.expectEqual(LoadOutcome.rejected, parse(a, "not json at all").outcome);
    // Truncated mid-document — the crash-during-write shape.
    try std.testing.expectEqual(
        LoadOutcome.rejected,
        parse(a, "{\"version\":1,\"mailboxes\":{\"a\":[\"{\\\"m\\\"").outcome,
    );
    // A future version must not be guessed at.
    const skew = parse(a, "{\"version\":99,\"mailboxes\":{}}");
    try std.testing.expectEqual(LoadOutcome.rejected, skew.outcome);
    try std.testing.expect(skew.reason != null);
    // Missing version.
    try std.testing.expectEqual(LoadOutcome.rejected, parse(a, "{\"mailboxes\":{}}").outcome);
    // Root of the wrong shape.
    try std.testing.expectEqual(LoadOutcome.rejected, parse(a, "[1,2,3]").outcome);

    // Every rejection carries a reason: a silent empty start would look
    // exactly like a first run, which is the confusion to avoid.
    for ([_][]const u8{ "not json", "{\"version\":99}", "[1]" }) |bad| {
        try std.testing.expect(parse(a, bad).reason != null);
    }
}

test "per-identity message ceiling truncates the FILE, not the promise" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var msgs = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < max_messages_per_identity + 50) : (i += 1) {
        try msgs.append(a, "{\"m\":0}");
    }
    const doc = try serialize(a, .{
        .mailboxes = &.{.{ .id = "claude-flood", .messages = msgs.items }},
    });
    const result = parse(a, doc);
    try std.testing.expectEqual(LoadOutcome.loaded, result.outcome);
    try std.testing.expectEqual(@as(usize, 1), result.snapshot.mailboxes.len);
    try std.testing.expectEqual(max_messages_per_identity, result.snapshot.mailboxes[0].messages.len);
}

test "file round-trip through an atomic write" {
    std.testing.log_level = .err;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var pbuf: [256]u8 = undefined;
    const tmp = sys.getenv("TMPDIR") orelse "/tmp";
    const scratch = try std.fmt.bufPrint(&pbuf, "{s}synapty-state-test-{d}.json", .{ tmp, std.c.getpid() });
    defer std.Io.Dir.cwd().deleteFile(io_mod.get(), scratch) catch {};

    // Absent before anything is written.
    try std.testing.expectEqual(LoadOutcome.absent, load(a, scratch).outcome);

    const doc = try serialize(a, .{
        .mailboxes = &.{.{ .id = "claude-abc", .messages = &.{"{\"hello\":1}"} }},
        .durable_ids = &.{"claude-abc"},
    });
    try writeFile(scratch, doc);

    const result = load(a, scratch);
    try std.testing.expectEqual(LoadOutcome.loaded, result.outcome);
    try std.testing.expectEqualStrings("claude-abc", result.snapshot.mailboxes[0].id);
    try std.testing.expectEqualStrings("{\"hello\":1}", result.snapshot.mailboxes[0].messages[0]);
}

test "a spooled message survives the restart it was promised across" {
    // [[RFC-0009]] C-DELIVERY: "SPOOL LIFETIME IS HUB LIFETIME, and the
    // spool MUST be persisted with the mailbox. A spooled message is one
    // the sender was told would be delivered later; losing it on a hub
    // restart would make that answer a lie."
    //
    // The snapshot carried mailboxes and durable identities and nothing
    // else, so every `spooled` answer the hub had ever given was a lie
    // across a restart — and the drops the same clause requires to be
    // "written where the spool is written" had nowhere to be written.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // ONE THAT HAS ALREADY GONE OUT AND ONE THAT HAS NOT. A retry after a
    // RESTART must carry the id its first attempt went out under, or the
    // peer queues a second copy — the duplication the id exists to
    // prevent, with a process boundary in the middle. And a message that
    // never went out has no id, which must not be confused with an empty
    // one or refuse to restore.
    const spooled = [_]SpooledMessage{
        .{ .msg_id = "m1", .target = "claude-remote01", .raw = "{\"type\":\"dm\"}", .enqueued_ms = 1000,
           .forward_id = "1000-7" },
        .{ .msg_id = "m2", .target = "claude-remote02", .raw = "{\"type\":\"dm\",\"id\":\"2\"}", .enqueued_ms = 2000 },
    };
    const doc = try serialize(a, .{
        .spool = &.{.{ .peer = "remotehost-4e84", .messages = &spooled }},
    });

    const back = parse(a, doc);
    try std.testing.expectEqual(LoadOutcome.loaded, back.outcome);
    try std.testing.expectEqual(@as(usize, 1), back.snapshot.spool.len);
    const q = back.snapshot.spool[0];
    try std.testing.expectEqualStrings("remotehost-4e84", q.peer);
    try std.testing.expectEqual(@as(usize, 2), q.messages.len);
    try std.testing.expectEqualStrings("1000-7", q.messages[0].forward_id.?);
    try std.testing.expect(q.messages[1].forward_id == null);

    // THE ORDER IS THE POINT, not merely the contents: C-DELIVERY's flush
    // rule has spooled traffic precede newly submitted traffic, and a
    // restore that reshuffled the queue would let a sender's later
    // message overtake its earlier one with nothing reporting it.
    try std.testing.expectEqualStrings("m1", q.messages[0].msg_id);
    try std.testing.expectEqualStrings("m2", q.messages[1].msg_id);
    try std.testing.expectEqualStrings("claude-remote01", q.messages[0].target);
    try std.testing.expectEqual(@as(i64, 1000), q.messages[0].enqueued_ms);

    // AND THE AGE SURVIVES WITH IT. Restoring a message with a fresh
    // timestamp would silently extend every spooled message's TTL by the
    // uptime of the hub that restarted, so a queue could outlive the
    // directory entry naming where to send it.
    try std.testing.expectEqual(@as(i64, 2000), q.messages[1].enqueued_ms);
}
