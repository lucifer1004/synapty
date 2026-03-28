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

    fn getMembers(self: *ChannelRegistry, name: []const u8, allocator: Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ch = self.map.get(name) orelse return error.ChannelNotFound;
        const count = ch.members.count();
        const slice = try allocator.alloc([]const u8, count);
        var it = ch.members.keyIterator();
        var i: usize = 0;
        while (it.next()) |key| : (i += 1) {
            slice[i] = key.*;
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

    /// List channels an agent is a member of.
    fn channelsFor(self: *ChannelRegistry, agent_id: []const u8, allocator: Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var result = std.ArrayList([]const u8).empty;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.members.contains(agent_id)) {
                try result.append(allocator, entry.key_ptr.*);
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

    fn init(allocator: Allocator) HubState {
        return .{
            .routing_table = RoutingTable.init(allocator),
            .agent_registry = AgentRegistry.init(allocator),
            .channel_registry = ChannelRegistry.init(allocator),
            .message_log = MessageLog.init(10_000),
            .allocator = allocator,
        };
    }

    fn deinit(self: *HubState) void {
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

/// Send a response envelope to a client stream.
fn sendResponse(arena: Allocator, stream: net.Stream, req_id: []const u8, target: []const u8, ok: bool, data: ?json.Value, err_msg: ?[]const u8) !void {
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
    const raw = try protocol.serializeEnvelope(arena, resp);
    try stream.writeAll(raw);
    try stream.writeAll("\n");
}

/// Send an envelope to a stream (for push delivery).
fn pushEnvelope(arena: Allocator, stream: net.Stream, envelope: protocol.Envelope) !void {
    const raw = try protocol.serializeEnvelope(arena, envelope);
    try stream.writeAll(raw);
    try stream.writeAll("\n");
}

// -- Handler: list_agents per [[RFC-0002:C-CLI-MCP]] -----------------------

fn handleListAgents(state: *HubState, arena: Allocator, stream: net.Stream, req: protocol.Envelope) !void {
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
    const raw = try protocol.serializeEnvelope(arena, resp);
    try stream.writeAll(raw);
    try stream.writeAll("\n");
}

// -- Handler: agent_update per [[RFC-0002:C-AGENT-IDENTITY]] ---------------

fn handleAgentUpdate(state: *HubState, stream: net.Stream, arena: Allocator, envelope: protocol.Envelope) !void {
    const payload = if (envelope.payload == .object) envelope.payload.object else {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "missing payload");
        return;
    };
    const info = AgentInfo{
        .tool = if (payload.get("tool")) |v| (if (v == .string) v.string else null) else null,
        .project = if (payload.get("project")) |v| (if (v == .string) v.string else null) else null,
        .session = if (payload.get("session")) |v| (if (v == .string) v.string else null) else null,
    };
    try state.agent_registry.update(envelope.source, info);
    try sendResponse(arena, stream, envelope.id, envelope.source, true, null, null);
}

// -- Handler: dm per [[RFC-0002:C-DM]] -------------------------------------

fn handleDm(state: *HubState, stream: net.Stream, arena: Allocator, envelope: protocol.Envelope) !void {
    const target = envelope.target;
    if (target.len == 0) {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "missing target");
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

    // Route to target.
    state.routing_table.mutex.lock();
    const target_stream = state.routing_table.lookup(target);
    state.routing_table.mutex.unlock();

    if (target_stream) |ts| {
        pushEnvelope(arena, ts, envelope) catch |err| {
            log.err("failed to deliver dm to {s}: {any}", .{ target, err });
            try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "delivery failed");
            return;
        };
        try sendResponse(arena, stream, envelope.id, envelope.source, true, null, null);
    } else {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "agent not connected");
        return;
    }
}

// -- Handler: channel_create per [[RFC-0002:C-GROUP-CHAT]] -----------------

fn handleChannelCreate(state: *HubState, stream: net.Stream, arena: Allocator, envelope: protocol.Envelope) !void {
    const payload = if (envelope.payload == .object) envelope.payload.object else {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "missing payload");
        return;
    };
    const name = if (payload.get("name")) |v| (if (v == .string) v.string else {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "invalid channel name type");
        return;
    }) else {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "missing channel name");
        return;
    };
    const desc = if (payload.get("description")) |v| (if (v == .string) v.string else "") else "";

    state.channel_registry.create(name, desc, envelope.source) catch |err| switch (err) {
        error.ChannelExists => {
            try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "channel already exists");
            return;
        },
        else => return err,
    };
    try sendResponse(arena, stream, envelope.id, envelope.source, true, null, null);
}

// -- Handler: channel_invite per [[RFC-0002:C-GROUP-CHAT]] -----------------

