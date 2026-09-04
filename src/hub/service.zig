//! Running a hub AS A SERVICE: port selection, the discovery file, and
//! the supervision lifecycle.
//!
//! [[ADR-0008]]: every machine that hosts agents runs a hub, and agents
//! always connect to their own machine's over loopback. Two supervision
//! contracts share this one implementation:
//!
//!   - SUPERVISED (a workbench spawned it): --parent-pid ties the hub's
//!     lifetime to that workbench. Parent death starts a grace window
//!     rather than an immediate exit, so a workbench RESTART can reclaim
//!     the same hub; nobody reclaims it, it exits. Orphans are bounded
//!     by the window instead of being possible.
//!   - SERVICE (a machine hosting detached agents): no --parent-pid, so
//!     the hub outlives every workbench connection. This is what lets a
//!     remote agent stay reachable while the operator's laptop is off.
//!
//! Port policy and the discovery file are inherited unchanged from the
//! embedded-hub era (ADR-0006, since superseded by ADR-0007 and then by
//! ADR-0008 above — named here as provenance, not as authority: they
//! were independent of the process boundary and survived the move):
//! default port with a sequential ladder, SYNAPTY_HUB_PORT as
//! the only override, and ~/.config/synapty/machine/hub.json as the
//! local out-of-process contract for bare CLIs.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io");
const sys = @import("sys");
const server_mod = @import("server.zig");
const HubServer = server_mod.HubServer;
const log = @import("diag").scoped(.hub);

/// Rungs tried before the ephemeral fallback: preferred .. preferred+9.
pub const ladder_len: u16 = 10;
pub const default_port: u16 = 9000;

/// How long a supervised hub waits for a supervisor to come back before
/// exiting. Long enough for a workbench relaunch to reclaim it, short
/// enough that a forgotten hub is not a lasting orphan.
pub const default_grace_secs: u32 = 30;

pub const Options = struct {
    port: u16 = default_port,
    /// Bind exactly `port` or fail (the SYNAPTY_HUB_PORT escape hatch).
    strict: bool = false,
    /// Workbench pid to tie our lifetime to; null = service mode.
    parent_pid: ?i32 = null,
    grace_secs: u32 = default_grace_secs,
};

/// Bind a listener using the ladder: preferred, preferred+1..+9, then an
/// OS-assigned ephemeral port. `strict` binds exactly the preferred port
/// or fails — an explicit request must not be silently redirected.
pub fn bindWithLadder(opts: Options) !HubServer {
    const total: u16 = if (opts.strict) 1 else ladder_len + 1;
    var attempt: u16 = 0;
    while (attempt < total) : (attempt += 1) {
        const p: u16 = if (opts.strict)
            opts.port
        else if (attempt < ladder_len)
            opts.port +| attempt
        else
            0; // last rung: let the kernel choose
        return HubServer.initWithAddress("127.0.0.1", p) catch |err| switch (err) {
            error.AddressInUse => continue,
            else => return err,
        };
    }
    return error.AddressInUse;
}

// ---------------------------------------------------------------------------
// Discovery file (~/.config/synapty/machine/hub.json)
// ---------------------------------------------------------------------------

/// Test hook: absolute discovery-file path override. Tests MUST set this
/// so they never touch the real ~/.config, which holds the operator's
/// own state.
pub var discovery_path_override: ?[]const u8 = null;

fn discoveryPath(buf: []u8) ?[]const u8 {
    if (discovery_path_override) |p| return p;
    return @import("paths").discovery.path(buf);
}

