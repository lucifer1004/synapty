//! Minimal POSIX socket/fd bindings for Synapty.
//!
//! Zig 0.16 removed `std.net` and moved networking into the async `std.Io`
//! abstraction, which does not support unix sockets ("Io.net currently
//! lacks a way to do non-IP networking" — 0.16.0 release notes). Synapty's
//! synchronous, thread-per-connection design therefore uses the low-level
//! `std.posix.system` layer directly (the officially sanctioned "go lower"
//! path), with thin error-mapping wrappers.
//!
//! All targets link libc (see build.zig), so `std.posix.system` is `std.c`
//! everywhere and the call signatures are uniform.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const system = posix.system;

pub const fd_t = posix.fd_t;

// ---------------------------------------------------------------------------
// Constants (from posix namespaces)
// ---------------------------------------------------------------------------

pub const AF = posix.AF;
pub const SOCK = posix.SOCK;
pub const SOL = posix.SOL;
pub const SO = posix.SO;
pub const SHUT = posix.SHUT;
pub const F = posix.F;

/// O_NONBLOCK bit value. `posix.O` is a packed struct on macOS, so we use
/// the raw integer values for fcntl flag arithmetic.
pub const O_NONBLOCK: i32 = switch (builtin.os.tag) {
    .macos => 0x0004,
    .linux => 0x800,
    else => @compileError("unsupported OS"),
};

/// SIGPIPE value (13 on macOS and Linux). `posix.SIG.PIPE` is not exposed
/// in 0.16's SIG enum on all targets, so we hardcode the POSIX value.
pub const SIGPIPE: i32 = 13;

// ---------------------------------------------------------------------------
// Address structures
// ---------------------------------------------------------------------------

/// `sa_family_t`: macOS uses a 1-byte family (prefixed by a length byte
/// in sockaddr_in/sockaddr_un); Linux uses a 2-byte family with no length
/// prefix. Using the wrong width shifts the rest of the struct, so the
/// kernel reads garbage (e.g. the first path byte as the high half of the
/// family) and connect/bind fails with EAFNOSUPPORT.
pub const sa_family_t = switch (builtin.os.tag) {
    .macos => u8,
    .linux => u16,
    else => @compileError("unsupported OS"),
};

/// IPv4 socket address (`struct sockaddr_in`).
/// macOS prefixes the family byte with a length byte; Linux does not.
pub const sockaddr_in = extern struct {
    prefix: Prefix,
    family: sa_family_t,
    port: u16, // network byte order
    addr: u32, // network byte order
    zero: [8]u8,

    const Prefix = if (builtin.os.tag == .macos)
        extern struct { len: u8 }
    else if (builtin.os.tag == .linux)
        extern struct {}
    else
        @compileError("unsupported OS");

    comptime {
        if (@sizeOf(sockaddr_in) != 16) @compileError("bad sockaddr_in size");
        // Linux sa_family_t is u16 at offset 0 (no length prefix); macOS is
        // u8 at offset 1 (after the length byte).
        if (builtin.os.tag == .linux and @offsetOf(sockaddr_in, "family") != 0)
            @compileError("bad Linux sockaddr_in family offset");
        if (builtin.os.tag == .macos and @offsetOf(sockaddr_in, "family") != 1)
            @compileError("bad macOS sockaddr_in family offset");
    }

    pub fn init(addr: u32, port: u16) sockaddr_in {
        return .{
            .prefix = if (builtin.os.tag == .macos)
                .{ .len = @sizeOf(sockaddr_in) }
            else
                .{},
            .family = @intCast(AF.INET),
            .port = std.mem.nativeToBig(u16, port),
            .addr = addr,
            .zero = [_]u8{0} ** 8,
        };
    }
};

