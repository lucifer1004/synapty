const std = @import("std");
const mem = std.mem;
const json = std.json;
const Allocator = mem.Allocator;

// ---------------------------------------------------------------------------
// A2A JSON Routing Envelope
// ---------------------------------------------------------------------------

/// Top-level message types flowing over the WebSocket control plane.
pub const MessageType = enum {
    register,
    a2a_request,
    a2a_response,

    pub fn toString(self: MessageType) []const u8 {
        return switch (self) {
            .register => "register",
            .a2a_request => "a2a_request",
            .a2a_response => "a2a_response",
        };
    }

    pub fn fromString(s: []const u8) ?MessageType {
        if (mem.eql(u8, s, "register")) return .register;
        if (mem.eql(u8, s, "a2a_request")) return .a2a_request;
        if (mem.eql(u8, s, "a2a_response")) return .a2a_response;
        return null;
    }
};

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

/// Build a Register envelope ready for serialization.
pub fn makeRegisterEnvelope(agent_id: []const u8, capabilities: []const []const u8) Envelope {
    // Build the payload as a json.Value manually is verbose; instead we
    // keep it simple for V1 — the Hub inspects `type` == "register" and
    // then re-parses `payload` as RegisterPayload when needed.
    _ = capabilities;
    return Envelope{
        .@"type" = "register",
        .id = "reg-0",
        .source = agent_id,
        .target = "",
        .payload = .null,
    };
}

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

test "MessageType round-trip" {
    const t = MessageType.a2a_request;
    const s = t.toString();
    const back = MessageType.fromString(s);
    try std.testing.expectEqual(MessageType.a2a_request, back.?);
}

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
    const env = makeRegisterEnvelope("my-agent", &.{});
    try std.testing.expectEqualStrings("register", env.@"type");
    try std.testing.expectEqualStrings("my-agent", env.source);
}
