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

/// Read the persisted peer id, or null when this machine has not minted
/// one yet. Copies into `out` and returns the slice.
pub fn load(out: []u8) ?[]const u8 {
    const io = io_mod.get();
    var pbuf: [1024]u8 = undefined;
    const path = identityPath(&pbuf) orelse return null;
    var rbuf: [512]u8 = undefined;
    const content = readSmall(io, path, &rbuf) orelse return null;
    const needle = "\"peer_id\":\"";
    const at = mem.indexOf(u8, content, needle) orelse return null;
    const start = at + needle.len;
    const end = mem.indexOfScalarPos(u8, content, start, '"') orelse return null;
    const id = content[start..end];
    if (!federation.validPeerId(id)) return null;
    const n = @min(id.len, out.len);
    @memcpy(out[0..n], id[0..n]);
    return out[0..n];
}

fn readSmall(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    @memset(buf, 0);
    _ = f.readPositionalAll(io, buf, 0) catch {};
    const len = mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    if (len == 0) return null;
    return buf[0..len];
}

fn write(id: []const u8) bool {
    const io = io_mod.get();
    var pbuf: [1024]u8 = undefined;
    const path = identityPath(&pbuf) orelse return false;
    if (std.fs.path.dirname(path)) |dir| {
        // Ignored on purpose: the directory usually exists, and
        // createDirPath fails for an existing top-level path. Only a
        // failure to create the FILE is a real failure.
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    var cbuf: [256]u8 = undefined;
    const content = std.fmt.bufPrint(&cbuf, "{{\"peer_id\":\"{s}\"}}\n", .{id}) catch return false;
    var out = std.Io.Dir.cwd().createFile(io, path, .{}) catch return false;
    defer out.close(io);
    out.writeStreamingAll(io, content) catch return false;
    var zbuf: [1024]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return false;
    _ = std.c.chmod(pz.ptr, 0o600);
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
pub fn ensure(out: []u8, suggested_label: ?[]const u8) ?[]const u8 {
    if (load(out)) |existing| return existing;

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
    return out[0..n];
}

/// Mint a NEW id, replacing any existing one. The only resolution for a
/// collision (C-COLLISION): two machines hold one id because a disk image
/// was copied or a backup restored, and renaming cannot fix it because the
/// label and the id are deliberately independent.
pub fn remint(out: []u8, suggested_label: ?[]const u8) ?[]const u8 {
    var lbuf: [128]u8 = undefined;
    var hbuf: [256]u8 = undefined;
    var prev: [128]u8 = undefined;
    const previous = load(&prev);

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
    const tmp = sys.getenv("TMPDIR") orelse "/tmp";
    return std.fmt.bufPrint(buf, "{s}synapty-id-{s}-{d}.json", .{ tmp, tag, std.c.getpid() }) catch unreachable;
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
    const first = ensure(&a, "RemoteHost").?;
    try testing.expect(federation.validPeerId(first));
    try testing.expect(mem.startsWith(u8, first, "remotehost-"));

    // A SUGGESTION, not an override: a second call with a different label
    // must return the existing identity untouched, because another party
    // may already be keying state on it.
    const second = ensure(&b, "something-else").?;
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
    const id = ensure(&a, null).?;
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
    const before = ensure(&a, "deskmac").?;
    const after = remint(&b, null).?;
    try testing.expect(!mem.eql(u8, before, after));
    // The label survives: a re-mint resolves a COLLISION, and renaming the
    // machine at the same time would make the operator's fleet harder to
    // read for no reason.
    try testing.expect(mem.startsWith(u8, after, "deskmac-"));
    // And it persisted — a re-mint that only lived in memory would leave
    // the collision in place after a restart.
    var c: [128]u8 = undefined;
    try testing.expectEqualStrings(after, load(&c).?);
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
    try testing.expect(load(&a) == null);
    // ensure() then mints a good one over it rather than refusing to run.
    const id = ensure(&a, "deskmac").?;
    try testing.expect(federation.validPeerId(id));
}