/// Best effort: the discovery file is a convenience contract for bare
/// CLIs, never a startup blocker.
pub fn writeDiscovery(port: u16, build_id: []const u8) void {
    const io = io_mod.get();
    var pbuf: [1024]u8 = undefined;
    const path = discoveryPath(&pbuf) orelse return;
    if (std.fs.path.dirname(path)) |dir_path| {
        // The error is IGNORED on purpose: the directory usually already
        // exists, and createDirPath fails for an existing top-level path
        // like /tmp. Returning here would leave a hub publishing NOTHING
        // while every reader concludes no hub is running — silently,
        // since the whole function is best-effort. Only failing to create
        // the FILE is a real failure, and that is checked below.
        std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
    }
    var cbuf: [256]u8 = undefined;
    const content = std.fmt.bufPrint(
        &cbuf,
        "{{\"port\":{d},\"pid\":{d},\"build\":\"{s}\"}}\n",
        .{ port, std.c.getpid(), build_id },
    ) catch return;
    var out = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer out.close(io);
    out.writeStreamingAll(io, content) catch return;
    var zbuf: [1024]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return;
    _ = std.c.chmod(path_z.ptr, 0o600);
}

/// Remove the discovery file — but ONLY when this process wrote it.
/// Another machine's workbench (or another instance) must keep its own.
pub fn removeDiscovery() void {
    const io = io_mod.get();
    var pbuf: [1024]u8 = undefined;
    const path = discoveryPath(&pbuf) orelse return;
    var rbuf: [512]u8 = undefined;
    const content = readSmallFile(io, path, &rbuf) orelse return;
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"pid\":{d}", .{std.c.getpid()}) catch return;
    if (std.mem.indexOf(u8, content, needle) == null) return;
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

pub fn readSmallFile(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var reader = f.reader(io, buf);
    const n = reader.interface.readSliceShort(buf) catch return null;
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// Supervision (parent-death watch + lease grace)
// ---------------------------------------------------------------------------

/// Shared state between the watchdog thread and the hub's supervisor
/// connections. `supervisors` is the count of live workbench supervisor
/// links; the watchdog only exits when the grace window elapses with
/// none present.
pub const Supervision = struct {
    /// Set once the watched parent is gone.
    parent_gone: bool = false,
    /// Live supervisor connections (workbench links).
    supervisors: u32 = 0,
    mutex: std.Io.Mutex = .init,

    pub fn supervisorAttached(self: *Supervision) void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        self.supervisors += 1;
    }

    pub fn supervisorDetached(self: *Supervision) void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        if (self.supervisors > 0) self.supervisors -= 1;
    }

    pub fn supervisorCount(self: *Supervision) u32 {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        return self.supervisors;
    }
};

/// Should a supervised hub exit now? Pure decision so the policy is
/// testable without spawning processes: exit only when the watched
/// parent is gone AND the grace window has elapsed AND no supervisor
/// reclaimed us in the meantime.
pub fn shouldExit(parent_gone: bool, supervisors: u32, elapsed_secs: u64, grace_secs: u32) bool {
    if (!parent_gone) return false;
    if (supervisors > 0) return false; // reclaimed by a (re)connected workbench
    return elapsed_secs >= grace_secs;
}

/// The supervision countdown as an explicit state machine, so the
/// RE-ARMING behaviour is testable rather than hidden in a thread loop.
///
/// This exists because the first live test found the hole: the original
/// loop RETURNED after a reclaim, on the assumption that "the new
/// supervisor has its own watch". That assumption is false — a
/// reclaiming workbench did not spawn this hub, so it passed no
/// --parent-pid and established no watch. The hub stayed up forever
/// after the reclaimer left: precisely the orphan the design exists to
/// prevent. The rule is therefore continuous, not one-shot: a supervised
/// hub exits whenever it has been WITHOUT A SUPERVISOR for the grace
/// window, however many times it is reclaimed in between.
pub const SupervisionClock = struct {
    idle_secs: u64 = 0,
    grace_secs: u32,

    pub const Tick = enum {
        /// Keep serving; the window has not elapsed.
        keep_running,
        /// A supervisor is present — the countdown reset this tick.
        reclaimed,
        /// No supervisor for the whole window: shut down.
        exit_now,
    };

    pub fn tick(self: *SupervisionClock, parent_gone: bool, supervisors: u32) Tick {
        if (supervisors > 0) {
            const was_counting = self.idle_secs > 0;
            self.idle_secs = 0;
            return if (was_counting) .reclaimed else .keep_running;
        }
        if (shouldExit(parent_gone, supervisors, self.idle_secs, self.grace_secs)) {
            return .exit_now;
        }
        if (parent_gone) self.idle_secs += 1;
        return .keep_running;
    }
};

