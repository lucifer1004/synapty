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
    /// Serializes writes to hub_stream (hubReaderThread is the sole reader).
    hub_write_mutex: std.Thread.Mutex,
    /// Protects pending_responses — the response mailbox between hubReaderThread
    /// and IPC handlers that need a Hub response.
    response_mutex: std.Thread.Mutex,
    pending_responses: std.ArrayList([]const u8),
    /// Monotonic counter for unique envelope IDs (prevents stale-response misrouting).
    next_request_id: u32,

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

        // Send register envelope (newline-terminated for Hub's line framing).
        const reg = protocol.makeRegisterEnvelope(agent_id, &.{});
        const reg_raw = try protocol.serializeEnvelope(allocator, reg);
        defer allocator.free(reg_raw);
        try hub_stream.writeAll(reg_raw);
        try hub_stream.writeAll("\n");

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
            .hub_write_mutex = .{},
            .response_mutex = .{},
            .pending_responses = std.ArrayList([]const u8).empty,
            .next_request_id = 0,
        };
    }

    pub fn deinit(self: *RunServer) void {
        for (self.pending_responses.items) |r| self.allocator.free(r);
        self.pending_responses.deinit(self.allocator);
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

        // Signal threads to stop.
        @atomicStore(bool, &self.running, false, .release);

        // Unblock hubReaderThread: shutdown causes read() to return 0/error.
        posix.shutdown(self.hub_stream.handle, .both) catch {};

        // Unblock ipcServerThread: dummy connection causes accept() to return.
        if (net.connectUnixSocket(self.socket_path)) |dummy| {
            dummy.close();
        } else |_| {}

        hub_thread.join();
        ipc_thread.join();
    }

    /// Start hub reader and IPC server threads without spawning a child process.
    /// Caller must call stopThreads() to shut down.
    pub fn startThreads(self: *RunServer) !struct { hub: std.Thread, ipc: std.Thread } {
        self.running = true;
        const hub_thread = try std.Thread.spawn(.{}, hubReaderThread, .{self});
        const ipc_thread = try std.Thread.spawn(.{}, ipcServerThread, .{self});
        return .{ .hub = hub_thread, .ipc = ipc_thread };
    }

    /// Signal threads to stop and join them.
    pub fn stopThreads(self: *RunServer, threads: struct { hub: std.Thread, ipc: std.Thread }) void {
        @atomicStore(bool, &self.running, false, .release);
        posix.shutdown(self.hub_stream.handle, .both) catch {};
        if (net.connectUnixSocket(self.socket_path)) |dummy| {
            dummy.close();
        } else |_| {}
        threads.hub.join();
        threads.ipc.join();
    }
};

// ---------------------------------------------------------------------------
// Thread functions
// ---------------------------------------------------------------------------

/// Sole reader of hub_stream. Buffers partial TCP frames across reads,
/// routes "response" envelopes to the response slot and everything else
/// to the message queue.
fn hubReaderThread(srv: *RunServer) void {
    var line_buf: [64 * 1024]u8 = undefined;
    var filled: usize = 0;

    // Per-line arena for parsing envelope type — reset after each line.
    var parse_arena = std.heap.ArenaAllocator.init(srv.allocator);
    defer parse_arena.deinit();

    while (@atomicLoad(bool, &srv.running, .acquire)) {
        if (filled >= line_buf.len) {
            log.err("hub message exceeds buffer", .{});
            break;
        }
        const n = srv.hub_stream.read(line_buf[filled..]) catch break;
        if (n == 0) break;
        filled += n;

        // Extract complete newline-delimited lines.
        var start: usize = 0;
        while (mem.indexOfScalar(u8, line_buf[start..filled], '\n')) |rel| {
            const end = start + rel;
            const line = mem.trimRight(u8, line_buf[start..end], "\r ");
            start = end + 1;
            if (line.len == 0) continue;

            // Parse the envelope to check the type field reliably.
            _ = parse_arena.reset(.retain_capacity);
            const is_response = blk: {
                const parsed = json.parseFromSlice(json.Value, parse_arena.allocator(), line, .{ .allocate = .alloc_always }) catch break :blk false;
                const obj = if (parsed.value == .object) parsed.value.object else break :blk false;
                const type_val = obj.get("type") orelse break :blk false;
                break :blk if (type_val == .string) mem.eql(u8, type_val.string, "response") else false;
            };

            if (is_response) {
                const copy = srv.allocator.dupe(u8, line) catch continue;
                srv.response_mutex.lock();
                srv.pending_responses.append(srv.allocator, copy) catch {
                    srv.allocator.free(copy);
                };
                srv.response_mutex.unlock();
            } else {
                srv.message_queue.push(line) catch |err| {
                    log.err("message_queue.push failed: {any}", .{err});
                };
            }
        }

        // Shift unconsumed bytes to the front.
        const remaining = filled - start;
        if (remaining > 0 and start > 0) {
            mem.copyForwards(u8, line_buf[0..remaining], line_buf[start..filled]);
        }
        filled = remaining;
    }
}

