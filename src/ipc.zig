const std = @import("std");
const sys = @import("sys");
const framing = @import("framing");
const io_mod = @import("io");
const mem = std.mem;
const posix = std.posix;

// ---------------------------------------------------------------------------
// IpcServer
// ---------------------------------------------------------------------------

pub const IpcServer = struct {
    listener_fd: sys.fd_t,
    socket_path: []const u8,

    /// Bind a unix domain socket at socket_path.
    pub fn init(socket_path: []const u8) !IpcServer {
        // Remove any stale socket file left by a previous crashed run.
        sys.unlink(socket_path);

        const fd = try sys.socket(sys.AF.UNIX, sys.SOCK.STREAM, 0);
        errdefer sys.close(fd);
        const addr = sys.sockaddr_un.init(socket_path) orelse return error.NameTooLong;
        try sys.bind(fd, &addr, addr.len());
        // Owner-only: /tmp is world-readable and the socket carries the
        // agent's full IPC capability (recv/send/mcp) — any other local
        // user must not be able to connect (WI-2026-08-08-017).
        try sys.chmod(socket_path, 0o700);
        try sys.listen(fd, 16);
        return .{
            .listener_fd = fd,
            .socket_path = socket_path,
        };
    }

    /// A BOUND LISTENER AND A REACHABLE ONE ARE DIFFERENT THINGS. The path
    /// is what clients connect through, and it can be removed while this
    /// process is alive and still holding the socket bound to it — a pane
    /// was found in exactly that state, its wrapper healthy and every
    /// `connect` since answering ENOENT ([[WI-2026-09-03-007]]). Nothing
    /// in the process notices on its own: the fd is fine, `accept` simply
    /// never hears from anyone again.
    ///
    /// So the listener re-binds rather than staying quietly unreachable.
    /// Returns true when it had to. Whoever removed the path does not
    /// matter here; a pane that can be reached again is the answer to all
    /// of them.
    ///
    /// A FRESH SOCKET, NOT A RENAMED ONE: a unix path cannot be re-linked
    /// to an existing bound socket, so this binds a new one and closes the
    /// old. Connections already accepted are unaffected — they are their
    /// own descriptors — and one parked in the old listener's backlog is
    /// lost, which is the same thing that happens to a client that gave up
    /// waiting.
    pub fn ensureBound(self: *IpcServer) bool {
        if (pathIsSocket(self.socket_path)) return false;
        // init() unlinks first, so a path that reappeared between the
        // check and here is replaced rather than colliding.
        const fresh = IpcServer.init(self.socket_path) catch return false;
        sys.close(self.listener_fd);
        self.listener_fd = fresh.listener_fd;
        return true;
    }

    /// Close listener, unlink socket file.
    pub fn deinit(self: *IpcServer) void {
        sys.close(self.listener_fd);
        sys.unlink(self.socket_path);
    }

    /// Accept a connection, returning the client fd.
    pub fn accept(self: *IpcServer) !sys.fd_t {
        return sys.accept(self.listener_fd);
    }

    /// Read bytes from fd until '\n', returning the line without '\n'.
    /// Returns null on EOF. Returns error.StreamTooLong if line exceeds buf.
    ///
    /// ONE-SHOT, BY CONTRACT. A fresh LineBuffer is built per call, so any
    /// bytes read past the first newline are dropped with it. That is
    /// correct for the IPC protocol, which carries exactly one line each
    /// way per connection, and wrong for anything pipelined — a reader
    /// that expects a second line on the same fd must hold its own
    /// framing.LineBuffer across calls ([[WI-2026-09-02-025]]).
    pub fn readLine(fd: sys.fd_t, buf: []u8) !?[]const u8 {
        var lb = framing.LineBuffer.init(buf);
        return lb.readLine(fd);
    }

    /// Write data followed by '\n' to fd.
    pub fn writeLine(fd: sys.fd_t, data: []const u8) !void {
        try sys.writeAll(fd, data);
        try sys.writeAll(fd, "\n");
    }
};

// ---------------------------------------------------------------------------
// IpcClient
// ---------------------------------------------------------------------------

