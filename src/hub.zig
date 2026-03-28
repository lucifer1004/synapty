const std = @import("std");
const net = std.net;
const mem = std.mem;
const json = std.json;
const posix = std.posix;
const protocol = @import("protocol");
const Allocator = mem.Allocator;
const log = std.log.scoped(.hub);

// ---------------------------------------------------------------------------
// Sub-module re-exports
// ---------------------------------------------------------------------------

const connection_mod = @import("hub/connection.zig");
pub const Connection = connection_mod.Connection;
const writerThread = connection_mod.writerThread;

const registry = @import("hub/registry.zig");
pub const HubState = registry.HubState;
const RoutingTable = registry.RoutingTable;
const AgentRegistry = registry.AgentRegistry;
const AgentInfo = registry.AgentInfo;
const ChannelRegistry = registry.ChannelRegistry;
const MessageLog = registry.MessageLog;

const handlers = @import("hub/handlers.zig");
const dispatchEnvelope = handlers.dispatchEnvelope;
const processLines = handlers.processLines;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const default_listen_addr = "127.0.0.1";
const default_listen_port: u16 = 9000;

/// Per-connection receive buffer size (64 KiB).
const recv_buf_size = handlers.recv_buf_size;

// ---------------------------------------------------------------------------
// Reader thread
// ---------------------------------------------------------------------------

/// Reader thread args.
const ReaderArgs = struct {
    state: *HubState,
    conn: *Connection,
};

