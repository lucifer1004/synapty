const std = @import("std");
const mem = std.mem;
const json = std.json;
const Allocator = mem.Allocator;

// ---------------------------------------------------------------------------
// A2A JSON Routing Envelope
// ---------------------------------------------------------------------------

/// The canonical A2A routing envelope carried over WebSocket frames.
/// `payload` uses deferred parsing (`json.Value`) so the Hub can route
/// without deserializing application-layer contents.
pub const Envelope = struct {
    @"type": []const u8,
    id: []const u8,
    source: []const u8,
    target: []const u8 = "",
    payload: json.Value = .null,
};

/// Registration payload sent by a Daemon on first connect.
pub const RegisterPayload = struct {
    agent_id: []const u8,
    capabilities: []const []const u8 = &.{},
};

// ---------------------------------------------------------------------------
// Serialization helpers
// ---------------------------------------------------------------------------

/// Serialize an Envelope to JSON bytes using the provided allocator.
pub fn serializeEnvelope(allocator: Allocator, envelope: Envelope) ![]const u8 {
    return json.Stringify.valueAlloc(allocator, envelope, .{});
}

/// Parse a raw JSON byte slice into an Envelope.
/// Caller owns the returned parsed tree and must call `deinit()` on the result
/// when done.
pub fn parseEnvelope(allocator: Allocator, raw: []const u8) !json.Parsed(Envelope) {
    return json.parseFromSlice(
        Envelope,
        allocator,
        raw,
        .{ .allocate = .alloc_always },
    );
}

// ---------------------------------------------------------------------------
// IPC types (unix socket communication between CLI and daemon)
// ---------------------------------------------------------------------------

/// IPC actions per [[RFC-0003:C-CLI-TOOLS]] (the daemon socket the task CLI routes through).
pub const IpcAction = enum {
    send,
    recv,
    agents,
    register,
    channel_create,
    channel_invite,
    channel_leave,
    channel_list,

    pub fn jsonStringify(self: IpcAction, jw: anytype) !void {
        try jw.write(@tagName(self));
    }

    pub fn jsonParse(allocator: Allocator, source: anytype, options: json.ParseOptions) !IpcAction {
        _ = options;
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, 64);
        defer switch (token) {
            .allocated_string => |sl| allocator.free(sl),
            else => {},
        };
        const str = switch (token) {
            .string => |sl| sl,
            .allocated_string => |sl| sl,
            else => return error.UnexpectedToken,
        };
        inline for (@typeInfo(IpcAction).@"enum".fields) |f| {
            if (mem.eql(u8, str, f.name)) return @enumFromInt(f.value);
        }
        return error.InvalidEnumTag;
    }
};

