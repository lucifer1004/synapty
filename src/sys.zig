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

/// THE HARD BOUND ON A UNIX SOCKET PATH, named because it is the only
/// path length in this system the kernel decides. Anything that BUILDS
/// such a path has to answer to it, and the answer has to be the same
/// one everywhere — a bound discovered at `connect` is a bound each
/// caller invents a behaviour for.
pub const max_unix_path: usize = if (builtin.os.tag == .macos)
    104
else if (builtin.os.tag == .linux)
    108
else
    @compileError("unsupported OS");

/// Unix domain socket address (`struct sockaddr_un`).
pub const sockaddr_un = extern struct {
    prefix: Prefix,
    family: sa_family_t,
    path: [PathLen]u8,

    const PathLen = max_unix_path;

    const Prefix = if (builtin.os.tag == .macos)
        extern struct { len: u8 }
    else if (builtin.os.tag == .linux)
        extern struct {}
    else
        @compileError("unsupported OS");

    comptime {
        // Layout guard — see the `sa_family_t` note above.
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

/// Every socket Synapty opens is CLOSE-ON-EXEC ([[WI-2026-08-14-004]]).
///
/// Nothing here passes a socket to a child across exec, and one that
/// leaks into a child leaks AUTHORITY, not just a descriptor: a pane's
/// shell inheriting the wrapper's hub connection can speak to the hub as
/// that pane's agent, and keeps the connection — and so the registration
/// — alive after the wrapper exits.
///
/// macOS has no SOCK_CLOEXEC, so this is a second call rather than a flag
/// on socket(). Applied at accept() too: an accepted connection is a new
/// descriptor and inherits nothing from the listener.
fn setCloexec(fd: fd_t) void {
    // Best effort: a socket that could not be marked is still a working
    // socket, and failing the connection would turn a hygiene problem
    // into an outage.
    // Zig 0.16 dropped std.posix.fcntl; libc's is variadic, so call it
    // directly — the same reason this file wraps POSIX at all.
    _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
}

pub fn socket(family: i32, sock_type: i32, protocol: i32) !fd_t {
    const rc = system.socket(@intCast(family), @intCast(sock_type), @intCast(protocol));
    if (rc < 0) return errnoError();
    const fd: fd_t = @intCast(rc);
    setCloexec(fd);
    return fd;
}

pub const BindError = error{
    /// Another listener holds the address (the port ladder's signal to
    /// try the next rung — WI-2026-08-11-017).
    AddressInUse,
    AccessDenied,
    Unexpected,
};

pub fn bind(fd: fd_t, addr: *const anyopaque, addrlen: u32) BindError!void {
    const sa: *const system.sockaddr = @ptrCast(@alignCast(addr));
    if (system.bind(fd, sa, addrlen) != 0) {
        const e: E = @enumFromInt(errnoValue());
        return switch (e) {
            .ADDRINUSE => error.AddressInUse,
            .ACCES => error.AccessDenied,
            else => posix.unexpectedErrno(e),
        };
    }
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
            // deinit() closes the listener while the accept thread
            // blocks — EBADF here IS normal shutdown, not an unexpected
            // errno. Falling through to posix.unexpectedErrno ABORTS test
            // builds, and blames whichever test ran in the foreground.
            @intFromEnum(E.BADF) => error.ConnectionAborted,
            else => errnoError(),
        };
    }
    const fd_out: fd_t = @intCast(rc);
    setCloexec(fd_out);
    return fd_out;
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
/// The permission bits of a path, for a caller that has just set them
/// and needs to be able to prove it ([[RFC-0014]] C-ENTITLEMENT). Zig
/// 0.16's `Io.File.Stat` does not carry a mode, so this goes to libc.
pub fn fileMode(path: []const u8) !u16 {
    var zbuf: [512]u8 = undefined;
    if (path.len >= zbuf.len) return error.NameTooLong;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    var st: std.c.Stat = undefined;
    const AT_FDCWD: fd_t = -2;
    if (std.c.fstatat(AT_FDCWD, @ptrCast(&zbuf), &st, 0) != 0) return errnoError();
    return @intCast(st.mode & 0o7777);
}

pub const ChmodError = error{
    /// The path is not ours to re-mode, or is not there. NAMED RATHER
    /// THAN UNEXPECTED for the reason `TimeoutError.SocketGone` is: an
    /// ordinary outcome must not go through `unexpectedErrno`.
    NotOurs,
} || posix.UnexpectedError;

pub fn chmod(path: []const u8, mode: u16) ChmodError!void {
    const path_z = posix.toPosixPath(path) catch return error.NotOurs;
    if (system.chmod(&path_z, mode) == 0) return;
    return switch (@as(E, @enumFromInt(errnoValue()))) {
        .PERM, .ACCES, .NOENT, .ROFS, .NOTDIR => error.NotOurs,
        else => errnoError(),
    };
}

/// WHO IS ON THE OTHER END OF THIS CONNECTION, asked of the kernel
/// ([[RFC-0014]] C-ENTITLEMENT: "The holder is responsible for its own
/// checks").
///
/// FILE PERMISSIONS ARE THE FENCE, NOT THE ANSWER. A mode on the socket
/// is checked when the path is resolved, which leaves the window between
/// bind and chmod, anything that inherited a descriptor, and any
/// re-creation of the path by something with the right to do so. The
/// credentials the kernel attaches to the connection itself are the fact;
/// everything else is inference about how the connection was obtained.
/// TWO KERNELS, ONE QUESTION. BSD (and macOS) answer it with
/// `getpeereid`; Linux with `SO_PEERCRED`, which musl does NOT wrap as
/// `getpeereid` — a deploy target that cross-compiles for
/// aarch64-linux-musl fails to link against a symbol that is not there.
/// Found by the deploy build, which is the whole reason it runs.
extern "c" fn getpeereid(fd: c_int, euid: *std.c.uid_t, egid: *std.c.gid_t) c_int;

pub fn peerUid(fd: fd_t) !std.c.uid_t {
    switch (builtin.os.tag) {
        .linux => {
            var cred: extern struct { pid: i32, uid: u32, gid: u32 } = undefined;
            var len: u32 = @sizeOf(@TypeOf(cred));
            if (system.getsockopt(fd, SOL.SOCKET, SO.PEERCRED, @ptrCast(&cred), &len) != 0) {
                return errnoError();
            }
            return @intCast(cred.uid);
        },
        else => {
            var uid: std.c.uid_t = undefined;
            var gid: std.c.gid_t = undefined;
            if (getpeereid(fd, &uid, &gid) != 0) return errnoError();
            return uid;
        },
    }
}

/// This process's effective user — what a peer has to match.
pub fn selfUid() std.c.uid_t {
    return std.c.geteuid();
}


/// Milliseconds since the epoch, on the WALL clock.
///
/// THE WALL CLOCK IS THE ONLY ONE TWO PROCESSES SHARE. What this stamps
/// is read by the workbench, which did not start when this process did,
/// so a monotonic reading would mean nothing to it. Zig 0.16 removed
/// `std.time.milliTimestamp`, and `Io`'s clock speaks durations rather
/// than dates, so this goes to libc like the rest of this file.
pub fn nowMillis() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Open a file for appending, creating it if it is not there.
///
/// O_APPEND RATHER THAN A SEEK TO THE END, because more than one process
/// writes to these: every write lands at the end as it stands at that
/// moment, so two writers cannot land on top of each other
/// ([[WI-2026-08-17-016]]).
pub fn openAppend(path: []const u8) !fd_t {
    const path_z = try posix.toPosixPath(path);
    const flags: std.c.O = .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true };
    const rc = system.open(&path_z, flags, @as(c_uint, 0o600));
    if (rc < 0) return errnoError();
    return @intCast(rc);
}