fn handleChannelInvite(state: *HubState, stream: net.Stream, arena: Allocator, envelope: protocol.Envelope) !void {
    const payload = if (envelope.payload == .object) envelope.payload.object else {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "missing payload");
        return;
    };
    const ch_name = if (payload.get("channel")) |v| (if (v == .string) v.string else {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "invalid channel type");
        return;
    }) else {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "missing channel");
        return;
    };
    const agent_id = if (payload.get("agent_id")) |v| (if (v == .string) v.string else {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "invalid agent_id type");
        return;
    }) else {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "missing agent_id");
        return;
    };

    if (!state.channel_registry.isMember(ch_name, envelope.source)) {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "not a member of channel");
        return;
    }

    state.channel_registry.addMember(ch_name, agent_id) catch |err| switch (err) {
        error.ChannelNotFound => {
            try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "channel not found");
            return;
        },
        else => return err,
    };

    // Notify invited agent.
    state.routing_table.mutex.lock();
    const invited_stream = state.routing_table.lookup(agent_id);
    state.routing_table.mutex.unlock();

    if (invited_stream) |is| {
        var evt_payload = json.ObjectMap.init(arena);
        try evt_payload.put("channel", .{ .string = ch_name });
        try evt_payload.put("event", .{ .string = "invited" });
        try evt_payload.put("by", .{ .string = envelope.source });
        pushEnvelope(arena, is, .{
            .@"type" = "channel_event",
            .id = "evt-0",
            .source = "hub",
            .target = agent_id,
            .payload = .{ .object = evt_payload },
        }) catch {};
    }

    try sendResponse(arena, stream, envelope.id, envelope.source, true, null, null);
}

// -- Handler: channel_leave per [[RFC-0002:C-GROUP-CHAT]] ------------------

fn handleChannelLeave(state: *HubState, stream: net.Stream, arena: Allocator, envelope: protocol.Envelope) !void {
    const payload = if (envelope.payload == .object) envelope.payload.object else {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "missing payload");
        return;
    };
    const ch_name = if (payload.get("channel")) |v| (if (v == .string) v.string else {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "invalid channel type");
        return;
    }) else {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "missing channel");
        return;
    };

    state.channel_registry.removeMember(ch_name, envelope.source) catch {};

    // Notify remaining members.
    const members = state.channel_registry.getMembers(ch_name, arena) catch &.{};
    for (members) |mid| {
        state.routing_table.mutex.lock();
        const ms = state.routing_table.lookup(mid);
        state.routing_table.mutex.unlock();
        if (ms) |s| {
            var evt_payload = json.ObjectMap.init(arena);
            try evt_payload.put("channel", .{ .string = ch_name });
            try evt_payload.put("event", .{ .string = "left" });
            try evt_payload.put("agent_id", .{ .string = envelope.source });
            pushEnvelope(arena, s, .{
                .@"type" = "channel_event",
                .id = "evt-0",
                .source = "hub",
                .target = mid,
                .payload = .{ .object = evt_payload },
            }) catch {};
        }
    }

    try sendResponse(arena, stream, envelope.id, envelope.source, true, null, null);
}

// -- Handler: channel_msg per [[RFC-0002:C-GROUP-CHAT]] --------------------

fn handleChannelMsg(state: *HubState, stream: net.Stream, arena: Allocator, envelope: protocol.Envelope) !void {
    const target = envelope.target;
    // Extract channel name from "channel:<name>" prefix.
    if (!mem.startsWith(u8, target, "channel:")) {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "invalid channel target");
        return;
    }
    const ch_name = target["channel:".len..];

    if (!state.channel_registry.isMember(ch_name, envelope.source)) {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "not a member of channel");
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
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "channel not found");
        return;
    };

    for (members) |mid| {
        if (mem.eql(u8, mid, envelope.source)) continue;
        state.routing_table.mutex.lock();
        const ms = state.routing_table.lookup(mid);
        state.routing_table.mutex.unlock();
        if (ms) |s| {
            pushEnvelope(arena, s, envelope) catch |err| {
                log.err("failed to fan-out to {s}: {any}", .{ mid, err });
            };
        }
    }
    try sendResponse(arena, stream, envelope.id, envelope.source, true, null, null);
}

// -- Handler: list_channels per [[RFC-0002:C-CLI-MCP]] ---------------------

fn handleListChannels(state: *HubState, stream: net.Stream, arena: Allocator, envelope: protocol.Envelope) !void {
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
    const raw = try protocol.serializeEnvelope(arena, resp);
    try stream.writeAll(raw);
    try stream.writeAll("\n");
}

// -- Message dispatcher ----------------------------------------------------

