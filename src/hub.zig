const std = @import("std");
const net = std.net;
const mem = std.mem;
const json = std.json;
const posix = std.posix;
const protocol = @import("protocol");
const Allocator = mem.Allocator;
const log = std.log.scoped(.hub);

// ---------------------------------------------------------------------------
// Connection — owns stream + outbound queue with dedicated writer thread
// ---------------------------------------------------------------------------

const Connection = struct {
    stream: net.Stream,
    allocator: Allocator,
    state: *HubState, // back-pointer for removeConnection on final release
    outbound: std.ArrayListUnmanaged([]const u8),
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    closed: bool,
    stream_closed: bool,
    /// Atomic reference count. Starts at 1 (reader thread owns).
    /// Cross-agent lookups retain temporarily; release frees when count hits 0.
    ref_count: std.atomic.Value(u32),

    fn init(allocator: Allocator, state: *HubState, stream: net.Stream) Connection {
        return .{
            .stream = stream,
            .allocator = allocator,
            .state = state,
            .outbound = .empty,
            .mutex = .{},
            .cond = .{},
            .closed = false,
            .stream_closed = false,
            .ref_count = std.atomic.Value(u32).init(1),
        };
    }

    fn deinit(self: *Connection) void {
        for (self.outbound.items) |item| self.allocator.free(item);
        self.outbound.deinit(self.allocator);
        if (!self.stream_closed) self.stream.close();
    }

    /// Close the stream (e.g. on spawn failure). Prevents double-close in deinit.
    fn closeStream(self: *Connection) void {
        if (!self.stream_closed) {
            self.stream.close();
            self.stream_closed = true;
        }
    }

    /// Increment reference count (called under routing table lock).
    fn retain(self: *Connection) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    /// Decrement reference count. When it hits 0, remove from HubState and free.
    fn release(self: *Connection) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            self.state.removeConnection(self);
        }
    }

    /// Enqueue a pre-serialized bytes slice for the writer thread.
    /// Duplicates data into owned storage.
    /// Returns error.ConnectionClosed if the connection is already closing.
    fn enqueue(self: *Connection, data: []const u8) error{ ConnectionClosed, OutOfMemory }!void {
        const copy = try self.allocator.dupe(u8, data);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) {
            self.allocator.free(copy);
            return error.ConnectionClosed;
        }
        self.outbound.append(self.allocator, copy) catch |err| {
            self.allocator.free(copy);
            return err;
        };
        self.cond.signal();
    }

    /// Serialize envelope, append newline, and enqueue atomically.
    fn enqueueEnvelope(self: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
        const raw = try protocol.serializeEnvelope(arena, envelope);
        // Build "raw\n" as a single owned buffer for atomic delivery.
        const with_nl = try arena.alloc(u8, raw.len + 1);
        @memcpy(with_nl[0..raw.len], raw);
        with_nl[raw.len] = '\n';
        try self.enqueue(with_nl);
    }

    /// Signal the writer thread to drain and stop.
    fn shutdown(self: *Connection) void {
        self.mutex.lock();
        self.closed = true;
        self.cond.signal();
        self.mutex.unlock();
    }
};