/// BOUNDED BY THE FILESYSTEM, NOT BY A SOCKET. This used
/// `sockaddr_un.PathLen` — 104 — and returned silently above it, so a
/// socket file at a longer path was never removed and a stale one was
/// left for the next holder to trip over. `unlink` takes PATH_MAX like
/// any other path syscall; the 104 belongs to `bind` and `connect` and
/// to nothing else.
/// TAKE AN EXCLUSIVE CLAIM ON AN OPEN FILE, or say it is already held.
///
/// `flock` binds to the OPEN, not to the process id, and the kernel
/// releases it however the holder dies — exit, SIGKILL, a reboot. That is
/// what makes it able to answer a question `kill(pid, 0)` cannot: whether
/// THIS process is still there, rather than whether some process wears
/// its number ([[holder.sweepEnded]]).
///
/// Never blocks. A caller asking whether an owner is alive must not wait
/// on the answer, and a caller taking a claim of its own has nothing to
/// wait for: if the claim is held, the file is not its to take.
pub fn tryClaim(fd: fd_t) bool {
    return system.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) == 0;
}

/// Open an existing file for the sole purpose of asking whether its claim
/// is free. Read-only: `flock` needs a descriptor, not write access.
pub fn openForClaim(path: []const u8) ?fd_t {
    const path_z = posix.toPosixPath(path) catch return null;
    const fd = system.open(&path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    return if (fd < 0) null else @intCast(fd);
}

pub fn unlink(path: []const u8) void {
    const path_z = posix.toPosixPath(path) catch return;
    _ = system.unlink(&path_z);
}

/// A DIRECTORY FILE DESCRIPTOR, so a working directory can be restored
/// even if the path it was reached by has since moved.
pub fn openDirFd(path: []const u8) !fd_t {
    // Spelled out because this file talks to libc directly and does not
    // import a flags namespace: O_RDONLY 0, O_DIRECTORY 0x100000,
    // O_CLOEXEC 0x1000000 on Darwin; 0, 0o200000, 0o2000000 on Linux.
    const flags: c_int = switch (builtin.os.tag) {
        .macos => 0x100000 | 0x1000000,
        .linux => 0o200000 | 0o2000000,
        else => @compileError("unsupported OS"),
    };
    const path_z = try posix.toPosixPath(path);
    const rc = open(&path_z, flags);
    if (rc < 0) return errnoError();
    return rc;
}

pub fn chdir(path: []const u8) !void {
    const path_z = try posix.toPosixPath(path);
    if (system.chdir(&path_z) == 0) return;
    return errnoError();
}

pub fn getcwd(buf: []u8) ![]const u8 {
    if (system.getcwd(buf.ptr, buf.len)) |p| {
        return std.mem.sliceTo(p, 0);
    }
    return errnoError();
}

pub fn fchdir(fd: fd_t) !void {
    if (system.fchdir(fd) == 0) return;
    return errnoError();
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

pub const PollError = error{
    SystemResources,
    Unexpected,
};

/// Wait until `fd` has something to read, or `timeout_ms` elapses.
/// True means readable (or at end of stream — the read that follows says
/// which); false means the time ran out.
///
/// A THREAD PARKED IN read() CANNOT BE TOLD ANYTHING. It holds no lock and
/// checks no flag until a byte arrives, so a client whose session has
/// ended waits in join() for a keystroke that has no reason to come, and
/// the descriptor it would write that keystroke to may be gone by then.
/// Waiting with a deadline is what gives the loop a place to look at the
/// flag that stops it.
pub fn waitReadable(fd: fd_t, timeout_ms: i32) PollError!bool {
    var fds = [_]system.pollfd{.{
        .fd = fd,
        // HUP and NVAL arrive in revents whether or not they are asked
        // for; IN is the only thing to request.
        .events = @intCast(system.POLL.IN),
        .revents = 0,
    }};
    while (true) {
        const n = system.poll(&fds, 1, timeout_ms);
        if (n < 0) {
            return switch (@as(E, @enumFromInt(errnoValue()))) {
                .INTR => continue,
                .NOMEM, .AGAIN => error.SystemResources,
                else => errnoError(),
            };
        }
        return n > 0;
    }
}

/// Is fd a terminal? (libc isatty — std.posix dropped its wrapper.)
pub fn isatty(fd: fd_t) bool {
    return std.c.isatty(fd) != 0;
}

/// Set O_NONBLOCK on fd via fcntl.
/// Set a receive timeout on a socket (SO_RCVTIMEO): blocked reads return
/// error.WouldBlock after `ms` milliseconds. Used by `synapty wait` to
/// bound its event-stream reads (RFC-0004 C-WAIT --timeout).
/// THROUGH THE RAW CALL, not `std.posix.setsockopt`, which marks EINVAL
/// `unreachable` — a panic no caller can catch, reached by asking a
/// descriptor that has stopped being a socket for a timeout. That is an
/// ordinary race in a program where one thread may close what another is
/// still holding, and it must be an error rather than an abort. Mapping
/// errno instead of trusting an assumption is what this module is for.
pub fn setRecvTimeout(fd: fd_t, ms: u64) !void {
    return setTimeval(fd, SO.RCVTIMEO, ms);
}

pub const TimeoutError = error{
    /// The descriptor cannot take a timeout because it has stopped being
    /// a live socket — the peer tore it down, or another thread closed
    /// it. NAMED RATHER THAN UNEXPECTED, which is the other half of the
    /// fix the comment above describes.
    ///
    /// `errnoError` routes everything through `posix.unexpectedErrno`,
    /// and in a debug build that PRINTS and dumps a stack trace. For a
    /// race this module already calls ordinary, that is noise — and it is
    /// not only noise: it wrote into the stream `zig build test` uses to
    /// talk to its runner over `--listen=-`, and the runner died of it
    /// with "internal test runner failure". The whole suite could not be
    /// run, while the same binary invoked directly passed all 33 tests.
    SocketGone,
} || posix.UnexpectedError;

fn setTimeval(fd: fd_t, opt: u32, ms: u64) TimeoutError!void {
    const tv = posix.timeval{
        .sec = @intCast(ms / 1000),
        .usec = @intCast((ms % 1000) * 1000),
    };
    const rc = system.setsockopt(fd, SOL.SOCKET, opt, @ptrCast(&tv), @sizeOf(posix.timeval));
    if (rc == 0) return;
    return switch (@as(E, @enumFromInt(errnoValue()))) {
        .INVAL, .BADF, .NOTSOCK, .NOTCONN, .PIPE => error.SocketGone,
        else => errnoError(),
    };
}

/// Bound how long a write may block ([[RFC-0014]] C-STALLED-CLIENT): a
/// send into a half-open connection must not hold up the thread that is
/// moving a child's output.
pub fn setSendTimeout(fd: fd_t, ms: u64) !void {
    return setTimeval(fd, SO.SNDTIMEO, ms);
}

pub fn setNonblocking(fd: fd_t) !void {
    const flags = system.fcntl(fd, F.GETFL, @as(c_int, 0));
    if (flags < 0) return errnoError();
    if (system.fcntl(fd, F.SETFL, @as(c_int, @intCast(flags | O_NONBLOCK))) < 0) return errnoError();
}

// ---------------------------------------------------------------------------
// Pseudoterminals ([[RFC-0014]], [[WI-2026-08-17-003]])
//
// BUILT FROM PRIMITIVES RATHER THAN `forkpty`. The convenience call lives
// in libutil on glibc and in libc on musl and Darwin, so depending on it
// would make one deploy target link differently from the others for a
// function that is twenty lines of the primitives every target already
// has. The primitives are also the only way to be explicit about the two
// steps that matter — a new session, and the controlling terminal — which
// is what makes the child a terminal's owner rather than merely a process
// with a terminal-shaped file descriptor.
// ---------------------------------------------------------------------------

pub const winsize = extern struct {
    ws_row: u16 = 0,
    ws_col: u16 = 0,
    ws_xpixel: u16 = 0,
    ws_ypixel: u16 = 0,
};

/// Terminal ioctls. Their numbers are encoded from direction, size and a
/// letter on BSD, and are small ordinals on Linux — there is no shared
/// value to derive, so both are written out.
const TIOC = switch (builtin.os.tag) {
    .macos => struct {
        const SCTTY: c_ulong = 0x20007461;
        const SWINSZ: c_ulong = 0x80087467;
        const GWINSZ: c_ulong = 0x40087468;
    },
    .linux => struct {
        const SCTTY: c_ulong = 0x540E;
        const SWINSZ: c_ulong = 0x5414;
        const GWINSZ: c_ulong = 0x5413;
    },
    else => @compileError("unsupported OS"),
};

extern "c" fn posix_openpt(oflag: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn setsid() c_int;
extern "c" fn fork() c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn _exit(code: c_int) noreturn;
/// libc, because Zig 0.16 moved sleeping into `std.Io` and this module
/// deliberately imports nothing of ours.
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn tcgetpgrp(fd: c_int) c_int;

/// A process's working directory, and the command it is running.
///
/// TWO KERNELS, TWO ANSWERS. Linux publishes both in `/proc`; Darwin has
/// no such filesystem and answers through `proc_pidinfo`. Neither is
/// portable to the other, and a holder that could only answer on one of
/// them would leave the destination of a cross-host drop unknown on the
/// other ([[RFC-0014]] C-PWD).
pub const ProcInfo = struct {
    /// Absolute path, or empty when the kernel would not say.
    cwd: []const u8,
    /// The executable's name as the kernel reports it, or empty.
    command: []const u8,
};

/// PROC_PIDVNODEPATHINFO on Darwin.
const proc_vnodepathinfo_size = 2352;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn proc_name(pid: c_int, buffer: ?*anyopaque, buffersize: u32) c_int;

pub fn procInfo(pid: i32, cwd_buf: []u8, cmd_buf: []u8) ProcInfo {
    var out = ProcInfo{ .cwd = "", .command = "" };
    if (pid <= 0) return out;
    switch (builtin.os.tag) {
        .macos => {
            var vpi: [proc_vnodepathinfo_size]u8 align(8) = undefined;
            if (proc_pidinfo(pid, 9, 0, &vpi, proc_vnodepathinfo_size) == proc_vnodepathinfo_size) {
                // `vip_path` of the CURRENT directory vnode sits at a
                // fixed offset in the struct; the layout is stable ABI on
                // this platform, and the alternative is vendoring a
                // header for one field.
                const path_off = 152;
                const raw = vpi[path_off..];
                const n = std.mem.indexOfScalar(u8, raw, 0) orelse 0;
                if (n > 0 and n < cwd_buf.len and raw[0] == '/') {
                    @memcpy(cwd_buf[0..n], raw[0..n]);
                    out.cwd = cwd_buf[0..n];
                }
            }
            var name: [256]u8 = undefined;
            const nn = proc_name(pid, &name, name.len);
            if (nn > 0) {
                const len = @min(@as(usize, @intCast(nn)), cmd_buf.len);
                @memcpy(cmd_buf[0..len], name[0..len]);
                out.command = cmd_buf[0..len];
            }
        },
        .linux => {
            var path: [64]u8 = undefined;
            if (std.fmt.bufPrintZ(&path, "/proc/{d}/cwd", .{pid})) |p| {
                const n = readLinkC(p.ptr, cwd_buf);
                if (n > 0) out.cwd = cwd_buf[0..n];
            } else |_| {}
            if (std.fmt.bufPrintZ(&path, "/proc/{d}/comm", .{pid})) |p| {
                const n = readFileC(p.ptr, cmd_buf);
                if (n > 0) {
                    const trimmed = std.mem.trimEnd(u8, cmd_buf[0..n], "\n");
                    out.command = trimmed;
                }
            } else |_| {}
        },
        else => {},
    }
    return out;
}

extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, bufsize: usize) isize;

fn readLinkC(path: [*:0]const u8, buf: []u8) usize {
    const n = readlink(path, buf.ptr, buf.len);
    return if (n > 0) @intCast(n) else 0;
}

fn readFileC(path: [*:0]const u8, buf: []u8) usize {
    const O_RDONLY: c_int = 0;
    const fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    defer close(fd);
    return read(fd, buf) catch 0;
}

/// Which process group is in the foreground of a pseudoterminal — the one
/// a human's keystrokes reach, and the one whose working directory answers
/// "where is this pane standing" ([[RFC-0014]] C-PWD, C-FOREGROUND).
///
/// BOTH ENDS ARE TRIED, and which one answers is not the same as for the
/// size. Measured on Darwin: `tcgetpgrp` returns the group on the MASTER
/// and ENOTTY on the slave, the mirror image of the winsize ioctls, which
/// answer on the slave and refuse on the master. Rather than encode two
/// platform tables that a third platform would falsify, both ends are
/// asked and the first real answer is taken.
///
/// Returns a negative value when the terminal has no foreground group,
/// which a caller must not read as an error to retry.
pub fn foregroundGroup(pty: *const Pty) i32 {
    const from_master = tcgetpgrp(pty.master);
    if (from_master > 0) return from_master;
    return tcgetpgrp(pty.slave);
}

/// Become a process nothing is waiting for.
///
/// TWICE, and the second time matters. The first fork lets the caller
/// return; the child then leaves its parent's session with `setsid`, so
/// the hangup that ends an ssh command does not reach it. The SECOND fork
/// gives up session leadership, which is what stops the process from
/// ever acquiring a controlling terminal by opening one — a holder that
/// adopted a terminal would take a hangup from it, which is precisely the
/// death this exists to avoid.
///
/// Three outcomes, because two forks can each fail: the caller learns
/// whether a grandchild exists (`launched`) or not (`failed`), and only
/// the grandchild sees `in_daemon`. The intermediate child exits with
/// the second fork's verdict and the caller reaps it here, so it is
/// neither a zombie nor a lie — a failed second fork used to exit 0 and
/// leave the caller waiting on a session that would never come up
/// ([[WI-2026-09-02-025]]).
pub const Daemonized = enum { in_daemon, launched, failed };

pub fn daemonize() Daemonized {
    const first = fork();
    if (first < 0) return .failed;
    if (first != 0) {
        var status: c_int = 0;
        while (std.c.waitpid(first, &status, 0) < 0) {
            if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) return .failed;
        }
        const s: u32 = @bitCast(status);
        return if (std.c.W.IFEXITED(s) and std.c.W.EXITSTATUS(s) == 0) .launched else .failed;
    }
    _ = setsid();
    const second = fork();
    if (second < 0) _exit(1); // no grandchild; the caller reads this
    if (second != 0) _exit(0); // the intermediate child has done its job
    // Standard descriptors go to /dev/null: a detached process writing to
    // a terminal that has gone is a SIGPIPE at an arbitrary later moment.
    const O_RDWR: c_int = 2;
    const devnull = open("/dev/null", O_RDWR);
    if (devnull >= 0) {
        _ = std.c.dup2(devnull, 0);
        _ = std.c.dup2(devnull, 1);
        _ = std.c.dup2(devnull, 2);
        if (devnull > 2) _ = std.c.close(devnull);
    }
    return .in_daemon;
}

pub const PtyError = error{
    OpenFailed,
    GrantFailed,
    UnlockFailed,
    NoSlaveName,
    ForkFailed,
};

/// Both ends of a new pseudoterminal.
///
/// THE HOLDER KEEPS THE SLAVE OPEN, for two reasons that are not obvious
/// and cost a debugging session each if rediscovered.
///
/// The size ioctls are the first. On Darwin they answer ENOTTY on the
/// master and succeed on the slave; on Linux either end works. Measured,
/// not assumed — TIOCGWINSZ on a `posix_openpt` master returned errno 25.
/// So the slave is the portable end to ask, and something has to be
/// holding it.
///
/// The last close of the slave is the second. When no slave fd remains
/// open, a read on the master reports end-of-file — and a child that
/// wrote its final line and exited immediately can lose it that way. The
/// holder learns of the exit from `waitpid` instead, so keeping its own
/// slave fd open costs one descriptor and removes that race entirely.
pub const Pty = struct {
    master: fd_t,
    slave: fd_t,

    pub fn deinit(self: *const Pty) void {
        close(self.slave);
        close(self.master);
    }
};

pub fn openPty() PtyError!Pty {
    // O_NOCTTY on both ends: opening a terminal must not make it OURS. A
    // holder with no controlling terminal of its own — which is every
    // holder started from a daemon — would otherwise adopt the pty it
    // just created, and then the child could not.
    const O_RDWR: c_int = 2;
    const O_NOCTTY: c_int = switch (builtin.os.tag) {
        .macos => 0x20000,
        .linux => 0x100,
        else => unreachable,
    };
    const master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) return error.OpenFailed;
    errdefer close(master);
    if (grantpt(master) != 0) return error.GrantFailed;
    if (unlockpt(master) != 0) return error.UnlockFailed;
    const name = ptsname(master) orelse return error.NoSlaveName;
    const slave = open(name, O_RDWR | O_NOCTTY);
    if (slave < 0) return error.OpenFailed;
    return .{ .master = master, .slave = slave };
}