/// Wait up to ~1 second for a hub response whose envelope ID matches `expected_id`.
/// Stale responses with non-matching IDs are discarded.
/// Caller owns the returned slice and must free it with srv.allocator.
fn waitForHubResponse(srv: *RunServer, expected_id: []const u8) ?[]const u8 {
    // Build pattern: "id":"<expected_id>" to match in JSON.
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"id\":\"{s}\"", .{expected_id}) catch return null;

    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        srv.response_mutex.lock();
        // Scan the queue for a matching response; discard stale ones.
        var found: ?[]const u8 = null;
        while (srv.pending_responses.items.len > 0) {
            const data = srv.pending_responses.items[0];
            if (mem.indexOf(u8, data, pattern) != null) {
                // Match — remove from queue.
                found = srv.pending_responses.orderedRemove(0);
                break;
            } else {
                // Stale response from a prior timed-out request — discard.
                srv.allocator.free(srv.pending_responses.orderedRemove(0));
            }
        }
        srv.response_mutex.unlock();
        if (found) |f| return f;
        std.time.sleep(1 * std.time.ns_per_ms);
    }
    return null;
}

/// Write a newline-terminated message to the hub under mutex.
/// Mutex is always released even if write fails (via defer).
fn writeToHub(srv: *RunServer, data: []const u8) !void {
    srv.hub_write_mutex.lock();
    defer srv.hub_write_mutex.unlock();
    try srv.hub_stream.writeAll(data);
    try srv.hub_stream.writeAll("\n");
}

/// Generate a unique request ID for envelope correlation.
fn nextRequestId(srv: *RunServer, buf: *[32]u8) []const u8 {
    const id = srv.next_request_id;
    srv.next_request_id += 1;
    return std.fmt.bufPrint(buf, "req-{d}", .{id}) catch "req-0";
}