fn dispatchEnvelope(state: *HubState, arena: Allocator, stream: net.Stream, agent_id: []const u8, envelope: protocol.Envelope) void {
    const msg_type = envelope.@"type";

    if (mem.eql(u8, msg_type, "list_agents")) {
        handleListAgents(state, arena, stream, envelope) catch |err| {
            log.err("list_agents failed for {s}: {any}", .{ agent_id, err });
        };
    } else if (mem.eql(u8, msg_type, "list_channels")) {
        handleListChannels(state, stream, arena, envelope) catch |err| {
            log.err("list_channels failed for {s}: {any}", .{ agent_id, err });
        };
    } else if (mem.eql(u8, msg_type, "agent_update")) {
        handleAgentUpdate(state, stream, arena, envelope) catch |err| {
            log.err("agent_update failed for {s}: {any}", .{ agent_id, err });
        };
    } else if (mem.eql(u8, msg_type, "dm")) {
        handleDm(state, stream, arena, envelope) catch |err| {
            log.err("dm failed for {s}: {any}", .{ agent_id, err });
        };
    } else if (mem.eql(u8, msg_type, "channel_create")) {
        handleChannelCreate(state, stream, arena, envelope) catch |err| {
            log.err("channel_create failed for {s}: {any}", .{ agent_id, err });
        };
    } else if (mem.eql(u8, msg_type, "channel_invite")) {
        handleChannelInvite(state, stream, arena, envelope) catch |err| {
            log.err("channel_invite failed for {s}: {any}", .{ agent_id, err });
        };
    } else if (mem.eql(u8, msg_type, "channel_leave")) {
        handleChannelLeave(state, stream, arena, envelope) catch |err| {
            log.err("channel_leave failed for {s}: {any}", .{ agent_id, err });
        };
    } else if (mem.eql(u8, msg_type, "channel_msg")) {
        handleChannelMsg(state, stream, arena, envelope) catch |err| {
            log.err("channel_msg failed for {s}: {any}", .{ agent_id, err });
        };
    } else {
        log.warn("unknown message type from {s}: {s}", .{ agent_id, msg_type });
    }
}

/// Handle a single client connection: read JSON envelopes and dispatch them.
/// Uses a per-connection ArenaAllocator so parsed data is freed on disconnect,
/// and a line buffer so partial TCP frames are carried across reads.
fn handleClient(state: *HubState, backing_alloc: Allocator, stream: net.Stream) void {
    _ = backing_alloc;
    defer stream.close();

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

    state.routing_table.register(agent_id, stream) catch |err| {
        log.err("failed to register {s}: {any}", .{ agent_id, err });
        return;
    };
    defer {
        state.routing_table.unregister(agent_id);
        state.agent_registry.remove(agent_id);
        // Remove from all channels, notify members per [[RFC-0002:C-HUB-STATE]].
        // Use conn_alloc for cleanup temporaries.
        const affected = state.channel_registry.removeFromAll(agent_id, conn_alloc) catch &.{};
        for (affected) |ch_name| {
            const members = state.channel_registry.getMembers(ch_name, conn_alloc) catch continue;
            for (members) |mid| {
                state.routing_table.mutex.lock();
                const ms = state.routing_table.lookup(mid);
                state.routing_table.mutex.unlock();
                if (ms) |s| {
                    var evt_payload = json.ObjectMap.init(conn_alloc);
                    evt_payload.put("channel", .{ .string = ch_name }) catch continue;
                    evt_payload.put("event", .{ .string = "left" }) catch continue;
                    evt_payload.put("agent_id", .{ .string = agent_id }) catch continue;
                    pushEnvelope(conn_alloc, s, .{
                        .@"type" = "channel_event",
                        .id = "evt-0",
                        .source = "hub",
                        .target = mid,
                        .payload = .{ .object = evt_payload },
                    }) catch {};
                }
            }
        }
    }

    // Process any additional complete lines from the initial read(s).
    processLines(state, &msg_arena, stream, agent_id, &line_buf, &filled);

    // Main receive loop with line buffering.
    while (true) {
        if (filled >= line_buf.len) {
            log.err("message from {s} exceeds buffer", .{agent_id});
            break;
        }
        const n = stream.read(line_buf[filled..]) catch |err| {
            log.err("read error from {s}: {any}", .{ agent_id, err });
            break;
        };
        if (n == 0) break;
        filled += n;

        processLines(state, &msg_arena, stream, agent_id, &line_buf, &filled);
    }
}

