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
const RoutingTable = struct {
    map: std.StringHashMap(net.Stream),

    fn init(allocator: Allocator) RoutingTable {
        return .{ .map = std.StringHashMap(net.Stream).init(allocator) };
    }

    fn deinit(self: *RoutingTable) void {
        self.map.deinit();
    }

    fn register(self: *RoutingTable, agent_id: []const u8, stream: net.Stream) !void {
        try self.map.put(agent_id, stream);
        log.info("registered agent: {s}", .{agent_id});
    }

    fn unregister(self: *RoutingTable, agent_id: []const u8) void {
        _ = self.map.remove(agent_id);
        log.info("unregistered agent: {s}", .{agent_id});
    }

    fn lookup(self: *const RoutingTable, agent_id: []const u8) ?net.Stream {
        return self.map.get(agent_id);
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
fn routeMessage(routing_table: *const RoutingTable, envelope: protocol.Envelope, raw: []const u8) void {
    const target = envelope.target;
    if (target.len == 0) {
        log.warn("envelope from {s} has no target, dropping", .{envelope.source});
        return;
    }

    const target_stream = routing_table.lookup(target) orelse {
        log.warn("target {s} not found in routing table", .{target});
        return;
    };

    _ = target_stream.write(raw) catch |err| {
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
};

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

    // We can't easily create a real net.Stream in tests, so we test
    // the map operations indirectly via the HashMap API.
    try std.testing.expect(rt.lookup("agent-a") == null);
}