/// Check if a hub response indicates success (payload.ok == true).
fn parseHubOk(response: []const u8) bool {
    return mem.indexOf(u8, response, "\"ok\":true") != null;
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
            // Detect channel target per [[RFC-0002:C-GROUP-CHAT]].
            const envelope_type: []const u8 = if (mem.startsWith(u8, target, "channel:"))
                "channel_msg"
            else
                "dm";
            var id_buf: [32]u8 = undefined;
            const req_id = nextRequestId(srv, &id_buf);
            var payload_obj = json.ObjectMap.init(alloc);
            try payload_obj.put("text", .{ .string = text_str });
            const envelope = protocol.Envelope{
                .@"type" = envelope_type,
                .id = req_id,
                .source = srv.agent_id,
                .target = target,
                .payload = .{ .object = payload_obj },
            };
            const raw = try protocol.serializeEnvelope(alloc, envelope);
            try writeToHub(srv, raw);
            // Wait for hub acknowledgment, matched by request ID.
            const hub_resp = waitForHubResponse(srv, req_id);
            defer if (hub_resp) |r| srv.allocator.free(r);
            const success = if (hub_resp) |r| parseHubOk(r) else false;
            const resp = protocol.IpcResponse{
                .success = success,
                .data = hub_resp,
                .error_msg = if (!success and hub_resp == null) "hub timeout" else null,
            };
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
            var id_buf: [32]u8 = undefined;
            const req_id = nextRequestId(srv, &id_buf);
            const envelope = protocol.Envelope{
                .@"type" = "list_agents",
                .id = req_id,
                .source = srv.agent_id,
                .target = "hub",
                .payload = .null,
            };
            const raw = try protocol.serializeEnvelope(alloc, envelope);
            try writeToHub(srv, raw);
            const hub_resp = waitForHubResponse(srv, req_id);
            defer if (hub_resp) |r| srv.allocator.free(r);
            const success = hub_resp != null;
            const resp = protocol.IpcResponse{
                .success = success,
                .data = hub_resp,
                .error_msg = if (!success) "hub timeout" else null,
            };
            const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
            try ipc.IpcServer.writeLine(client_stream, resp_raw);
        },
        .register => {
            var id_buf: [32]u8 = undefined;
            const req_id = nextRequestId(srv, &id_buf);
            var payload_obj = json.ObjectMap.init(alloc);
            if (req.tool) |t| try payload_obj.put("tool", .{ .string = t });
            if (req.project) |p| try payload_obj.put("project", .{ .string = p });
            if (req.session) |s| try payload_obj.put("session", .{ .string = s });
            const envelope = protocol.Envelope{
                .@"type" = "agent_update",
                .id = req_id,
                .source = srv.agent_id,
                .target = "hub",
                .payload = .{ .object = payload_obj },
            };
            const raw = try protocol.serializeEnvelope(alloc, envelope);
            try writeToHub(srv, raw);
            // Wait for hub acknowledgment, matched by request ID.
            const hub_resp = waitForHubResponse(srv, req_id);
            defer if (hub_resp) |r| srv.allocator.free(r);
            const success = if (hub_resp) |r| parseHubOk(r) else false;
            const resp = protocol.IpcResponse{
                .success = success,
                .data = hub_resp,
                .error_msg = if (!success and hub_resp == null) "hub timeout" else null,
            };
            const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
            try ipc.IpcServer.writeLine(client_stream, resp_raw);
        },
        .channel_create, .channel_invite, .channel_leave, .channel_list => {
            var id_buf: [32]u8 = undefined;
            const req_id = nextRequestId(srv, &id_buf);
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
                .id = req_id,
                .source = srv.agent_id,
                .target = "hub",
                .payload = .{ .object = payload_obj },
            };
            const raw = try protocol.serializeEnvelope(alloc, envelope);
            try writeToHub(srv, raw);
            const hub_resp = waitForHubResponse(srv, req_id);
            defer if (hub_resp) |r| srv.allocator.free(r);
            const success = if (hub_resp) |r| parseHubOk(r) else false;
            const resp = protocol.IpcResponse{
                .success = success,
                .data = hub_resp,
                .error_msg = if (!success and hub_resp == null) "hub timeout" else null,
            };
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

// -- Finding 3: channel send routing tests ----------------------------------

test "send to channel: target produces channel_msg envelope type" {
    const target = "channel:design-review";
    const envelope_type: []const u8 = if (mem.startsWith(u8, target, "channel:"))
        "channel_msg"
    else
        "dm";
    try std.testing.expectEqualStrings("channel_msg", envelope_type);
}

test "send to plain agent target produces dm envelope type" {
    const target = "agent-b";
    const envelope_type: []const u8 = if (mem.startsWith(u8, target, "channel:"))
        "channel_msg"
    else
        "dm";
    try std.testing.expectEqualStrings("dm", envelope_type);
}

// -- Finding 2: line buffering tests ----------------------------------------

