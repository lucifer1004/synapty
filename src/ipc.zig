const std = @import("std");
const sys = @import("sys");
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
        try sys.listen(fd, 16);
        return .{
            .listener_fd = fd,
            .socket_path = socket_path,
        };
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
    pub fn readLine(fd: sys.fd_t, buf: []u8) !?[]const u8 {
        var i: usize = 0;
        while (i < buf.len) {
            var byte: [1]u8 = undefined;
            const n = try sys.read(fd, &byte);
            if (n == 0) {
                if (i == 0) return null; // EOF with no data
                return buf[0..i]; // EOF after partial line
            }
            if (byte[0] == '\n') return buf[0..i];
            buf[i] = byte[0];
            i += 1;
        }
        return error.StreamTooLong;
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

    /// Read a line from the server (without '\n'). Returns null on EOF.
    pub fn recv(self: *IpcClient, buf: []u8) !?[]const u8 {
        return IpcServer.readLine(self.fd, buf);
    }
};

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
