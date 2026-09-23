const std = @import("std");
const sys = @import("sys");
const io_mod = @import("io");
const mem = std.mem;
const federation = @import("federation.zig");
const log = @import("diag").scoped(.hub);

// ---------------------------------------------------------------------------
// Machine identity — [[RFC-0010]] C-PEER-IDENTITY
//
// A machine's peer id is minted ONCE and persisted, and every other party
// accepts what this machine reports rather than proposing a value.
//
// THIS FILE EXISTS SEPARATELY FROM state_store.zig ON PURPOSE. The hub's
// working state (mailboxes, durable ids) is discardable — a `--no-state`
// start throws it away deliberately, and an operator may delete it to
// clear a stuck queue. A machine's NAME is not discardable: peers key
// directory entries, spooled mail and qualified fallback ids on it, so
// losing it re-mints and every one of those goes stale on machines this
// one cannot even see. Keeping the two in one file would make the cheap
// operation silently perform the expensive one.
//
// The suffix is random rather than derived, and that is a real difference
// from RFC-0008's durable agent ids, whose fragment comes from an
// externally durable value and so survives total state loss. There is no
// externally durable value for "this machine" to derive from — a hostname
// is not stable and a MAC address is not portable — so the durability has
// to come from the file. C-PEER-IDENTITY's endpoint-continuity rule is
// what covers the case where it is lost anyway.
// ---------------------------------------------------------------------------

pub var path_override: ?[]const u8 = null;

pub fn identityPath(buf: []u8) ?[]const u8 {
    if (path_override) |p| return p;
    // MACHINE-scoped by classification, not by convention — see paths.zig.
    return @import("paths").identity.path(buf);
}

/// What reading the persisted peer id found ([[WI-2026-09-23-002]]).
///
/// THREE ANSWERS, BECAUSE "I COULD NOT READ IT" IS NOT "THERE IS NONE".
/// This returned an optional, and every `open` failure — a permission,
/// a descriptor limit, an I/O error — came back as the same `null` as a
/// machine that had never minted one. `ensure` then minted a new id and
/// wrote it OVER the file: the one thing the header of this file exists
/// to prevent, done in answer to a question that could not be asked.
/// `SessionRecord` learned this for session records
/// ([[WI-2026-09-07-008]]); this is the same lesson for the name every
/// peer keys its mail on.
pub const Loaded = union(enum) {
    found: []const u8,
    /// No file, or a file that holds no usable id. Minting is allowed:
    /// the first because there is nothing to lose, the second by a
    /// recorded decision — an id with `@` in it would break the qualifier
    /// split every peer performs, so there is nothing worth keeping
    /// either (see the test on a corrupt file).
    none,
    /// A file is there and could not be read. It may hold a perfectly
    /// good identity, so nothing may be written over it.
    unreadable,
};

pub fn load(out: []u8) Loaded {
    const io = io_mod.get();
    var pbuf: [1024]u8 = undefined;
    // No path at all is not a file this process failed to read; it is
    // a machine with nowhere to keep one, and minting for this run is
    // what `ensure` has always done there.
    const path = identityPath(&pbuf) orelse return .none;
    var rbuf: [512]u8 = undefined;
    const content = switch (readSmall(io, path, &rbuf)) {
        .content => |c| c,
        .absent => return .none,
        .unreadable => return .unreadable,
    };
    const needle = "\"peer_id\":\"";
    const at = mem.indexOf(u8, content, needle) orelse return .none;
    const start = at + needle.len;
    const end = mem.indexOfScalarPos(u8, content, start, '"') orelse return .none;
    const id = content[start..end];
    if (!federation.validPeerId(id)) return .none;
    const n = @min(id.len, out.len);
    @memcpy(out[0..n], id[0..n]);
    return .{ .found = out[0..n] };
}

const Read = union(enum) { content: []const u8, absent, unreadable };

/// ONLY `FileNotFound` MEANS THERE IS NOTHING THERE. Everything else is
/// this process being unable to look.
fn readSmall(io: std.Io, path: []const u8, buf: []u8) Read {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| return switch (err) {
        error.FileNotFound => .absent,
        else => .unreadable,
    };
    defer f.close(io);
    @memset(buf, 0);
    _ = f.readPositionalAll(io, buf, 0) catch return .unreadable;
    const len = mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return .{ .content = buf[0..len] };
}