/// IPC request per [[RFC-0003:C-CLI-TOOLS]] — fields are action-specific.
pub const IpcRequest = struct {
    action: IpcAction,
    // send
    target: ?[]const u8 = null,
    text: ?[]const u8 = null,
    // register (agent_update)
    tool: ?[]const u8 = null,
    project: ?[]const u8 = null,
    session: ?[]const u8 = null,
    // channel_create / channel_invite / channel_leave / channel_list
    channel: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

pub const IpcResponse = struct {
    success: bool,
    data: ?[]const u8 = null,
    error_msg: ?[]const u8 = null,
};

/// Serialize an IpcRequest to JSON bytes using the provided allocator.
pub fn serializeIpcRequest(allocator: Allocator, request: IpcRequest) ![]const u8 {
    return json.Stringify.valueAlloc(allocator, request, .{});
}

/// Parse a raw JSON byte slice into an IpcRequest.
pub fn parseIpcRequest(allocator: Allocator, raw: []const u8) !json.Parsed(IpcRequest) {
    return json.parseFromSlice(
        IpcRequest,
        allocator,
        raw,
        .{ .allocate = .alloc_always },
    );
}

/// Serialize an IpcResponse to JSON bytes using the provided allocator.
pub fn serializeIpcResponse(allocator: Allocator, response: IpcResponse) ![]const u8 {
    return json.Stringify.valueAlloc(allocator, response, .{});
}

/// Parse a raw JSON byte slice into an IpcResponse.
pub fn parseIpcResponse(allocator: Allocator, raw: []const u8) !json.Parsed(IpcResponse) {
    return json.parseFromSlice(
        IpcResponse,
        allocator,
        raw,
        .{ .allocate = .alloc_always },
    );
}

/// Build a Register envelope ready for serialization.
/// Build a register envelope. `capabilities` are honored: they are
/// emitted into the payload (the hub parses `payload` when present).
/// The envelope id is unique per call so multiple register frames from one
/// connection stay distinguishable (WI-2026-08-08-028). `id_buf` receives
/// the formatted id; the returned Envelope borrows it, so callers must
/// keep it alive until the envelope is serialized.
pub fn makeRegisterEnvelope(allocator: Allocator, agent_id: []const u8, capabilities: []const []const u8) !Envelope {
    var payload_obj = json.ObjectMap.empty;
    if (capabilities.len > 0) {
        var caps = json.Array.init(allocator);
        for (capabilities) |c| try caps.append(.{ .string = c });
        try payload_obj.put(allocator, "capabilities", .{ .array = caps });
    }
    const seq = register_seq.fetchAdd(1, .monotonic);
    // Caller-owned (arena pattern): registrations are rare and the
    // envelope is serialized immediately (WI-2026-08-08-028).
    const id = try std.fmt.allocPrint(allocator, "reg-{d}", .{seq});
    return Envelope{
        .@"type" = "register",
        .id = id,
        .source = agent_id,
        .target = "",
        .payload = if (payload_obj.count() > 0) .{ .object = payload_obj } else .null,
    };
}

var register_seq: std.atomic.Value(u32) = .init(0);

// ---------------------------------------------------------------------------
// OSC sequence constants
// ---------------------------------------------------------------------------

/// OSC 99 is our private namespace for human-in-the-loop notifications.
/// Format: \x1b]99;id=<agent_id>;status=<status>\x1b\\
pub const osc_prefix = "\x1b]99;";
pub const osc_terminator = "\x1b\\";

/// Parse an OSC 99 sequence, returning (agent_id, status) slices or null.
pub fn parseOsc99(data: []const u8) ?struct { agent_id: []const u8, status: []const u8 } {
    // Find the OSC prefix
    const start = mem.indexOf(u8, data, osc_prefix) orelse return null;
    const after_prefix = start + osc_prefix.len;

    // Find the terminator
    const end = mem.indexOf(u8, data[after_prefix..], osc_terminator) orelse return null;
    const params = data[after_prefix .. after_prefix + end];

    // Parse key=value pairs separated by ';'
    var agent_id: ?[]const u8 = null;
    var status: ?[]const u8 = null;

    var iter = mem.splitScalar(u8, params, ';');
    while (iter.next()) |kv| {
        if (mem.startsWith(u8, kv, "id=")) {
            agent_id = kv[3..];
        } else if (mem.startsWith(u8, kv, "status=")) {
            status = kv[7..];
        }
    }

    if (agent_id != null and status != null) {
        return .{ .agent_id = agent_id.?, .status = status.? };
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseOsc99 valid" {
    const seq = "\x1b]99;id=agent-01;status=wait_human\x1b\\";
    const result = parseOsc99(seq) orelse unreachable;
    try std.testing.expectEqualStrings("agent-01", result.agent_id);
    try std.testing.expectEqualStrings("wait_human", result.status);
}

test "parseOsc99 invalid" {
    const result = parseOsc99("hello world");
    try std.testing.expect(result == null);
}

test "makeRegisterEnvelope fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const env = try makeRegisterEnvelope(arena, "my-agent", &.{});
    try std.testing.expectEqualStrings("register", env.@"type");
    try std.testing.expectEqualStrings("my-agent", env.source);
    // Unique ids: two frames from one connection stay distinguishable.
    const env2 = try makeRegisterEnvelope(arena, "my-agent", &.{});
    try std.testing.expect(!mem.eql(u8, env.id, env2.id));
}

test "makeRegisterEnvelope honors capabilities" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const env = try makeRegisterEnvelope(arena, "my-agent", &.{ "task", "skills" });
    try std.testing.expect(env.payload == .object);
    const caps = env.payload.object.get("capabilities") orelse return error.TestUnexpectedResult;
    try std.testing.expect(caps == .array);
    try std.testing.expectEqual(@as(usize, 2), caps.array.items.len);
}