/// Writer thread: drains the outbound queue until closed and empty.
/// Poisons the connection (closed=true) under the mutex at every exit point
/// so enqueue() never accepts a message after the writer has decided to stop.
fn writerThread(conn: *Connection) void {
    while (true) {
        var batch: [][]const u8 = &.{};
        {
            conn.mutex.lock();
            defer conn.mutex.unlock();
            while (conn.outbound.items.len == 0 and !conn.closed) {
                conn.cond.wait(&conn.mutex);
            }
            if (conn.closed and conn.outbound.items.len == 0) break;
            batch = conn.outbound.toOwnedSlice(conn.allocator) catch {
                // OOM — poison under lock so no new enqueues are accepted.
                conn.closed = true;
                break;
            };
        }
        var write_failed = false;
        for (batch) |item| {
            if (!write_failed) {
                conn.stream.writeAll(item) catch {
                    write_failed = true;
                };
            }
            conn.allocator.free(item);
        }
        conn.allocator.free(batch);
        if (write_failed) {
            // Poison under lock so no new enqueues are accepted.
            conn.mutex.lock();
            conn.closed = true;
            conn.mutex.unlock();
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// Routing Table
// ---------------------------------------------------------------------------

/// Maps agent_id -> active Connection pointer.
/// Protected by a mutex for thread-safe access.
const RoutingTable = struct {
    map: std.StringHashMap(*Connection),
    mutex: std.Thread.Mutex,

    fn init(allocator: Allocator) RoutingTable {
        return .{
            .map = std.StringHashMap(*Connection).init(allocator),
            .mutex = .{},
        };
    }

    fn deinit(self: *RoutingTable) void {
        self.map.deinit();
    }

    fn register(self: *RoutingTable, agent_id: []const u8, conn: *Connection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.map.put(agent_id, conn);
        log.info("registered agent: {s}", .{agent_id});
    }

    fn unregister(self: *RoutingTable, agent_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.map.remove(agent_id);
        log.info("unregistered agent: {s}", .{agent_id});
    }

    fn lookup(self: *const RoutingTable, agent_id: []const u8) ?*Connection {
        // Callers must hold mutex before calling.
        return self.map.get(agent_id);
    }

    /// Lookup and retain a connection. Caller must call conn.release() when done.
    /// Safe against concurrent unregister — the routing table mutex serializes
    /// retain vs unregister, so the pointer is guaranteed alive until release.
    fn lookupAndRetain(self: *RoutingTable, agent_id: []const u8) ?*Connection {
        self.mutex.lock();
        defer self.mutex.unlock();
        const conn = self.map.get(agent_id) orelse return null;
        conn.retain();
        return conn;
    }

    /// Return a heap-allocated slice of duped agent ID strings.
    /// Caller owns both the slice and each string — free strings first, then slice.
    fn agentIds(self: *RoutingTable, allocator: Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = self.map.count();
        const slice = try allocator.alloc([]const u8, count);
        var i: usize = 0;
        errdefer {
            for (slice[0..i]) |s| allocator.free(s);
            allocator.free(slice);
        }
        var it = self.map.keyIterator();
        while (it.next()) |key| : (i += 1) {
            slice[i] = try allocator.dupe(u8, key.*);
        }
        return slice;
    }
};

// ---------------------------------------------------------------------------
// Agent Registry — per [[RFC-0002:C-AGENT-IDENTITY]]
// ---------------------------------------------------------------------------

const AgentInfo = struct {
    tool: ?[]const u8 = null,
    project: ?[]const u8 = null,
    session: ?[]const u8 = null,
};

const AgentRegistry = struct {
    map: std.StringHashMap(AgentInfo),
    mutex: std.Thread.Mutex,
    allocator: Allocator,

    fn init(allocator: Allocator) AgentRegistry {
        return .{
            .map = std.StringHashMap(AgentInfo).init(allocator),
            .mutex = .{},
            .allocator = allocator,
        };
    }

    fn deinit(self: *AgentRegistry) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.freeInfo(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    /// Dupe key and info strings into owned storage, replacing any previous entry.
    fn update(self: *AgentRegistry, agent_id: []const u8, info: AgentInfo) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const owned_key = try self.allocator.dupe(u8, agent_id);
        errdefer self.allocator.free(owned_key);
        const owned = AgentInfo{
            .tool = if (info.tool) |t| try self.allocator.dupe(u8, t) else null,
            .project = if (info.project) |p| try self.allocator.dupe(u8, p) else null,
            .session = if (info.session) |s| try self.allocator.dupe(u8, s) else null,
        };
        // fetchPut overwrites both key and value; returns old pair if existed.
        const prev = self.map.fetchPut(owned_key, owned) catch |err| {
            self.allocator.free(owned_key);
            self.freeInfo(owned);
            return err;
        };
        if (prev) |old| {
            self.allocator.free(old.key); // free replaced key
            self.freeInfo(old.value);
        }
        log.info("agent metadata updated: {s} tool={s}", .{ agent_id, info.tool orelse "-" });
    }

    fn remove(self: *AgentRegistry, agent_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.fetchRemove(agent_id)) |kv| {
            self.allocator.free(kv.key);
            self.freeInfo(kv.value);
        }
    }

    /// Return a snapshot of agent info with duped strings (caller-owned).
    /// Safe to use after the mutex is released — no borrowed pointers.
    fn get(self: *AgentRegistry, agent_id: []const u8, alloc: Allocator) ?AgentInfo {
        self.mutex.lock();
        defer self.mutex.unlock();
        const info = self.map.get(agent_id) orelse return null;
        return AgentInfo{
            .tool = if (info.tool) |t| alloc.dupe(u8, t) catch null else null,
            .project = if (info.project) |p| alloc.dupe(u8, p) catch null else null,
            .session = if (info.session) |s| alloc.dupe(u8, s) catch null else null,
        };
    }

    fn freeInfo(self: *AgentRegistry, info: AgentInfo) void {
        if (info.tool) |t| self.allocator.free(t);
        if (info.project) |p| self.allocator.free(p);
        if (info.session) |s| self.allocator.free(s);
    }
};

// ---------------------------------------------------------------------------
// Channel Registry — per [[RFC-0002:C-GROUP-CHAT]]
// ---------------------------------------------------------------------------

const Channel = struct {
    name: []const u8,
    description: []const u8,
    members: std.StringHashMap(void),
    created_by: []const u8,
    created_at: i64,
};

const ChannelRegistry = struct {
    map: std.StringHashMap(Channel),
    mutex: std.Thread.Mutex,
    allocator: Allocator,

    fn init(allocator: Allocator) ChannelRegistry {
        return .{
            .map = std.StringHashMap(Channel).init(allocator),
            .mutex = .{},
            .allocator = allocator,
        };
    }

    fn deinit(self: *ChannelRegistry) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.freeChannelStrings(entry.key_ptr.*, entry.value_ptr.*);
        }
        self.map.deinit();
    }

    fn create(self: *ChannelRegistry, name: []const u8, description: []const u8, creator: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.contains(name)) return error.ChannelExists;
        // Dupe all strings — channel data outlives the creating connection.
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_desc = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(owned_desc);
        const owned_creator = try self.allocator.dupe(u8, creator);
        errdefer self.allocator.free(owned_creator);
        const member_key = try self.allocator.dupe(u8, creator);
        errdefer self.allocator.free(member_key);
        var members = std.StringHashMap(void).init(self.allocator);
        try members.put(member_key, {});
        try self.map.put(owned_name, .{
            .name = owned_name,
            .description = owned_desc,
            .members = members,
            .created_by = owned_creator,
            .created_at = std.time.timestamp(),
        });
        log.info("channel created: {s} by {s}", .{ name, creator });
    }

    fn addMember(self: *ChannelRegistry, name: []const u8, agent_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ch = self.map.getPtr(name) orelse return error.ChannelNotFound;
        const owned_id = try self.allocator.dupe(u8, agent_id);
        errdefer self.allocator.free(owned_id);
        try ch.members.put(owned_id, {});
    }

    fn removeMember(self: *ChannelRegistry, name: []const u8, agent_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ch = self.map.getPtr(name) orelse return error.ChannelNotFound;
        if (ch.members.fetchRemove(agent_id)) |kv| {
            self.allocator.free(kv.key);
        }
        // Garbage-collect empty channels.
        if (ch.members.count() == 0) {
            if (self.map.fetchRemove(name)) |kv| {
                self.freeChannelStrings(kv.key, kv.value);
            }
            log.info("channel garbage-collected: {s}", .{name});
        }
    }

    /// Free all owned strings of a channel entry.
    fn freeChannelStrings(self: *ChannelRegistry, key: []const u8, ch: Channel) void {
        // Free remaining member keys.
        var copy = ch;
        var member_it = copy.members.keyIterator();
        while (member_it.next()) |k| self.allocator.free(k.*);
        copy.members.deinit();
        // key == ch.name (same pointer from create), free once.
        self.allocator.free(key);
        self.allocator.free(ch.description);
        self.allocator.free(ch.created_by);
    }

    fn isMember(self: *ChannelRegistry, name: []const u8, agent_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ch = self.map.get(name) orelse return false;
        return ch.members.contains(agent_id);
    }

    /// Return duped member ID strings. Caller owns both slice and each string.
    fn getMembers(self: *ChannelRegistry, name: []const u8, allocator: Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ch = self.map.get(name) orelse return error.ChannelNotFound;
        const count = ch.members.count();
        const slice = try allocator.alloc([]const u8, count);
        var i: usize = 0;
        errdefer {
            for (slice[0..i]) |s| allocator.free(s);
            allocator.free(slice);
        }
        var it = ch.members.keyIterator();
        while (it.next()) |key| : (i += 1) {
            slice[i] = try allocator.dupe(u8, key.*);
        }
        return slice;
    }

    /// Remove an agent from all channels, returning channel names it was in.
    fn removeFromAll(self: *ChannelRegistry, agent_id: []const u8, allocator: Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var affected = std.ArrayList([]const u8).empty;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.members.fetchRemove(agent_id)) |kv| {
                self.allocator.free(kv.key); // free owned member key
                // Dupe into caller's allocator so the name survives GC below.
                try affected.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
            }
        }
        // Garbage-collect empty channels (deferred to avoid mutation during iteration).
        for (affected.items) |ch_name| {
            if (self.map.getPtr(ch_name)) |ch| {
                if (ch.members.count() == 0) {
                    if (self.map.fetchRemove(ch_name)) |kv| {
                        self.freeChannelStrings(kv.key, kv.value);
                    }
                }
            }
        }
        return affected.toOwnedSlice(allocator);
    }

    /// List channels an agent is a member of. Returns duped channel names.
    fn channelsFor(self: *ChannelRegistry, agent_id: []const u8, allocator: Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var result = std.ArrayList([]const u8).empty;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.members.contains(agent_id)) {
                try result.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
            }
        }
        return result.toOwnedSlice(allocator);
    }
};