/// Watchdog thread body for a SUPERVISED hub. Blocks until the parent
/// exits (kqueue, no polling), then polls the grace window at 1s so a
/// reconnecting workbench can reclaim the hub. Never returns while the
/// hub should keep running.
pub fn watchParent(sup: *Supervision, parent_pid: i32, grace_secs: u32) void {
    if (!sys.waitForPidExit(parent_pid)) {
        // Watchdog unavailable (non-macOS, or the watch could not be
        // established). Fall back to polling — a missing watchdog must
        // never be read as "the parent is alive forever".
        while (sys.pidAlive(parent_pid)) {
            io_mod.get().sleep(std.Io.Duration.fromMilliseconds(1000), .awake) catch {};
        }
    }
    {
        sup.mutex.lock(io_mod.get()) catch unreachable;
        sup.parent_gone = true;
        sup.mutex.unlock(io_mod.get());
    }
    log.info("supervising workbench {d} exited; grace {d}s before shutdown", .{ parent_pid, grace_secs });

    // Continuous, never one-shot: a reclaim resets the countdown but does
    // NOT end supervision, because the reclaiming workbench established
    // no watch of its own. parent_gone stays true for the rest of this
    // process's life — from here on, "has a supervisor" is the lifeline.
    var clock = SupervisionClock{ .grace_secs = grace_secs };
    while (true) {
        switch (clock.tick(true, sup.supervisorCount())) {
            .exit_now => {
                log.info("no workbench for {d}s — exiting", .{grace_secs});
                removeDiscovery();
                std.process.exit(0);
            },
            .reclaimed => log.info("workbench reclaimed the hub — shutdown cancelled", .{}),
            .keep_running => {},
        }
        io_mod.get().sleep(std.Io.Duration.fromMilliseconds(1000), .awake) catch {};
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "port ladder skips an occupied rung; strict refuses to walk" {
    std.testing.log_level = .err;
    var blocker = try HubServer.initWithAddress("127.0.0.1", 0);
    defer blocker.deinit();
    const base = blocker.bound_port;

    // Strict on an occupied port fails rather than silently landing
    // somewhere the caller did not ask for.
    try std.testing.expectError(
        error.AddressInUse,
        bindWithLadder(.{ .port = base, .strict = true }),
    );

    var next = try bindWithLadder(.{ .port = base });
    defer next.deinit();
    try std.testing.expectEqual(base + 1, next.bound_port);
}

test "discovery file round-trips and is removed only by its writer" {
    std.testing.log_level = .err;
    const io = io_mod.get();
    var path_buf: [256]u8 = undefined;
    const tmp = sys.getenv("TMPDIR") orelse "/tmp";
    const scratch = try std.fmt.bufPrint(&path_buf, "{s}synapty-svc-test-{d}.json", .{ tmp, std.c.getpid() });
    discovery_path_override = scratch;
    defer discovery_path_override = null;
    defer std.Io.Dir.cwd().deleteFile(io, scratch) catch {};

    writeDiscovery(9317, "testbuild");
    var rbuf: [512]u8 = undefined;
    const content = readSmallFile(io, scratch, &rbuf).?;
    try std.testing.expect(std.mem.indexOf(u8, content, "\"port\":9317") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "testbuild") != null);

    // A foreign instance's file survives our removal attempt.
    {
        var out = try std.Io.Dir.cwd().createFile(io, scratch, .{});
        defer out.close(io);
        try out.writeStreamingAll(io, "{\"port\":9001,\"pid\":1,\"build\":\"other\"}\n");
    }
    removeDiscovery();
    var rbuf2: [512]u8 = undefined;
    try std.testing.expect(readSmallFile(io, scratch, &rbuf2) != null);

    // Ours is removed.
    writeDiscovery(9317, "testbuild");
    removeDiscovery();
    var rbuf3: [512]u8 = undefined;
    try std.testing.expect(readSmallFile(io, scratch, &rbuf3) == null);
}

test "shouldExit: orphan bounded by grace, reclaim cancels it" {
    // Parent alive: never exit, however long we have been running.
    try std.testing.expect(!shouldExit(false, 0, 9999, 30));
    // Parent gone but a workbench reclaimed us: never exit.
    try std.testing.expect(!shouldExit(true, 1, 9999, 30));
    // Parent gone, nobody reclaimed, still inside the window: wait.
    try std.testing.expect(!shouldExit(true, 0, 29, 30));
    // Parent gone, nobody reclaimed, window elapsed: exit — this is the
    // bound that makes an orphaned hub impossible.
    try std.testing.expect(shouldExit(true, 0, 30, 30));
    // Zero grace = exit as soon as the parent is gone.
    try std.testing.expect(shouldExit(true, 0, 0, 0));
}

test "SupervisionClock re-arms after a reclaim (the live-test hole)" {
    // Regression for the defect the first live run exposed: the loop used
    // to RETURN after a reclaim, leaving the hub unsupervised forever
    // once the reclaimer disconnected — an orphan by another route.
    var clock = SupervisionClock{ .grace_secs = 3 };

    // Parent gone, nobody watching: the countdown runs.
    try std.testing.expectEqual(SupervisionClock.Tick.keep_running, clock.tick(true, 0));
    try std.testing.expectEqual(SupervisionClock.Tick.keep_running, clock.tick(true, 0));

    // A workbench reclaims — countdown resets and we say so.
    try std.testing.expectEqual(SupervisionClock.Tick.reclaimed, clock.tick(true, 1));
    try std.testing.expectEqual(@as(u64, 0), clock.idle_secs);
    // While it stays connected we simply keep running (no repeat noise).
    try std.testing.expectEqual(SupervisionClock.Tick.keep_running, clock.tick(true, 1));

    // It leaves again: supervision must RE-ARM, not stay cancelled.
    try std.testing.expectEqual(SupervisionClock.Tick.keep_running, clock.tick(true, 0));
    try std.testing.expectEqual(SupervisionClock.Tick.keep_running, clock.tick(true, 0));
    try std.testing.expectEqual(SupervisionClock.Tick.keep_running, clock.tick(true, 0));
    try std.testing.expectEqual(SupervisionClock.Tick.exit_now, clock.tick(true, 0));
}

test "SupervisionClock never counts down while the parent lives" {
    var clock = SupervisionClock{ .grace_secs = 1 };
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expectEqual(SupervisionClock.Tick.keep_running, clock.tick(false, 0));
    }
    try std.testing.expectEqual(@as(u64, 0), clock.idle_secs);
}

