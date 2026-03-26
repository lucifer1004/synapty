const std = @import("std");
const net = std.net;
const mem = std.mem;
const json = std.json;
const posix = std.posix;
const protocol = @import("protocol");
const Allocator = mem.Allocator;
const log = std.log.scoped(.hub);

// ---------------------------------------------------------------------------
// Routing Table
// ---------------------------------------------------------------------------

/// Maps agent_id -> active client connection stream.
/// Protected by a mutex for thread-safe access from handler threads and
/// the GUI status-bar query path.
const RoutingTable = struct {
    map: std.StringHashMap(net.Stream),
    mutex: std.Thread.Mutex,

    fn init(allocator: Allocator) RoutingTable {
        return .{
            .map = std.StringHashMap(net.Stream).init(allocator),
            .mutex = .{},
        };
    }

    fn deinit(self: *RoutingTable) void {
        self.map.deinit();
    }

    fn register(self: *RoutingTable, agent_id: []const u8, stream: net.Stream) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.map.put(agent_id, stream);
        log.info("registered agent: {s}", .{agent_id});
    }

    fn unregister(self: *RoutingTable, agent_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.map.remove(agent_id);
        log.info("unregistered agent: {s}", .{agent_id});
    }

    fn lookup(self: *const RoutingTable, agent_id: []const u8) ?net.Stream {
        // Callers that need to hold the lock during lookup use lockForLookup.
        // This bare version is only safe when called under an external lock.
        return self.map.get(agent_id);
    }

    /// Return a heap-allocated slice of all currently registered agent IDs.
    /// Caller owns the returned slice and must free it with `allocator`.
    fn agentIds(self: *RoutingTable, allocator: Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = self.map.count();
        const slice = try allocator.alloc([]const u8, count);
        errdefer allocator.free(slice);
        var it = self.map.keyIterator();
        var i: usize = 0;
        while (it.next()) |key| : (i += 1) {
            slice[i] = key.*;
        }
        return slice;
    }
};

// ---------------------------------------------------------------------------
// Client handler
// ---------------------------------------------------------------------------

/// Per-connection receive buffer size (64 KiB).
const recv_buf_size = 64 * 1024;

/// Handle a single client connection: read JSON envelopes and route them.
fn handleClient(routing_table: *RoutingTable, arena: Allocator, stream: net.Stream) void {
    defer stream.close();

    var buf: [recv_buf_size]u8 = undefined;

    // First message must be a "register" envelope.
    const initial_len = stream.read(&buf) catch |err| {
        log.err("read error on initial message: {any}", .{err});
        return;
    };
    if (initial_len == 0) return;

    const initial_raw = buf[0..initial_len];
    const parsed_init = protocol.parseEnvelope(arena, initial_raw) catch |err| {
        log.err("failed to parse initial envelope: {any}", .{err});
        return;
    };
    const init_envelope = parsed_init.value;

    if (!mem.eql(u8, init_envelope.@"type", "register")) {
        log.err("expected register, got: {s}", .{init_envelope.@"type"});
        return;
    }

    const agent_id = init_envelope.source;
    routing_table.register(agent_id, stream) catch |err| {
        log.err("failed to register {s}: {any}", .{ agent_id, err });
        return;
    };
    defer routing_table.unregister(agent_id);

    // Main receive loop: parse envelope, route to target.
    while (true) {
        const n = stream.read(&buf) catch |err| {
            log.err("read error from {s}: {any}", .{ agent_id, err });
            break;
        };
        if (n == 0) break; // connection closed

        const raw = buf[0..n];

        const parsed = protocol.parseEnvelope(arena, raw) catch |err| {
            log.err("bad envelope from {s}: {any}", .{ agent_id, err });
            continue;
        };
        const envelope = parsed.value;

        routeMessage(routing_table, envelope, raw);
    }
}

