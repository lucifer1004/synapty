const std = @import("std");
const net = std.net;
const mem = std.mem;
const posix = std.posix;

// ---------------------------------------------------------------------------
// IpcServer
// ---------------------------------------------------------------------------

pub const IpcServer = struct {
    listener: net.Server,
    socket_path: []const u8,

    /// Bind a unix domain socket at socket_path.
    pub fn init(socket_path: []const u8) !IpcServer {
        const address = try net.Address.initUnix(socket_path);
        const listener = try address.listen(.{});
        return .{
            .listener = listener,
            .socket_path = socket_path,
        };
    }

    /// Close listener, unlink socket file.
    pub fn deinit(self: *IpcServer) void {
        self.listener.deinit();
        posix.unlink(self.socket_path) catch {};
    }

    /// Accept a connection, returning the client stream.
    pub fn accept(self: *IpcServer) !net.Stream {
        const conn = try self.listener.accept();
        return conn.stream;
    }

    /// Read bytes from stream until '\n', returning the line without '\n'.
    /// Returns null on EOF. Returns error.StreamTooLong if line exceeds buf.
    pub fn readLine(stream: net.Stream, buf: []u8) !?[]const u8 {
        var i: usize = 0;
        while (i < buf.len) {
            var byte: [1]u8 = undefined;
            const n = try stream.read(&byte);
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

    /// Write data followed by '\n' to stream.
    pub fn writeLine(stream: net.Stream, data: []const u8) !void {
        try stream.writeAll(data);
        try stream.writeAll("\n");
    }
};

// ---------------------------------------------------------------------------
// IpcClient
// ---------------------------------------------------------------------------

pub const IpcClient = struct {
    stream: net.Stream,

    /// Connect to a unix domain socket at socket_path.
    pub fn connect(socket_path: []const u8) !IpcClient {
        const stream = try net.connectUnixSocket(socket_path);
        return .{ .stream = stream };
    }

    /// Close the stream.
    pub fn deinit(self: *IpcClient) void {
        self.stream.close();
    }

    /// Write data + '\n' to the server.
    pub fn send(self: *IpcClient, data: []const u8) !void {
        try IpcServer.writeLine(self.stream, data);
    }

    /// Read a line from the server (without '\n'). Returns null on EOF.
    pub fn recv(self: *IpcClient, buf: []u8) !?[]const u8 {
        return IpcServer.readLine(self.stream, buf);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "IpcServer init/deinit creates and removes socket file" {
    const path = "/tmp/synapty-test-init.sock";
    // Ensure no leftover socket from a previous run.
    posix.unlink(path) catch {};

    var server = try IpcServer.init(path);

    // Socket file should exist after init.
    const stat = try std.fs.cwd().statFile(path);
    _ = stat;

    server.deinit();

    // Socket file should be removed after deinit.
    const result = std.fs.cwd().statFile(path);
    try std.testing.expectError(error.FileNotFound, result);
}

test "IpcClient connects to IpcServer" {
    const path = "/tmp/synapty-test-connect.sock";
    posix.unlink(path) catch {};

    var server = try IpcServer.init(path);
    defer server.deinit();

    var client = try IpcClient.connect(path);
    defer client.deinit();

    const conn = try server.accept();
    defer conn.close();
}

test "Client send + Server readLine round-trip" {
    const path = "/tmp/synapty-test-send.sock";
    posix.unlink(path) catch {};

    var server = try IpcServer.init(path);
    defer server.deinit();

    var client = try IpcClient.connect(path);
    defer client.deinit();

    const conn = try server.accept();
    defer conn.close();

    try client.send("hello world");

    var buf: [256]u8 = undefined;
    const line = try IpcServer.readLine(conn, &buf);
    try std.testing.expect(line != null);
    try std.testing.expectEqualStrings("hello world", line.?);
}

test "Server writeLine + Client recv round-trip" {
    const path = "/tmp/synapty-test-recv.sock";
    posix.unlink(path) catch {};

    var server = try IpcServer.init(path);
    defer server.deinit();

    var client = try IpcClient.connect(path);
    defer client.deinit();

    const conn = try server.accept();
    defer conn.close();

    try IpcServer.writeLine(conn, "response data");

    var buf: [256]u8 = undefined;
    const line = try client.recv(&buf);
    try std.testing.expect(line != null);
    try std.testing.expectEqualStrings("response data", line.?);
}

test "Full request-response cycle" {
    const path = "/tmp/synapty-test-cycle.sock";
    posix.unlink(path) catch {};

    var server = try IpcServer.init(path);
    defer server.deinit();

    var client = try IpcClient.connect(path);
    defer client.deinit();

    const conn = try server.accept();
    defer conn.close();

    // Client sends a request.
    try client.send("{\"action\":\"agents\"}");

    // Server reads the request.
    var req_buf: [512]u8 = undefined;
    const req_line = try IpcServer.readLine(conn, &req_buf);
    try std.testing.expect(req_line != null);
    try std.testing.expectEqualStrings("{\"action\":\"agents\"}", req_line.?);

    // Server sends a response.
    try IpcServer.writeLine(conn, "{\"success\":true,\"data\":\"agent-a,agent-b\"}");

    // Client reads the response.
    var resp_buf: [512]u8 = undefined;
    const resp_line = try client.recv(&resp_buf);
    try std.testing.expect(resp_line != null);
    try std.testing.expectEqualStrings("{\"success\":true,\"data\":\"agent-a,agent-b\"}", resp_line.?);
}