test "Supervision counts attach/detach without underflowing" {
    var sup = Supervision{};
    try std.testing.expectEqual(@as(u32, 0), sup.supervisorCount());
    sup.supervisorAttached();
    sup.supervisorAttached();
    try std.testing.expectEqual(@as(u32, 2), sup.supervisorCount());
    sup.supervisorDetached();
    try std.testing.expectEqual(@as(u32, 1), sup.supervisorCount());
    sup.supervisorDetached();
    sup.supervisorDetached(); // extra detach must not wrap around
    try std.testing.expectEqual(@as(u32, 0), sup.supervisorCount());
}

// ---------------------------------------------------------------------------
// Idempotent ensure-running — [[ADR-0008]] stage 3b (WI-2026-08-12-008)
//
// A machine that hosts agents runs a hub, and on a REMOTE machine nobody is
// around to start it: the workbench is on the laptop, and the human is not
// going to ssh in after every server reboot. So the deploy path asks the
// binary itself to guarantee one is running.
//
// Idempotence here has to mean "one hub per machine", which the port ladder
// alone does NOT give — a second `synapty hub` would happily bind port 9001
// and the machine would then have two hubs, two directories and two
// mailboxes for the same agents. So this PROBES first and only spawns when
// the probe fails.
// ---------------------------------------------------------------------------

pub const EnsureResult = struct {
    port: u16,
    pid: i32,
    /// The running hub's federation id, copied into `peer_id_buf`.
    peer_id_buf: [64]u8 = undefined,
    peer_id_len: usize = 0,
    /// False when an existing hub answered — the idempotent case, and the
    /// normal one on every connect after the first.
    started: bool,
};

