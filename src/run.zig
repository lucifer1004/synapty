const std = @import("std");
const net = std.net;
const mem = std.mem;
const json = std.json;
const posix = std.posix;
const protocol = @import("protocol");
const ipc = @import("ipc");
const Allocator = mem.Allocator;
const log = std.log.scoped(.run);

// ---------------------------------------------------------------------------
// MessageQueue — thread-safe FIFO for incoming Hub messages
// ---------------------------------------------------------------------------

pub const MessageQueue = struct {
    mutex: std.Thread.Mutex,
    messages: std.ArrayList([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) MessageQueue {
        return .{
            .mutex = .{},
            .messages = std.ArrayList([]const u8).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MessageQueue) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg);
        }
        self.messages.deinit(self.allocator);
    }

    /// Push a copy of msg onto the queue.
    pub fn push(self: *MessageQueue, msg: []const u8) !void {
        const copy = try self.allocator.dupe(u8, msg);
        errdefer self.allocator.free(copy);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.messages.append(self.allocator, copy);
    }

    /// Drain all messages into a newly allocated slice.
    /// Caller owns both the outer slice and each inner string — free each with
    /// allocator.free(item) then allocator.free(slice).
    pub fn drain(self: *MessageQueue, allocator: Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const count = self.messages.items.len;
        if (count == 0) {
            return try allocator.alloc([]const u8, 0);
        }

        const result = try allocator.alloc([]const u8, count);
        for (self.messages.items, 0..) |item, i| {
            result[i] = item;
        }
        // Clear without freeing items — ownership transferred to caller.
        self.messages.clearRetainingCapacity();
        return result;
    }
};

// ---------------------------------------------------------------------------
// RunServer
// ---------------------------------------------------------------------------

pub const RunServer = struct {
    allocator: Allocator,
    agent_id: []const u8,
    hub_stream: net.Stream,
    ipc_server: ipc.IpcServer,
    socket_path: []const u8,
    message_queue: MessageQueue,
    running: bool,

    /// Create socket path, connect to Hub, send register, create IPC server.
    pub fn init(
        allocator: Allocator,
        agent_id: []const u8,
        hub_addr: []const u8,
        hub_port: u16,
    ) !RunServer {
        const builtin = @import("builtin");
        const pid: i32 = switch (builtin.os.tag) {
            .linux => std.os.linux.getpid(),
            else => std.c.getpid(),
        };
        const socket_path = try std.fmt.allocPrint(allocator, "/tmp/synapty-{d}.sock", .{pid});
        errdefer allocator.free(socket_path);

        // Remove any stale socket from a prior run.
        posix.unlink(socket_path) catch {};

        // Connect to Hub.
        const address = try net.Address.parseIp4(hub_addr, hub_port);
        const hub_stream = try net.tcpConnectToAddress(address);
        errdefer hub_stream.close();

        // Send register envelope.
        const reg = protocol.makeRegisterEnvelope(agent_id, &.{});
        const reg_raw = try protocol.serializeEnvelope(allocator, reg);
        defer allocator.free(reg_raw);
        _ = try hub_stream.write(reg_raw);

        // Bind IPC unix socket.
        const ipc_server = try ipc.IpcServer.init(socket_path);
        errdefer {
            var s = ipc_server;
            s.deinit();
        }

        return RunServer{
            .allocator = allocator,
            .agent_id = agent_id,
            .hub_stream = hub_stream,
            .ipc_server = ipc_server,
            .socket_path = socket_path,
            .message_queue = MessageQueue.init(allocator),
            .running = false,
        };
    }

    pub fn deinit(self: *RunServer) void {
        self.hub_stream.close();
        self.ipc_server.deinit();
        self.message_queue.deinit();
        self.allocator.free(self.socket_path);
    }

    /// Spawn child with PTY passthrough, run background threads, wait for child.
    pub fn run(self: *RunServer, child_argv: []const []const u8) !void {
        self.running = true;

        var child = std.process.Child.init(child_argv, self.allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        // Build env map inheriting current env then adding our vars.
        var env_map = try std.process.getEnvMap(self.allocator);
        defer env_map.deinit();
        try env_map.put("SYNAPTY_AGENT_ID", self.agent_id);
        try env_map.put("SYNAPTY_SOCK", self.socket_path);

        // Prepend the directory of the current executable to PATH so child
        // processes (e.g. MCP servers) can find `synapty`.
        // Works for all deployments: dev (zig-out/bin/), bundled (.app/Resources/),
        // and remote (~/.synapty/bin/).
        var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fs.selfExePath(&self_exe_buf)) |self_exe| {
            if (std.fs.path.dirnamePosix(self_exe)) |exe_dir| {
                if (env_map.get("PATH")) |existing_path| {
                    const new_path = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ exe_dir, existing_path });
                    defer self.allocator.free(new_path);
                    try env_map.put("PATH", new_path);
                } else {
                    try env_map.put("PATH", exe_dir);
                }
            }
        } else |_| {}
        child.env_map = &env_map;

        try child.spawn();

        // Spawn hub reader thread.
        const hub_thread = try std.Thread.spawn(.{}, hubReaderThread, .{self});

        // Spawn IPC server thread.
        const ipc_thread = try std.Thread.spawn(.{}, ipcServerThread, .{self});

        // Wait for child to exit.
        _ = try child.wait();

        // Signal threads to stop and wait for them.
        @atomicStore(bool, &self.running, false, .release);
        hub_thread.join();
        ipc_thread.join();
    }
};

