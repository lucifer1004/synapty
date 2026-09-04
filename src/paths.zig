const std = @import("std");
const sys = @import("sys");
const mem = std.mem;

// ---------------------------------------------------------------------------
// Config paths, classified by LIFETIME — WI-2026-08-13-003
//
// Two kinds of state, separated by lifetime. Mixing them in one
// directory is harmless only while nothing syncs it:
//
//   SHARED  — the human's intent, identical on every machine they own:
//             hosts, the task-centre repo, appearance. Safe to replicate.
//   MACHINE — this machine and nothing else: its minted peer id, its hub's
//             discovery entry and durable state, its window layout.
//
// The split exists because the natural sync operation is "sync the config
// directory", and under the old flat layout that operation replicated
// identity.json. [[RFC-0010]] C-COLLISION names a copied disk image or a
// restored backup as one of exactly two ways two machines end up holding
// one peer id; the remedy is a manual re-mint and the symptom is that
// every message between those machines is misrouted. A directory sync is
// that scenario automated and running continuously.
//
// So the point is not that the files moved. It is that the SAFE thing is
// now the OBVIOUS thing: `shared/` is a complete, self-contained, portable
// unit, and it cannot reach `machine/` because they are siblings. Nobody
// has to remember which file is which.
// ---------------------------------------------------------------------------

pub const Kind = enum {
    /// Replicable across a human's machines.
    shared,
    /// This machine only. Copying it is a defect, not a convenience.
    machine,
};

/// Test hook: override the config root so a test never writes the real one.
/// The same discipline `--discovery-path` and `--identity-path` exist for,
/// and for the same reason — this project has clobbered a real hosts.json
/// and renamed a real machine from a test before.
pub var root_override: ?[]const u8 = null;

/// THE SAME ROOT THE WORKBENCH USES, including the variable it honours.
///
/// `SYNAPTY_CONFIG_ROOT` exists so a dev launch or a UI test writes
/// somewhere other than the config the operator actually uses
/// ([[ConfigPaths]]). The Swift side read it and this one did not, which
/// was harmless only while nothing here wrote per-session state: a test
/// pointed at a scratch root started panes whose session records landed
/// in the REAL directory, where they outlived the test and accumulated.
///
/// ABSOLUTE OR IGNORED, for the reason the Swift side gives: a relative
/// path resolves against a bundled application's working directory, which
/// is `/`, so a typo would build a config tree at the root of the disk
/// rather than fail.
fn root(buf: []u8) ?[]const u8 {
    if (root_override) |r| return r;
    if (sys.getenv("SYNAPTY_CONFIG_ROOT")) |raw| {
        if (raw.len > 0 and raw[0] == '/') return std.fmt.bufPrint(buf, "{s}", .{raw}) catch null;
    }
    const home = sys.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/synapty", .{home}) catch null;
}

/// Absolute path to a file of the given lifetime.
pub fn resolve(buf: []u8, kind: Kind, name: []const u8) ?[]const u8 {
    var rbuf: [1024]u8 = undefined;
    const r = root(&rbuf) orelse return null;
    const dir = switch (kind) {
        .shared => "shared",
        .machine => "machine",
    };
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ r, dir, name }) catch null;
}

/// The directory a sync layer may replicate WHOLESALE. Nothing machine
/// scoped is reachable from it; that is the property the split buys and
/// the one the guard test pins.
pub fn sharedDir(buf: []u8) ?[]const u8 {
    var rbuf: [1024]u8 = undefined;
    const r = root(&rbuf) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/shared", .{r}) catch null;
}

pub fn machineDir(buf: []u8) ?[]const u8 {
    var rbuf: [1024]u8 = undefined;
    const r = root(&rbuf) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/machine", .{r}) catch null;
}

/// WHERE THE SESSIONS ON THIS MACHINE ARE RECORDED ([[RFC-0014]] C-SCOPE).
///
/// MACHINE-SCOPED, like the hub's state and this machine's identity: a
/// record names a process on THIS host, and replicating it onto another
/// Mac would offer that machine a session it cannot reach.
///
/// A DIRECTORY WE OWN, which is the point rather than a detail. A session
/// used to be findable only through its socket in `/tmp` — a directory the
/// operating system is free to sweep and any user is free to empty. What
/// was lost with it was not a convenience: the holder and its child went
/// on running with nothing able to name them, so they could be neither
/// listed nor ended.
pub fn sessionsDir(buf: []u8) ?[]const u8 {
    var rbuf: [1024]u8 = undefined;
    const r = root(&rbuf) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/machine/sessions", .{r}) catch null;
}

// -- The classification itself ---------------------------------------------
//
// Named entries rather than free-form strings, so the classification is a
// fact in one place instead of a decision each caller makes.

pub const github_config: Entry = .{ .kind = .shared, .name = "config.toml" };
pub const settings: Entry = .{ .kind = .shared, .name = "settings.json" };
pub const ghostty_config: Entry = .{ .kind = .shared, .name = "ghostty.conf" };