/// Unix domain socket address (`struct sockaddr_un`).
pub const sockaddr_un = extern struct {
    prefix: Prefix,
    family: sa_family_t,
    path: [PathLen]u8,

    const PathLen = if (builtin.os.tag == .macos)
        104
    else if (builtin.os.tag == .linux)
        108
    else
        @compileError("unsupported OS");

    const Prefix = if (builtin.os.tag == .macos)
        extern struct { len: u8 }
    else if (builtin.os.tag == .linux)
        extern struct {}
    else
        @compileError("unsupported OS");

    comptime {
        // Layout guard: the kernel reads sa_family_t (1 byte on macOS, 2 on
        // Linux) directly from the struct. If the family width or path
        // offset is wrong, connect/bind fail with EAFNOSUPPORT because the
        // first path byte lands where the family's high byte should be.
        if (builtin.os.tag == .macos) {
            if (@sizeOf(sockaddr_un) != 106) @compileError("bad macOS sockaddr_un size");
            if (@offsetOf(sockaddr_un, "path") != 2) @compileError("bad macOS sockaddr_un path offset");
        } else if (builtin.os.tag == .linux) {
            if (@sizeOf(sockaddr_un) != 110) @compileError("bad Linux sockaddr_un size");
            if (@offsetOf(sockaddr_un, "path") != 2) @compileError("bad Linux sockaddr_un path offset");
        }
    }

    /// Build an address from a path. Returns null if the path does not fit.
    pub fn init(path: []const u8) ?sockaddr_un {
        if (path.len >= PathLen) return null;
        var addr: sockaddr_un = .{
            .prefix = if (builtin.os.tag == .macos)
                .{ .len = @intCast(@offsetOf(sockaddr_un, "path") + path.len + 1) }
            else
                .{},
            .family = @intCast(AF.UNIX),
            .path = [_]u8{0} ** PathLen,
        };
        @memcpy(addr.path[0..path.len], path);
        if (builtin.os.tag == .macos) {
            // sun_len = offsetof(sun_path) + path length (incl. NUL).
            addr.prefix.len = @intCast(@offsetOf(sockaddr_un, "path") + path.len + 1);
        }
        return addr;
    }

    pub fn len(self: *const sockaddr_un) u32 {
        if (builtin.os.tag == .macos) return self.prefix.len;
        const nul = std.mem.indexOfScalar(u8, &self.path, 0) orelse self.path.len;
        return @offsetOf(sockaddr_un, "path") + @as(u32, @intCast(nul)) + 1;
    }
};

// ---------------------------------------------------------------------------
// Error mapping
// ---------------------------------------------------------------------------

const E = posix.E;

fn errnoValue() i32 {
    return std.c._errno().*;
}

/// Map the current errno to a Zig error.
fn errnoError() posix.UnexpectedError {
    return posix.unexpectedErrno(@enumFromInt(errnoValue()));
}

pub const AcceptError = error{
    ConnectionAborted,
    ConnectionResetByPeer,
    WouldBlock,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    SocketUnconnected,
    Unexpected,
};

pub const ConnectError = error{
    ConnectionRefused,
    NetworkUnreachable,
    ConnectionTimedOut,
    ConnectionResetByPeer,
    AddressFamilyNotSupported,
    FileNotFound,
    WouldBlock,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    Unexpected,
};

pub const WriteError = error{
    ConnectionResetByPeer,
    NotConnected,
    BrokenPipe,
    WouldBlock,
    SystemResources,
    Unexpected,
};

// ---------------------------------------------------------------------------
// Socket lifecycle
// ---------------------------------------------------------------------------

pub fn socket(family: i32, sock_type: i32, protocol: i32) !fd_t {
    const rc = system.socket(@intCast(family), @intCast(sock_type), @intCast(protocol));
    if (rc < 0) return errnoError();
    return @intCast(rc);
}

pub fn bind(fd: fd_t, addr: *const anyopaque, addrlen: u32) !void {
    const sa: *const system.sockaddr = @ptrCast(@alignCast(addr));
    if (system.bind(fd, sa, addrlen) != 0) return errnoError();
}

pub fn listen(fd: fd_t, backlog: i32) !void {
    if (system.listen(fd, @intCast(backlog)) != 0) return errnoError();
}

pub fn accept(fd: fd_t) AcceptError!fd_t {
    const rc = system.accept(fd, null, null);
    if (rc < 0) {
        return switch (errnoValue()) {
            @intFromEnum(E.CONNABORTED) => error.ConnectionAborted,
            @intFromEnum(E.CONNRESET) => error.ConnectionResetByPeer,
            @intFromEnum(E.AGAIN) => error.WouldBlock,
            @intFromEnum(E.MFILE) => error.ProcessFdQuotaExceeded,
            @intFromEnum(E.NFILE) => error.SystemFdQuotaExceeded,
            @intFromEnum(E.NOBUFS), @intFromEnum(E.NOMEM) => error.SystemResources,
            @intFromEnum(E.NOTCONN) => error.SocketUnconnected,
            else => errnoError(),
        };
    }
    return @intCast(rc);
}

