const std = @import("std");
const sys = @import("sys");
const io_mod = @import("io");
const framing = @import("framing");
const mem = std.mem;
const json = std.json;
const protocol = @import("protocol");
const Allocator = mem.Allocator;

// ---------------------------------------------------------------------------
// synapty wait — per [[RFC-0004:C-WAIT]]
//
// Implemented as a FILTERED SUBSCRIPTION (C-SUBSCRIPTION): subscribe to the
// hub event stream, check the snapshot for already-satisfied / unregistered
// / generation pinning, then react to pushed events. No polling anywhere.
// ---------------------------------------------------------------------------

pub const Outcome = enum {
    /// Target reached the requested state (exit 0).
    satisfied,
    /// Target had no registration at wait start (exit 2).
    not_registered,
    /// THE TARGET EXISTS AND THIS HUB CANNOT RECEIVE THE EVENT THAT WOULD
    /// END THE WAIT (exit 2, [[RFC-0004]] C-WAIT's federation qualifier).
    /// Such a wait is a timeout with extra steps, and exit 3 would read as
    /// a slow agent — so it fails at the start, carrying WHICH of the
    /// three cases it was. The exit-code set stays closed; federation adds
    /// no code to it, which is why the cause has to ride the payload.
    unresolved,
    /// --timeout expired (exit 3).
    timeout,
    /// The pinned generation ended while waiting (exit 4).
    generation_ended,
    /// Hub closed the stream / sent something unparseable (exit 1).
    protocol_error,
};

pub const WaitResult = struct {
    outcome: Outcome,
    /// Final merged status when satisfied.
    status: protocol.Status = .unknown,
    /// The pinned registration generation (0 when never resolved).
    generation: u64 = 0,
    /// `unresolved` only: which of C-WAIT's three cases. The row already
    /// carries this word ([[RFC-0010]] C-DIAGNOSABILITY), and the wait
    /// reports what the row would have said rather than inventing a
    /// second name for it.
    cause: ?protocol.UnknownCause = null,
};