/// ATOMIC AND BORN PRIVATE, through the one writer that already is both
/// ([[state_store.writeFile]], [[WI-2026-09-23-002]]).
///
/// This truncated the file in place and then wrote it, so a crash or a
/// full disk between the two left a file holding no id — and a re-mint,
/// which is the operator's deliberate replacement, lost the old name and
/// the new one together. It also created the file with the default mode
/// and chmodded it afterwards, which is the world-readable window
/// [[WI-2026-09-02-025]] closed for the state file. Sharing the writer is
/// not sharing the file: the header's reason for keeping them apart is
/// about what may be discarded, and that is untouched.
fn write(id: []const u8) bool {
    var pbuf: [1024]u8 = undefined;
    const path = identityPath(&pbuf) orelse return false;
    var cbuf: [256]u8 = undefined;
    const content = std.fmt.bufPrint(&cbuf, "{{\"peer_id\":\"{s}\"}}\n", .{id}) catch return false;
    @import("state_store.zig").writeFile(path, content) catch return false;
    return true;
}

/// Process-wide, seeded ONCE. Re-seeding per call from the clock looks
/// harmless and is not: two calls inside the same millisecond in the same
/// process get an identical seed and therefore an identical suffix, so a
/// re-mint immediately after a mint returns the id it was supposed to
/// replace — silently doing nothing, which is the single outcome an
/// operator resolving a collision cannot detect. Caught by the remint
/// test on the first run.
var prng: ?std.Random.DefaultPrng = null;

/// A 4-hex suffix. Not cryptographic: it only has to make two machines
/// that share a label distinguishable within one human's fleet, and
/// C-COLLISION handles the case where two do collide.
fn mintSuffix(out: *[federation.peer_suffix_len]u8) void {
    if (prng == null) {
        var seed: u64 = @bitCast(std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds());
        seed ^= @as(u64, @intCast(std.c.getpid())) *% 0x9E3779B97F4A7C15;
        seed ^= @intFromPtr(out) *% 0xBF58476D1CE4E5B9;
        prng = std.Random.DefaultPrng.init(seed);
    }
    const hex = "0123456789abcdef";
    for (out) |*c| c.* = hex[prng.?.random().int(u4)];
}

/// This machine's peer id, minting and persisting one if absent.
/// `suggested_label` is a SUGGESTION used only at mint time — an existing
/// identity is never overridden by it (C-PEER-IDENTITY: provisioning may
/// suggest, never override).
/// What `ensure` could give this process ([[WI-2026-09-23-002]]).
///
/// NOT AN OPTIONAL, for the reason `Loaded` is not one: "there is a file
/// and it could not be read" has to reach whoever tells the human, and a
/// `null` would have said only that there was no name.
pub const Ensured = union(enum) {
    id: []const u8,
    /// The file is there and could not be read, and nothing was written
    /// over it. RUN WITHOUT A NAME RATHER THAN TAKE A NEW ONE: a hub with
    /// no peer id cannot federate this run, which is loud and recoverable;
    /// a hub that re-mints has silently orphaned every directory entry and
    /// spooled message its peers hold under the old name, which is neither.
    unreadable,
};

pub fn ensure(out: []u8, suggested_label: ?[]const u8) Ensured {
    switch (load(out)) {
        .found => |existing| return .{ .id = existing },
        .none => {},
        .unreadable => return .unreadable,
    }

    var lbuf: [128]u8 = undefined;
    var hbuf: [256]u8 = undefined;
    const raw = suggested_label orelse (sys.hostName(&hbuf) orelse "host");
    const label = federation.disciplineLabel(&lbuf, raw);

    var suffix: [federation.peer_suffix_len]u8 = undefined;
    mintSuffix(&suffix);
    var idbuf: [128]u8 = undefined;
    const id = federation.composePeerId(&idbuf, label, &suffix);

    if (!write(id)) {
        // A hub that cannot persist its name would mint a new one every
        // restart, which is the state-loss failure on a loop. Report it
        // and use the id anyway for this process — better than refusing
        // to run, and loud enough to be found.
        log.err("identity: could not persist peer id '{s}' — it will change on restart, and every peer's directory entries and spooled mail are keyed on it", .{id});
    }
    const n = @min(id.len, out.len);
    @memcpy(out[0..n], id[0..n]);
    return .{ .id = out[0..n] };
}