/// Read the discovery file and confirm a LIVE hub is behind it. Three
/// checks, because each catches a different lie: the file may be stale
/// (pid dead), the pid may have been reused by an unrelated process, and
/// the port may be held by something that is not a hub at all.
pub fn probeRunning() ?EnsureResult {
    const io = io_mod.get();
    var pbuf: [1024]u8 = undefined;
    const path = discoveryPath(&pbuf) orelse return null;
    var rbuf: [512]u8 = undefined;
    const content = readSmallFile(io, path, &rbuf) orelse return null;

    const port = parseJsonU16(content, "port") orelse return null;
    const pid: i32 = @intCast(parseJsonU16(content, "pid") orelse 0);
    // A pid over 65535 is normal on Linux; fall back to a wider parse.
    const real_pid = parseJsonI64(content, "pid") orelse pid;
    if (real_pid <= 0) return null;
    if (!sys.pidAlive(@intCast(real_pid))) return null;
    var id_buf: [64]u8 = undefined;
    const id_len = hubInfoPeerId(port, &id_buf) orelse return null;
    var result: EnsureResult = .{ .port = port, .pid = @intCast(real_pid), .started = false };
    result.peer_id_len = id_len;
    @memcpy(result.peer_id_buf[0..id_len], id_buf[0..id_len]);
    return result;
}

fn parseJsonU16(text: []const u8, key: []const u8) ?u16 {
    const v = parseJsonI64(text, key) orelse return null;
    return std.math.cast(u16, v);
}

fn parseJsonI64(text: []const u8, key: []const u8) ?i64 {
    var kbuf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&kbuf, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, text, needle) orelse return null;
    var i = at + needle.len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    const start = i;
    while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == '-')) i += 1;
    if (i == start) return null;
    return std.fmt.parseInt(i64, text[start..i], 10) catch null;
}

/// Ask the listener who it is, and copy back its peer id. null = not a
/// hub we understand. A port being open is NOT evidence a hub is behind
/// it — the version-skew incident behind [[ADR-0008]] started with a
/// workbench trusting an open port.
fn hubInfoPeerId(port: u16, out: []u8) ?usize {
    const fd = sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0) catch return null;
    defer sys.close(fd);
    const addr4 = std.Io.net.Ip4Address.loopback(port);
    const sa = sys.sockaddr_in.init(@bitCast(addr4.bytes), port);
    sys.connect(fd, &sa, @sizeOf(sys.sockaddr_in)) catch return null;
    const req =
        \\{"type":"hub_info","id":"ensure","source":"ensure","target":""}
    ;
    sys.writeAll(fd, req) catch return null;
    sys.writeAll(fd, "\n") catch return null;
    var tv = std.c.timeval{ .sec = 1, .usec = 0 };
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, &tv, @sizeOf(std.c.timeval));
    var buf: [2048]u8 = undefined;
    const n = sys.read(fd, &buf) catch return null;
    if (n == 0) return null;
    const body = buf[0..n];
    if (std.mem.indexOf(u8, body, "\"build\"") == null) return null;
    return copyJsonString(body, "peer_id", out) orelse 0;
}

fn copyJsonString(text: []const u8, key: []const u8, out: []u8) ?usize {
    var kbuf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&kbuf, "\"{s}\":\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, text, needle) orelse return null;
    const start = at + needle.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return null;
    const len = @min(end - start, out.len);
    @memcpy(out[0..len], text[start .. start + len]);
    return len;
}

/// Cap on the detached hub's log. Checked and truncated at each spawn,
/// which is the only moment a process is guaranteed to be between hubs.
pub const max_hub_log_bytes: i64 = 4 * 1024 * 1024;