pub const identity: Entry = .{ .kind = .machine, .name = "identity.json" };
pub const discovery: Entry = .{ .kind = .machine, .name = "hub.json" };
pub const hub_state: Entry = .{ .kind = .machine, .name = "hub-state.json" };
pub const session: Entry = .{ .kind = .machine, .name = "session.json" };
/// A log is EVIDENCE ABOUT THIS MACHINE, so it is machine-scoped for the
/// same reason hub-state is: replicating it onto another Mac would present
/// one machine's failures as the other's.
pub const hub_log: Entry = .{ .kind = .machine, .name = "hub.log" };

pub const Entry = struct {
    kind: Kind,
    name: []const u8,

    pub fn path(self: Entry, buf: []u8) ?[]const u8 {
        return resolve(buf, self.kind, self.name);
    }
};

/// Every classified entry, for the guard test and for migration.
///
/// DERIVED, NOT LISTED. Written out by hand this was a second copy of the
/// classification, and the guard below only guards what it names — so an
/// entry added above and forgotten here would be unclassified and
/// unguarded at once, which is the failure the guard exists to prevent.
/// The Swift side had the same two lists and the same omission, and there
/// it reached the data being synced.
pub const all = blk: {
    const decls = @typeInfo(@This()).@"struct".decls;
    var list: [decls.len]Entry = undefined;
    var n: usize = 0;
    for (decls) |d| {
        // ITSELF EXCEPTED, because reading its own type to decide whether
        // to include it is a definition that depends on itself.
        if (std.mem.eql(u8, d.name, "all")) continue;
        if (@TypeOf(@field(@This(), d.name)) == Entry) {
            list[n] = @field(@This(), d.name);
            n += 1;
        }
    }
    const frozen = list[0..n].*;
    break :blk frozen;
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the shared directory cannot reach anything machine-scoped" {
    // THE GUARD. The mistake this WI exists to prevent is a FUTURE one:
    // somebody writes "sync the shared directory" and a machine-scoped
    // file is sitting inside it. This test fails if that ever becomes
    // true, which is the only way the property outlives the change that
    // established it.
    root_override = "/tmp/synapty-paths-test";
    defer root_override = null;

    var sbuf: [512]u8 = undefined;
    const shared = sharedDir(&sbuf).?;

    for (all) |entry| {
        var pbuf: [512]u8 = undefined;
        const p = entry.path(&pbuf).?;
        switch (entry.kind) {
            .shared => try testing.expect(mem.startsWith(u8, p, shared)),
            .machine => try testing.expect(!mem.startsWith(u8, p, shared)),
        }
    }
}

test "identity is machine-scoped, and that is the whole point" {
    // Stated as its own assertion because it is the one whose
    // misclassification has a named consequence: RFC-0010 C-COLLISION,
    // two machines holding one peer id, every message between them
    // misrouted, remedied only by a manual re-mint.
    try testing.expectEqual(Kind.machine, identity.kind);
    try testing.expectEqual(Kind.machine, discovery.kind);
    try testing.expectEqual(Kind.machine, hub_state.kind);
    try testing.expectEqual(Kind.machine, session.kind);
}

test "the shared set is what a human would expect to find on a new Mac" {
    try testing.expectEqual(Kind.shared, github_config.kind);
    try testing.expectEqual(Kind.shared, settings.kind);
    try testing.expectEqual(Kind.shared, ghostty_config.kind);
}

test "an override keeps a test off the real config root" {
    root_override = "/tmp/synapty-paths-test";
    defer root_override = null;
    var buf: [512]u8 = undefined;
    const p = identity.path(&buf).?;
    try testing.expect(mem.startsWith(u8, p, "/tmp/synapty-paths-test"));
    try testing.expect(mem.indexOf(u8, p, "/machine/identity.json") != null);
}

/// Move a file from the old flat layout into its classified home, once.
/// Returns true if something moved.
///
/// Migration is a RENAME and never a copy: a copy would leave identity.json
/// readable at the old path, which is exactly the file whose duplication
/// this split exists to prevent. Half a migration must not leave the
/// landmine armed.
pub fn migrateOne(entry: Entry) bool {
    var rbuf: [1024]u8 = undefined;
    const r = root(&rbuf) orelse return false;
    var oldbuf: [1200]u8 = undefined;
    const old = std.fmt.bufPrint(&oldbuf, "{s}/{s}", .{ r, entry.name }) catch return false;
    var newbuf: [1200]u8 = undefined;
    const new = entry.path(&newbuf) orelse return false;

    var oldz: [1201]u8 = undefined;
    var newz: [1201]u8 = undefined;
    const oz = std.fmt.bufPrintZ(&oldz, "{s}", .{old}) catch return false;
    const nz = std.fmt.bufPrintZ(&newz, "{s}", .{new}) catch return false;

    // Present at the destination already? Then a previous run finished and
    // the destination is what everything now reads, so the legacy file is
    // SUPERSEDED. Remove it rather than leaving it: a stale identity.json
    // sitting at the old flat path is precisely the artefact this split
    // exists to prevent from ever being replicated, and "it is only
    // reachable if someone syncs the root" is the kind of only that stops
    // being true. Observed for real — an older build ran once after a
    // migration and recreated two of these.
    if (std.c.access(nz.ptr, 0) == 0) {
        if (std.c.access(oz.ptr, 0) == 0) _ = std.c.unlink(oz.ptr);
        return false;
    }
    if (std.c.access(oz.ptr, 0) != 0) return false;
    return std.c.rename(oz.ptr, nz.ptr) == 0;
}