test "hubReaderThread line buffer: extracts complete lines and carries partial" {
    // Simulate the line buffer extraction logic used in hubReaderThread.
    var line_buf: [256]u8 = undefined;
    var filled: usize = 0;

    // First "read": partial message, no newline yet.
    const chunk1 = "{\"type\":\"dm\",\"id\":\"1\",\"s";
    @memcpy(line_buf[filled..][0..chunk1.len], chunk1);
    filled += chunk1.len;

    // Extract complete lines — should find none.
    var lines_found: usize = 0;
    {
        var start: usize = 0;
        while (mem.indexOfScalar(u8, line_buf[start..filled], '\n')) |rel| {
            start += rel + 1;
            lines_found += 1;
        }
        const remaining = filled - start;
        if (remaining > 0 and start > 0) {
            mem.copyForwards(u8, line_buf[0..remaining], line_buf[start..filled]);
        }
        filled = remaining;
    }
    try std.testing.expectEqual(@as(usize, 0), lines_found);
    try std.testing.expectEqual(chunk1.len, filled); // partial still in buffer

    // Second "read": rest of message + newline + start of next.
    const chunk2 = "rc\":\"a\"}\n{\"type\":\"d";
    @memcpy(line_buf[filled..][0..chunk2.len], chunk2);
    filled += chunk2.len;

    // Extract complete lines — should find one.
    var complete_line: ?[]const u8 = null;
    {
        var start: usize = 0;
        while (mem.indexOfScalar(u8, line_buf[start..filled], '\n')) |rel| {
            const end = start + rel;
            complete_line = line_buf[start..end];
            start = end + 1;
        }
        const remaining = filled - start;
        if (remaining > 0 and start > 0) {
            mem.copyForwards(u8, line_buf[0..remaining], line_buf[start..filled]);
        }
        filled = remaining;
    }
    try std.testing.expect(complete_line != null);
    try std.testing.expectEqualStrings("{\"type\":\"dm\",\"id\":\"1\",\"src\":\"a\"}", complete_line.?);

    // Partial remainder should still be in buffer.
    try std.testing.expectEqualStrings("{\"type\":\"d", line_buf[0..filled]);
}

test "hubReaderThread line buffer: multiple complete lines in one read" {
    var line_buf: [256]u8 = undefined;
    var filled: usize = 0;

    const chunk = "line-one\nline-two\nline-three\n";
    @memcpy(line_buf[filled..][0..chunk.len], chunk);
    filled += chunk.len;

    var count: usize = 0;
    var start: usize = 0;
    while (mem.indexOfScalar(u8, line_buf[start..filled], '\n')) |rel| {
        start += rel + 1;
        count += 1;
    }
    const remaining = filled - start;
    filled = remaining;

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(usize, 0), filled); // no partial remainder
}

// -- Follow-up fix tests: response matching, success parsing, register \n ---

test "parseHubOk returns true for ok:true response" {
    try std.testing.expect(parseHubOk("{\"type\":\"response\",\"id\":\"req-0\",\"payload\":{\"ok\":true}}"));
}

test "parseHubOk returns false for ok:false response" {
    try std.testing.expect(!parseHubOk("{\"type\":\"response\",\"id\":\"req-0\",\"payload\":{\"ok\":false,\"error\":\"not found\"}}"));
}

test "parseHubOk returns false for missing ok field" {
    try std.testing.expect(!parseHubOk("{\"type\":\"response\",\"id\":\"req-0\",\"payload\":{}}"));
}

test "register envelope is newline-terminated" {
    const reg = protocol.makeRegisterEnvelope("test-agent", &.{});
    const raw = try protocol.serializeEnvelope(std.testing.allocator, reg);
    defer std.testing.allocator.free(raw);
    // The hub's handleClient expects newline-terminated frames.
    // RunServer.init() appends "\n" after writing raw — verify raw itself
    // does NOT contain a newline (so the explicit "\n" write is needed).
    try std.testing.expect(mem.indexOfScalar(u8, raw, '\n') == null);
}