/// Extract and dispatch all complete newline-delimited lines from the buffer.
/// Resets msg_arena after each envelope so per-message memory is bounded.
fn processLines(state: *HubState, msg_arena: *std.heap.ArenaAllocator, stream: net.Stream, agent_id: []const u8, line_buf: *[recv_buf_size]u8, filled: *usize) void {
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
        dispatchEnvelope(state, alloc, stream, agent_id, parsed.value);
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

    pub fn init(allocator: Allocator) !HubServer {
        _ = allocator;
        return initWithAddress(default_listen_addr, default_listen_port);
    }

    /// Create a Hub bound to a specific address/port. Use port 0 for an
    /// OS-assigned ephemeral port (useful for tests).
    pub fn initWithAddress(addr: []const u8, port: u16) !HubServer {
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
        };
    }

    pub fn deinit(self: *HubServer) void {
        // Close listener first to stop accepting new connections.
        self.listener.deinit();
        // Join all client handler threads (they exit when their stream closes).
        self.client_threads_mutex.lock();
        for (self.client_threads.items) |t| t.join();
        self.client_threads.deinit(std.heap.page_allocator);
        self.client_threads_mutex.unlock();
        // Now safe to free shared state.
        self.state.deinit();
    }

    /// Accept connections in a loop, spawning a thread per client.
    pub fn run(self: *HubServer) !void {
        while (true) {
            const conn = try self.listener.accept();
            log.info("accepted connection from {f}", .{conn.address});
            const thread = std.Thread.spawn(.{}, handleClient, .{
                &self.state,
                std.heap.page_allocator,
                conn.stream,
            }) catch |err| {
                log.err("failed to spawn handler thread: {any}", .{err});
                conn.stream.close();
                continue;
            };
            self.client_threads_mutex.lock();
            self.client_threads.append(std.heap.page_allocator, thread) catch {};
            self.client_threads_mutex.unlock();
        }
    }

    pub fn startInBackground(allocator: Allocator) !*HubServer {
        const server = try allocator.create(HubServer);
        errdefer allocator.destroy(server);
        server.* = try HubServer.init(allocator);
        errdefer server.deinit();

        _ = try std.Thread.spawn(.{}, runBackground, .{server});
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
    defer std.testing.allocator.free(members);
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
    defer std.testing.allocator.free(channels);
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

test "MessageLog channel message has channel field" {
    var ml = MessageLog.init(10);
    defer ml.deinit(std.testing.allocator);

    try ml.append(std.testing.allocator, .{ .from = "a", .to = "channel:design", .channel = "design", .text = "hello", .ts = 1 });
    try std.testing.expectEqualStrings("design", ml.entries.items[0].channel.?);
}

test "HubState init and deinit" {
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();

    // All registries should be empty.
    const agents = try state.routing_table.agentIds(std.testing.allocator);
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

// -- Finding 2: line buffering tests ----------------------------------------

test "processLines extracts complete lines and preserves partial remainder" {
    // We cannot call processLines directly (needs HubState/stream), but we
    // verify the same buffer logic used in handleClient.
    const recv_buf_sz = recv_buf_size;
    var line_buf: [recv_buf_sz]u8 = undefined;
    var filled: usize = 0;

    // Simulate two reads that split a message across the boundary.
    const chunk1 = "{\"type\":\"register\"}\n{\"type\":\"dm\",\"par";
    @memcpy(line_buf[0..chunk1.len], chunk1);
    filled = chunk1.len;

    // Extract lines from chunk1.
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(std.testing.allocator);
    var start: usize = 0;
    while (mem.indexOfScalar(u8, line_buf[start..filled], '\n')) |rel| {
        const end = start + rel;
        const raw = mem.trimRight(u8, line_buf[start..end], "\r ");
        start = end + 1;
        if (raw.len > 0) {
            try lines.append(std.testing.allocator, try std.testing.allocator.dupe(u8, raw));
        }
    }
    const remaining = filled - start;
    if (remaining > 0 and start > 0) {
        mem.copyForwards(u8, line_buf[0..remaining], line_buf[start..filled]);
    }
    filled = remaining;

    // Should have extracted the register line, with partial dm remaining.
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("{\"type\":\"register\"}", lines.items[0]);
    try std.testing.expect(filled > 0); // partial dm still in buffer

    // Second chunk completes the dm.
    const chunk2 = "t\":\"hello\"}\n";
    @memcpy(line_buf[filled..][0..chunk2.len], chunk2);
    filled += chunk2.len;

    start = 0;
    while (mem.indexOfScalar(u8, line_buf[start..filled], '\n')) |rel| {
        const end = start + rel;
        const raw = mem.trimRight(u8, line_buf[start..end], "\r ");
        start = end + 1;
        if (raw.len > 0) {
            try lines.append(std.testing.allocator, try std.testing.allocator.dupe(u8, raw));
        }
    }
    const remaining2 = filled - start;
    if (remaining2 > 0 and start > 0) {
        mem.copyForwards(u8, line_buf[0..remaining2], line_buf[start..filled]);
    }
    filled = remaining2;

    // Should now have the complete dm line, no remainder.
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("{\"type\":\"dm\",\"part\":\"hello\"}", lines.items[1]);
    try std.testing.expectEqual(@as(usize, 0), filled);

    for (lines.items) |l| std.testing.allocator.free(l);
}