/// Start a hub in its own SESSION; true when the fork succeeded. setsid is
/// the point, not a detail: without it the hub stays in
/// the SSH session's process group and the next disconnect SIGHUPs it —
/// which would make "runs as a service" a claim that survives exactly one
/// logout. Double-fork so the intermediate exits immediately and the hub
/// is reparented to init rather than left as a zombie for a process that
/// is about to exit anyway.
pub fn spawnDetached(exe_path: [*:0]const u8, extra: []const ?[*:0]const u8) bool {
    // Resolve and prepare the log path BEFORE the fork. Everything after
    // it runs between fork and exec, where only async-signal-safe calls
    // are legal — no allocation, no std.Io, no formatting into a heap
    // buffer.
    var logz_buf: [1200]u8 = undefined;
    const logz: ?[*:0]const u8 = blk: {
        var pbuf: [1024]u8 = undefined;
        const path = @import("paths").hub_log.path(&pbuf) orelse break :blk null;
        if (std.fs.path.dirname(path)) |d| {
            var dz: [1025]u8 = undefined;
            const dzs = std.fmt.bufPrintZ(&dz, "{s}", .{d}) catch break :blk null;
            _ = std.c.mkdir(dzs.ptr, 0o700);
        }
        const z = std.fmt.bufPrintZ(&logz_buf, "{s}", .{path}) catch break :blk null;
        // Bound it here, in the PARENT — before the fork, where normal
        // std.Io is still legal and truncation is safe and cheap. A hub on
        // a server runs for weeks, and an unbounded log fills the disk it
        // was meant to help diagnose.
        const io = io_mod.get();
        if (std.Io.Dir.cwd().openFile(io, path, .{})) |f| {
            var fh = f;
            defer fh.close(io);
            const size: i64 = if (fh.stat(io)) |st| @intCast(st.size) else |_| 0;
            // Delete rather than truncate: a fresh file per spawn is
            // more predictable than a half-file whose first line lands
            // mid-record, and the alternative (keep the tail) needs a
            // rewrite this does not earn.
            if (size > max_hub_log_bytes) std.Io.Dir.cwd().deleteFile(io, path) catch {};
        } else |_| {}
        break :blk z.ptr;
    };

    const first = std.c.fork();
    if (first < 0) return false;
    if (first > 0) {
        // Reap the intermediate; the grandchild is init's problem now.
        var status: c_int = 0;
        _ = std.c.waitpid(first, &status, 0);
        return true;
    }
    // Child: new session, then fork again and let this one exit.
    _ = std.c.setsid();
    const second = std.c.fork();
    // _exit, NOT exit: between fork and exec, exit() would run atexit
    // handlers and flush stdio buffers INHERITED FROM THE PARENT. Harmless
    // for today's caller (a single-threaded CLI with neither), and exactly
    // the kind of thing that becomes a corruption bug the day this is
    // called from the hub process itself.
    if (second != 0) std.c._exit(0);

    // Grandchild: detach stdio so the hub never writes into a terminal
    // that is about to go away — but send its DIAGNOSTICS to a file
    // rather than discarding them.
    //
    // /dev/null would be the wrong destination even though detaching is
    // right. The hubs reached through this path are precisely the ones
    // nobody can watch: a remote machine's hub, and any hub that
    // self-heals after a reboot with no human present ([[ADR-0008]] stage
    // 3b). Every log.err they
    // emit — a peer refusing the link, a C-BOUNDARIES refusal, a durable
    // state that only partly restored — was destroyed at the source, so
    // the machine that most needs a record was the only one with none.
    const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
    if (devnull >= 0) {
        _ = std.c.dup2(devnull, 0);
        if (devnull > 2) _ = std.c.close(devnull);
    }
    const logfd: c_int = if (logz) |lz|
        std.c.open(lz, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o600))
    else
        -1;
    if (logfd >= 0) {
        _ = std.c.dup2(logfd, 1);
        _ = std.c.dup2(logfd, 2);
        if (logfd > 2) _ = std.c.close(logfd);
    } else if (devnull >= 0) {
        // No log file is still better than writing into a dying terminal.
        _ = std.c.dup2(devnull, 1);
        _ = std.c.dup2(devnull, 2);
    }
    // The child MUST inherit the discovery path. Without it the probe
    // watches one file while the hub publishes to another, so ensure
    // reports failure and spawns AGAIN on every call — and each orphan
    // writes the machine's real discovery entry, clobbering whatever the
    // actual hub published.
    var argv_buf: [12]?[*:0]const u8 = undefined;
    var n: usize = 0;
    argv_buf[n] = exe_path;
    n += 1;
    argv_buf[n] = "hub";
    n += 1;
    argv_buf[n] = "--state-path";
    n += 1;
    argv_buf[n] = "default";
    n += 1;
    for (extra) |a| {
        if (n + 1 >= argv_buf.len) break;
        argv_buf[n] = a;
        n += 1;
    }
    argv_buf[n] = null;
    // The environment is INHERITED, not empty. The hub resolves its
    // discovery file (and its durable state) from $HOME, so a child with
    // no environment starts, listens, and publishes NOTHING — which is
    // indistinguishable from "no hub is running" to every reader,
    // including the ensure that just spawned it. It then spawns another
    // on the next call. Found on a real remote host: the local smoke had
    // passed --discovery-path explicitly, so it never needed $HOME.
    _ = std.c.execve(exe_path, @ptrCast(&argv_buf), @ptrCast(std.c.environ));
    // execve only returns on failure.
    std.c._exit(127);
}