// ---------------------------------------------------------------------------
// Message Log — per [[RFC-0002:C-HUB-STATE]]
// ---------------------------------------------------------------------------

const LogEntry = struct {
    from: []const u8,
    to: []const u8,
    channel: ?[]const u8,
    text: []const u8,
    ts: i64,
};

const MessageLog = struct {
    entries: std.ArrayList(LogEntry),
    mutex: std.Thread.Mutex,
    max_entries: usize,

    fn init(max_entries: usize) MessageLog {
        return .{
            .entries = std.ArrayList(LogEntry).empty,
            .mutex = .{},
            .max_entries = max_entries,
        };
    }

    fn deinit(self: *MessageLog, allocator: Allocator) void {
        for (self.entries.items) |entry| {
            freeLogEntry(allocator, entry);
        }
        self.entries.deinit(allocator);
    }

    fn freeLogEntry(allocator: Allocator, entry: LogEntry) void {
        allocator.free(entry.from);
        allocator.free(entry.to);
        if (entry.channel) |ch| allocator.free(ch);
        allocator.free(entry.text);
    }

    /// Append a log entry, duping all strings so the entry outlives the caller's arena.
    fn append(self: *MessageLog, allocator: Allocator, entry: LogEntry) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const owned = LogEntry{
            .from = try allocator.dupe(u8, entry.from),
            .to = try allocator.dupe(u8, entry.to),
            .channel = if (entry.channel) |ch| try allocator.dupe(u8, ch) else null,
            .text = try allocator.dupe(u8, entry.text),
            .ts = entry.ts,
        };
        try self.entries.append(allocator, owned);
        // FIFO eviction.
        if (self.entries.items.len > self.max_entries) {
            const evicted = self.entries.orderedRemove(0);
            freeLogEntry(allocator, evicted);
        }
    }
};

