const std = @import("std");
const sys = @import("sys");
const framing = @import("framing");
const io_mod = @import("io");
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
    mutex: std.Io.Mutex,
    messages: std.ArrayList([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) MessageQueue {
        return .{
            .mutex = .init,
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
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        try self.messages.append(self.allocator, copy);
    }

    /// Drain up to `max` messages into a newly allocated slice.
    /// Caller owns both the outer slice and each inner string — free each with
    /// allocator.free(item) then allocator.free(slice). The cap bounds the
    /// serialized response so the 64KiB IPC line cannot truncate or hang the
    /// client (WI-2026-08-08-028).
    pub fn drain(self: *MessageQueue, allocator: Allocator, max: usize) ![][]const u8 {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());

        const count = @min(self.messages.items.len, max);
        if (count == 0) {
            return try allocator.alloc([]const u8, 0);
        }

        const result = try allocator.alloc([]const u8, count);
        for (self.messages.items[0..count], 0..) |item, i| {
            result[i] = item;
        }
        // Remove without freeing — ownership transferred to caller.
        for (0..count) |_| _ = self.messages.orderedRemove(0);
        return result;
    }
};

// ---------------------------------------------------------------------------
// RunServer
// ---------------------------------------------------------------------------

pub const RunServer = struct {
    allocator: Allocator,
    agent_id: []const u8,
    hub_fd: sys.fd_t,
    ipc_server: ipc.IpcServer,
    socket_path: []const u8,
    message_queue: MessageQueue,
    running: bool,
    /// Serializes writes to hub_stream (hubReaderThread is the sole reader).
    hub_write_mutex: std.Io.Mutex,
    /// Protects pending_responses — the response mailbox between hubReaderThread
    /// and IPC handlers that need a Hub response.
    response_mutex: std.Io.Mutex,
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
        sys.unlink(socket_path);

        // Connect to Hub.
        const hub_fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
        errdefer sys.close(hub_fd);
        const addr4 = std.Io.net.Ip4Address.parse(hub_addr, hub_port) catch {
            sys.close(hub_fd);
            return error.InvalidHubAddress;
        };
        const sa = sys.sockaddr_in.init(@bitCast(addr4.bytes), hub_port);
        try sys.connect(hub_fd, &sa, @sizeOf(sys.sockaddr_in));

        // Send register envelope (newline-terminated for Hub's line framing).
        const reg = try protocol.makeRegisterEnvelope(allocator, agent_id, &.{});
        const reg_raw = try protocol.serializeEnvelope(allocator, reg);
        defer allocator.free(reg_raw);
        try sys.writeAll(hub_fd, reg_raw);
        try sys.writeAll(hub_fd, "\n");

        // Bind IPC unix socket.
        const ipc_server = try ipc.IpcServer.init(socket_path);
        errdefer {
            var s = ipc_server;
            s.deinit();
        }

        return RunServer{
            .allocator = allocator,
            .agent_id = agent_id,
            .hub_fd = hub_fd,
            .ipc_server = ipc_server,
            .socket_path = socket_path,
            // Message queue + pending responses use the thread-safe smp
            // allocator: dupes must be FREABLE (the caller's arena free is
            // a no-op — items would live for the daemon's lifetime) and
            // freeable from the IPC thread while the reader thread appends
            // (WI-2026-08-08-017).
            .message_queue = MessageQueue.init(std.heap.smp_allocator),
            .running = false,
            .hub_write_mutex = .init,
            .response_mutex = .init,
            .pending_responses = std.ArrayList([]const u8).empty,
            .next_request_id = 0,
        };
    }

    pub fn deinit(self: *RunServer) void {
        for (self.pending_responses.items) |r| std.heap.smp_allocator.free(r);
        self.pending_responses.deinit(std.heap.smp_allocator);
        sys.close(self.hub_fd);
        self.ipc_server.deinit();
        self.message_queue.deinit();
        self.allocator.free(self.socket_path);
    }

    /// Spawn child with PTY passthrough, run background threads, wait for child.
    pub fn run(self: *RunServer, child_argv: []const []const u8) !void {
        self.running = true;

        // Build env map inheriting current env then adding our vars.
        var env_map = try buildEnvMap(self.allocator);
        defer env_map.deinit();
        try env_map.put("SYNAPTY_AGENT_ID", self.agent_id);
        try env_map.put("SYNAPTY_SOCK", self.socket_path);

        // Prepend the directory of the current executable to PATH so child
        // processes (e.g. MCP servers) can find `synapty`.
        // Works for all deployments: dev (zig-out/bin/), bundled (.app/Resources/),
        // and remote (~/.synapty/bin/).
        var self_exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const self_exe_n = std.process.executablePath(io_mod.get(), &self_exe_buf) catch 0;
        if (self_exe_n > 0) {
            const self_exe = self_exe_buf[0..self_exe_n];
            if (std.fs.path.dirnamePosix(self_exe)) |exe_dir| {
                if (env_map.get("PATH")) |existing_path| {
                    const new_path = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ exe_dir, existing_path });
                    defer self.allocator.free(new_path);
                    try env_map.put("PATH", new_path);
                } else {
                    try env_map.put("PATH", exe_dir);
                }
            }
        }

        var child = try std.process.spawn(io_mod.get(), .{
            .argv = child_argv,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
            .environ_map = &env_map,
        });

        // Spawn hub reader thread. On failure: kill and reap the child,
        // mark stopped, rethrow — an orphaned child would keep running
        // with nobody to manage it (WI-2026-08-08-017).
        const hub_thread = std.Thread.spawn(.{}, hubReaderThread, .{self}) catch |err| {
            @atomicStore(bool, &self.running, false, .release);
            std.process.Child.kill(&child, io_mod.get());
            _ = std.process.Child.wait(&child, io_mod.get()) catch {};
            return err;
        };

        // Spawn IPC server thread. On failure: stop the reader thread, join
        // it (it must not run against a deinitializing RunServer), then
        // kill/reap the child.
        const ipc_thread = std.Thread.spawn(.{}, ipcServerThread, .{self}) catch |err| {
            @atomicStore(bool, &self.running, false, .release);
            sys.shutdown(self.hub_fd, sys.SHUT.RDWR);
            hub_thread.join();
            std.process.Child.kill(&child, io_mod.get());
            _ = std.process.Child.wait(&child, io_mod.get()) catch {};
            return err;
        };

        // Wait for child to exit.
        _ = try std.process.Child.wait(&child, io_mod.get());

        // Signal threads to stop.
        @atomicStore(bool, &self.running, false, .release);

        // Unblock hubReaderThread: shutdown causes read() to return 0/error.
        sys.shutdown(self.hub_fd, sys.SHUT.RDWR);

        // Unblock ipcServerThread: dummy connection causes accept() to return.
        if (connectUnixDummy(self.socket_path)) |fd| {
            sys.close(fd);
        }

        hub_thread.join();
        ipc_thread.join();
    }

    /// Start hub reader and IPC server threads without spawning a child process.
    /// Caller must call stopThreads() to shut down.
    pub const ThreadHandles = struct { hub: std.Thread, ipc: std.Thread };

    pub fn startThreads(self: *RunServer) !ThreadHandles {
        self.running = true;
        const hub_thread = try std.Thread.spawn(.{}, hubReaderThread, .{self});
        const ipc_thread = std.Thread.spawn(.{}, ipcServerThread, .{self}) catch |err| {
            // Partial failure: stop and join the already-spawned thread so
            // it never runs against a deinitializing RunServer
            // (WI-2026-08-08-017).
            @atomicStore(bool, &self.running, false, .release);
            sys.shutdown(self.hub_fd, sys.SHUT.RDWR);
            hub_thread.join();
            return err;
        };
        return .{ .hub = hub_thread, .ipc = ipc_thread };
    }

    /// Signal threads to stop and join them.
    pub fn stopThreads(self: *RunServer, threads: ThreadHandles) void {
        @atomicStore(bool, &self.running, false, .release);
        sys.shutdown(self.hub_fd, sys.SHUT.RDWR);
        if (connectUnixDummy(self.socket_path)) |fd| {
            sys.close(fd);
        }
        threads.hub.join();
        threads.ipc.join();
    }
};


// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Connect a dummy unix-socket client to unblock the IPC accept loop.
/// Returns the fd, or null on failure.
fn connectUnixDummy(socket_path: []const u8) ?sys.fd_t {
    const fd = sys.socket(sys.AF.UNIX, sys.SOCK.STREAM, 0) catch return null;
    const addr = sys.sockaddr_un.init(socket_path) orelse {
        sys.close(fd);
        return null;
    };
    sys.connect(fd, &addr, addr.len()) catch {
        sys.close(fd);
        return null;
    };
    return fd;
}

/// Build an env map inheriting the current process environment (libc environ).
fn buildEnvMap(allocator: Allocator) !std.process.Environ.Map {
    var env_map = std.process.Environ.Map.init(allocator);
    // Count entries up to the null sentinel.
    var count: usize = 0;
    while (std.c.environ[count]) |_| : (count += 1) {}
    const block: std.process.Environ.PosixBlock = .{
        .slice = @ptrCast(std.c.environ[0..count :null]),
    };
    try env_map.putPosixBlock(block.view());
    return env_map;
}

// ---------------------------------------------------------------------------
// Thread functions
// ---------------------------------------------------------------------------

/// Sole reader of hub_stream. Buffers partial TCP frames across reads,
/// routes "response" envelopes to the response slot and everything else
/// to the message queue.
fn hubReaderThread(srv: *RunServer) void {
    var line_buf: [64 * 1024]u8 = undefined;
    // Shared framing (WI-2026-08-08-035): carry-remainder chunked reader,
    // oversized-line resync built in.
    var lb = framing.LineBuffer.init(&line_buf);

    // Per-line arena for parsing envelope type — reset after each line.
    var parse_arena = std.heap.ArenaAllocator.init(srv.allocator);
    defer parse_arena.deinit();

    while (@atomicLoad(bool, &srv.running, .acquire)) {
        const line = lb.readLine(srv.hub_fd) catch |err| switch (err) {
            // An oversized line (e.g. a huge list_agents response) must
            // not kill the reader permanently — every later IPC request
            // would hang then time out. Drop through the next newline and
            // keep serving (WI-2026-08-08-029).
            error.StreamTooLong => {
                log.err("hub message exceeds buffer — dropping oversized line", .{});
                lb.dropOversizedLine(srv.hub_fd);
                continue;
            },
            else => break,
        } orelse break;
        const trimmed = mem.trimEnd(u8, line, "\r ");
        if (trimmed.len == 0) continue;

        // Parse the envelope to check the type field reliably.
        _ = parse_arena.reset(.retain_capacity);
        const is_response = blk: {
            const parsed = json.parseFromSlice(json.Value, parse_arena.allocator(), trimmed, .{ .allocate = .alloc_always }) catch break :blk false;
            const obj = if (parsed.value == .object) parsed.value.object else break :blk false;
            const type_val = obj.get("type") orelse break :blk false;
            break :blk if (type_val == .string) mem.eql(u8, type_val.string, "response") else false;
        };

        if (is_response) {
            const copy = std.heap.smp_allocator.dupe(u8, trimmed) catch continue;
            srv.response_mutex.lock(io_mod.get()) catch unreachable;
            srv.pending_responses.append(std.heap.smp_allocator, copy) catch {
                std.heap.smp_allocator.free(copy);
            };
            srv.response_mutex.unlock(io_mod.get());
        } else {
            srv.message_queue.push(trimmed) catch |err| {
                log.err("message_queue.push failed: {any}", .{err});
            };
        }
    }
}