/// The size of a terminal a client is looking at — its own tty, not a
/// holder's. Same ioctl, different subject.
pub const WinsizeError = error{
    /// The descriptor has no window size to report — it is not a
    /// terminal, or has stopped being one. NAMED RATHER THAN UNEXPECTED,
    /// for the reason [[TimeoutError]] gives; a client polls this on a
    /// timer, so the stack trace would land in the terminal's own output.
    NotATerminal,
} || posix.UnexpectedError;

pub fn winsizeOf(fd: fd_t) WinsizeError!winsize {
    var ws = winsize{};
    if (ioctl(fd, TIOC.GWINSZ, &ws) == 0) return ws;
    return switch (@as(E, @enumFromInt(errnoValue()))) {
        .NODEV, .NOTTY, .BADF, .INVAL => error.NotATerminal,
        else => errnoError(),
    };
}

/// The terminal settings of `fd`, and the same with every kind of local
/// processing turned off.
///
/// RAW IS THE ONLY CORRECT MODE FOR A CLIENT. A client is a pipe between
/// a human's terminal and a terminal on another machine, and every
/// convenience the local tty offers — echo, line buffering, signal keys,
/// CR translation — is a second terminal interpreting keystrokes the far
/// one is about to interpret again. Ctrl-C is the visible case: cooked,
/// it kills the client; raw, it reaches the program the human meant.
pub const Termios = std.c.termios;

