const std = @import("std");
const json = std.json;
const protocol = @import("protocol");

// ---------------------------------------------------------------------------
// Sub-module re-exports
// ---------------------------------------------------------------------------

pub const Connection = @import("hub/connection.zig").Connection;
pub const HubServer = @import("hub/server.zig").HubServer;
pub const HubState = @import("hub/registry.zig").HubState;

// Pull in tests from sub-modules.
comptime {
    _ = @import("hub/connection.zig");
    _ = @import("hub/registry.zig");
    _ = @import("hub/handlers.zig");
    _ = @import("hub/server.zig");
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
