const std = @import("std");
const sys = @import("sys");
const io_mod = @import("io");
const mem = std.mem;
const protocol = @import("protocol");
const Allocator = mem.Allocator;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const hub_addr = "127.0.0.1";
pub const default_hub_port: u16 = 9000;

// ---------------------------------------------------------------------------
// Hub port resolution (WI-2026-08-11-017: the port is a runtime detail)
// ---------------------------------------------------------------------------

/// Test hook: discovery-file path override, so tests never read the real
/// ~/.config, which holds the operator's own state.
pub var discovery_path_override: ?[]const u8 = null;

/// Resolve the hub port for a bare (out-of-pane) CLI invocation:
/// 1. SYNAPTY_HUB_PORT — the single manual escape hatch.
/// 2. The workbench's discovery file (~/.config/synapty/machine/hub.json),
///    honored only while its writer pid is alive (stale files from a
///    crashed app must not send the CLI to a dead port).
/// 3. The 9000 default.
/// In-pane CLIs never get here (SYNAPTY_SOCK rides the pane daemon);
/// wrappers get --hub from the app's spawn args.
pub fn resolveHubPort() u16 {
    if (sys.getenv("SYNAPTY_HUB_PORT")) |raw| {
        if (std.fmt.parseInt(u16, raw, 10) catch null) |p| {
            if (p > 0) return p;
        }
    }
    if (discoveryPort()) |p| return p;
    return default_hub_port;
}

fn discoveryPort() ?u16 {
    var pbuf: [1024]u8 = undefined;
    // THE SAME FUNCTION THE WRITER USES ([[WI-2026-08-14-007]]). Building
    // this path by hand lets the reader and the writer drift apart, and a
    // reader looking in the wrong place degrades to the 9000 default —
    // which is silently correct until the port ladder moves the hub.
    const path = discovery_path_override orelse
        @import("paths").discovery.path(&pbuf) orelse return null;
    const io = io_mod.get();
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var rbuf: [512]u8 = undefined;
    var reader = f.reader(io, &rbuf);
    var content_buf: [512]u8 = undefined;
    const n = reader.interface.readSliceShort(&content_buf) catch return null;
    const content = content_buf[0..n];
    const port = scanUInt(content, "\"port\":") orelse return null;
    const pid = scanUInt(content, "\"pid\":") orelse return null;
    // Liveness: signal 0 probes without sending. EPERM still means alive.
    if (std.c.kill(@intCast(pid), @enumFromInt(0)) != 0 and !isEperm()) return null;
    return std.math.cast(u16, port) orelse null;
}

fn isEperm() bool {
    return std.c._errno().* == @intFromEnum(std.posix.E.PERM);
}

/// Scan `"key":<digits>` out of the machine-written discovery JSON —
/// dependency-free by design (this runs before any allocator exists).
fn scanUInt(content: []const u8, needle: []const u8) ?u64 {
    const start = (mem.indexOf(u8, content, needle) orelse return null) + needle.len;
    var end = start;
    while (end < content.len and std.ascii.isDigit(content[end])) end += 1;
    if (end == start) return null;
    return std.fmt.parseInt(u64, content[start..end], 10) catch null;
}

// ---------------------------------------------------------------------------
// Hub connection helpers
// ---------------------------------------------------------------------------

/// Connect to the Hub and send an initial register envelope.
/// Returns the open stream; caller must close it.
pub fn connectAndRegister(allocator: Allocator, agent_id: []const u8) !sys.fd_t {
    const fd = try connectToHub(hub_addr, resolveHubPort());
    errdefer sys.close(fd);

    const reg = try protocol.makeRegisterEnvelope(allocator, agent_id, &.{});
    const payload = try protocol.serializeEnvelope(allocator, reg);
    defer allocator.free(payload);

    try sys.writeAll(fd, payload);
    try sys.writeAll(fd, "\n");
    return fd;
}

/// Open a TCP connection to the Hub at addr:port.
pub fn connectToHub(addr: []const u8, port: u16) !sys.fd_t {
    const fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    errdefer sys.close(fd);
    const addr4 = std.Io.net.Ip4Address.parse(addr, port) catch {
        sys.close(fd);
        return error.InvalidHubAddress;
    };
    const sa = sys.sockaddr_in.init(@bitCast(addr4.bytes), port);
    try sys.connect(fd, &sa, @sizeOf(sys.sockaddr_in));
    return fd;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// zig 0.16's std.c has no setenv/unsetenv wrappers on macOS.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "resolveHubPort: env override, live discovery, stale-pid fallback (WI-2026-08-11-017)" {
    std.testing.log_level = .err;
    const io = io_mod.get();
    var pbuf: [256]u8 = undefined;
    const tmp = sys.getenv("TMPDIR") orelse "/tmp";
    const scratch = try std.fmt.bufPrint(&pbuf, "{s}synapty-transport-test-{d}.json", .{ tmp, std.c.getpid() });
    discovery_path_override = scratch;
    defer discovery_path_override = null;
    defer std.Io.Dir.cwd().deleteFile(io, scratch) catch {};

    // No file, no env: the default.
    try std.testing.expectEqual(default_hub_port, resolveHubPort());

    // Discovery file with a LIVE writer pid (ours): honored.
    {
        var f = try std.Io.Dir.cwd().createFile(io, scratch, .{});
        defer f.close(io);
        var cbuf: [128]u8 = undefined;
        const c = try std.fmt.bufPrint(&cbuf, "{{\"port\":9317,\"pid\":{d},\"build\":\"t\"}}\n", .{std.c.getpid()});
        try f.writeStreamingAll(io, c);
    }
    try std.testing.expectEqual(@as(u16, 9317), resolveHubPort());

    // SYNAPTY_HUB_PORT beats the discovery file.
    try std.testing.expectEqual(@as(c_int, 0), setenv("SYNAPTY_HUB_PORT", "9555", 1));
    try std.testing.expectEqual(@as(u16, 9555), resolveHubPort());
    _ = unsetenv("SYNAPTY_HUB_PORT");

    // Stale writer (a pid that cannot exist): fall back to the default —
    // a crashed app's file must not send the CLI to a dead port.
    {
        var f = try std.Io.Dir.cwd().createFile(io, scratch, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "{\"port\":9317,\"pid\":99999999,\"build\":\"t\"}\n");
    }
    try std.testing.expectEqual(default_hub_port, resolveHubPort());

    // Garbage content: default, never a crash.
    {
        var f = try std.Io.Dir.cwd().createFile(io, scratch, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "not json at all");
    }
    try std.testing.expectEqual(default_hub_port, resolveHubPort());
}