extern "c" fn tcgetattr(fd: c_int, t: *Termios) c_int;
extern "c" fn tcsetattr(fd: c_int, action: c_int, t: *const Termios) c_int;
extern "c" fn cfmakeraw(t: *Termios) void;

pub fn getTermios(fd: fd_t) !Termios {
    var t: Termios = undefined;
    if (tcgetattr(fd, &t) != 0) return errnoError();
    return t;
}

pub fn setTermios(fd: fd_t, t: *const Termios) !void {
    // TCSANOW: the human pressed a key expecting the mode they can see,
    // so a change that waits for the output queue to drain is a change
    // that applies to keystrokes typed under the old rules.
    const TCSANOW: c_int = 0;
    if (tcsetattr(fd, TCSANOW, t) != 0) return errnoError();
}

pub fn makeRaw(fd: fd_t) !Termios {
    const saved = try getTermios(fd);
    var raw = saved;
    cfmakeraw(&raw);
    try setTermios(fd, &raw);
    return saved;
}

/// Size is set and read on the SLAVE end — see `Pty`.
pub fn setWinsize(pty: *const Pty, ws: winsize) !void {
    var copy = ws;
    if (ioctl(pty.slave, TIOC.SWINSZ, &copy) != 0) return errnoError();
}

pub fn getWinsize(pty: *const Pty) !winsize {
    var ws = winsize{};
    if (ioctl(pty.slave, TIOC.GWINSZ, &ws) != 0) return errnoError();
    return ws;
}