// ---------------------------------------------------------------------------
// Hub State — combines all registries
// ---------------------------------------------------------------------------

const HubState = struct {
    routing_table: RoutingTable,
    agent_registry: AgentRegistry,
    channel_registry: ChannelRegistry,
    message_log: MessageLog,
    allocator: Allocator,
    /// All heap-allocated connections — freed in deinit after all threads join.
    /// Connections outlive their reader/writer threads to prevent use-after-free
    /// when a cross-agent enqueue races with disconnect cleanup.
    all_connections: std.ArrayList(*Connection),
    all_connections_mutex: std.Thread.Mutex,

    fn init(allocator: Allocator) HubState {
        return .{
            .routing_table = RoutingTable.init(allocator),
            .agent_registry = AgentRegistry.init(allocator),
            .channel_registry = ChannelRegistry.init(allocator),
            .message_log = MessageLog.init(10_000),
            .allocator = allocator,
            .all_connections = std.ArrayList(*Connection).empty,
            .all_connections_mutex = .{},
        };
    }

    /// Remove a connection from tracking, close its stream, and free it.
    fn removeConnection(self: *HubState, conn: *Connection) void {
        self.all_connections_mutex.lock();
        // Find and swap-remove.
        for (self.all_connections.items, 0..) |c, idx| {
            if (c == conn) {
                _ = self.all_connections.swapRemove(idx);
                break;
            }
        }
        self.all_connections_mutex.unlock();
        conn.closeStream();
        conn.deinit();
        self.allocator.destroy(conn);
    }

    fn deinit(self: *HubState) void {
        // Free any remaining connections (e.g. from threads that didn't clean up).
        for (self.all_connections.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.all_connections.deinit(self.allocator);
        self.routing_table.deinit();
        self.agent_registry.deinit();
        self.channel_registry.deinit();
        self.message_log.deinit(self.allocator);
    }
};

// ---------------------------------------------------------------------------
// Client handler
// ---------------------------------------------------------------------------

/// Per-connection receive buffer size (64 KiB).
const recv_buf_size = 64 * 1024;

/// Send a response envelope by enqueueing it into the sender's Connection.
fn sendResponse(arena: Allocator, conn: *Connection, req_id: []const u8, target: []const u8, ok: bool, data: ?json.Value, err_msg: ?[]const u8) !void {
    var payload_obj = json.ObjectMap.init(arena);
    try payload_obj.put("ok", .{ .bool = ok });
    if (data) |d| try payload_obj.put("data", d);
    if (err_msg) |e| try payload_obj.put("error", .{ .string = e });

    const resp = protocol.Envelope{
        .@"type" = "response",
        .id = req_id,
        .source = "hub",
        .target = target,
        .payload = .{ .object = payload_obj },
    };
    try conn.enqueueEnvelope(arena, resp);
}

// -- Handler: list_agents per [[RFC-0002:C-CLI-MCP]] -----------------------

fn handleListAgents(state: *HubState, arena: Allocator, conn: *Connection, req: protocol.Envelope) !void {
    const agent_ids = try state.routing_table.agentIds(arena);

    var arr = json.Array.init(arena);
    for (agent_ids) |id| {
        var agent_obj = json.ObjectMap.init(arena);
        try agent_obj.put("id", .{ .string = id });
        const info = state.agent_registry.get(id, arena);
        try agent_obj.put("tool", .{ .string = if (info) |i| i.tool orelse "-" else "-" });
        try agent_obj.put("project", .{ .string = if (info) |i| i.project orelse "-" else "-" });
        try agent_obj.put("session", .{ .string = if (info) |i| i.session orelse "-" else "-" });
        try arr.append(.{ .object = agent_obj });
    }

    var data_obj = json.ObjectMap.init(arena);
    try data_obj.put("ok", .{ .bool = true });
    try data_obj.put("agents", .{ .array = arr });

    const resp = protocol.Envelope{
        .@"type" = "response",
        .id = req.id,
        .source = "hub",
        .target = req.source,
        .payload = .{ .object = data_obj },
    };
    try conn.enqueueEnvelope(arena, resp);
}

// -- Handler: agent_update per [[RFC-0002:C-AGENT-IDENTITY]] ---------------

fn handleAgentUpdate(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
    const payload = if (envelope.payload == .object) envelope.payload.object else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing payload");
        return;
    };
    const info = AgentInfo{
        .tool = if (payload.get("tool")) |v| (if (v == .string) v.string else null) else null,
        .project = if (payload.get("project")) |v| (if (v == .string) v.string else null) else null,
        .session = if (payload.get("session")) |v| (if (v == .string) v.string else null) else null,
    };
    try state.agent_registry.update(envelope.source, info);
    try sendResponse(arena, conn, envelope.id, envelope.source, true, null, null);
}

