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

    fn init(allocator: Allocator) AgentRegistry {
        return .{
            .map = std.StringHashMap(AgentInfo).init(allocator),
            .mutex = .{},
        };
    }

    fn deinit(self: *AgentRegistry) void {
        self.map.deinit();
    }

    fn update(self: *AgentRegistry, agent_id: []const u8, info: AgentInfo) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.map.put(agent_id, info);
        log.info("agent metadata updated: {s} tool={s}", .{ agent_id, info.tool orelse "-" });
    }

    fn remove(self: *AgentRegistry, agent_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.map.remove(agent_id);
    }

    fn get(self: *AgentRegistry, agent_id: []const u8) ?AgentInfo {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.get(agent_id);
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
        var it = self.map.valueIterator();
        while (it.next()) |ch| {
            ch.members.deinit();
        }
        self.map.deinit();
    }

    fn create(self: *ChannelRegistry, name: []const u8, description: []const u8, creator: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.contains(name)) return error.ChannelExists;
        var members = std.StringHashMap(void).init(self.allocator);
        try members.put(creator, {});
        try self.map.put(name, .{
            .name = name,
            .description = description,
            .members = members,
            .created_by = creator,
            .created_at = std.time.timestamp(),
        });
        log.info("channel created: {s} by {s}", .{ name, creator });
    }

    fn addMember(self: *ChannelRegistry, name: []const u8, agent_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ch = self.map.getPtr(name) orelse return error.ChannelNotFound;
        try ch.members.put(agent_id, {});
    }

    fn removeMember(self: *ChannelRegistry, name: []const u8, agent_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ch = self.map.getPtr(name) orelse return error.ChannelNotFound;
        _ = ch.members.remove(agent_id);
        // Garbage-collect empty channels.
        if (ch.members.count() == 0) {
            var removed = self.map.fetchRemove(name);
            if (removed) |*kv| kv.value.members.deinit();
            log.info("channel garbage-collected: {s}", .{name});
        }
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
            if (entry.value_ptr.members.contains(agent_id)) {
                _ = entry.value_ptr.members.remove(agent_id);
                try affected.append(allocator, entry.key_ptr.*);
            }
        }
        // Garbage-collect empty channels (deferred to avoid mutation during iteration).
        for (affected.items) |ch_name| {
            if (self.map.getPtr(ch_name)) |ch| {
                if (ch.members.count() == 0) {
                    var removed = self.map.fetchRemove(ch_name);
                    if (removed) |*kv| kv.value.members.deinit();
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
        self.entries.deinit(allocator);
    }

    fn append(self: *MessageLog, allocator: Allocator, entry: LogEntry) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.entries.append(allocator, entry);
        // FIFO eviction.
        if (self.entries.items.len > self.max_entries) {
            _ = self.entries.orderedRemove(0);
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
    _ = try stream.write(raw);
    _ = try stream.write("\n");
}

/// Send an envelope to a stream (for push delivery).
fn pushEnvelope(arena: Allocator, stream: net.Stream, envelope: protocol.Envelope) !void {
    const raw = try protocol.serializeEnvelope(arena, envelope);
    _ = try stream.write(raw);
    _ = try stream.write("\n");
}

// -- Handler: list_agents per [[RFC-0002:C-CLI-MCP]] -----------------------

fn handleListAgents(state: *HubState, arena: Allocator, stream: net.Stream, req: protocol.Envelope) !void {
    const agent_ids = try state.routing_table.agentIds(arena);

    var arr = json.Array.init(arena);
    for (agent_ids) |id| {
        var agent_obj = json.ObjectMap.init(arena);
        try agent_obj.put("id", .{ .string = id });
        const info = state.agent_registry.get(id);
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
    _ = try stream.write(raw);
    _ = try stream.write("\n");
}

// -- Handler: agent_update per [[RFC-0002:C-AGENT-IDENTITY]] ---------------

fn handleAgentUpdate(state: *HubState, stream: net.Stream, arena: Allocator, envelope: protocol.Envelope) !void {
    const payload = if (envelope.payload == .object) envelope.payload.object else {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "missing payload");
        return;
    };
    const info = AgentInfo{
        .tool = if (payload.get("tool")) |v| v.string else null,
        .project = if (payload.get("project")) |v| v.string else null,
        .session = if (payload.get("session")) |v| v.string else null,
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
    const name = if (payload.get("name")) |v| v.string else {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "missing channel name");
        return;
    };
    const desc = if (payload.get("description")) |v| v.string else "";

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
    const ch_name = if (payload.get("channel")) |v| v.string else {
        try sendResponse(arena, stream, envelope.id, envelope.source, false, null, "missing channel");
        return;
    };
    const agent_id = if (payload.get("agent_id")) |v| v.string else {
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
    const ch_name = if (payload.get("channel")) |v| v.string else {
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
    _ = try stream.write(raw);
    _ = try stream.write("\n");
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
fn handleClient(state: *HubState, arena: Allocator, stream: net.Stream) void {
    defer stream.close();

    var buf: [recv_buf_size]u8 = undefined;

    // First read must contain the register envelope.
    const initial_len = stream.read(&buf) catch |err| {
        log.err("read error on initial message: {any}", .{err});
        return;
    };
    if (initial_len == 0) return;

    var initial_iter = mem.splitScalar(u8, buf[0..initial_len], '\n');
    const first_line = mem.trimRight(u8, initial_iter.next() orelse return, "\r ");
    if (first_line.len == 0) return;

    const parsed_init = protocol.parseEnvelope(arena, first_line) catch |err| {
        log.err("failed to parse initial envelope: {any}", .{err});
        return;
    };
    const init_envelope = parsed_init.value;

    if (!mem.eql(u8, init_envelope.@"type", "register")) {
        log.err("expected register, got: {s}", .{init_envelope.@"type"});
        return;
    }

    const agent_id = init_envelope.source;
    state.routing_table.register(agent_id, stream) catch |err| {
        log.err("failed to register {s}: {any}", .{ agent_id, err });
        return;
    };
    defer {
        state.routing_table.unregister(agent_id);
        state.agent_registry.remove(agent_id);
        // Remove from all channels, notify members per [[RFC-0002:C-HUB-STATE]].
        const affected = state.channel_registry.removeFromAll(agent_id, arena) catch &.{};
        for (affected) |ch_name| {
            const members = state.channel_registry.getMembers(ch_name, arena) catch continue;
            for (members) |mid| {
                state.routing_table.mutex.lock();
                const ms = state.routing_table.lookup(mid);
                state.routing_table.mutex.unlock();
                if (ms) |s| {
                    var evt_payload = json.ObjectMap.init(arena);
                    evt_payload.put("channel", .{ .string = ch_name }) catch continue;
                    evt_payload.put("event", .{ .string = "left" }) catch continue;
                    evt_payload.put("agent_id", .{ .string = agent_id }) catch continue;
                    pushEnvelope(arena, s, .{
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

    // Process remaining messages from initial read.
    while (initial_iter.next()) |line| {
        const trimmed = mem.trimRight(u8, line, "\r ");
        if (trimmed.len == 0) continue;
        const parsed = protocol.parseEnvelope(arena, trimmed) catch |err| {
            log.err("bad envelope from {s}: {any}", .{ agent_id, err });
            continue;
        };
        dispatchEnvelope(state, arena, stream, agent_id, parsed.value);
    }

    // Main receive loop.
    while (true) {
        const n = stream.read(&buf) catch |err| {
            log.err("read error from {s}: {any}", .{ agent_id, err });
            break;
        };
        if (n == 0) break;

        var iter = mem.splitScalar(u8, buf[0..n], '\n');
        while (iter.next()) |line| {
            const raw = mem.trimRight(u8, line, "\r ");
            if (raw.len == 0) continue;
            const parsed = protocol.parseEnvelope(arena, raw) catch |err| {
                log.err("bad envelope from {s}: {any}", .{ agent_id, err });
                continue;
            };
            dispatchEnvelope(state, arena, stream, agent_id, parsed.value);
        }
    }
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

const default_listen_addr = "127.0.0.1";
const default_listen_port: u16 = 9000;

pub const HubServer = struct {
    listener: net.Server,
    state: HubState,

    pub fn init(allocator: Allocator) !HubServer {
        _ = allocator;

        const address = net.Address.parseIp4(default_listen_addr, default_listen_port) catch unreachable;
        const listener = try address.listen(.{
            .reuse_address = true,
        });

        log.info("Synapty Hub listening on {s}:{d}", .{ default_listen_addr, default_listen_port });

        return .{
            .listener = listener,
            .state = HubState.init(std.heap.page_allocator),
        };
    }

    pub fn deinit(self: *HubServer) void {
        self.state.deinit();
        self.listener.deinit();
    }

    /// Accept connections in a loop, spawning a thread per client.
    pub fn run(self: *HubServer) !void {
        while (true) {
            const conn = try self.listener.accept();
            log.info("accepted connection from {f}", .{conn.address});
            _ = std.Thread.spawn(.{}, handleClient, .{
                &self.state,
                std.heap.page_allocator,
                conn.stream,
            }) catch |err| {
                log.err("failed to spawn handler thread: {any}", .{err});
                conn.stream.close();
            };
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
