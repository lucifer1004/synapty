const std = @import("std");
const io_mod = @import("io");
const mem = std.mem;
const json = std.json;
const protocol = @import("protocol");
const Allocator = mem.Allocator;
const Connection = @import("connection.zig").Connection;
const registry = @import("registry.zig");
const HubState = registry.HubState;
const AgentInfo = registry.AgentInfo;
const log = std.log.scoped(.hub);

// ---------------------------------------------------------------------------
// Response helper
// ---------------------------------------------------------------------------

/// Send a response envelope by enqueueing it into the sender's Connection.
pub fn sendResponse(arena: Allocator, conn: *Connection, req_id: []const u8, target: []const u8, ok: bool, data: ?json.Value, err_msg: ?[]const u8) !void {
    var payload_obj = json.ObjectMap.empty;
    try payload_obj.put(arena, "ok", .{ .bool = ok });
    if (data) |d| try payload_obj.put(arena, "data", d);
    if (err_msg) |e| try payload_obj.put(arena, "error", .{ .string = e });

    const resp = protocol.Envelope{
        .@"type" = "response",
        .id = req_id,
        .source = "hub",
        .target = target,
        .payload = .{ .object = payload_obj },
    };
    try conn.enqueueEnvelope(arena, resp);
}

// ---------------------------------------------------------------------------
// Handler: list_agents per [[RFC-0002:C-CLI-MCP]]
// ---------------------------------------------------------------------------

pub fn handleListAgents(state: *HubState, arena: Allocator, conn: *Connection, req: protocol.Envelope) !void {
    const agent_ids = try state.routing_table.agentIds(arena);

    var arr = json.Array.init(arena);
    for (agent_ids) |id| {
        var agent_obj = json.ObjectMap.empty;
        try agent_obj.put(arena, "id", .{ .string = id });
        const info = state.agent_registry.get(id, arena);
        try agent_obj.put(arena, "tool", .{ .string = if (info) |i| i.tool orelse "-" else "-" });
        try agent_obj.put(arena, "project", .{ .string = if (info) |i| i.project orelse "-" else "-" });
        try agent_obj.put(arena, "session", .{ .string = if (info) |i| i.session orelse "-" else "-" });
        try arr.append(.{ .object = agent_obj });
    }

    var data_obj = json.ObjectMap.empty;
    try data_obj.put(arena, "ok", .{ .bool = true });
    try data_obj.put(arena, "agents", .{ .array = arr });

    const resp = protocol.Envelope{
        .@"type" = "response",
        .id = req.id,
        .source = "hub",
        .target = req.source,
        .payload = .{ .object = data_obj },
    };
    try conn.enqueueEnvelope(arena, resp);
}

// ---------------------------------------------------------------------------
// Handler: agent_update per [[RFC-0002:C-AGENT-IDENTITY]]
// ---------------------------------------------------------------------------