// -- Handler: dm per [[RFC-0002:C-DM]] -------------------------------------

fn handleDm(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
    const target = envelope.target;
    if (target.len == 0) {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing target");
        return;
    }

    // Extract text from payload for logging.
    const text = blk: {
        if (envelope.payload == .object) {
            if (envelope.payload.object.get("text")) |v| {
                if (v == .string) break :blk v.string;
            }
        }
        break :blk "";
    };

    // Log the message per [[RFC-0002:C-HUB-STATE]].
    state.message_log.append(state.allocator, .{
        .from = envelope.source,
        .to = target,
        .channel = null,
        .text = text,
        .ts = std.time.timestamp(),
    }) catch {};

    // Route to target — lookupAndRetain ensures pointer is alive until release.
    if (state.routing_table.lookupAndRetain(target)) |tc| {
        defer tc.release();
        tc.enqueueEnvelope(arena, envelope) catch |err| {
            log.warn("failed to deliver dm to {s}: {any}", .{ target, err });
            try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "delivery failed");
            return;
        };
        try sendResponse(arena, conn, envelope.id, envelope.source, true, null, null);
    } else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "agent not connected");
        return;
    }
}

// -- Handler: channel_create per [[RFC-0002:C-GROUP-CHAT]] -----------------

fn handleChannelCreate(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
    const payload = if (envelope.payload == .object) envelope.payload.object else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing payload");
        return;
    };
    const name = if (payload.get("name")) |v| (if (v == .string) v.string else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "invalid channel name type");
        return;
    }) else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing channel name");
        return;
    };
    const desc = if (payload.get("description")) |v| (if (v == .string) v.string else "") else "";

    state.channel_registry.create(name, desc, envelope.source) catch |err| switch (err) {
        error.ChannelExists => {
            try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "channel already exists");
            return;
        },
        else => return err,
    };
    try sendResponse(arena, conn, envelope.id, envelope.source, true, null, null);
}

// -- Handler: channel_invite per [[RFC-0002:C-GROUP-CHAT]] -----------------