/// Fork a child onto `pty`'s slave end and exec `argv` there.
///
/// FORK, NOT `std.process.Child`: between the fork and the exec the child
/// has to do three things no spawn API exposes — leave its parent's
/// session, claim the terminal as its controlling one, and put that
/// terminal on all three standard descriptors. Everything in the child
/// path below is async-signal-safe by construction, and this is called
/// before the holder starts any thread.
///
/// `env` entries are "NAME=VALUE" and are applied in the child, so the
/// parent's own environment is not disturbed by what it hands a child.
pub fn spawnOnPty(
    pty: *const Pty,
    argv: []const [*:0]const u8,
    env: []const [*:0]const u8,
    ws: winsize,
) PtyError!i32 {
    var argv_buf: [64]?[*:0]const u8 = undefined;
    if (argv.len == 0 or argv.len >= argv_buf.len) return error.ForkFailed;
    for (argv, 0..) |a, i| argv_buf[i] = a;
    argv_buf[argv.len] = null;

    // BEFORE THE FORK. The child's first repaint then happens at the size
    // it will keep, rather than at the kernel's 0x0 followed by a resize
    // the human sees as a flicker — and a shell that asks `stty size`
    // before any resize arrives gets the truth.
    setWinsize(pty, ws) catch {};

    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid > 0) return pid;

    // ---- child ----
    // The slave was inherited across the fork, so it is claimed rather
    // than reopened: reopening by name is a second lookup of a path that
    // could have been recycled, and buys nothing.
    if (setsid() < 0) _exit(127);
    if (ioctl(pty.slave, TIOC.SCTTY, @as(c_int, 0)) != 0) _exit(127);
    _ = std.c.dup2(pty.slave, 0);
    _ = std.c.dup2(pty.slave, 1);
    _ = std.c.dup2(pty.slave, 2);
    if (pty.slave > 2) _ = std.c.close(pty.slave);
    _ = std.c.close(pty.master);
    for (env) |e| {
        const eq = std.mem.indexOfScalar(u8, std.mem.span(e), '=') orelse continue;
        var name_buf: [256]u8 = undefined;
        if (eq >= name_buf.len) continue;
        @memcpy(name_buf[0..eq], e[0..eq]);
        name_buf[eq] = 0;
        _ = setenv(@ptrCast(&name_buf), @ptrCast(e + eq + 1), 1);
    }
    _ = execvp(argv[0], @ptrCast(&argv_buf));
    _exit(127);
}