pub fn handleAgentUpdate(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
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

// ---------------------------------------------------------------------------
// Handler: dm per [[RFC-0002:C-DM]]
// ---------------------------------------------------------------------------

pub fn handleDm(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
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
        .ts = std.Io.Timestamp.now(io_mod.get(), .real).toSeconds(),
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

// ---------------------------------------------------------------------------
// Handler: channel_create per [[RFC-0002:C-GROUP-CHAT]]
// ---------------------------------------------------------------------------

pub fn handleChannelCreate(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
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

// ---------------------------------------------------------------------------
// Handler: channel_invite per [[RFC-0002:C-GROUP-CHAT]]
// ---------------------------------------------------------------------------

pub fn handleChannelInvite(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
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
        var evt_payload = json.ObjectMap.empty;
        try evt_payload.put(arena, "channel", .{ .string = ch_name });
        try evt_payload.put(arena, "event", .{ .string = "invited" });
        try evt_payload.put(arena, "by", .{ .string = envelope.source });
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

// ---------------------------------------------------------------------------
// Handler: channel_leave per [[RFC-0002:C-GROUP-CHAT]]
// ---------------------------------------------------------------------------

pub fn handleChannelLeave(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
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
            var evt_payload = json.ObjectMap.empty;
            try evt_payload.put(arena, "channel", .{ .string = ch_name });
            try evt_payload.put(arena, "event", .{ .string = "left" });
            try evt_payload.put(arena, "agent_id", .{ .string = envelope.source });
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

// ---------------------------------------------------------------------------
// Handler: channel_msg per [[RFC-0002:C-GROUP-CHAT]]
// ---------------------------------------------------------------------------

pub fn handleChannelMsg(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
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
        .ts = std.Io.Timestamp.now(io_mod.get(), .real).toSeconds(),
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

// ---------------------------------------------------------------------------
// Handler: list_channels per [[RFC-0002:C-CLI-MCP]]
// ---------------------------------------------------------------------------

pub fn handleListChannels(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
    const channels = try state.channel_registry.channelsFor(envelope.source, arena);

    var arr = json.Array.init(arena);
    for (channels) |ch_name| {
        var ch_obj = json.ObjectMap.empty;
        try ch_obj.put(arena, "name", .{ .string = ch_name });
        try arr.append(.{ .object = ch_obj });
    }

    var data_obj = json.ObjectMap.empty;
    try data_obj.put(arena, "ok", .{ .bool = true });
    try data_obj.put(arena, "channels", .{ .array = arr });

    const resp = protocol.Envelope{
        .@"type" = "response",
        .id = envelope.id,
        .source = "hub",
        .target = envelope.source,
        .payload = .{ .object = data_obj },
    };
    try conn.enqueueEnvelope(arena, resp);
}

// ---------------------------------------------------------------------------
// Message dispatcher
// ---------------------------------------------------------------------------

pub fn dispatchEnvelope(state: *HubState, arena: Allocator, conn: *Connection, agent_id: []const u8, envelope: protocol.Envelope) void {
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
    else if (mem.eql(u8, msg_type, "tool_request"))
        handleToolRequest(state, arena, conn, envelope)
    else {
        log.warn("unknown message type from {s}: {s}", .{ agent_id, msg_type });
        return;
    };

    result catch |err| {
        // IO errors during handler execution mean the client disconnected
        // while a response was being written — expected during concurrent
        // shutdown, not a bug.
        switch (err) {
            error.BrokenPipe, error.ConnectionResetByPeer, error.ConnectionClosed => {},
            else => log.warn("{s} handler failed for {s}: {any}", .{ msg_type, agent_id, err }),
        }
    };
}

/// Extract and dispatch all complete newline-delimited lines from the buffer.
/// Resets msg_arena after each envelope so per-message memory is bounded.
pub fn processLines(state: *HubState, msg_arena: *std.heap.ArenaAllocator, conn: *Connection, agent_id: []const u8, line_buf: *[recv_buf_size]u8, filled: *usize) void {
    var start: usize = 0;
    while (mem.indexOfScalar(u8, line_buf[start..filled.*], '\n')) |rel| {
        const end = start + rel;
        const raw = mem.trimEnd(u8, line_buf[start..end], "\r ");
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

/// Per-connection receive buffer size (64 KiB).
pub const recv_buf_size = 64 * 1024;

// ---------------------------------------------------------------------------
// Tool requests — RFC-0003 task tools executed on the login device
// ---------------------------------------------------------------------------

const github = @import("github");

/// Send a tool_response envelope.
fn sendToolResponse(arena: Allocator, conn: *Connection, req_id: []const u8, target: []const u8, ok: bool, data: ?json.Value, err_msg: ?[]const u8) !void {
    var payload_obj = json.ObjectMap.empty;
    try payload_obj.put(arena, "ok", .{ .bool = ok });
    if (data) |d| try payload_obj.put(arena, "data", d);
    if (err_msg) |e| try payload_obj.put(arena, "error", .{ .string = e });
    const resp = protocol.Envelope{
        .@"type" = "tool_response",
        .id = req_id,
        .source = "hub",
        .target = target,
        .payload = .{ .object = payload_obj },
    };
    try conn.enqueueEnvelope(arena, resp);
}

/// Extract a string field from a JSON object.
fn objGetString(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Shrink a GitHub issue JSON into the compact task shape.
fn compactIssue(arena: Allocator, issue: json.Value) !json.Value {
    var out = json.ObjectMap.empty;
    const obj = issue.object;
    if (obj.get("number")) |n| try out.put(arena, "number", n);
    if (objGetString(obj, "title")) |t| try out.put(arena, "title", .{ .string = t });
    if (objGetString(obj, "state")) |st| try out.put(arena, "state", .{ .string = st });
    if (objGetString(obj, "html_url")) |u| try out.put(arena, "url", .{ .string = u });

    // labels: string array of label names.
    if (obj.get("labels")) |labels| {
        var arr = json.Array.init(arena);
        switch (labels) {
            .array => |arr_val| for (arr_val.items) |item| {
                switch (item) {
                    .object => |lo| if (objGetString(lo, "name")) |name|
                        try arr.append(.{ .string = name }),
                    else => {},
                }
            },
            else => {},
        }
        try out.put(arena, "labels", .{ .array = arr });
    }

    // assignee: login string.
    if (obj.get("assignee")) |a| {
        switch (a) {
            .object => |ao| if (objGetString(ao, "login")) |login|
                try out.put(arena, "assignee", .{ .string = login }),
            else => {},
        }
    }
    return .{ .object = out };
}

/// Load config + token; returns null (with err_msg set) when not configured.
fn loadBridge(arena: Allocator, err_msg: *?[]const u8) ?github.Api {
    const config = github.Config.load(arena) catch {
        err_msg.* = "github not configured: run `synapty github login` on the login device";
        return null;
    } orelse {
        err_msg.* = "github not configured: run `synapty github login` on the login device";
        return null;
    };
    const account = std.fmt.allocPrint(arena, "{s}/{s}", .{ config.owner, config.repo }) catch {
        err_msg.* = "out of memory";
        return null;
    };
    const token = github.loadToken(arena, account) catch {
        err_msg.* = "github token unavailable in Keychain";
        return null;
    } orelse {
        err_msg.* = "github token not found: run `synapty github login`";
        return null;
    };
    return github.Api{ .allocator = arena, .owner = config.owner, .repo = config.repo, .token = token };
}

/// Replace state labels (s:*) on an issue with the given one.
fn updateStateLabels(arena: Allocator, api: *const github.Api, number: u32, new_state_label: []const u8, close: bool) ![]const u8 {
    // Fetch current issue to preserve non-state labels.
    const path = try std.fmt.allocPrint(arena, "/repos/{s}/{s}/issues/{d}", .{ api.owner, api.repo, number });
    defer arena.free(path);
    const body = try api.request(.GET, path, null);
    const parsed = try json.parseFromSlice(json.Value, arena, body, .{ .allocate = .alloc_always });
    const obj = parsed.value.object;

    var labels = std.ArrayList([]const u8).empty;
    if (obj.get("labels")) |labels_val| {
        switch (labels_val) {
            .array => |arr_val| for (arr_val.items) |item| {
                switch (item) {
                    .object => |lo| if (objGetString(lo, "name")) |name| {
                        if (!mem.startsWith(u8, name, "s:")) {
                            try labels.append(arena, name);
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
    try labels.append(arena, new_state_label);

    const state: ?[]const u8 = if (close) "closed" else "open";
    return api.updateIssue(number, state, labels.items, null);
}

/// task.list — compact issue list filtered by project/state.
fn handleTaskList(arena: Allocator, conn: *Connection, req_id: []const u8, source: []const u8, args: json.ObjectMap) !void {
    const labels = objGetString(args, "labels");
    const state = objGetString(args, "state") orelse "open";
    var err_msg: ?[]const u8 = null;
    const api = loadBridge(arena, &err_msg) orelse {
        try sendToolResponse(arena, conn, req_id, source, false, null, err_msg);
        return;
    };
    const body = api.listIssues(labels, state) catch {
        try sendToolResponse(arena, conn, req_id, source, false, null, "github api error");
        return;
    };
    const parsed = try json.parseFromSlice(json.Value, arena, body, .{ .allocate = .alloc_always });
    var out = json.Array.init(arena);
    switch (parsed.value) {
        .array => |arr_val| for (arr_val.items) |item| {
            try out.append(try compactIssue(arena, item));
        },
        else => {},
    }
    try sendToolResponse(arena, conn, req_id, source, true, .{ .array = out }, null);
}

/// task.claim — s:todo -> s:doing, self-assign.
fn handleTaskClaim(arena: Allocator, conn: *Connection, req_id: []const u8, source: []const u8, args: json.ObjectMap) !void {
    const number_val = args.get("number") orelse {
        try sendToolResponse(arena, conn, req_id, source, false, null, "missing number");
        return;
    };
    const number: u32 = switch (number_val) {
        .integer => |i| @intCast(i),
        .float => |f| @intCast(@as(i64, @intFromFloat(f))),
        else => {
            try sendToolResponse(arena, conn, req_id, source, false, null, "number must be an integer");
            return;
        },
    };
    var err_msg: ?[]const u8 = null;
    const api = loadBridge(arena, &err_msg) orelse {
        try sendToolResponse(arena, conn, req_id, source, false, null, err_msg);
        return;
    };
    const labels: []const []const u8 = &.{"s:doing"};
    const body = api.updateIssue(number, null, labels, source) catch {
        try sendToolResponse(arena, conn, req_id, source, false, null, "github api error (claim)");
        return;
    };
    const parsed = try json.parseFromSlice(json.Value, arena, body, .{ .allocate = .alloc_always });
    try sendToolResponse(arena, conn, req_id, source, true, try compactIssue(arena, parsed.value), null);
}

/// task.update — status transitions per C-ISSUE-STATES.
fn handleTaskUpdate(arena: Allocator, conn: *Connection, req_id: []const u8, source: []const u8, args: json.ObjectMap) !void {
    const number_val = args.get("number") orelse {
        try sendToolResponse(arena, conn, req_id, source, false, null, "missing number");
        return;
    };
    const number: u32 = switch (number_val) {
        .integer => |i| @intCast(i),
        else => {
            try sendToolResponse(arena, conn, req_id, source, false, null, "number must be an integer");
            return;
        },
    };
    const status = objGetString(args, "status") orelse {
        try sendToolResponse(arena, conn, req_id, source, false, null, "missing status (todo|doing|done)");
        return;
    };
    var err_msg: ?[]const u8 = null;
    const api = loadBridge(arena, &err_msg) orelse {
        try sendToolResponse(arena, conn, req_id, source, false, null, err_msg);
        return;
    };
    const label = if (mem.eql(u8, status, "doing"))
        "s:doing"
    else if (mem.eql(u8, status, "done"))
        "s:done"
    else
        "s:todo";
    const close = mem.eql(u8, status, "done");
    const body = updateStateLabels(arena, &api, number, label, close) catch {
        try sendToolResponse(arena, conn, req_id, source, false, null, "github api error (update)");
        return;
    };
    const parsed = try json.parseFromSlice(json.Value, arena, body, .{ .allocate = .alloc_always });
    try sendToolResponse(arena, conn, req_id, source, true, try compactIssue(arena, parsed.value), null);
}

/// task.comment — append a comment.
fn handleTaskComment(arena: Allocator, conn: *Connection, req_id: []const u8, source: []const u8, args: json.ObjectMap) !void {
    const number_val = args.get("number") orelse {
        try sendToolResponse(arena, conn, req_id, source, false, null, "missing number");
        return;
    };
    const number: u32 = switch (number_val) {
        .integer => |i| @intCast(i),
        else => {
            try sendToolResponse(arena, conn, req_id, source, false, null, "number must be an integer");
            return;
        },
    };
    const body_text = objGetString(args, "body") orelse {
        try sendToolResponse(arena, conn, req_id, source, false, null, "missing body");
        return;
    };
    var err_msg: ?[]const u8 = null;
    const api = loadBridge(arena, &err_msg) orelse {
        try sendToolResponse(arena, conn, req_id, source, false, null, err_msg);
        return;
    };
    const resp_body = api.addComment(number, body_text) catch {
        try sendToolResponse(arena, conn, req_id, source, false, null, "github api error (comment)");
        return;
    };
    const parsed = try json.parseFromSlice(json.Value, arena, resp_body, .{ .allocate = .alloc_always });
    const id: ?json.Value = if (parsed.value == .object) parsed.value.object.get("id") else null;
    try sendToolResponse(arena, conn, req_id, source, true, id, null);
}

/// task.create — file a new issue.
fn handleTaskCreate(arena: Allocator, conn: *Connection, req_id: []const u8, source: []const u8, args: json.ObjectMap) !void {
    const title = objGetString(args, "title") orelse {
        try sendToolResponse(arena, conn, req_id, source, false, null, "missing title");
        return;
    };
    const body_text = objGetString(args, "body");
    const project = objGetString(args, "project") orelse {
        try sendToolResponse(arena, conn, req_id, source, false, null, "missing project (p:<name>)");
        return;
    };
    var err_msg: ?[]const u8 = null;
    const api = loadBridge(arena, &err_msg) orelse {
        try sendToolResponse(arena, conn, req_id, source, false, null, err_msg);
        return;
    };
    const labels: []const []const u8 = &.{ project, "s:todo" };
    const body = api.createIssue(title, body_text, labels) catch {
        try sendToolResponse(arena, conn, req_id, source, false, null, "github api error (create)");
        return;
    };
    const parsed = try json.parseFromSlice(json.Value, arena, body, .{ .allocate = .alloc_always });
    try sendToolResponse(arena, conn, req_id, source, true, try compactIssue(arena, parsed.value), null);
}

/// Dispatcher for tool_request envelopes.
fn handleToolRequest(state: *HubState, arena: Allocator, conn: *Connection, envelope: protocol.Envelope) !void {
    _ = state;
    const req_id = envelope.id;
    const source = envelope.source;
    const tool = blk: {
        switch (envelope.payload) {
            .object => |obj| {
                const t = objGetString(obj, "tool") orelse {
                    try sendToolResponse(arena, conn, req_id, source, false, null, "missing tool name");
                    return;
                };
                break :blk t;
            },
            else => {
                try sendToolResponse(arena, conn, req_id, source, false, null, "payload must be an object");
                return;
            },
        }
    };
    const args: json.ObjectMap = switch (envelope.payload) {
        .object => |obj| if (obj.get("args")) |a| switch (a) {
            .object => |ao| ao,
            else => json.ObjectMap.empty,
        } else json.ObjectMap.empty,
        else => json.ObjectMap.empty,
    };

    if (mem.eql(u8, tool, "task.list"))
        return handleTaskList(arena, conn, req_id, source, args)
    else if (mem.eql(u8, tool, "task.claim"))
        return handleTaskClaim(arena, conn, req_id, source, args)
    else if (mem.eql(u8, tool, "task.update"))
        return handleTaskUpdate(arena, conn, req_id, source, args)
    else if (mem.eql(u8, tool, "task.comment"))
        return handleTaskComment(arena, conn, req_id, source, args)
    else if (mem.eql(u8, tool, "task.create"))
        return handleTaskCreate(arena, conn, req_id, source, args)
    else {
        try sendToolResponse(arena, conn, req_id, source, false, null, "unknown tool");
        return;
    }
}