fn handleChannelInvite(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
    const payload = if (envelope.payload == .object) envelope.payload.object else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing payload");
        return;
    };
    const ch_name = if (payload.get("channel")) |v| (if (v == .string) v.string else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "invalid channel type");
        return;
    }) else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing channel");
        return;
    };
    const agent_id = if (payload.get("agent_id")) |v| (if (v == .string) v.string else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "invalid agent_id type");
        return;
    }) else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing agent_id");
        return;
    };

    if (!state.channel_registry.isMember(ch_name, envelope.source)) {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "not a member of channel");
        return;
    }

    state.channel_registry.addMember(ch_name, agent_id) catch |err| switch (err) {
        error.ChannelNotFound => {
            try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "channel not found");
            return;
        },
        else => return err,
    };

    // Notify invited agent.
    if (state.routing_table.lookupAndRetain(agent_id)) |ic| {
        defer ic.release();
        var evt_payload = json.ObjectMap.init(arena);
        try evt_payload.put("channel", .{ .string = ch_name });
        try evt_payload.put("event", .{ .string = "invited" });
        try evt_payload.put("by", .{ .string = envelope.source });
        ic.enqueueEnvelope(arena, .{
            .@"type" = "channel_event",
            .id = "evt-0",
            .source = "hub",
            .target = agent_id,
            .payload = .{ .object = evt_payload },
        }) catch {};
    }

    try sendResponse(arena, conn, envelope.id, envelope.source, true, null, null);
}

// -- Handler: channel_leave per [[RFC-0002:C-GROUP-CHAT]] ------------------

fn handleChannelLeave(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
    const payload = if (envelope.payload == .object) envelope.payload.object else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing payload");
        return;
    };
    const ch_name = if (payload.get("channel")) |v| (if (v == .string) v.string else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "invalid channel type");
        return;
    }) else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing channel");
        return;
    };

    state.channel_registry.removeMember(ch_name, envelope.source) catch {};

    // Notify remaining members.
    const members = state.channel_registry.getMembers(ch_name, arena) catch &.{};
    for (members) |mid| {
        if (state.routing_table.lookupAndRetain(mid)) |member_conn| {
            defer member_conn.release();
            var evt_payload = json.ObjectMap.init(arena);
            try evt_payload.put("channel", .{ .string = ch_name });
            try evt_payload.put("event", .{ .string = "left" });
            try evt_payload.put("agent_id", .{ .string = envelope.source });
            member_conn.enqueueEnvelope(arena, .{
                .@"type" = "channel_event",
                .id = "evt-0",
                .source = "hub",
                .target = mid,
                .payload = .{ .object = evt_payload },
            }) catch {};
        }
    }

    try sendResponse(arena, conn, envelope.id, envelope.source, true, null, null);
}

// -- Handler: channel_msg per [[RFC-0002:C-GROUP-CHAT]] --------------------

fn handleChannelMsg(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
    const target = envelope.target;
    // Extract channel name from "channel:<name>" prefix.
    if (!mem.startsWith(u8, target, "channel:")) {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "invalid channel target");
        return;
    }
    const ch_name = target["channel:".len..];

    if (!state.channel_registry.isMember(ch_name, envelope.source)) {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "not a member of channel");
        return;
    }

    // Extract text for logging.
    const text = blk: {
        if (envelope.payload == .object) {
            if (envelope.payload.object.get("text")) |v| {
                if (v == .string) break :blk v.string;
            }
        }
        break :blk "";
    };

    // Log per [[RFC-0002:C-HUB-STATE]].
    state.message_log.append(state.allocator, .{
        .from = envelope.source,
        .to = target,
        .channel = ch_name,
        .text = text,
        .ts = std.time.timestamp(),
    }) catch {};

    // Fan-out to connected members except sender.
    const members = state.channel_registry.getMembers(ch_name, arena) catch {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "channel not found");
        return;
    };

    for (members) |mid| {
        if (mem.eql(u8, mid, envelope.source)) continue;
        if (state.routing_table.lookupAndRetain(mid)) |member_conn| {
            defer member_conn.release();
            member_conn.enqueueEnvelope(arena, envelope) catch |err| {
                log.warn("failed to fan-out to {s}: {any}", .{ mid, err });
            };
        }
    }
    try sendResponse(arena, conn, envelope.id, envelope.source, true, null, null);
}

// -- Handler: list_channels per [[RFC-0002:C-CLI-MCP]] ---------------------

fn handleListChannels(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
    const channels = try state.channel_registry.channelsFor(envelope.source, arena);

    var arr = json.Array.init(arena);
    for (channels) |ch_name| {
        var ch_obj = json.ObjectMap.init(arena);
        try ch_obj.put("name", .{ .string = ch_name });
        try arr.append(.{ .object = ch_obj });
    }

    var data_obj = json.ObjectMap.init(arena);
    try data_obj.put("ok", .{ .bool = true });
    try data_obj.put("channels", .{ .array = arr });

    const resp = protocol.Envelope{
        .@"type" = "response",
        .id = envelope.id,
        .source = "hub",
        .target = envelope.source,
        .payload = .{ .object = data_obj },
    };
    try conn.enqueueEnvelope(arena, resp);
}