/// Guarantee this machine has exactly one running hub, and report it.
/// Idempotent by construction: probe, and only spawn when nothing answers.
pub fn ensureRunning(exe_path: [*:0]const u8, extra: []const ?[*:0]const u8, wait_ms: u64) ?EnsureResult {
    if (probeRunning()) |existing| return existing;
    if (!spawnDetached(exe_path, extra)) return null;
    const io = io_mod.get();
    var waited: u64 = 0;
    while (waited < wait_ms) : (waited += 50) {
        io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
        if (probeRunning()) |found| {
            var started = found;
            started.started = true;
            return started;
        }
    }
    return null;
}

test "parseJsonI64 reads the discovery fields and rejects what is not there" {
    const text =
        \\{"port":9000,"pid":990448,"build":"dev"}
    ;
    try std.testing.expectEqual(@as(?i64, 9000), parseJsonI64(text, "port"));
    // pid is routinely above 65535 on Linux — parsing it as u16 would
    // silently mis-identify the process to signal-check.
    try std.testing.expectEqual(@as(?i64, 990448), parseJsonI64(text, "pid"));
    try std.testing.expectEqual(@as(?i64, null), parseJsonI64(text, "missing"));
    try std.testing.expectEqual(@as(?i64, null), parseJsonI64("{\"port\":\"x\"}", "port"));
    try std.testing.expectEqual(@as(?i64, null), parseJsonI64("", "port"));
}

test "probeRunning refuses a stale discovery file rather than reporting a hub" {
    const io = io_mod.get();
    var path_buf: [256]u8 = undefined;
    const tmp = sys.getenv("TMPDIR") orelse "/tmp";
    const scratch = try std.fmt.bufPrint(&path_buf, "{s}synapty-probe-test-{d}.json", .{ tmp, std.c.getpid() });
    discovery_path_override = scratch;
    defer discovery_path_override = null;
    defer std.Io.Dir.cwd().deleteFile(io, scratch) catch {};

    // No file at all.
    std.Io.Dir.cwd().deleteFile(io, scratch) catch {};
    try std.testing.expect(probeRunning() == null);

    // A file naming pid 1: it IS alive, but it is not a hub. The
    // hub_info check is what must reject it — a pid-liveness test alone
    // would report init as this machine's hub, and every agent would
    // then be told to connect to port 1.
    {
        var f = try std.Io.Dir.cwd().createFile(io, scratch, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "{\"port\":1,\"pid\":1,\"build\":\"dev\"}\n");
    }
    try std.testing.expect(probeRunning() == null);

    // A file naming a pid that is certainly dead short-circuits before
    // any socket work.
    {
        var f = try std.Io.Dir.cwd().createFile(io, scratch, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "{\"port\":9000,\"pid\":2147483600,\"build\":\"dev\"}\n");
    }
    try std.testing.expect(probeRunning() == null);
}