/// Mint a NEW id, replacing any existing one. The only resolution for a
/// collision (C-COLLISION): two machines hold one id because a disk image
/// was copied or a backup restored, and renaming cannot fix it because the
/// label and the id are deliberately independent.
pub fn remint(out: []u8, suggested_label: ?[]const u8) ?[]const u8 {
    var lbuf: [128]u8 = undefined;
    var hbuf: [256]u8 = undefined;
    var prev: [128]u8 = undefined;
    // A RE-MINT IS THE DELIBERATE REPLACEMENT, so an unreadable file does
    // not stop it — replacing is what the operator asked for. It only
    // loses the old LABEL, which then comes from the host name.
    const previous: ?[]const u8 = switch (load(&prev)) {
        .found => |p| p,
        .none, .unreadable => null,
    };

    const raw = suggested_label orelse blk: {
        // Keep the existing LABEL by default: a re-mint resolves a
        // collision, and changing what the machine is called at the same
        // time would make the operator's own fleet harder to read.
        if (previous) |p| {
            if (mem.lastIndexOfScalar(u8, p, '-')) |dash| break :blk p[0..dash];
        }
        break :blk sys.hostName(&hbuf) orelse "host";
    };
    const label = federation.disciplineLabel(&lbuf, raw);

    var suffix: [federation.peer_suffix_len]u8 = undefined;
    var attempt: usize = 0;
    var idbuf: [128]u8 = undefined;
    var id: []const u8 = undefined;
    while (attempt < 8) : (attempt += 1) {
        mintSuffix(&suffix);
        id = federation.composePeerId(&idbuf, label, &suffix);
        // A re-mint that produced the same id would silently do nothing,
        // which is the one outcome the operator cannot detect.
        if (previous == null or !mem.eql(u8, id, previous.?)) break;
    }
    if (!write(id)) return null;
    const n = @min(id.len, out.len);
    @memcpy(out[0..n], id[0..n]);
    return out[0..n];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn scratch(buf: []u8, tag: []const u8) []const u8 {
    return @import("paths").tempFile(buf, "synapty-id-{s}-{d}.json", .{ tag, std.c.getpid() }).?;
}

test "ensure mints once and is stable across calls" {
    const io = io_mod.get();
    var pbuf: [256]u8 = undefined;
    const p = scratch(&pbuf, "mint");
    path_override = p;
    defer path_override = null;
    defer std.Io.Dir.cwd().deleteFile(io, p) catch {};
    std.Io.Dir.cwd().deleteFile(io, p) catch {};

    var a: [128]u8 = undefined;
    var b: [128]u8 = undefined;
    const first = ensure(&a, "RemoteHost").id;
    try testing.expect(federation.validPeerId(first));
    try testing.expect(mem.startsWith(u8, first, "remotehost-"));

    // A SUGGESTION, not an override: a second call with a different label
    // must return the existing identity untouched, because another party
    // may already be keying state on it.
    const second = ensure(&b, "something-else").id;
    try testing.expectEqualStrings(first, second);
}

test "a suggestion never overrides, and a hostname is only the default" {
    const io = io_mod.get();
    var pbuf: [256]u8 = undefined;
    const p = scratch(&pbuf, "suggest");
    path_override = p;
    defer path_override = null;
    defer std.Io.Dir.cwd().deleteFile(io, p) catch {};
    std.Io.Dir.cwd().deleteFile(io, p) catch {};

    var a: [128]u8 = undefined;
    // No suggestion: falls back to this machine's hostname, disciplined.
    const id = ensure(&a, null).id;
    try testing.expect(federation.validPeerId(id));
    try testing.expect(mem.indexOfScalar(u8, id, '@') == null);
}

test "remint changes the id and keeps the label" {
    const io = io_mod.get();
    var pbuf: [256]u8 = undefined;
    const p = scratch(&pbuf, "remint");
    path_override = p;
    defer path_override = null;
    defer std.Io.Dir.cwd().deleteFile(io, p) catch {};
    std.Io.Dir.cwd().deleteFile(io, p) catch {};

    var a: [128]u8 = undefined;
    var b: [128]u8 = undefined;
    const before = ensure(&a, "deskmac").id;
    const after = remint(&b, null).?;
    try testing.expect(!mem.eql(u8, before, after));
    // The label survives: a re-mint resolves a COLLISION, and renaming the
    // machine at the same time would make the operator's fleet harder to
    // read for no reason.
    try testing.expect(mem.startsWith(u8, after, "deskmac-"));
    // And it persisted — a re-mint that only lived in memory would leave
    // the collision in place after a restart.
    var c: [128]u8 = undefined;
    try testing.expectEqualStrings(after, load(&c).found);
}

test "an identity file that cannot be read is never minted over" {
    // THE DEFECT ([[WI-2026-09-23-002]]). Any failure to open the file
    // read as "no identity", and `ensure` wrote a fresh one over it —
    // replacing the name every peer keys its directory entries and its
    // spooled mail on, because this process could not look.
    const io = io_mod.get();
    var pbuf: [256]u8 = undefined;
    const p = scratch(&pbuf, "unreadable");
    path_override = p;
    defer path_override = null;
    defer std.Io.Dir.cwd().deleteFile(io, p) catch {};

    const original = "{\"peer_id\":\"deskmac-1a2b\"}\n";
    {
        var f = try std.Io.Dir.cwd().createFile(io, p, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, original);
    }
    var zbuf: [256]u8 = undefined;
    const pz = try std.fmt.bufPrintZ(&zbuf, "{s}", .{p});
    // UNREADABLE BY ITS OWNER, which is as close to "the file is there
    // and cannot be read" as a test can get without root.
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(pz.ptr, 0o000));
    defer _ = std.c.chmod(pz.ptr, 0o600);

    var a: [128]u8 = undefined;
    try testing.expect(load(&a) == .unreadable);
    try testing.expect(ensure(&a, "otherhost") == .unreadable);

    _ = std.c.chmod(pz.ptr, 0o600);
    var rbuf: [256]u8 = undefined;
    const after = switch (readSmall(io, p, &rbuf)) {
        .content => |c| c,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings(original, after);
}

test "an absent identity file is still minted" {
    // AND THE OTHER HALF STAYS AS IT WAS: nothing there is the one case
    // that licenses a new name.
    const io = io_mod.get();
    var pbuf: [256]u8 = undefined;
    const p = scratch(&pbuf, "absent");
    path_override = p;
    defer path_override = null;
    defer std.Io.Dir.cwd().deleteFile(io, p) catch {};
    std.Io.Dir.cwd().deleteFile(io, p) catch {};

    var a: [128]u8 = undefined;
    try testing.expect(load(&a) == .none);
    const id = ensure(&a, "deskmac").id;
    try testing.expect(federation.validPeerId(id));
}

test "a corrupt or invalid identity file is treated as absent" {
    const io = io_mod.get();
    var pbuf: [256]u8 = undefined;
    const p = scratch(&pbuf, "corrupt");
    path_override = p;
    defer path_override = null;
    defer std.Io.Dir.cwd().deleteFile(io, p) catch {};

    {
        var f = try std.Io.Dir.cwd().createFile(io, p, .{});
        defer f.close(io);
        // An id with '@' in it must not be honoured: it would break the
        // qualifier split every peer performs.
        try f.writeStreamingAll(io, "{\"peer_id\":\"bad@id\"}\n");
    }
    var a: [128]u8 = undefined;
    try testing.expect(load(&a) == .none);
    // ensure() then mints a good one over it rather than refusing to run.
    const id = ensure(&a, "deskmac").id;
    try testing.expect(federation.validPeerId(id));
}