// -- Message dispatcher ----------------------------------------------------

fn dispatchEnvelope(state: *HubState, arena: Allocator, conn: *Connection, agent_id: []const u8, envelope: protocol.Envelope) void {
    const msg_type = envelope.@"type";

    const result: anyerror!void = if (mem.eql(u8, msg_type, "list_agents"))
        handleListAgents(state, arena, conn, envelope)
    else if (mem.eql(u8, msg_type, "list_channels"))
        handleListChannels(state, conn, arena, envelope)
    else if (mem.eql(u8, msg_type, "agent_update"))
        handleAgentUpdate(state, conn, arena, envelope)
    else if (mem.eql(u8, msg_type, "dm"))
        handleDm(state, conn, arena, envelope)
    else if (mem.eql(u8, msg_type, "channel_create"))
        handleChannelCreate(state, conn, arena, envelope)
    else if (mem.eql(u8, msg_type, "channel_invite"))
        handleChannelInvite(state, conn, arena, envelope)
    else if (mem.eql(u8, msg_type, "channel_leave"))
        handleChannelLeave(state, conn, arena, envelope)
    else if (mem.eql(u8, msg_type, "channel_msg"))
        handleChannelMsg(state, conn, arena, envelope)
    else {
        log.warn("unknown message type from {s}: {s}", .{ agent_id, msg_type });
        return;
    };

    result catch |err| {
        // IO errors during handler execution mean the client disconnected
        // while a response was being written — expected during concurrent
        // shutdown, not a bug.
        switch (err) {
            error.BrokenPipe, error.ConnectionResetByPeer, error.NotOpenForWriting, error.ConnectionClosed => {},
            else => log.warn("{s} handler failed for {s}: {any}", .{ msg_type, agent_id, err }),
        }
    };
}

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