/// Parse an envelope line and return true when its `id` field equals
/// `expected_id` EXACTLY. Substring matching collided ('req-5' matched
/// 'req-50'; WI-2026-08-08-028).
fn responseIdMatches(line: []const u8, expected_id: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = json.parseFromSlice(json.Value, arena, line, .{ .allocate = .alloc_always }) catch return false;
    if (parsed.value != .object) return false;
    const id_val = parsed.value.object.get("id") orelse return false;
    return if (id_val == .string) mem.eql(u8, id_val.string, expected_id) else false;
}

/// Wait up to ~1 second for a hub response whose envelope ID matches `expected_id`.
/// Stale responses with non-matching IDs are discarded.
/// Caller owns the returned slice and must free it with std.heap.smp_allocator.
fn waitForHubResponse(srv: *RunServer, expected_id: []const u8) ?[]const u8 {
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        srv.response_mutex.lock(io_mod.get()) catch unreachable;
        // Scan the queue for a matching response; discard stale ones.
        var found: ?[]const u8 = null;
        while (srv.pending_responses.items.len > 0) {
            const data = srv.pending_responses.items[0];
            if (responseIdMatches(data, expected_id)) {
                // Match — remove from queue.
                found = srv.pending_responses.orderedRemove(0);
                break;
            } else {
                // Stale response from a prior timed-out request — discard.
                std.heap.smp_allocator.free(srv.pending_responses.orderedRemove(0));
            }
        }
        srv.response_mutex.unlock(io_mod.get());
        if (found) |f| return f;
        io_mod.get().sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    return null;
}