test "IpcRequest send round-trip" {
    const req = IpcRequest{
        .action = .send,
        .target = "agent-b",
        .text = "hello",
    };
    const serialized = try serializeIpcRequest(std.testing.allocator, req);
    defer std.testing.allocator.free(serialized);

    var parsed = try parseIpcRequest(std.testing.allocator, serialized);
    defer parsed.deinit();

    try std.testing.expectEqual(IpcAction.send, parsed.value.action);
    try std.testing.expectEqualStrings("agent-b", parsed.value.target.?);
    try std.testing.expectEqualStrings("hello", parsed.value.text.?);
}

test "IpcRequest register round-trip" {
    const req = IpcRequest{
        .action = .register,
        .tool = "codex",
        .project = "/path/to/project",
        .session = "auth refactor",
    };
    const serialized = try serializeIpcRequest(std.testing.allocator, req);
    defer std.testing.allocator.free(serialized);

    var parsed = try parseIpcRequest(std.testing.allocator, serialized);
    defer parsed.deinit();

    try std.testing.expectEqual(IpcAction.register, parsed.value.action);
    try std.testing.expectEqualStrings("codex", parsed.value.tool.?);
    try std.testing.expectEqualStrings("/path/to/project", parsed.value.project.?);
    try std.testing.expectEqualStrings("auth refactor", parsed.value.session.?);
}

test "IpcRequest channel_create round-trip" {
    const req = IpcRequest{
        .action = .channel_create,
        .channel = "design-review",
        .description = "Auth module redesign",
    };
    const serialized = try serializeIpcRequest(std.testing.allocator, req);
    defer std.testing.allocator.free(serialized);

    var parsed = try parseIpcRequest(std.testing.allocator, serialized);
    defer parsed.deinit();

    try std.testing.expectEqual(IpcAction.channel_create, parsed.value.action);
    try std.testing.expectEqualStrings("design-review", parsed.value.channel.?);
    try std.testing.expectEqualStrings("Auth module redesign", parsed.value.description.?);
}

test "IpcRequest recv round-trip" {
    const req = IpcRequest{ .action = .recv };
    const serialized = try serializeIpcRequest(std.testing.allocator, req);
    defer std.testing.allocator.free(serialized);

    var parsed = try parseIpcRequest(std.testing.allocator, serialized);
    defer parsed.deinit();

    try std.testing.expectEqual(IpcAction.recv, parsed.value.action);
    try std.testing.expect(parsed.value.target == null);
    try std.testing.expect(parsed.value.text == null);
}

test "IpcRequest agents round-trip" {
    const req = IpcRequest{ .action = .agents };
    const serialized = try serializeIpcRequest(std.testing.allocator, req);
    defer std.testing.allocator.free(serialized);

    var parsed = try parseIpcRequest(std.testing.allocator, serialized);
    defer parsed.deinit();

    try std.testing.expectEqual(IpcAction.agents, parsed.value.action);
}

test "IpcResponse success round-trip" {
    const resp = IpcResponse{
        .success = true,
        .data = "some-data",
    };
    const serialized = try serializeIpcResponse(std.testing.allocator, resp);
    defer std.testing.allocator.free(serialized);

    var parsed = try parseIpcResponse(std.testing.allocator, serialized);
    defer parsed.deinit();

    try std.testing.expect(parsed.value.success);
    try std.testing.expectEqualStrings("some-data", parsed.value.data.?);
    try std.testing.expect(parsed.value.error_msg == null);
}

test "IpcResponse error round-trip" {
    const resp = IpcResponse{
        .success = false,
        .error_msg = "target not found",
    };
    const serialized = try serializeIpcResponse(std.testing.allocator, resp);
    defer std.testing.allocator.free(serialized);

    var parsed = try parseIpcResponse(std.testing.allocator, serialized);
    defer parsed.deinit();

    try std.testing.expect(!parsed.value.success);
    try std.testing.expect(parsed.value.data == null);
    try std.testing.expectEqualStrings("target not found", parsed.value.error_msg.?);
}