/// Read an environment variable (libc getenv). Returns null when unset.
/// Block until `pid` exits, using kqueue's process filter — the kernel
/// tells us, so there is no polling interval to get wrong
/// ([[ADR-0008]] supervised-hub lifetime, WI-2026-08-12-001).
///
/// Returns immediately (true) if the process is already gone. Returns
/// false only when the watch could not be established at all, which the
/// caller must treat as "watchdog unavailable" and fall back to polling
/// — never as "the parent is alive".
pub fn waitForPidExit(pid: i32) bool {
    if (builtin.os.tag != .macos) return false;
    const kq = std.c.kqueue();
    if (kq < 0) return false;
    defer close(kq);

    var change = std.c.Kevent{
        .ident = @intCast(pid),
        .filter = std.c.EVFILT.PROC,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.ONESHOT,
        .fflags = std.c.NOTE.EXIT,
        .data = 0,
        .udata = 0,
    };
    var event: std.c.Kevent = undefined;
    // Registering a watch on a dead pid fails with ESRCH — which is the
    // answer we wanted, not an error.
    if (std.c.kevent(kq, @ptrCast(&change), 1, @ptrCast(&event), 0, null) < 0) {
        return errnoValue() == @intFromEnum(posix.E.SRCH);
    }
    // Blocking wait for the exit notification (no timeout).
    return std.c.kevent(kq, @ptrCast(&change), 0, @ptrCast(&event), 1, null) > 0;
}

/// Is `pid` still alive? signal 0 probes without delivering; EPERM means
/// alive-but-not-ours. The fallback when kqueue is unavailable.
pub fn pidAlive(pid: i32) bool {
    if (std.c.kill(pid, @enumFromInt(0)) == 0) return true;
    return errnoValue() == @intFromEnum(posix.E.PERM);
}

pub fn getenv(name: []const u8) ?[]const u8 {
    var buf: [256:0]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const v = system.getenv(buf[0..name.len :0].ptr) orelse return null;
    return std.mem.span(v);
}

// ---------------------------------------------------------------------------
// Executable path
// ---------------------------------------------------------------------------

extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;

/// Absolute path of the running executable. Zig 0.16 removed
/// std.fs.selfExePath, so this uses the platform primitives directly —
/// the same reason src/sys.zig exists at all.
///
/// argv[0] is NOT a substitute: it is whatever the caller chose to pass,
/// commonly a relative path or a bare name found on PATH, and re-exec'ing
/// it from a detached process with a different cwd would fail or, worse,
/// run a different binary.
pub fn selfExePath(buf: []u8) ?[]const u8 {
    switch (@import("builtin").os.tag) {
        .macos, .ios, .watchos, .tvos => {
            var size: u32 = @intCast(buf.len);
            if (_NSGetExecutablePath(buf.ptr, &size) != 0) return null;
            const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
            return buf[0..len];
        },
        else => {
            const n = std.c.readlink("/proc/self/exe", buf.ptr, buf.len);
            if (n <= 0) return null;
            return buf[0..@intCast(n)];
        },
    }
}

extern "c" fn gethostname(name: [*]u8, len: usize) c_int;

/// This machine's hostname, or null. Used as the DEFAULT peer id for a
/// hub nobody configured — a service hub on a remote box has no human
/// present to name it, and "the machine is the authority on what it is
/// called" (RFC-0009 C-BOUNDARIES) makes its own hostname the right
/// default rather than a name the dialing side imposes.
pub fn hostName(buf: []u8) ?[]const u8 {
    if (gethostname(buf.ptr, buf.len) != 0) return null;
    const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    if (len == 0) return null;
    // Bare host, not the FQDN: the short name is what a human labels a
    // box with, and it is stable across DNS suffix changes.
    const dot = std.mem.indexOfScalar(u8, buf[0..len], '.') orelse len;
    return buf[0..dot];
}

test "hostName returns a usable short name" {
    var buf: [256]u8 = undefined;
    const h = hostName(&buf) orelse return error.NoHostName;
    try std.testing.expect(h.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, h, '.') == null);
}

test "selfExePath resolves to an absolute path that exists" {
    var buf: [4096]u8 = undefined;
    const p = selfExePath(&buf) orelse return error.NoSelfExePath;
    try std.testing.expect(p.len > 0);
    try std.testing.expectEqual(@as(u8, '/'), p[0]);
    // It must be re-executable: a detached hub is spawned from exactly
    // this path, so a value that does not resolve is not a warning, it
    // is a hub that never starts.
    var zbuf: [4097]u8 = undefined;
    const pz = try std.fmt.bufPrintZ(&zbuf, "{s}", .{p});
    try std.testing.expectEqual(@as(c_int, 0), std.c.access(pz.ptr, 1)); // X_OK
}