/// Write a newline-terminated message to the hub under mutex.
/// Mutex is always released even if write fails (via defer).
fn writeToHub(srv: *RunServer, data: []const u8) !void {
    srv.hub_write_mutex.lock(io_mod.get()) catch unreachable;
    defer srv.hub_write_mutex.unlock(io_mod.get());
    try sys.writeAll(srv.hub_fd, data);
    try sys.writeAll(srv.hub_fd, "\n");
}

/// Write an envelope to the hub, wait for its response, and send the
/// daemon's IPC response to the client. The send/register/channel branches
/// used to repeat this write->wait->respond sequence by hand
/// (WI-2026-08-08-038).
fn hubRoundtripAndRespond(srv: *RunServer, alloc: Allocator, client_fd: sys.fd_t, envelope: protocol.Envelope) !void {
    const raw = try protocol.serializeEnvelope(alloc, envelope);
    defer alloc.free(raw);
    try writeToHub(srv, raw);
    // Wait for hub acknowledgment, matched by request ID.
    const hub_resp = waitForHubResponse(srv, envelope.id);
    defer if (hub_resp) |r| std.heap.smp_allocator.free(r);
    const success = if (hub_resp) |r| parseHubOk(r) else false;
    const resp = protocol.IpcResponse{
        .success = success,
        .data = hub_resp,
        .error_msg = if (!success and hub_resp == null) "hub timeout" else null,
    };
    const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
    try ipc.IpcServer.writeLine(client_fd, resp_raw);
}

/// Generate a unique request ID for envelope correlation.
fn nextRequestId(srv: *RunServer, buf: *[32]u8) []const u8 {
    const id = srv.next_request_id;
    srv.next_request_id += 1;
    return std.fmt.bufPrint(buf, "req-{d}", .{id}) catch "req-0";
}

/// Check if a hub response indicates success (payload.ok == true).
/// Parse the envelope payload and return true only when
/// payload.ok == true. Substring matching could false-positive on a
/// nested data payload (WI-2026-08-08-028).
fn parseHubOk(response: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = json.parseFromSlice(json.Value, arena, response, .{ .allocate = .alloc_always }) catch return false;
    if (parsed.value != .object) return false;
    const payload = parsed.value.object.get("payload") orelse return false;
    if (payload != .object) return false;
    const ok = payload.object.get("ok") orelse return false;
    return ok == .bool and ok.bool;
}

fn ipcServerThread(srv: *RunServer) void {
    while (@atomicLoad(bool, &srv.running, .acquire)) {
        const client_fd = srv.ipc_server.accept() catch |err| {
            if (!@atomicLoad(bool, &srv.running, .acquire)) break;
            log.err("ipc accept error: {any}", .{err});
            continue;
        };
        defer sys.close(client_fd);
        handleIpcConnection(srv, client_fd) catch |err| {
            log.err("ipc connection error: {any}", .{err});
        };
    }
}