/// Extract and dispatch all complete newline-delimited lines from the buffer.
/// Resets msg_arena after each envelope so per-message memory is bounded.
fn processLines(state: *HubState, msg_arena: *std.heap.ArenaAllocator, conn: *Connection, agent_id: []const u8, line_buf: *[recv_buf_size]u8, filled: *usize) void {
    var start: usize = 0;
    while (mem.indexOfScalar(u8, line_buf[start..filled.*], '\n')) |rel| {
        const end = start + rel;
        const raw = mem.trimRight(u8, line_buf[start..end], "\r ");
        start = end + 1;
        if (raw.len == 0) continue;

        // Reset per-message arena so each envelope parse is bounded.
        _ = msg_arena.reset(.retain_capacity);
        const alloc = msg_arena.allocator();

        const parsed = protocol.parseEnvelope(alloc, raw) catch |err| {
            log.err("bad envelope from {s}: {any}", .{ agent_id, err });
            continue;
        };
        dispatchEnvelope(state, alloc, conn, agent_id, parsed.value);
    }
    // Shift unconsumed bytes to the front.
    const remaining = filled.* - start;
    if (remaining > 0 and start > 0) {
        mem.copyForwards(u8, line_buf[0..remaining], line_buf[start..filled.*]);
    }
    filled.* = remaining;
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

const default_listen_addr = "127.0.0.1";
const default_listen_port: u16 = 9000;

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
            const connection = self.state.allocator.create(Connection) catch {
                accepted.stream.close();
                continue;
            };
            connection.* = Connection.init(self.state.allocator, &self.state, accepted.stream);
            {
                self.state.all_connections_mutex.lock();
                defer self.state.all_connections_mutex.unlock();
                self.state.all_connections.append(self.state.allocator, connection) catch {
                    connection.deinit();
                    self.state.allocator.destroy(connection);
                    continue;
                };
            }

            const thread = std.Thread.spawn(.{}, readerThread, .{ReaderArgs{
                .state = &self.state,
                .conn = connection,
            }}) catch |err| {
                log.err("failed to spawn handler thread: {any}", .{err});
                connection.shutdown();
                connection.release(); // refcount → 0 → removeConnection
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
                _ = std.c.shutdown(connection.stream.handle, 2);
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

// ---------------------------------------------------------------------------
// RFC-0002 state structure tests
// ---------------------------------------------------------------------------

test "AgentRegistry update and get" {
    var reg = AgentRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.update("agent-a", .{ .tool = "codex", .project = "/path", .session = "auth refactor" });
    const info = reg.get("agent-a", std.testing.allocator).?;
    defer {
        if (info.tool) |t| std.testing.allocator.free(t);
        if (info.project) |p| std.testing.allocator.free(p);
        if (info.session) |s| std.testing.allocator.free(s);
    }
    try std.testing.expectEqualStrings("codex", info.tool.?);
    try std.testing.expectEqualStrings("/path", info.project.?);
    try std.testing.expectEqualStrings("auth refactor", info.session.?);
}

test "AgentRegistry remove clears entry" {
    var reg = AgentRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.update("agent-a", .{ .tool = "claude" });
    reg.remove("agent-a");
    try std.testing.expect(reg.get("agent-a", std.testing.allocator) == null);
}

test "ChannelRegistry create and membership" {
    var cr = ChannelRegistry.init(std.testing.allocator);
    defer cr.deinit();

    try cr.create("design", "Design discussion", "agent-a");
    try std.testing.expect(cr.isMember("design", "agent-a"));
    try std.testing.expect(!cr.isMember("design", "agent-b"));

    try cr.addMember("design", "agent-b");
    try std.testing.expect(cr.isMember("design", "agent-b"));

    const members = try cr.getMembers("design", std.testing.allocator);
    defer {
        for (members) |m| std.testing.allocator.free(m);
        std.testing.allocator.free(members);
    }
    try std.testing.expectEqual(@as(usize, 2), members.len);
}

test "ChannelRegistry duplicate create returns error" {
    var cr = ChannelRegistry.init(std.testing.allocator);
    defer cr.deinit();

    try cr.create("design", "", "agent-a");
    try std.testing.expectError(error.ChannelExists, cr.create("design", "", "agent-b"));
}

test "ChannelRegistry removeMember garbage-collects empty channel" {
    var cr = ChannelRegistry.init(std.testing.allocator);
    defer cr.deinit();

    try cr.create("temp", "", "agent-a");
    try cr.removeMember("temp", "agent-a");
    // Channel should be garbage-collected.
    try std.testing.expect(!cr.isMember("temp", "agent-a"));
    try std.testing.expectError(error.ChannelNotFound, cr.getMembers("temp", std.testing.allocator));
}

test "ChannelRegistry removeFromAll removes agent from all channels" {
    var cr = ChannelRegistry.init(std.testing.allocator);
    defer cr.deinit();

    try cr.create("ch-1", "", "agent-a");
    try cr.create("ch-2", "", "agent-a");
    try cr.addMember("ch-1", "agent-b");

    const affected = try cr.removeFromAll("agent-a", std.testing.allocator);
    defer {
        for (affected) |name| std.testing.allocator.free(name);
        std.testing.allocator.free(affected);
    }
    try std.testing.expectEqual(@as(usize, 2), affected.len);

    // agent-a should be gone from ch-1, ch-2 should be garbage-collected.
    try std.testing.expect(!cr.isMember("ch-1", "agent-a"));
    try std.testing.expect(cr.isMember("ch-1", "agent-b"));
}

test "ChannelRegistry channelsFor lists memberships" {
    var cr = ChannelRegistry.init(std.testing.allocator);
    defer cr.deinit();

    try cr.create("ch-1", "", "agent-a");
    try cr.create("ch-2", "", "agent-b");
    try cr.addMember("ch-2", "agent-a");

    const channels = try cr.channelsFor("agent-a", std.testing.allocator);
    defer {
        for (channels) |ch| std.testing.allocator.free(ch);
        std.testing.allocator.free(channels);
    }
    try std.testing.expectEqual(@as(usize, 2), channels.len);
}

test "MessageLog append and FIFO eviction" {
    var ml = MessageLog.init(3);
    defer ml.deinit(std.testing.allocator);

    try ml.append(std.testing.allocator, .{ .from = "a", .to = "b", .channel = null, .text = "msg1", .ts = 1 });
    try ml.append(std.testing.allocator, .{ .from = "a", .to = "b", .channel = null, .text = "msg2", .ts = 2 });
    try ml.append(std.testing.allocator, .{ .from = "a", .to = "b", .channel = null, .text = "msg3", .ts = 3 });
    try std.testing.expectEqual(@as(usize, 3), ml.entries.items.len);

    // 4th entry should evict the first.
    try ml.append(std.testing.allocator, .{ .from = "a", .to = "b", .channel = null, .text = "msg4", .ts = 4 });
    try std.testing.expectEqual(@as(usize, 3), ml.entries.items.len);
    try std.testing.expectEqualStrings("msg2", ml.entries.items[0].text);
    try std.testing.expectEqualStrings("msg4", ml.entries.items[2].text);
}