/// Drive the wait state machine over an already-connected hub stream.
/// `timeout_ms` bounds the total wall time (null = block indefinitely,
/// matching `recv --wait` precedent).
pub fn waitOnHub(
    allocator: Allocator,
    fd: sys.fd_t,
    target: []const u8,
    until: protocol.Status,
    timeout_ms: ?u64,
) !WaitResult {
    const deadline_ms: ?i64 = if (timeout_ms) |t|
        std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds() + @as(i64, @intCast(t))
    else
        null;

    // Subscribe (anonymous, read-only surface).
    const now_ms = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds();
    const source_id = try std.fmt.allocPrint(allocator, "{s}wait-{d}", .{ protocol.temp_agent_prefix, now_ms });
    defer allocator.free(source_id);
    const sub = protocol.Envelope{
        .@"type" = "subscribe",
        .id = "wait-0",
        .source = source_id,
        .target = "hub",
    };
    const raw = try protocol.serializeEnvelope(allocator, sub);
    defer allocator.free(raw);
    try sys.writeAll(fd, raw);
    try sys.writeAll(fd, "\n");

    var line_buf: [64 * 1024]u8 = undefined;
    var lb = framing.LineBuffer.init(&line_buf);

    // --- Snapshot: pin the generation, check already-satisfied. ---
    const snap_line = readWithDeadline(&lb, fd, deadline_ms) catch |err| switch (err) {
        error.WouldBlock => return .{ .outcome = .timeout },
        else => return .{ .outcome = .protocol_error },
    } orelse return .{ .outcome = .protocol_error };

    var generation: u64 = 0;
    {
        const parsed = json.parseFromSlice(json.Value, allocator, snap_line, .{}) catch
            return .{ .outcome = .protocol_error };
        defer parsed.deinit();
        const agents = getPath(parsed.value, &.{ "payload", "data", "agents" }) orelse
            return .{ .outcome = .protocol_error };
        if (agents != .array) return .{ .outcome = .protocol_error };
        var found = false;
        for (agents.array.items) |entry| {
            if (entry != .object) continue;
            const id = getString(entry, "id") orelse continue;
            if (!mem.eql(u8, id, target)) continue;
            found = true;
            if (entry.object.get("generation")) |g| {
                if (g == .integer and g.integer > 0) generation = @intCast(g.integer);
            }
            const status_str = getString(entry, "status") orelse "unknown";
            // Unrecognized wire values read as unknown (C-VOCABULARY).
            const status = protocol.Status.fromString(status_str) orelse .unknown;
            if (status == until) {
                return .{ .outcome = .satisfied, .status = status, .generation = generation };
            }
            // A WAIT THAT CANNOT RECEIVE THE EVENT THAT WOULD END IT FAILS
            // IMMEDIATELY ([[RFC-0004]] C-WAIT). The three cases the clause
            // names are the three the row already distinguishes: the
            // hosting peer's link is down, two peers claim the identity so
            // it is addressed by nobody, or the link is up and that peer
            // never declared `presence_relay` — a link being up is not
            // evidence that events will come, the capability is.
            //
            // `no_evidence` IS NOT ONE OF THEM and the difference is the
            // whole point: it means the link is up, the peer can relay,
            // and it simply has not said anything yet. That is precisely
            // what a wait is for.
            if (getString(entry, "unknown_cause")) |cause_str| {
                if (protocol.UnknownCause.fromString(cause_str)) |cause| {
                    if (cause != .no_evidence) {
                        return .{ .outcome = .unresolved, .cause = cause, .generation = generation };
                    }
                }
            }
        }
        // Waiting for a not-yet-registered agent is out of scope (V1).
        if (!found) return .{ .outcome = .not_registered };
    }

    // --- Event loop: react to pushed events in log order. ---
    while (true) {
        const line = readWithDeadline(&lb, fd, deadline_ms) catch |err| switch (err) {
            error.WouldBlock => return .{ .outcome = .timeout },
            else => return .{ .outcome = .protocol_error },
        } orelse return .{ .outcome = .protocol_error };

        const parsed = json.parseFromSlice(json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const payload = getPath(parsed.value, &.{"payload"}) orelse continue;
        if (payload != .object) continue;
        const kind = getString(payload, "kind") orelse continue;
        const agent = getString(payload, "agent") orelse continue;
        if (!mem.eql(u8, agent, target)) continue;

        // A REMOTE IDENTITY'S EVENTS HAVE THEIR OWN KINDS, and this loop
        // knew only the local pair — so a wait on an agent hosted by a
        // peer could never be SATISFIED. It blocked to `--timeout` and
        // exited 3, which is the failure C-WAIT names and forbids, and
        // the fail-fast added for the three unreachable cases made the
        // refusals correct while leaving the success path unreachable.
        //
        // [[RFC-0009]] C-EVENT-LOCALITY requires the kinds to be DISTINCT
        // from the local lifecycle kinds they resemble, so no consumer
        // mistakes a directory fact for a local registration — which is
        // exactly why a consumer has to name both.
        if (mem.eql(u8, kind, "agent_unregistered") or
            mem.eql(u8, kind, "directory_identity_removed"))
        {
            // Pinned identity: the observed generation ended — a newcomer
            // reusing the pane must not satisfy this wait (C-WAIT). For a
            // remote identity the directory entry going is the same fact:
            // the thing being waited for is no longer addressable, and
            // exit 4 already means "it went away while you waited".
            return .{ .outcome = .generation_ended, .generation = generation };
        }
        if (mem.eql(u8, kind, "agent_status_changed") or
            mem.eql(u8, kind, "peer_presence_relayed"))
        {
            // BOTH CARRY THE NEW STATE UNDER `new` (events.zig serialises
            // `new_state` under that name for every kind that has one), so
            // this reads one field and not two.
            const new_str = getString(payload, "new") orelse continue;
            const new_status = protocol.Status.fromString(new_str) orelse .unknown;
            if (new_status == until) {
                return .{ .outcome = .satisfied, .status = new_status, .generation = generation };
            }
        }
    }
}

/// Read one line, bounding the blocked read with the remaining deadline
/// via SO_RCVTIMEO. Returns error.WouldBlock when the deadline expires.
fn readWithDeadline(lb: *framing.LineBuffer, fd: sys.fd_t, deadline_ms: ?i64) !?[]const u8 {
    if (deadline_ms) |dl| {
        const now = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds();
        const remaining = dl - now;
        if (remaining <= 0) return error.WouldBlock;
        try sys.setRecvTimeout(fd, @intCast(remaining));
    }
    return lb.readLine(fd);
}

/// Walk a chain of object keys ("payload" -> "data" -> ...).
fn getPath(root: json.Value, keys: []const []const u8) ?json.Value {
    var v = root;
    for (keys) |k| {
        if (v != .object) return null;
        v = v.object.get(k) orelse return null;
    }
    return v;
}

fn getString(v: json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const field = v.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}