// ---------------------------------------------------------------------------
// Thread functions
// ---------------------------------------------------------------------------

fn hubReaderThread(srv: *RunServer) void {
    var buf: [64 * 1024]u8 = undefined;
    while (@atomicLoad(bool, &srv.running, .acquire)) {
        const n = srv.hub_stream.read(&buf) catch break;
        if (n == 0) break;
        srv.message_queue.push(buf[0..n]) catch |err| {
            log.err("message_queue.push failed: {any}", .{err});
        };
    }
}

fn ipcServerThread(srv: *RunServer) void {
    while (@atomicLoad(bool, &srv.running, .acquire)) {
        const client_stream = srv.ipc_server.accept() catch |err| {
            if (!@atomicLoad(bool, &srv.running, .acquire)) break;
            log.err("ipc accept error: {any}", .{err});
            continue;
        };
        defer client_stream.close();
        handleIpcConnection(srv, client_stream) catch |err| {
            log.err("ipc connection error: {any}", .{err});
        };
    }
}

fn handleIpcConnection(srv: *RunServer, client_stream: net.Stream) !void {
    var buf: [64 * 1024]u8 = undefined;
    const line = try ipc.IpcServer.readLine(client_stream, &buf) orelse return;

    var arena = std.heap.ArenaAllocator.init(srv.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req_parsed = protocol.parseIpcRequest(alloc, line) catch {
        const resp = protocol.IpcResponse{ .success = false, .error_msg = "invalid request" };
        const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
        try ipc.IpcServer.writeLine(client_stream, resp_raw);
        return;
    };
    defer req_parsed.deinit();

    const req = req_parsed.value;

    switch (req.action) {
        .send => {
            const target = req.target orelse {
                const resp = protocol.IpcResponse{ .success = false, .error_msg = "missing target" };
                const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
                try ipc.IpcServer.writeLine(client_stream, resp_raw);
                return;
            };
            const text_str = req.text orelse "";
            // Build DM envelope per [[RFC-0002:C-DM]].
            var payload_obj = json.ObjectMap.init(alloc);
            try payload_obj.put("text", .{ .string = text_str });
            const envelope = protocol.Envelope{
                .@"type" = "dm",
                .id = "run-send-0",
                .source = srv.agent_id,
                .target = target,
                .payload = .{ .object = payload_obj },
            };
            const raw = try protocol.serializeEnvelope(alloc, envelope);
            _ = try srv.hub_stream.write(raw);
            const resp = protocol.IpcResponse{ .success = true };
            const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
            try ipc.IpcServer.writeLine(client_stream, resp_raw);
        },
        .recv => {
            const msgs = try srv.message_queue.drain(alloc);
            // Serialize messages as a JSON array of strings.
            var array = json.Array.init(alloc);
            for (msgs) |msg| {
                try array.append(json.Value{ .string = msg });
            }
            const arr_val = json.Value{ .array = array };
            const data_raw = try json.Stringify.valueAlloc(alloc, arr_val, .{});
            const resp = protocol.IpcResponse{ .success = true, .data = data_raw };
            const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
            try ipc.IpcServer.writeLine(client_stream, resp_raw);
        },
        .agents => {
            // Forward a list_agents envelope to the Hub.
            const envelope = protocol.Envelope{
                .@"type" = "list_agents",
                .id = "run-agents-0",
                .source = srv.agent_id,
                .target = "hub",
                .payload = .null,
            };
            const raw = try protocol.serializeEnvelope(alloc, envelope);
            _ = try srv.hub_stream.write(raw);
            _ = try srv.hub_stream.write("\n");
            // Best-effort read response.
            var resp_buf: [64 * 1024]u8 = undefined;
            const n = srv.hub_stream.read(&resp_buf) catch 0;
            const data: ?[]const u8 = if (n > 0) resp_buf[0..n] else null;
            const resp = protocol.IpcResponse{ .success = true, .data = data };
            const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
            try ipc.IpcServer.writeLine(client_stream, resp_raw);
        },
        .register => {
            // Forward agent_update to Hub per [[RFC-0002:C-AGENT-IDENTITY]].
            var payload_obj = json.ObjectMap.init(alloc);
            if (req.tool) |t| try payload_obj.put("tool", .{ .string = t });
            if (req.project) |p| try payload_obj.put("project", .{ .string = p });
            if (req.session) |s| try payload_obj.put("session", .{ .string = s });
            const envelope = protocol.Envelope{
                .@"type" = "agent_update",
                .id = "run-register-0",
                .source = srv.agent_id,
                .target = "hub",
                .payload = .{ .object = payload_obj },
            };
            const raw = try protocol.serializeEnvelope(alloc, envelope);
            _ = try srv.hub_stream.write(raw);
            _ = try srv.hub_stream.write("\n");
            const resp = protocol.IpcResponse{ .success = true };
            const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
            try ipc.IpcServer.writeLine(client_stream, resp_raw);
        },
        .channel_create, .channel_invite, .channel_leave, .channel_list => {
            // Forward channel commands to Hub per [[RFC-0002:C-GROUP-CHAT]].
            const msg_type: []const u8 = switch (req.action) {
                .channel_create => "channel_create",
                .channel_invite => "channel_invite",
                .channel_leave => "channel_leave",
                .channel_list => "list_channels",
                else => unreachable,
            };
            var payload_obj = json.ObjectMap.init(alloc);
            if (req.channel) |ch| try payload_obj.put("channel", .{ .string = ch });
            if (req.agent_id) |aid| try payload_obj.put("agent_id", .{ .string = aid });
            if (req.description) |d| try payload_obj.put("description", .{ .string = d });
            if (req.channel) |name| try payload_obj.put("name", .{ .string = name });
            const envelope = protocol.Envelope{
                .@"type" = msg_type,
                .id = "run-channel-0",
                .source = srv.agent_id,
                .target = "hub",
                .payload = .{ .object = payload_obj },
            };
            const raw = try protocol.serializeEnvelope(alloc, envelope);
            _ = try srv.hub_stream.write(raw);
            _ = try srv.hub_stream.write("\n");
            // Read Hub response.
            var resp_buf: [64 * 1024]u8 = undefined;
            const n = srv.hub_stream.read(&resp_buf) catch 0;
            const data: ?[]const u8 = if (n > 0) resp_buf[0..n] else null;
            const resp = protocol.IpcResponse{ .success = true, .data = data };
            const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
            try ipc.IpcServer.writeLine(client_stream, resp_raw);
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "MessageQueue init and deinit" {
    var q = MessageQueue.init(std.testing.allocator);
    defer q.deinit();
    try std.testing.expectEqual(@as(usize, 0), q.messages.items.len);
}

test "MessageQueue push then drain returns messages in order" {
    var q = MessageQueue.init(std.testing.allocator);
    defer q.deinit();

    try q.push("first");
    try q.push("second");
    try q.push("third");

    const msgs = try q.drain(std.testing.allocator);
    defer {
        for (msgs) |m| std.testing.allocator.free(m);
        std.testing.allocator.free(msgs);
    }

    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    try std.testing.expectEqualStrings("first", msgs[0]);
    try std.testing.expectEqualStrings("second", msgs[1]);
    try std.testing.expectEqualStrings("third", msgs[2]);
}

test "MessageQueue drain returns empty slice when no messages" {
    var q = MessageQueue.init(std.testing.allocator);
    defer q.deinit();

    const msgs = try q.drain(std.testing.allocator);
    defer std.testing.allocator.free(msgs);

    try std.testing.expectEqual(@as(usize, 0), msgs.len);
}

test "MessageQueue drain empties the queue" {
    var q = MessageQueue.init(std.testing.allocator);
    defer q.deinit();

    try q.push("msg-a");

    // First drain returns the message.
    const first = try q.drain(std.testing.allocator);
    defer {
        for (first) |m| std.testing.allocator.free(m);
        std.testing.allocator.free(first);
    }
    try std.testing.expectEqual(@as(usize, 1), first.len);

    // Second drain returns empty.
    const second = try q.drain(std.testing.allocator);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqual(@as(usize, 0), second.len);
}

const ThreadPushContext = struct {
    q: *MessageQueue,
    prefix: []const u8,
    count: usize,
};

fn pushWorker(ctx: ThreadPushContext) void {
    var buf: [32]u8 = undefined;
    for (0..ctx.count) |i| {
        const s = std.fmt.bufPrint(&buf, "{s}{d}", .{ ctx.prefix, i }) catch unreachable;
        ctx.q.push(s) catch unreachable;
    }
}

test "MessageQueue is thread-safe: push from two threads drain gets all" {
    var q = MessageQueue.init(std.testing.allocator);
    defer q.deinit();

    const n = 50;
    const ctx_a = ThreadPushContext{ .q = &q, .prefix = "a-", .count = n };
    const ctx_b = ThreadPushContext{ .q = &q, .prefix = "b-", .count = n };

    const t1 = try std.Thread.spawn(.{}, pushWorker, .{ctx_a});
    const t2 = try std.Thread.spawn(.{}, pushWorker, .{ctx_b});
    t1.join();
    t2.join();

    const msgs = try q.drain(std.testing.allocator);
    defer {
        for (msgs) |m| std.testing.allocator.free(m);
        std.testing.allocator.free(msgs);
    }

    try std.testing.expectEqual(@as(usize, n * 2), msgs.len);
}