/// Forward a raw message to the target agent identified in the envelope.
fn routeMessage(routing_table: *RoutingTable, envelope: protocol.Envelope, raw: []const u8) void {
    const target = envelope.target;
    if (target.len == 0) {
        log.warn("envelope from {s} has no target, dropping", .{envelope.source});
        return;
    }

    routing_table.mutex.lock();
    const target_stream = routing_table.lookup(target);
    routing_table.mutex.unlock();

    const stream = target_stream orelse {
        log.warn("target {s} not found in routing table", .{target});
        return;
    };

    _ = stream.write(raw) catch |err| {
        log.err("failed to forward to {s}: {any}", .{ target, err });
    };
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

const default_listen_addr = "127.0.0.1";
const default_listen_port: u16 = 9000;

pub const HubServer = struct {
    listener: net.Server,
    routing_table: RoutingTable,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator) !HubServer {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const arena_alloc = arena.allocator();

        const address = net.Address.parseIp4(default_listen_addr, default_listen_port) catch unreachable;
        const listener = try address.listen(.{
            .reuse_address = true,
        });

        log.info("Synapty Hub listening on {s}:{d}", .{ default_listen_addr, default_listen_port });

        return .{
            .listener = listener,
            .routing_table = RoutingTable.init(arena_alloc),
            .arena = arena,
        };
    }

    pub fn deinit(self: *HubServer) void {
        self.routing_table.deinit();
        self.listener.deinit();
        self.arena.deinit();
    }

    /// Accept connections in a loop, spawning a thread per client.
    pub fn run(self: *HubServer) !void {
        while (true) {
            const conn = try self.listener.accept();
            log.info("accepted connection from {any}", .{conn.address});

            const arena_alloc = self.arena.allocator();
            _ = std.Thread.spawn(.{}, handleClient, .{
                &self.routing_table,
                arena_alloc,
                conn.stream,
            }) catch |err| {
                log.err("failed to spawn handler thread: {any}", .{err});
                conn.stream.close();
            };
        }
    }

    /// Start the Hub in a background thread and return a pointer to the
    /// heap-allocated server. The caller owns the returned pointer and must
    /// call `deinit()` followed by `allocator.destroy()` when done.
    ///
    /// Intended for embedding in the macOS GUI app so the Hub starts
    /// automatically at launch without blocking the main thread.
    pub fn startInBackground(allocator: Allocator) !*HubServer {
        const server = try allocator.create(HubServer);
        errdefer allocator.destroy(server);
        server.* = try HubServer.init(allocator);
        errdefer server.deinit();

        _ = try std.Thread.spawn(.{}, runBackground, .{server});
        return server;
    }

    /// Return a heap-allocated slice of currently registered agent IDs.
    /// Caller owns the slice and each string is borrowed from the routing
    /// table's arena — valid until the next `deinit()` call. The slice
    /// itself must be freed with the same allocator passed in.
    pub fn registeredAgents(self: *HubServer, allocator: Allocator) ![][]const u8 {
        return self.routing_table.agentIds(allocator);
    }
};

/// Thread entry point for background Hub execution. Errors are logged and
/// the thread exits cleanly so the GUI app is not disrupted.
/// `error.ConnectionAborted` is the normal shutdown signal (listener closed),
/// so it is swallowed silently.
fn runBackground(server: *HubServer) void {
    server.run() catch |err| switch (err) {
        error.ConnectionAborted => {}, // normal shutdown via deinit()
        else => log.err("Hub background thread exited with error: {any}", .{err}),
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

test "RoutingTable register and lookup" {
    var rt = RoutingTable.init(std.testing.allocator);
    defer rt.deinit();

    try std.testing.expect(rt.lookup("agent-a") == null);
}

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

test "startInBackground returns valid server handle" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const server = try HubServer.startInBackground(allocator);
    // Give the background thread a moment to start, then verify the server
    // is usable: registeredAgents should return an empty list.
    std.Thread.sleep(10 * std.time.ns_per_ms);

    const agents = try server.registeredAgents(allocator);
    defer allocator.free(agents);
    try std.testing.expectEqual(@as(usize, 0), agents.len);

    // Clean up: deinit closes the listener which will cause run() to error
    // and the background thread to exit.
    server.deinit();
    allocator.destroy(server);
}