/// Handle a single client connection: read JSON envelopes and dispatch them.
/// Uses a per-connection ArenaAllocator so parsed data is freed on disconnect,
/// and a line buffer so partial TCP frames are carried across reads.
/// Creates a Connection with an outbound queue and spawns a writer thread.
fn readerThread(args: ReaderArgs) void {
    const state = args.state;
    const conn = args.conn;
    const stream = conn.stream;
    // Release the reader's reference when done. If no cross-agent enqueue is
    // in flight, this frees the Connection. Otherwise the last release() frees.
    defer conn.release();

    // Per-connection arena for data that lives the whole connection (agent_id).
    var conn_arena = std.heap.ArenaAllocator.init(state.allocator);
    defer conn_arena.deinit();
    const conn_alloc = conn_arena.allocator();

    // Per-message arena — reset after each envelope dispatch so memory is bounded.
    var msg_arena = std.heap.ArenaAllocator.init(state.allocator);
    defer msg_arena.deinit();

    // Line buffer for TCP framing — carries partial lines across reads.
    var line_buf: [recv_buf_size]u8 = undefined;
    var filled: usize = 0;

    // Read until we have at least one complete line (the register envelope).
    const agent_id = blk: {
        while (true) {
            if (filled >= line_buf.len) {
                log.err("initial message exceeds buffer", .{});
                return;
            }
            const n = stream.read(line_buf[filled..]) catch |err| {
                log.err("read error on initial message: {any}", .{err});
                return;
            };
            if (n == 0) return;
            filled += n;

            // Check for a complete first line.
            if (mem.indexOfScalar(u8, line_buf[0..filled], '\n')) |nl| {
                const first_line = mem.trimRight(u8, line_buf[0..nl], "\r ");
                if (first_line.len == 0) return;

                // Parse with conn_arena so agent_id survives the connection.
                const parsed_init = protocol.parseEnvelope(conn_alloc, first_line) catch |err| {
                    log.err("failed to parse initial envelope: {any}", .{err});
                    return;
                };
                if (!mem.eql(u8, parsed_init.value.@"type", "register")) {
                    log.err("expected register, got: {s}", .{parsed_init.value.@"type"});
                    return;
                }
                // Shift consumed bytes out of line_buf.
                const consumed = nl + 1;
                const remaining = filled - consumed;
                if (remaining > 0) {
                    mem.copyForwards(u8, line_buf[0..remaining], line_buf[consumed..filled]);
                }
                filled = remaining;
                break :blk parsed_init.value.source;
            }
        }
    };

    // Connection was pre-created by the accept loop and registered in
    // HubState.all_connections, ensuring deinit can shutdown its stream.
    state.routing_table.register(agent_id, conn) catch |err| {
        log.err("failed to register {s}: {any}", .{ agent_id, err });
        return;
    };

    // Spawn the writer thread before entering the read loop.
    const writer = std.Thread.spawn(.{}, writerThread, .{conn}) catch |err| {
        log.err("failed to spawn writer thread for {s}: {any}", .{ agent_id, err });
        state.routing_table.unregister(agent_id);
        return;
    };

    defer {
        state.routing_table.unregister(agent_id);
        state.agent_registry.remove(agent_id);
        // Remove from all channels per [[RFC-0002:C-HUB-STATE]].
        _ = state.channel_registry.removeFromAll(agent_id, conn_alloc) catch {};
        // Signal writer to drain and stop, then wait for it.
        conn.shutdown();
        writer.join();
        // conn is released by the outer `defer conn.release()`. If refcount hits 0,
        // removeConnection removes from all_connections, closes stream, and frees.
    }

    // Process any additional complete lines from the initial read(s).
    processLines(state, &msg_arena, conn, agent_id, &line_buf, &filled);

    // Main receive loop with line buffering.
    while (true) {
        if (filled >= line_buf.len) {
            log.err("message from {s} exceeds buffer", .{agent_id});
            break;
        }
        const n = stream.read(line_buf[filled..]) catch |err| {
            switch (err) {
                error.ConnectionResetByPeer, error.BrokenPipe => {},
                else => log.warn("read error from {s}: {any}", .{ agent_id, err }),
            }
            break;
        };
        if (n == 0) break;
        filled += n;

        processLines(state, &msg_arena, conn, agent_id, &line_buf, &filled);
    }
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

pub const HubServer = struct {
    listener: net.Server,
    state: HubState,
    /// Tracks spawned client handler threads for clean shutdown.
    client_threads: std.ArrayList(std.Thread),
    client_threads_mutex: std.Thread.Mutex,
    /// Accept loop thread, set by startBackground().
    accept_thread: ?std.Thread,

    pub fn init(allocator: Allocator) !HubServer {
        _ = allocator;
        return initWithAddress(default_listen_addr, default_listen_port);
    }

    /// Create a Hub bound to a specific address/port. Use port 0 for an
    /// OS-assigned ephemeral port (useful for tests).
    pub fn initWithAddress(addr: []const u8, port: u16) !HubServer {
        // Ignore SIGPIPE so writes to disconnected clients return
        // error.BrokenPipe instead of killing the process.
        posix.sigaction(posix.SIG.PIPE, &.{
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = 0,
        }, null);

        const address = try net.Address.parseIp4(addr, port);
        const listener = try address.listen(.{
            .reuse_address = true,
        });

        const bound_port = listener.listen_address.getPort();
        log.info("Synapty Hub listening on {s}:{d}", .{ addr, bound_port });

        return .{
            .listener = listener,
            .state = HubState.init(std.heap.page_allocator),
            .client_threads = std.ArrayList(std.Thread).empty,
            .client_threads_mutex = .{},
            .accept_thread = null,
        };
    }

    pub fn deinit(self: *HubServer) void {
        // 1. Close listener to unblock accept() in the accept loop.
        self.listener.deinit();
        // 2. Join accept thread — guarantees no more client_threads.append() calls.
        if (self.accept_thread) |t| t.join();
        // 3. Shutdown all client streams to unblock readers blocked in read().
        //    Without this, idle clients prevent deinit from completing.
        self.state.all_connections_mutex.lock();
        for (self.state.all_connections.items) |conn| {
            // Use raw C shutdown to avoid Zig's unreachable on EBADF —
            // the reader thread may have already closed this fd.
            _ = std.c.shutdown(conn.stream.handle, 2); // SHUT_RDWR
        }
        self.state.all_connections_mutex.unlock();
        // 4. Join all reader threads (now unblocked by stream shutdown).
        self.client_threads_mutex.lock();
        for (self.client_threads.items) |t| t.join();
        self.client_threads.deinit(std.heap.page_allocator);
        self.client_threads_mutex.unlock();
        // 5. Free shared state (including all heap-allocated connections).
        self.state.deinit();
    }

    /// Start the accept loop in a background thread. Call deinit() to stop.
    pub fn startBackground(self: *HubServer) !void {
        self.accept_thread = try std.Thread.spawn(.{}, runBackground, .{self});
    }

    /// Accept connections in a loop, spawning a reader thread per client.
    pub fn run(self: *HubServer) !void {
        while (true) {
            const accepted = try self.listener.accept();
            log.info("accepted connection from {f}", .{accepted.address});

            // Create Connection on heap and register in all_connections BEFORE
            // spawning the reader thread, so deinit can always shutdown the
            // stream even if the thread hasn't started yet.
            const conn = self.state.allocator.create(Connection) catch {
                accepted.stream.close();
                continue;
            };
            conn.* = Connection.init(
                self.state.allocator,
                &self.state.all_connections,
                &self.state.all_connections_mutex,
                accepted.stream,
            );
            {
                self.state.all_connections_mutex.lock();
                defer self.state.all_connections_mutex.unlock();
                self.state.all_connections.append(self.state.allocator, conn) catch {
                    conn.deinit();
                    self.state.allocator.destroy(conn);
                    continue;
                };
            }

            const thread = std.Thread.spawn(.{}, readerThread, .{ReaderArgs{
                .state = &self.state,
                .conn = conn,
            }}) catch |err| {
                log.err("failed to spawn handler thread: {any}", .{err});
                conn.shutdown();
                conn.release(); // refcount -> 0 -> removeFromTracking
                continue;
            };
            self.client_threads_mutex.lock();
            const tracked = blk: {
                self.client_threads.append(std.heap.page_allocator, thread) catch break :blk false;
                break :blk true;
            };
            self.client_threads_mutex.unlock();

            if (!tracked) {
                // Can't track the thread — stop it now to prevent an orphaned
                // reader from accessing freed state after deinit.
                // Shutdown stream to unblock reader, then join. The reader's
                // defer will call conn.release() to clean up.
                _ = std.c.shutdown(conn.stream.handle, 2);
                thread.join();
            }
        }
    }

    pub fn startInBackground(allocator: Allocator) !*HubServer {
        const server = try allocator.create(HubServer);
        errdefer allocator.destroy(server);
        server.* = try HubServer.init(allocator);
        errdefer server.deinit();

        try server.startBackground();
        return server;
    }

    /// Return a heap-allocated slice of currently registered agent IDs.
    pub fn registeredAgents(self: *HubServer, allocator: Allocator) ![][]const u8 {
        return self.state.routing_table.agentIds(allocator);
    }
};

/// Thread entry point for background Hub execution. Errors are logged and
/// the thread exits cleanly so the GUI app is not disrupted.
/// `error.ConnectionAborted` is the normal shutdown signal (listener closed),
/// so it is swallowed silently.
fn runBackground(server: *HubServer) void {
    server.run() catch |err| switch (err) {
        error.ConnectionAborted => {}, // normal shutdown via deinit()
        else => log.err("Hub background thread exited with error: {}", .{err}),
    };
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var server = try HubServer.init(gpa.allocator());
    defer server.deinit();

    try server.run();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "HubServer.init succeeds and listener is bound" {
    var server = try HubServer.init(std.testing.allocator);
    defer server.deinit();

    // Verify the listener is bound by checking its address port is non-zero.
    const addr = server.listener.listen_address;
    try std.testing.expect(addr.getPort() != 0);
}

test "HubServer.registeredAgents returns empty list initially" {
    var server = try HubServer.init(std.testing.allocator);
    defer server.deinit();

    const agents = try server.registeredAgents(std.testing.allocator);
    defer std.testing.allocator.free(agents);

    try std.testing.expectEqual(@as(usize, 0), agents.len);
}

test "list_agents response envelope fields" {
    // Build the response envelope the same way handleClient will build it.
    const agent_list = [_][]const u8{ "agent-a", "agent-b" };
    const agents_slice: []const []const u8 = &agent_list;

    // Build a json.Value array for the payload.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var arr = std.json.Array.init(alloc);
    for (agents_slice) |id| {
        try arr.append(.{ .string = id });
    }

    var obj = std.json.ObjectMap.init(alloc);
    try obj.put("agents", .{ .array = arr });

    const resp_envelope = protocol.Envelope{
        .@"type" = "response",
        .id = "req-1",
        .source = "hub",
        .target = "agent-a",
        .payload = .{ .object = obj },
    };

    const serialized = try protocol.serializeEnvelope(alloc, resp_envelope);

    var parsed = try protocol.parseEnvelope(alloc, serialized);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("response", parsed.value.@"type");
    try std.testing.expectEqualStrings("hub", parsed.value.source);
    try std.testing.expectEqualStrings("agent-a", parsed.value.target);

    // Verify payload has "agents" array with correct entries.
    const payload_obj = parsed.value.payload.object;
    const agents_val = payload_obj.get("agents") orelse return error.MissingAgentsKey;
    try std.testing.expectEqual(@as(usize, 2), agents_val.array.items.len);
}

// Pull in tests from sub-modules.
comptime {
    _ = @import("hub/connection.zig");
    _ = @import("hub/registry.zig");
    _ = @import("hub/handlers.zig");
}
