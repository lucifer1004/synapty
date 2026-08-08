const std = @import("std");
const sys = @import("sys");
const io_mod = @import("io");
const mem = std.mem;
const json = std.json;
const protocol = @import("protocol");
const Allocator = mem.Allocator;
const Connection = @import("connection.zig").Connection;
const log = std.log.scoped(.hub);

// ---------------------------------------------------------------------------
// Routing Table
// ---------------------------------------------------------------------------

/// Maps agent_id -> active Connection pointer.
/// Protected by a mutex for thread-safe access.
pub const RoutingTable = struct {
    map: std.StringHashMap(*Connection),
    mutex: std.Io.Mutex,

    pub fn init(allocator: Allocator) RoutingTable {
        return .{
            .map = std.StringHashMap(*Connection).init(allocator),
            .mutex = .init,
        };
    }

    pub fn deinit(self: *RoutingTable) void {
        self.map.deinit();
    }

    pub fn register(self: *RoutingTable, agent_id: []const u8, conn: *Connection) !void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        if (try self.map.fetchPut(agent_id, conn)) |old| {
            // Duplicate registration (WI-2026-08-08-016): the new
            // connection atomically replaces the old one. Close the old
            // stream so its reader unblocks and exits; its eventual
            // unregisterIfOwned is a no-op because the entry now points
            // at the NEW connection.
            log.warn("duplicate registration for {s} — replacing previous connection", .{agent_id});
            old.value.closeStream();
        } else {
            log.info("registered agent: {s}", .{agent_id});
        }
    }

    /// Unregister agent_id ONLY when the entry still belongs to `conn`.
    /// A duplicate registration may have replaced the entry — the new
    /// connection owns the id now, and the old reader must not tear the
    /// new entry down (WI-2026-08-08-016). Returns true when the entry
    /// was removed (or never existed), so callers know whether to clean
    /// up derived state (agent metadata, channels).
    pub fn unregisterIfOwned(self: *RoutingTable, agent_id: []const u8, conn: *Connection) bool {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        if (self.map.get(agent_id)) |current| {
            if (current != conn) return false;
        }
        _ = self.map.remove(agent_id);
        log.info("unregistered agent: {s}", .{agent_id});
        return true;
    }

    pub fn lookup(self: *const RoutingTable, agent_id: []const u8) ?*Connection {
        // Callers must hold mutex before calling.
        return self.map.get(agent_id);
    }

    /// Lookup and retain a connection. Caller must call conn.release() when done.
    /// Safe against concurrent unregister — the routing table mutex serializes
    /// retain vs unregister, so the pointer is guaranteed alive until release.
    pub fn lookupAndRetain(self: *RoutingTable, agent_id: []const u8) ?*Connection {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        const conn = self.map.get(agent_id) orelse return null;
        conn.retain();
        return conn;
    }

    /// Return a heap-allocated slice of duped agent ID strings.
    /// Caller owns both the slice and each string — free strings first, then slice.
    pub fn agentIds(self: *RoutingTable, allocator: Allocator) ![][]const u8 {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
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
// Agent Registry — per [[RFC-0003]] (agent identity)
// ---------------------------------------------------------------------------

pub const AgentInfo = struct {
    tool: ?[]const u8 = null,
    project: ?[]const u8 = null,
    session: ?[]const u8 = null,
};

pub const AgentRegistry = struct {
    map: std.StringHashMap(AgentInfo),
    mutex: std.Io.Mutex,
    allocator: Allocator,

    pub fn init(allocator: Allocator) AgentRegistry {
        return .{
            .map = std.StringHashMap(AgentInfo).init(allocator),
            .mutex = .init,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AgentRegistry) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.freeInfo(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    /// Dupe key and info strings into owned storage, replacing any previous entry.
    pub fn update(self: *AgentRegistry, agent_id: []const u8, info: AgentInfo) !void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
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

    pub fn remove(self: *AgentRegistry, agent_id: []const u8) void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        if (self.map.fetchRemove(agent_id)) |kv| {
            self.allocator.free(kv.key);
            self.freeInfo(kv.value);
        }
    }

    /// Return a snapshot of agent info with duped strings (caller-owned).
    /// Safe to use after the mutex is released — no borrowed pointers.
    pub fn get(self: *AgentRegistry, agent_id: []const u8, alloc: Allocator) ?AgentInfo {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        const info = self.map.get(agent_id) orelse return null;
        return AgentInfo{
            .tool = if (info.tool) |t| alloc.dupe(u8, t) catch null else null,
            .project = if (info.project) |p| alloc.dupe(u8, p) catch null else null,
            .session = if (info.session) |s| alloc.dupe(u8, s) catch null else null,
        };
    }

    pub fn freeInfo(self: *AgentRegistry, info: AgentInfo) void {
        if (info.tool) |t| self.allocator.free(t);
        if (info.project) |p| self.allocator.free(p);
        if (info.session) |s| self.allocator.free(s);
    }
};

// ---------------------------------------------------------------------------
// Channel Registry — per [[RFC-0003:C-A2A-REDUCTION]] (legacy group-chat surface)
// ---------------------------------------------------------------------------

pub const Channel = struct {
    name: []const u8,
    description: []const u8,
    members: std.StringHashMap(void),
    created_by: []const u8,
    created_at: i64,
};

pub const ChannelRegistry = struct {
    map: std.StringHashMap(Channel),
    mutex: std.Io.Mutex,
    allocator: Allocator,

    pub fn init(allocator: Allocator) ChannelRegistry {
        return .{
            .map = std.StringHashMap(Channel).init(allocator),
            .mutex = .init,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ChannelRegistry) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.freeChannelStrings(entry.key_ptr.*, entry.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn create(self: *ChannelRegistry, name: []const u8, description: []const u8, creator: []const u8) !void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
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
            .created_at = std.Io.Timestamp.now(io_mod.get(), .real).toSeconds(),
        });
        log.info("channel created: {s} by {s}", .{ name, creator });
    }

    pub fn addMember(self: *ChannelRegistry, name: []const u8, agent_id: []const u8) !void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        const ch = self.map.getPtr(name) orelse return error.ChannelNotFound;
        const owned_id = try self.allocator.dupe(u8, agent_id);
        errdefer self.allocator.free(owned_id);
        try ch.members.put(owned_id, {});
    }

    pub fn removeMember(self: *ChannelRegistry, name: []const u8, agent_id: []const u8) !void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
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
    pub fn freeChannelStrings(self: *ChannelRegistry, key: []const u8, ch: Channel) void {
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

    pub fn isMember(self: *ChannelRegistry, name: []const u8, agent_id: []const u8) bool {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        const ch = self.map.get(name) orelse return false;
        return ch.members.contains(agent_id);
    }

    /// Return duped member ID strings. Caller owns both slice and each string.
    pub fn getMembers(self: *ChannelRegistry, name: []const u8, allocator: Allocator) ![][]const u8 {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
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
    pub fn removeFromAll(self: *ChannelRegistry, agent_id: []const u8, allocator: Allocator) ![][]const u8 {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
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
    pub fn channelsFor(self: *ChannelRegistry, agent_id: []const u8, allocator: Allocator) ![][]const u8 {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
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
// Message Log — per [[RFC-0003]] (hub state)
// ---------------------------------------------------------------------------

pub const LogEntry = struct {
    from: []const u8,
    to: []const u8,
    channel: ?[]const u8,
    text: []const u8,
    ts: i64,
};

pub const MessageLog = struct {
    entries: std.ArrayList(LogEntry),
    mutex: std.Io.Mutex,
    max_entries: usize,

    pub fn init(max_entries: usize) MessageLog {
        return .{
            .entries = std.ArrayList(LogEntry).empty,
            .mutex = .init,
            .max_entries = max_entries,
        };
    }

    pub fn deinit(self: *MessageLog, allocator: Allocator) void {
        for (self.entries.items) |entry| {
            freeLogEntry(allocator, entry);
        }
        self.entries.deinit(allocator);
    }

    pub fn freeLogEntry(allocator: Allocator, entry: LogEntry) void {
        allocator.free(entry.from);
        allocator.free(entry.to);
        if (entry.channel) |ch| allocator.free(ch);
        allocator.free(entry.text);
    }

    /// Append a log entry, duping all strings so the entry outlives the caller's arena.
    pub fn append(self: *MessageLog, allocator: Allocator, entry: LogEntry) !void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
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
// Activity Log — RFC-0003 C-HUB-ROLE: tool-request activity stream
// (replaces the chat-history role of MessageLog; MessageLog stays for
// the deprecated dm compat surface)
// ---------------------------------------------------------------------------

pub const ActivityEntry = struct {
    ts: i64,
    /// Requesting agent id (real agents; cli-tmp-* for one-shot tools).
    agent: []const u8,
    /// Tool name, e.g. "task.claim".
    tool: []const u8,
    /// Short human-readable detail, e.g. "claim #12".
    detail: []const u8,
};

pub const ActivityLog = struct {
    entries: std.ArrayList(ActivityEntry),
    mutex: std.Io.Mutex,
    max_entries: usize,

    pub fn init(max_entries: usize) ActivityLog {
        return .{
            .entries = std.ArrayList(ActivityEntry).empty,
            .mutex = .init,
            .max_entries = max_entries,
        };
    }

    pub fn deinit(self: *ActivityLog, allocator: Allocator) void {
        for (self.entries.items) |entry| {
            allocator.free(entry.agent);
            allocator.free(entry.tool);
            allocator.free(entry.detail);
        }
        self.entries.deinit(allocator);
    }

    /// Append an entry, duping strings into `allocator` (caller picks the
    /// long-lived allocator, e.g. HubState.allocator).
    pub fn append(self: *ActivityLog, allocator: Allocator, entry: ActivityEntry) !void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        const owned = ActivityEntry{
            .ts = entry.ts,
            .agent = try allocator.dupe(u8, entry.agent),
            .tool = try allocator.dupe(u8, entry.tool),
            .detail = try allocator.dupe(u8, entry.detail),
        };
        try self.entries.append(allocator, owned);
        if (self.entries.items.len > self.max_entries) {
            const evicted = self.entries.orderedRemove(0);
            allocator.free(evicted.agent);
            allocator.free(evicted.tool);
            allocator.free(evicted.detail);
        }
    }

    /// Copy the newest `limit` entries as JSON (caller allocates via arena).
    /// agent/tool/detail are duped into `arena` while the mutex is still
    /// held: a concurrent append past max_entries evicts and FREES the
    /// log's own strings, so returning borrowed slices would leave the
    /// caller serializing freed memory (WI-2026-08-08-003).
    pub fn toJson(self: *ActivityLog, arena: Allocator, limit: usize) !json.Value {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        var arr = json.Array.init(arena);
        const start = if (self.entries.items.len > limit) self.entries.items.len - limit else 0;
        for (self.entries.items[start..]) |entry| {
            var obj = json.ObjectMap.empty;
            try obj.put(arena, "ts", .{ .integer = entry.ts });
            try obj.put(arena, "agent", .{ .string = try arena.dupe(u8, entry.agent) });
            try obj.put(arena, "tool", .{ .string = try arena.dupe(u8, entry.tool) });
            try obj.put(arena, "detail", .{ .string = try arena.dupe(u8, entry.detail) });
            try arr.append(.{ .object = obj });
        }
        return .{ .array = arr };
    }
};

// ---------------------------------------------------------------------------
// Hub State — combines all registries
// ---------------------------------------------------------------------------

pub const HubState = struct {
    routing_table: RoutingTable,
    agent_registry: AgentRegistry,
    channel_registry: ChannelRegistry,
    message_log: MessageLog,
    /// Tool-request activity stream (RFC-0003 C-HUB-ROLE).
    activity_log: ActivityLog,
    allocator: Allocator,
    /// All heap-allocated connections — freed in deinit after all threads join.
    /// Connections outlive their reader/writer threads to prevent use-after-free
    /// when a cross-agent enqueue races with disconnect cleanup.
    all_connections: std.ArrayList(*Connection),
    all_connections_mutex: std.Io.Mutex,

    pub fn init(allocator: Allocator) HubState {
        return .{
            .routing_table = RoutingTable.init(allocator),
            .agent_registry = AgentRegistry.init(allocator),
            .channel_registry = ChannelRegistry.init(allocator),
            .message_log = MessageLog.init(10_000),
            .activity_log = ActivityLog.init(500),
            .allocator = allocator,
            .all_connections = std.ArrayList(*Connection).empty,
            .all_connections_mutex = .init,
        };
    }

    pub fn deinit(self: *HubState) void {
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
        self.activity_log.deinit(self.allocator);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "RoutingTable register and lookup" {
    var rt = RoutingTable.init(std.testing.allocator);
    defer rt.deinit();

    try std.testing.expect(rt.lookup("agent-a") == null);
}

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

test "ActivityLog toJson survives eviction after snapshot (WI-2026-08-08-003)" {
    // Regression: toJson must dupe into the caller's arena while holding
    // the mutex; a later append past max_entries evicts (frees) the log's
    // own strings, so the returned value must not borrow them.
    var al = ActivityLog.init(2);
    defer al.deinit(std.testing.allocator);

    try al.append(std.testing.allocator, .{ .ts = 1, .agent = "agent-a", .tool = "task.list", .detail = "list #1" });
    try al.append(std.testing.allocator, .{ .ts = 2, .agent = "agent-b", .tool = "task.claim", .detail = "claim #2" });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const snapshot = try al.toJson(arena, 50);

    // Evict both entries that the snapshot borrowed from.
    try al.append(std.testing.allocator, .{ .ts = 3, .agent = "agent-c", .tool = "task.update", .detail = "update #3" });
    try al.append(std.testing.allocator, .{ .ts = 4, .agent = "agent-d", .tool = "task.comment", .detail = "comment #4" });

    // Serialize the snapshot AFTER the eviction — must still be valid and
    // complete (would be a use-after-free with the borrowed-slice version).
    const text = try json.Stringify.valueAlloc(arena, snapshot, .{});

    try std.testing.expect(mem.indexOf(u8, text, "claim #2") != null);
    try std.testing.expect(mem.indexOf(u8, text, "list #1") != null);
    try std.testing.expect(mem.indexOf(u8, text, "agent-a") != null);
    try std.testing.expect(mem.indexOf(u8, text, "agent-b") != null);
    // The snapshot predates entries 3-4: they must not appear.
    try std.testing.expect(mem.indexOf(u8, text, "comment #4") == null);
    try std.testing.expect(mem.indexOf(u8, text, "update #3") == null);
}

test "RoutingTable duplicate registration replaces old connection (WI-2026-08-08-016)" {
    var table = RoutingTable.init(std.testing.allocator);
    defer table.deinit();

    // Two distinct connection objects on real fds so closeStream is exercised.
    const fd1 = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    const fd2 = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn1 = Connection.init(std.testing.allocator, fd1, @ptrCast(&dummy), noopRelease);
    var conn2 = Connection.init(std.testing.allocator, fd2, @ptrCast(&dummy), noopRelease);
    defer conn1.deinit();
    defer conn2.deinit();

    try table.register("agent-a", &conn1);
    try std.testing.expect(table.lookup("agent-a") == &conn1);

    // Duplicate: new connection replaces the old one and closes its stream.
    try table.register("agent-a", &conn2);
    try std.testing.expect(table.lookup("agent-a") == &conn2);
    try std.testing.expect(conn1.fd_closed);

    // The old reader's cleanup is a no-op: the entry belongs to conn2.
    try std.testing.expect(!table.unregisterIfOwned("agent-a", &conn1));
    try std.testing.expect(table.lookup("agent-a") == &conn2);

    // The owner's cleanup removes the entry.
    try std.testing.expect(table.unregisterIfOwned("agent-a", &conn2));
    try std.testing.expect(table.lookup("agent-a") == null);
}

fn noopRelease(_: *anyopaque, _: *Connection) void {}