pub const IpcClient = struct {
    fd: sys.fd_t,

    /// Connect to a unix domain socket at socket_path.
    pub fn connect(socket_path: []const u8) !IpcClient {
        const fd = try sys.socket(sys.AF.UNIX, sys.SOCK.STREAM, 0);
        errdefer sys.close(fd);
        const addr = sys.sockaddr_un.init(socket_path) orelse return error.NameTooLong;
        try sys.connect(fd, &addr, addr.len());
        return .{ .fd = fd };
    }

    /// Close the stream.
    pub fn deinit(self: *IpcClient) void {
        sys.close(self.fd);
    }

    /// Write data + '\n' to the server.
    pub fn send(self: *IpcClient, data: []const u8) !void {
        try IpcServer.writeLine(self.fd, data);
    }

    /// How long a reply may take to START arriving. A pane daemon that has
    /// wedged used to hang every in-pane verb — and hook-event, which the
    /// hooks' discipline says must never block the harness
    /// ([[WI-2026-09-02-033]]).
    pub const reply_timeout_ms: i32 = 10_000;

    /// Read a line from the server (without '\n'). Returns null on EOF and
    /// `error.Timeout` when nothing has arrived within `reply_timeout_ms`.
    pub fn recv(self: *IpcClient, buf: []u8) !?[]const u8 {
        return self.recvWithin(buf, reply_timeout_ms);
    }

    /// `timeout_ms < 0` waits for as long as it takes: `recv --wait` is a
    /// request whose whole point is to block until mail arrives, and a
    /// deadline meant for a wedged daemon killed it at ten seconds
    /// ([[WI-2026-09-02-036]]).
    pub fn recvWithin(self: *IpcClient, buf: []u8, timeout_ms: i32) !?[]const u8 {
        if (timeout_ms >= 0 and !try sys.waitReadable(self.fd, timeout_ms)) return error.Timeout;
        return IpcServer.readLine(self.fd, buf);
    }
};

test "a client that hears nothing gives up rather than waiting for a daemon that has wedged" {
    var fds: [2]c_int = undefined;
    try std.testing.expect(std.c.socketpair(sys.AF.UNIX, sys.SOCK.STREAM, 0, &fds) == 0);
    defer sys.close(fds[1]);
    var client = IpcClient{ .fd = fds[0] };
    defer client.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.Timeout, client.recvWithin(&buf, 50));
    try sys.writeAll(fds[1], "late\n");
    try std.testing.expectEqualStrings("late", (try client.recvWithin(&buf, 1000)).?);
}

/// Is there a socket at this path RIGHT NOW?
///
/// `stat`, not `connect`: a daemon whose backlog is full refuses
/// connections while being perfectly reachable, and rebinding under it
/// would be the cure becoming the disease — the distinction that already
/// cost this codebase a bug once ([[holder.claimState]]).
///
/// Through `std.Io` rather than libc, which is how the stale-socket sweep
/// asks the same question ([[run.sweepStaleSocketsIn]]). `std.c.fstatat`
/// is macOS-only in 0.16, so a libc spelling here compiled on the host
/// and broke every musl deploy target.
fn pathIsSocket(path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io_mod.get(), path, .{}) catch return false;
    return st.kind == .unix_domain_socket;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "IpcServer init/deinit creates and removes socket file" {
    const io = io_mod.get();
    const path = "/tmp/synapty-test-init.sock";
    // Ensure no leftover socket from a previous run.
    sys.unlink(path);

    var server = try IpcServer.init(path);

    // Socket file should exist after init.
    _ = try std.Io.Dir.cwd().statFile(io, path, .{});

    server.deinit();

    // Socket file should be removed after deinit.
    const result = std.Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectError(error.FileNotFound, result);
}

test "a listener whose path was removed under it binds the path again" {
    const path = "/tmp/synapty-test-rebind.sock";
    sys.unlink(path);

    var server = try IpcServer.init(path);
    defer server.deinit();

    // An intact path is not a reason to rebuild anything.
    try std.testing.expect(!server.ensureBound());

    // THE OBSERVED FAILURE: the path goes, the listener stays. The process
    // is fine and still holds the bound socket, so nothing in it notices —
    // but every client now gets ENOENT, for the pane's whole life.
    sys.unlink(path);
    try std.testing.expectError(error.FileNotFound, IpcClient.connect(path));

    try std.testing.expect(server.ensureBound());

    // Reachable again, and it is THIS server that answers.
    var client = try IpcClient.connect(path);
    defer client.deinit();
    try client.send("ping");
    const conn = try server.accept();
    defer sys.close(conn);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ping", (try IpcServer.readLine(conn, &buf)).?);
}