// ---------------------------------------------------------------------------
// Pseudoterminal tests ([[WI-2026-08-17-003]])
// ---------------------------------------------------------------------------

/// Read from `fd` until `needle` appears or the deadline passes. Returns
/// what was read. A pty master keeps a session's echo and its child's
/// output in one stream, so tests match rather than compare.
fn readUntil(fd: fd_t, buf: []u8, needle: []const u8, ms: u64) []const u8 {
    var total: usize = 0;
    var waited: u64 = 0;
    while (waited < ms) {
        var chunk: [1024]u8 = undefined;
        const n = read(fd, &chunk) catch |err| switch (err) {
            error.WouldBlock => {
                _ = usleep(10 * 1000);
                waited += 10;
                continue;
            },
            else => break,
        };
        if (n == 0) break;
        const room = @min(n, buf.len - total);
        @memcpy(buf[total .. total + room], chunk[0..room]);
        total += room;
        if (std.mem.indexOf(u8, buf[0..total], needle) != null) break;
    }
    return buf[0..total];
}

test "a child spawned on a pty has a terminal on its standard input" {
    const pty = try openPty();
    defer pty.deinit();
    try setNonblocking(pty.master);

    const pid = try spawnOnPty(
        &pty,
        &.{ "/bin/sh", "-c", "test -t 0 && printf IS_A_TTY" },
        &.{},
        .{ .ws_row = 24, .ws_col = 80 },
    );
    defer _ = std.c.waitpid(pid, null, 0);

    var buf: [4096]u8 = undefined;
    const out = readUntil(pty.master, &buf, "IS_A_TTY", 3000);
    try std.testing.expect(std.mem.indexOf(u8, out, "IS_A_TTY") != null);
}

test "the child sees the size the parent set, not a default" {
    const pty = try openPty();
    defer pty.deinit();
    try setNonblocking(pty.master);

    const pid = try spawnOnPty(
        &pty,
        &.{ "/bin/sh", "-c", "stty size" },
        &.{},
        .{ .ws_row = 37, .ws_col = 133 },
    );
    defer _ = std.c.waitpid(pid, null, 0);

    var buf: [4096]u8 = undefined;
    const out = readUntil(pty.master, &buf, "37 133", 3000);
    try std.testing.expect(std.mem.indexOf(u8, out, "37 133") != null);
}

test "the parent's writes reach the child's terminal" {
    const pty = try openPty();
    defer pty.deinit();
    try setNonblocking(pty.master);

    const pid = try spawnOnPty(
        &pty,
        &.{ "/bin/sh", "-c", "read line; printf 'ECHOED:%s' \"$line\"" },
        &.{},
        .{ .ws_row = 24, .ws_col = 80 },
    );
    defer _ = std.c.waitpid(pid, null, 0);

    // The shell has to reach `read` before input means anything to it.
    _ = usleep(200 * 1000);
    try writeAll(pty.master, "hello\r");

    var buf: [4096]u8 = undefined;
    const out = readUntil(pty.master, &buf, "ECHOED:hello", 3000);
    try std.testing.expect(std.mem.indexOf(u8, out, "ECHOED:hello") != null);
}

test "the environment handed to the child is the child's, not ours" {
    const pty = try openPty();
    defer pty.deinit();
    try setNonblocking(pty.master);

    const pid = try spawnOnPty(
        &pty,
        &.{ "/bin/sh", "-c", "printf 'ID:%s' \"$SYNAPTY_TEST_ID\"" },
        &.{"SYNAPTY_TEST_ID=holder-7f3c"},
        .{ .ws_row = 24, .ws_col = 80 },
    );
    defer _ = std.c.waitpid(pid, null, 0);

    var buf: [4096]u8 = undefined;
    const out = readUntil(pty.master, &buf, "ID:holder-7f3c", 3000);
    try std.testing.expect(std.mem.indexOf(u8, out, "ID:holder-7f3c") != null);
    // Setting it in the child must not have set it here.
    try std.testing.expect(getenv("SYNAPTY_TEST_ID") == null);
}

test "winsize survives a round trip through the master" {
    const pty = try openPty();
    defer pty.deinit();
    try setWinsize(&pty, .{ .ws_row = 11, .ws_col = 222 });
    const got = try getWinsize(&pty);
    try std.testing.expectEqual(@as(u16, 11), got.ws_row);
    try std.testing.expectEqual(@as(u16, 222), got.ws_col);
}

test "a process's own working directory and command come back from the kernel" {
    // Asked of THIS process, which is the one case where the answer is
    // already known ([[RFC-0014]] C-PWD).
    var cwd_buf: [1024]u8 = undefined;
    var cmd_buf: [256]u8 = undefined;
    const info = procInfo(std.c.getpid(), &cwd_buf, &cmd_buf);
    try std.testing.expect(info.cwd.len > 0);
    try std.testing.expectEqual(@as(u8, '/'), info.cwd[0]);
    try std.testing.expect(info.command.len > 0);
}

test "an absent process answers nothing rather than something" {
    var cwd_buf: [1024]u8 = undefined;
    var cmd_buf: [256]u8 = undefined;
    // A pid that cannot be running: the kernel refuses, and a caller that
    // substituted a default here would send a file to a directory nobody
    // asked for.
    const info = procInfo(0x7FFF_FFFE, &cwd_buf, &cmd_buf);
    try std.testing.expectEqual(@as(usize, 0), info.cwd.len);
}