pub fn connect(fd: fd_t, addr: *const anyopaque, addrlen: u32) ConnectError!void {
    const sa: *const system.sockaddr = @ptrCast(@alignCast(addr));
    if (system.connect(fd, sa, addrlen) != 0) {
        return switch (errnoValue()) {
            @intFromEnum(E.CONNREFUSED) => error.ConnectionRefused,
            @intFromEnum(E.NETUNREACH) => error.NetworkUnreachable,
            @intFromEnum(E.TIMEDOUT) => error.ConnectionTimedOut,
            @intFromEnum(E.CONNRESET) => error.ConnectionResetByPeer,
            @intFromEnum(E.AFNOSUPPORT) => error.AddressFamilyNotSupported,
            @intFromEnum(E.NOENT) => error.FileNotFound,
            @intFromEnum(E.AGAIN) => error.WouldBlock,
            @intFromEnum(E.MFILE) => error.ProcessFdQuotaExceeded,
            @intFromEnum(E.NFILE) => error.SystemFdQuotaExceeded,
            @intFromEnum(E.NOBUFS), @intFromEnum(E.NOMEM) => error.SystemResources,
            else => errnoError(),
        };
    }
}

pub fn close(fd: fd_t) void {
    _ = system.close(fd);
}

pub fn shutdown(fd: fd_t, how: i32) void {
    _ = system.shutdown(fd, how);
}

pub fn setReuseAddress(fd: fd_t) !void {
    const one: c_int = 1;
    if (system.setsockopt(fd, SOL.SOCKET, SO.REUSEADDR, &one, @sizeOf(c_int)) != 0) {
        return errnoError();
    }
}

/// Return the port bound to fd (from getsockname).
pub fn boundPort(fd: fd_t) !u16 {
    var addr: sockaddr_in = undefined;
    var len: u32 = @sizeOf(sockaddr_in);
    if (system.getsockname(fd, @ptrCast(&addr), &len) != 0) return errnoError();
    return std.mem.bigToNative(u16, addr.port);
}

/// Restrict a socket FILE to the owner (F10 — the daemon's IPC socket
/// was world-connectable, letting any local user recv/send/impersonate
/// the agent; WI-2026-08-08-017). chmod on the path (not fchmod on the
/// fd): macOS rejects fchmod on socket descriptors.
pub fn chmod(path: []const u8, mode: u16) !void {
    const path_z = try posix.toPosixPath(path);
    if (system.chmod(&path_z, mode) != 0) return errnoError();
}

pub fn unlink(path: []const u8) void {
    var buf: [sockaddr_un.PathLen:0]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = system.unlink(buf[0..path.len :0].ptr);
}

// ---------------------------------------------------------------------------
// fd I/O
// ---------------------------------------------------------------------------

/// Write all bytes to fd, retrying on partial writes and EINTR.
pub fn writeAll(fd: fd_t, bytes: []const u8) WriteError!void {
    var i: usize = 0;
    while (i < bytes.len) {
        const n = system.write(fd, bytes.ptr + i, bytes.len - i);
        if (n < 0) {
            const err = errnoValue();
            if (err == @intFromEnum(E.INTR)) continue;
            return switch (err) {
                @intFromEnum(E.PIPE) => error.BrokenPipe,
                @intFromEnum(E.CONNRESET) => error.ConnectionResetByPeer,
                @intFromEnum(E.NOTCONN) => error.NotConnected,
                @intFromEnum(E.AGAIN) => error.WouldBlock,
                @intFromEnum(E.NOBUFS), @intFromEnum(E.NOMEM) => error.SystemResources,
                else => errnoError(),
            };
        }
        i += @intCast(n);
    }
}

/// Read up to buf.len bytes. Returns 0 on EOF.
/// Wraps `posix.read`, which retries EINTR and maps errno to Zig errors.
pub fn read(fd: fd_t, buf: []u8) posix.ReadError!usize {
    return posix.read(fd, buf);
}

/// Set O_NONBLOCK on fd via fcntl.
pub fn setNonblocking(fd: fd_t) !void {
    const flags = system.fcntl(fd, F.GETFL, @as(c_int, 0));
    if (flags < 0) return errnoError();
    if (system.fcntl(fd, F.SETFL, @as(c_int, @intCast(flags | O_NONBLOCK))) < 0) return errnoError();
}

/// Read an environment variable (libc getenv). Returns null when unset.
pub fn getenv(name: []const u8) ?[]const u8 {
    var buf: [256:0]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const v = system.getenv(buf[0..name.len :0].ptr) orelse return null;
    return std.mem.span(v);
}