/// Create both roots and move anything found at the old flat paths.
/// Idempotent; safe to call on every start.
pub fn migrate() void {
    const io = @import("io").get();
    var sbuf: [1024]u8 = undefined;
    var mbuf: [1024]u8 = undefined;
    if (sharedDir(&sbuf)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    if (machineDir(&mbuf)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    for (all) |entry| _ = migrateOne(entry);
}

test "migration moves rather than copies, and is idempotent" {
    // A rename, never a copy — migrateOne's doc says why.
    const io = @import("io").get();
    var rbuf: [256]u8 = undefined;
    const scratch = try std.fmt.bufPrint(&rbuf, "/tmp/synapty-migrate-{d}", .{std.c.getpid()});
    root_override = scratch;
    defer root_override = null;
    try std.Io.Dir.cwd().createDirPath(io, scratch);
    // A SCRATCH ROOT IS SWEPT UP AFTER, like the socket sweep's is
    // ([[run.zig]] "the sweep only judges files it owns"). Without this
    // the pid in the name made every run leak a fresh tree, and 1598 of
    // them were counted in /tmp before anyone looked ([[WI-2026-09-03-008]]).
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};

    var legacy_buf: [512]u8 = undefined;
    const legacy = try std.fmt.bufPrintZ(&legacy_buf, "{s}/identity.json", .{scratch});
    {
        var f = try std.Io.Dir.cwd().createFile(io, legacy, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "{\"peer_id\":\"deskmac-2630\"}\n");
    }

    migrate();

    // Gone from the old place...
    try testing.expect(std.c.access(legacy.ptr, 0) != 0);
    // ...and present in the machine-scoped one.
    var newbuf: [512]u8 = undefined;
    const moved = identity.path(&newbuf).?;
    var nz: [513]u8 = undefined;
    const movedz = try std.fmt.bufPrintZ(&nz, "{s}", .{moved});
    try testing.expectEqual(@as(c_int, 0), std.c.access(movedz.ptr, 0));

    // Idempotent: a second run finds nothing to do and breaks nothing.
    migrate();
    try testing.expectEqual(@as(c_int, 0), std.c.access(movedz.ptr, 0));
}

test "a superseded legacy file is removed, not left at the old flat path" {
    // The case that actually happened: an older build ran once after a
    // migration and wrote identity.json back to the root. The destination
    // is what everything reads, so the root copy is superseded — and a
    // stale identity at the old path is the exact artefact this split
    // exists to keep out of any future replication.
    const io = @import("io").get();
    var rbuf: [256]u8 = undefined;
    const scratch = try std.fmt.bufPrint(&rbuf, "/tmp/synapty-supersede-{d}", .{std.c.getpid()});
    root_override = scratch;
    defer root_override = null;
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    var mbuf: [512]u8 = undefined;
    try std.Io.Dir.cwd().createDirPath(io, machineDir(&mbuf).?);

    // Destination present (current), legacy present (stale).
    var dbuf: [512]u8 = undefined;
    const dest = identity.path(&dbuf).?;
    var dz: [513]u8 = undefined;
    const destz = try std.fmt.bufPrintZ(&dz, "{s}", .{dest});
    {
        var f = try std.Io.Dir.cwd().createFile(io, destz, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "{\"peer_id\":\"current-0001\"}\n");
    }
    var lbuf: [512]u8 = undefined;
    const legacy = try std.fmt.bufPrintZ(&lbuf, "{s}/identity.json", .{scratch});
    {
        var f = try std.Io.Dir.cwd().createFile(io, legacy, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "{\"peer_id\":\"stale-9999\"}\n");
    }

    migrate();

    // The stale one is gone...
    try testing.expect(std.c.access(legacy.ptr, 0) != 0);
    // ...and the current one is untouched, not overwritten by the stale.
    var read_buf: [256]u8 = undefined;
    var f = try std.Io.Dir.cwd().openFile(io, destz, .{});
    defer f.close(io);
    @memset(&read_buf, 0);
    _ = f.readPositionalAll(io, &read_buf, 0) catch {};
    try testing.expect(mem.indexOf(u8, &read_buf, "current-0001") != null);
}

test "every classified entry is in the list the guard reads" {
    // NOT A COUNT WRITTEN OUT BY HAND, which would be the same second copy
    // one layer along. The point is that adding a `pub const … : Entry`
    // above cannot leave it unguarded, so what this asserts is that each
    // named entry is FOUND in the derived list.
    inline for (.{ github_config, settings, ghostty_config, identity, discovery, hub_state, session, hub_log }) |named| {
        var found = false;
        for (all) |e| {
            if (e.kind == named.kind and std.mem.eql(u8, e.name, named.name)) found = true;
        }
        try testing.expect(found);
    }
    // And nothing else got in: every derived entry is one of the names.
    try testing.expectEqual(@as(usize, 8), all.len);
}