test "a terminal reports the process group in its foreground" {
    const pty = try openPty();
    defer pty.deinit();
    try setNonblocking(pty.master);
    const pid = try spawnOnPty(&pty, &.{ "/bin/sh", "-c", "sleep 5" }, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        _ = std.c.kill(pid, @enumFromInt(9));
        _ = std.c.waitpid(pid, null, 0);
    }
    _ = usleep(300 * 1000);
    const pgrp = foregroundGroup(&pty);
    try std.testing.expect(pgrp > 0);
}

test "a wait on a quiet terminal ends by itself" {
    const pty = try openPty();
    defer pty.deinit();

    // Nothing has been written, so the wait must RETURN rather than park.
    // That return is the only thing that lets a reader thread notice it
    // was told to stop while its terminal stays quiet — a thread parked in
    // read() notices nothing, and the join that waits for it is what makes
    // a client outlive the session it was showing.
    try std.testing.expect(!try waitReadable(pty.master, 20));

    try writeAll(pty.slave, "x");
    try std.testing.expect(try waitReadable(pty.master, 1000));
}


// ---------------------------------------------------------------------------
// Threads that end are joined while the process lives
// ---------------------------------------------------------------------------

/// A LIST OF THREADS THAT ONLY EVER GREW ([[WI-2026-09-02-015]]). The hub
/// spawned one reader per accepted connection and joined them all in
/// deinit; the daemon did the same for IPC connections. An exited joinable
/// thread keeps its stack reservation until joined, and the workbench's
/// own health probe connects every few seconds — so a long-lived service
/// hub leaked one dead thread per probe, forever. Each tracked thread
/// flips a flag as its last act; `reap` joins the flagged ones, and the
/// owner calls it wherever it already does work (on every accept), so the
/// list is bounded by the LIVE connections and deinit still joins the rest.
pub const ThreadReaper = struct {
    const Entry = struct { thread: std.Thread, done: *std.atomic.Value(bool) };

    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// A spin lock rather than std.Io.Mutex: this module has no io, and
    /// the lock is held for a list append or a sweep — never across a
    /// join or a syscall.
    lock_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *ThreadReaper) void {
        while (self.lock_flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlock(self: *ThreadReaper) void {
        self.lock_flag.store(false, .release);
    }

    pub fn init(allocator: std.mem.Allocator) ThreadReaper {
        return .{ .allocator = allocator };
    }

    fn Runner(comptime Func: anytype, comptime Args: type) type {
        return struct {
            fn run(done: *std.atomic.Value(bool), args: Args) void {
                defer done.store(true, .release);
                @call(.auto, Func, args);
            }
        };
    }

    /// Spawn `f` with `args` and track it. On spawn failure nothing is
    /// tracked and the error is the caller's to handle.
    pub fn spawn(self: *ThreadReaper, comptime f: anytype, args: anytype) !void {
        const done = try self.allocator.create(std.atomic.Value(bool));
        errdefer self.allocator.destroy(done);
        done.* = std.atomic.Value(bool).init(false);
        const thread = try std.Thread.spawn(.{}, Runner(f, @TypeOf(args)).run, .{ done, args });
        self.lock();
        const appended = self.entries.append(self.allocator, .{ .thread = thread, .done = done });
        self.unlock();
        appended catch |err| {
            // Cannot remember it: wait for it here rather than leak a
            // thread nobody will ever join.
            thread.join();
            self.allocator.destroy(done);
            return err;
        };
    }

    /// Join every thread that has finished; returns how many were reaped.
    pub fn reap(self: *ThreadReaper) usize {
        self.lock();
        defer self.unlock();
        var reaped: usize = 0;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            if (e.done.load(.acquire)) {
                e.thread.join();
                self.allocator.destroy(e.done);
                _ = self.entries.swapRemove(i);
                reaped += 1;
            } else {
                i += 1;
            }
        }
        return reaped;
    }

    /// Threads still tracked (finished-but-unreaped ones count until
    /// `reap`).
    pub fn live(self: *ThreadReaper) usize {
        self.lock();
        defer self.unlock();
        return self.entries.items.len;
    }

    /// Join everything, finished or not. The caller has made the threads
    /// able to finish (shut their fds) before this.
    pub fn joinAll(self: *ThreadReaper) void {
        self.lock();
        const entries = self.entries.toOwnedSlice(self.allocator) catch &.{};
        self.unlock();
        for (entries) |e| {
            e.thread.join();
            self.allocator.destroy(e.done);
        }
        self.allocator.free(entries);
    }

    pub fn deinit(self: *ThreadReaper) void {
        self.joinAll();
        self.entries.deinit(self.allocator);
    }
};

fn reaperProbe(flag: *std.atomic.Value(u32)) void {
    _ = flag.fetchAdd(1, .acq_rel);
}

test "ThreadReaper joins what has finished and keeps only what is live (WI-2026-09-02-015)" {
    var reaper = ThreadReaper.init(std.testing.allocator);
    defer reaper.deinit();
    var ran = std.atomic.Value(u32).init(0);
    var i: usize = 0;
    while (i < 8) : (i += 1) try reaper.spawn(reaperProbe, .{&ran});
    // THE WAIT IS ON THE CLOCK. A bound in spin iterations is a bound in
    // nanoseconds, and a thread that has run its body is still a
    // scheduler's whim away from storing `done`; on a loaded CI runner
    // the last of eight was not there yet and the test reported a live
    // thread that was merely late (run 33699006905). Five seconds is
    // beyond any wait a healthy machine takes and short enough to fail.
    const deadline = nowMillis() + 5_000;
    const pause: std.c.timespec = .{ .sec = 0, .nsec = 1_000_000 };
    while (nowMillis() < deadline) {
        _ = reaper.reap();
        if (reaper.live() == 0) break;
        _ = std.c.nanosleep(&pause, null);
    }
    try std.testing.expectEqual(@as(usize, 0), reaper.live());
    try std.testing.expectEqual(@as(u32, 8), ran.load(.acquire));
}