test "writeDiscovery publishes even when the parent directory already exists" {
    // Regression: createDirPath fails for an existing top-level path like
    // /tmp, and the old `catch return` turned that into "publish nothing".
    // A hub was then running and reachable while every reader — including
    // ensureRunning, which would spawn ANOTHER — saw no hub at all.
    const io = io_mod.get();
    var path_buf: [256]u8 = undefined;
    const scratch = try std.fmt.bufPrint(&path_buf, "/tmp/synapty-topdir-{d}.json", .{std.c.getpid()});
    discovery_path_override = scratch;
    defer discovery_path_override = null;
    defer std.Io.Dir.cwd().deleteFile(io, scratch) catch {};

    writeDiscovery(9411, "testbuild");
    var rbuf: [512]u8 = undefined;
    const content = readSmallFile(io, scratch, &rbuf) orelse return error.DiscoveryNotWritten;
    try std.testing.expect(std.mem.indexOf(u8, content, "\"port\":9411") != null);
}

test "the detached hub inherits an environment it cannot run without" {
    // Not a behavioural test of spawnDetached (it execs), but a guard on
    // the decision: the hub resolves its discovery file and durable state
    // from $HOME, so a child launched with an empty environment would run
    // and publish nothing. That failure is INVISIBLE — the hub listens
    // normally, and every reader concludes no hub exists. Asserted at the
    // source so re-introducing an empty-envp exec fails here rather
    // than on a remote host three deploys later.
    const io = io_mod.get();
    const file = std.Io.Dir.cwd().openFile(io, "src/hub/service.zig", .{}) catch return;
    defer file.close(io);
    const buf = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    const source = buf[0..n];
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimStart(u8, raw, " \t");
        if (std.mem.startsWith(u8, line, "//")) continue;
        // The needle is ASSEMBLED rather than written literally: a
        // detector spelled out in full matches its own source line and
        // fails on itself. That happened twice while writing these
        // source-level guards, so it is worth the two lines.
        const needle = "std.c." ++ "exec" ++ "ve";
        if (std.mem.indexOf(u8, line, needle) == null) continue;
        // The exec must pass a real environment through. An empty envp
        // here compiles, runs, and fails invisibly.
        if (std.mem.indexOf(u8, line, "envi" ++ "ron") == null) {
            return error.DetachedHubWouldLoseItsEnvironment;
        }
    }
}

test "a minted identity is never overridden by a suggestion" {
    // [[RFC-0010]] C-PEER-IDENTITY. Naming a hub after its own hostname
    // was the previous rule, and only a SECOND machine exposes why it is
    // wrong: two laptops are routinely both called "macbook-pro" and
    // collide on their first meeting, with the loser silently unable to
    // peer. A machine now mints and persists its own id, and a
    // provisioning suggestion applies only when there is nothing yet.
    const id_store = @import("identity_store.zig");
    var pbuf: [256]u8 = undefined;
    const tmp = sys.getenv("TMPDIR") orelse "/tmp";
    const scratch_path = try std.fmt.bufPrint(&pbuf, "{s}synapty-svcid-{d}.json", .{ tmp, std.c.getpid() });
    id_store.path_override = scratch_path;
    defer id_store.path_override = null;
    defer std.Io.Dir.cwd().deleteFile(io_mod.get(), scratch_path) catch {};
    std.Io.Dir.cwd().deleteFile(io_mod.get(), scratch_path) catch {};

    var state = @import("registry.zig").HubState.init(std.testing.allocator);
    defer state.deinit();
    state.adoptMintedPeerId("deskmac");
    const first = state.peer_id.?;
    try std.testing.expect(@import("federation.zig").validPeerId(first));
    try std.testing.expect(std.mem.startsWith(u8, first, "deskmac-"));

    // A second hub on the same machine, handed a different suggestion,
    // must report the SAME identity — peers key their directory entries
    // and spooled mail on it.
    var other = @import("registry.zig").HubState.init(std.testing.allocator);
    defer other.deinit();
    other.adoptMintedPeerId("something-else");
    try std.testing.expectEqualStrings(first, other.peer_id.?);
}