fn handleIpcConnection(srv: *RunServer, client_fd: sys.fd_t) !void {
    var buf: [64 * 1024]u8 = undefined;
    const line = try ipc.IpcServer.readLine(client_fd, &buf) orelse return;

    // Per-connection arena over the thread-safe allocator: the IPC thread
    // must NOT allocate from the daemon's shared arena — the hub reader
    // thread bumps it concurrently (data race, WI-2026-08-08-017).
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req_parsed = protocol.parseIpcRequest(alloc, line) catch {
        const resp = protocol.IpcResponse{ .success = false, .error_msg = "invalid request" };
        const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
        try ipc.IpcServer.writeLine(client_fd, resp_raw);
        return;
    };
    defer req_parsed.deinit();

    const req = req_parsed.value;

    switch (req.action) {
        .send => {
            const target = req.target orelse {
                const resp = protocol.IpcResponse{ .success = false, .error_msg = "missing target" };
                const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
                try ipc.IpcServer.writeLine(client_fd, resp_raw);
                return;
            };
            const text_str = req.text orelse "";
            // Detect channel target (legacy group-chat surface, reduced away
            // by [[RFC-0003:C-A2A-REDUCTION]]; kept for the daemon IPC compat).
            const envelope_type: []const u8 = if (mem.startsWith(u8, target, "channel:"))
                "channel_msg"
            else
                "dm";
            var id_buf: [32]u8 = undefined;
            const req_id = nextRequestId(srv, &id_buf);
            var payload_obj = json.ObjectMap.empty;
            try payload_obj.put(alloc, "text", .{ .string = text_str });
            const envelope = protocol.Envelope{
                .@"type" = envelope_type,
                .id = req_id,
                .source = srv.agent_id,
                .target = target,
                .payload = .{ .object = payload_obj },
            };
            try hubRoundtripAndRespond(srv, alloc, client_fd, envelope);
        },
        .recv => {
            // Bounded drain: the IPC line buffer is 64KiB and the response
            // aggregates every queued message (WI-2026-08-08-028).
            const msgs = try srv.message_queue.drain(alloc, 50);
            // drain() transfers ownership: inner strings were duped with
            // the queue's smp allocator — free them after serialization
            // (previously leaked for the daemon's lifetime; WI-2026-08-08-017).
            defer {
                for (msgs) |msg| std.heap.smp_allocator.free(msg);
                alloc.free(msgs);
            }
            // Serialize messages as a JSON array of strings.
            var array = json.Array.init(alloc);
            for (msgs) |msg| {
                try array.append(json.Value{ .string = msg });
            }
            const arr_val = json.Value{ .array = array };
            const data_raw = try json.Stringify.valueAlloc(alloc, arr_val, .{});
            const resp = protocol.IpcResponse{ .success = true, .data = data_raw };
            const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
            try ipc.IpcServer.writeLine(client_fd, resp_raw);
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
            defer if (hub_resp) |r| std.heap.smp_allocator.free(r);
            const success = hub_resp != null;
            const resp = protocol.IpcResponse{
                .success = success,
                .data = hub_resp,
                .error_msg = if (!success) "hub timeout" else null,
            };
            const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
            try ipc.IpcServer.writeLine(client_fd, resp_raw);
        },
        .register => {
            var id_buf: [32]u8 = undefined;
            const req_id = nextRequestId(srv, &id_buf);
            var payload_obj = json.ObjectMap.empty;
            if (req.tool) |t| try payload_obj.put(alloc, "tool", .{ .string = t });
            if (req.project) |p| try payload_obj.put(alloc, "project", .{ .string = p });
            if (req.session) |s| try payload_obj.put(alloc, "session", .{ .string = s });
            const envelope = protocol.Envelope{
                .@"type" = "agent_update",
                .id = req_id,
                .source = srv.agent_id,
                .target = "hub",
                .payload = .{ .object = payload_obj },
            };
            try hubRoundtripAndRespond(srv, alloc, client_fd, envelope);
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
            var payload_obj = json.ObjectMap.empty;
            if (req.channel) |ch| try payload_obj.put(alloc, "channel", .{ .string = ch });
            if (req.agent_id) |aid| try payload_obj.put(alloc, "agent_id", .{ .string = aid });
            if (req.description) |d| try payload_obj.put(alloc, "description", .{ .string = d });
            if (req.channel) |name| try payload_obj.put(alloc, "name", .{ .string = name });
            const envelope = protocol.Envelope{
                .@"type" = msg_type,
                .id = req_id,
                .source = srv.agent_id,
                .target = "hub",
                .payload = .{ .object = payload_obj },
            };
            try hubRoundtripAndRespond(srv, alloc, client_fd, envelope);
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

    const msgs = try q.drain(std.testing.allocator, 50);
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

    const msgs = try q.drain(std.testing.allocator, 50);
    defer std.testing.allocator.free(msgs);

    try std.testing.expectEqual(@as(usize, 0), msgs.len);
}

test "MessageQueue drain empties the queue" {
    var q = MessageQueue.init(std.testing.allocator);
    defer q.deinit();

    try q.push("msg-a");

    // First drain returns the message.
    const first = try q.drain(std.testing.allocator, 50);
    defer {
        for (first) |m| std.testing.allocator.free(m);
        std.testing.allocator.free(first);
    }
    try std.testing.expectEqual(@as(usize, 1), first.len);

    // Second drain returns empty.
    const second = try q.drain(std.testing.allocator, 50);
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

    // Cap above the push count so the thread-safety assertion sees all
    // messages (drain caps at `max` by design; WI-2026-08-08-028).
    const msgs = try q.drain(std.testing.allocator, 200);
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
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reg = try protocol.makeRegisterEnvelope(arena, "test-agent", &.{});
    const raw = try protocol.serializeEnvelope(arena, reg);
    // The hub's handleClient expects newline-terminated frames.
    // RunServer.init() appends "\n" after writing raw — verify raw itself
    // does NOT contain a newline (so the explicit "\n" write is needed).
    try std.testing.expect(mem.indexOfScalar(u8, raw, '\n') == null);
}

test "responseIdMatches compares the envelope id exactly (WI-2026-08-08-034)" {
    // The F12 regression: substring matching collided ('req-5' matched
    // 'req-50').
    try std.testing.expect(responseIdMatches(
        "{\"type\":\"response\",\"id\":\"req-5\",\"payload\":{\"ok\":true}}",
        "req-5",
    ));
    try std.testing.expect(!responseIdMatches(
        "{\"type\":\"response\",\"id\":\"req-50\",\"payload\":{\"ok\":true}}",
        "req-5",
    ));
    try std.testing.expect(responseIdMatches(
        "{\"type\":\"response\",\"id\":\"req-50\",\"payload\":{\"ok\":true}}",
        "req-50",
    ));
}

test "responseIdMatches rejects malformed or missing ids (WI-2026-08-08-034)" {
    // Missing id field.
    try std.testing.expect(!responseIdMatches(
        "{\"type\":\"response\",\"payload\":{\"ok\":true}}",
        "req-5",
    ));
    // Non-string id.
    try std.testing.expect(!responseIdMatches(
        "{\"type\":\"response\",\"id\":42,\"payload\":{\"ok\":true}}",
        "42",
    ));
    // Malformed JSON.
    try std.testing.expect(!responseIdMatches("{broken", "req-5"));
    // Non-object root.
    try std.testing.expect(!responseIdMatches("[1,2,3]", "req-5"));
    // The id must match fully — a prefix is not enough.
    try std.testing.expect(!responseIdMatches(
        "{\"type\":\"response\",\"id\":\"req-5-suffix\",\"payload\":{\"ok\":true}}",
        "req-5",
    ));
}
