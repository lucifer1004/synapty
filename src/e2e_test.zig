const std = @import("std");
const net = std.net;
const mem = std.mem;
const json = std.json;
const protocol = @import("protocol");
const hub = @import("hub");
const ipc = @import("ipc");
const run = @import("run");
const Allocator = mem.Allocator;

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

const TestHub = struct {
    server: *hub.HubServer,
    port: u16,
};

/// Start a Hub on an ephemeral port.
fn startHub() !TestHub {
    const allocator = std.heap.page_allocator;
    const server = try allocator.create(hub.HubServer);
    server.* = try hub.HubServer.initWithAddress("127.0.0.1", 0);
    const port = server.listener.listen_address.getPort();
    try server.startBackground();
    return .{ .server = server, .port = port };
}

fn stopHub(h: TestHub) void {
    // deinit: closes listener → joins accept thread → joins client threads → frees state.
    h.server.deinit();
    std.heap.page_allocator.destroy(h.server);
}

/// Poll until an agent appears in the Hub's routing table (or timeout).
fn waitForRegistered(server: *hub.HubServer, agent_id: []const u8, timeout_ms: u64) bool {
    const alloc = std.heap.page_allocator;
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        const agents = server.registeredAgents(alloc) catch return false;
        defer {
            for (agents) |id| alloc.free(id);
            alloc.free(agents);
        }
        for (agents) |id| {
            if (mem.eql(u8, id, agent_id)) return true;
        }
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
    return false;
}

/// Poll until an agent is NOT in the Hub's routing table (or timeout).
fn waitForUnregistered(server: *hub.HubServer, agent_id: []const u8, timeout_ms: u64) bool {
    const alloc = std.heap.page_allocator;
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        const agents = server.registeredAgents(alloc) catch return true;
        defer {
            for (agents) |id| alloc.free(id);
            alloc.free(agents);
        }
        var found = false;
        for (agents) |id| {
            if (mem.eql(u8, id, agent_id)) found = true;
        }
        if (!found) return true;
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
    return false;
}

/// Connect to Hub and send a register envelope. Returns the connected stream.
fn connectAndRegister(allocator: Allocator, port: u16, agent_id: []const u8) !net.Stream {
    const address = try net.Address.parseIp4("127.0.0.1", port);
    const stream = try net.tcpConnectToAddress(address);
    errdefer stream.close();

    const reg = protocol.makeRegisterEnvelope(agent_id, &.{});
    const raw = try protocol.serializeEnvelope(allocator, reg);
    defer allocator.free(raw);
    try stream.writeAll(raw);
    try stream.writeAll("\n");
    return stream;
}

/// Read a complete newline-terminated line from a stream with timeout.
/// Returns the line (without \n) or null on timeout.
fn readLine(stream: net.Stream, buf: []u8, timeout_ms: u64) ?[]const u8 {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    var filled: usize = 0;
    // Set non-blocking for poll-style reads.
    const fd = stream.handle;
    var flags = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch return null;
    flags |= 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
    _ = std.posix.fcntl(fd, std.posix.F.SETFL, flags) catch return null;
    defer {
        // Restore blocking mode.
        flags &= ~@as(u32, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));
        _ = std.posix.fcntl(fd, std.posix.F.SETFL, flags) catch {};
    }

    while (std.time.milliTimestamp() < deadline) {
        if (filled >= buf.len) return null;
        const n = stream.read(buf[filled..]) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            },
            else => return null,
        };
        if (n == 0) return null;
        filled += n;
        if (mem.indexOfScalar(u8, buf[0..filled], '\n')) |nl| {
            return mem.trimRight(u8, buf[0..nl], "\r ");
        }
    }
    return null;
}

/// Parse an IPC response line, extract the "data" field, and parse it as JSON.
/// The IPC response is `{"success":...,"data":"<escaped-json>"}` — this
/// unescapes and parses the nested JSON so callers can navigate the structure.
/// Caller must use an arena allocator (no explicit deinit needed).
fn parseIpcData(alloc: Allocator, ipc_line: []const u8) !json.Value {
    const outer = try json.parseFromSlice(json.Value, alloc, ipc_line, .{ .allocate = .alloc_always });
    const outer_obj = if (outer.value == .object) outer.value.object else return error.UnexpectedToken;
    const data_val = outer_obj.get("data") orelse return error.MissingField;
    if (data_val != .string) return error.UnexpectedToken;
    const inner = try json.parseFromSlice(json.Value, alloc, data_val.string, .{ .allocate = .alloc_always });
    return inner.value;
}

/// Find an agent object by ID in a Hub agents response array.
fn findAgentInList(agents_arr: json.Array, agent_id: []const u8) ?json.ObjectMap {
    for (agents_arr.items) |item| {
        if (item != .object) continue;
        const id_val = item.object.get("id") orelse continue;
        if (id_val == .string and mem.eql(u8, id_val.string, agent_id)) return item.object;
    }
    return null;
}

/// Parse an envelope from a JSON line and check the "ok" field in payload.
fn envelopeOk(allocator: Allocator, line: []const u8) !bool {
    var parsed = try protocol.parseEnvelope(allocator, line);
    defer parsed.deinit();
    if (parsed.value.payload == .object) {
        if (parsed.value.payload.object.get("ok")) |v| {
            if (v == .bool) return v.bool;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// E2E Tests
// ---------------------------------------------------------------------------

test "e2e: register handshake — agent appears in registered list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h = try startHub();
    defer stopHub(h);

    const stream = try connectAndRegister(alloc, h.port, "agent-e2e-reg");
    defer stream.close();

    try std.testing.expect(waitForRegistered(h.server, "agent-e2e-reg", 2000));
}

test "e2e: DM routing — message delivered to target agent" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h = try startHub();
    defer stopHub(h);

    const stream_a = try connectAndRegister(alloc, h.port, "alice");
    defer stream_a.close();
    const stream_b = try connectAndRegister(alloc, h.port, "bob");
    defer stream_b.close();
    try std.testing.expect(waitForRegistered(h.server, "bob", 2000));

    // Alice sends a DM to Bob.
    var payload_obj = json.ObjectMap.init(alloc);
    try payload_obj.put("text", .{ .string = "hello bob" });
    const raw = try protocol.serializeEnvelope(alloc, .{
        .@"type" = "dm",
        .id = "dm-1",
        .source = "alice",
        .target = "bob",
        .payload = .{ .object = payload_obj },
    });
    try stream_a.writeAll(raw);
    try stream_a.writeAll("\n");

    // Bob should receive the DM.
    var bob_buf: [8192]u8 = undefined;
    const bob_line = readLine(stream_b, &bob_buf, 2000);
    try std.testing.expect(bob_line != null);
    try std.testing.expect(mem.indexOf(u8, bob_line.?, "hello bob") != null);
    try std.testing.expect(mem.indexOf(u8, bob_line.?, "\"source\":\"alice\"") != null);

    // Alice should receive a success response.
    var alice_buf: [8192]u8 = undefined;
    const alice_line = readLine(stream_a, &alice_buf, 2000);
    try std.testing.expect(alice_line != null);
    try std.testing.expect(try envelopeOk(alloc, alice_line.?));
}

test "e2e: DM to unknown agent returns error response" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h = try startHub();
    defer stopHub(h);

    const stream = try connectAndRegister(alloc, h.port, "sender");
    defer stream.close();
    try std.testing.expect(waitForRegistered(h.server, "sender", 2000));

    var payload_obj = json.ObjectMap.init(alloc);
    try payload_obj.put("text", .{ .string = "anyone there?" });
    const raw = try protocol.serializeEnvelope(alloc, .{
        .@"type" = "dm",
        .id = "dm-miss",
        .source = "sender",
        .target = "ghost",
        .payload = .{ .object = payload_obj },
    });
    try stream.writeAll(raw);
    try stream.writeAll("\n");

    var buf: [8192]u8 = undefined;
    const line = readLine(stream, &buf, 2000);
    try std.testing.expect(line != null);
    try std.testing.expect(!try envelopeOk(alloc, line.?));
    try std.testing.expect(mem.indexOf(u8, line.?, "agent not connected") != null);
}

test "e2e: disconnect cleanup — agent removed from routing" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h = try startHub();
    defer stopHub(h);

    const stream = try connectAndRegister(alloc, h.port, "ephemeral");
    try std.testing.expect(waitForRegistered(h.server, "ephemeral", 2000));

    stream.close();
    try std.testing.expect(waitForUnregistered(h.server, "ephemeral", 2000));
}

test "e2e: channel create + send fan-out to members" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h = try startHub();
    defer stopHub(h);

    // Register three agents.
    const stream_a = try connectAndRegister(alloc, h.port, "ch-alice");
    defer stream_a.close();
    const stream_b = try connectAndRegister(alloc, h.port, "ch-bob");
    defer stream_b.close();
    const stream_c = try connectAndRegister(alloc, h.port, "ch-carol");
    defer stream_c.close();
    try std.testing.expect(waitForRegistered(h.server, "ch-carol", 2000));

    // Alice creates a channel.
    {
        var p = json.ObjectMap.init(alloc);
        try p.put("name", .{ .string = "test-chan" });
        try p.put("description", .{ .string = "e2e test" });
        const env = protocol.Envelope{
            .@"type" = "channel_create",
            .id = "cc-1",
            .source = "ch-alice",
            .target = "hub",
            .payload = .{ .object = p },
        };
        const raw = try protocol.serializeEnvelope(alloc, env);

        try stream_a.writeAll(raw);
        try stream_a.writeAll("\n");
        // Read success response.
        var buf: [8192]u8 = undefined;
        const resp = readLine(stream_a, &buf, 2000);
        try std.testing.expect(resp != null);
        try std.testing.expect(try envelopeOk(alloc, resp.?));
    }

    // Alice invites Bob and Carol.
    inline for (.{ "ch-bob", "ch-carol" }) |invitee| {
        var p = json.ObjectMap.init(alloc);
        try p.put("channel", .{ .string = "test-chan" });
        try p.put("agent_id", .{ .string = invitee });
        const env = protocol.Envelope{
            .@"type" = "channel_invite",
            .id = "ci-" ++ invitee,
            .source = "ch-alice",
            .target = "hub",
            .payload = .{ .object = p },
        };
        const raw = try protocol.serializeEnvelope(alloc, env);

        try stream_a.writeAll(raw);
        try stream_a.writeAll("\n");
        // Verify invite response has ok=true.
        var buf: [8192]u8 = undefined;
        const invite_resp = readLine(stream_a, &buf, 2000);
        try std.testing.expect(invite_resp != null);
        try std.testing.expect(try envelopeOk(alloc, invite_resp.?));
        // Verify invitee receives channel_event with "invited".
        var inv_buf: [8192]u8 = undefined;
        const inv_stream = if (mem.eql(u8, invitee, "ch-bob")) stream_b else stream_c;
        const inv_event = readLine(inv_stream, &inv_buf, 2000);
        try std.testing.expect(inv_event != null);
        try std.testing.expect(mem.indexOf(u8, inv_event.?, "\"event\":\"invited\"") != null);
        try std.testing.expect(mem.indexOf(u8, inv_event.?, "test-chan") != null);
    }

    // Alice sends a channel message.
    {
        var p = json.ObjectMap.init(alloc);
        try p.put("text", .{ .string = "hello channel" });
        const env = protocol.Envelope{
            .@"type" = "channel_msg",
            .id = "cm-1",
            .source = "ch-alice",
            .target = "channel:test-chan",
            .payload = .{ .object = p },
        };
        const raw = try protocol.serializeEnvelope(alloc, env);

        try stream_a.writeAll(raw);
        try stream_a.writeAll("\n");

        // Bob and Carol should each receive the fan-out.
        var bob_buf: [8192]u8 = undefined;
        const bob_msg = readLine(stream_b, &bob_buf, 2000);
        try std.testing.expect(bob_msg != null);
        try std.testing.expect(mem.indexOf(u8, bob_msg.?, "hello channel") != null);

        var carol_buf: [8192]u8 = undefined;
        const carol_msg = readLine(stream_c, &carol_buf, 2000);
        try std.testing.expect(carol_msg != null);
        try std.testing.expect(mem.indexOf(u8, carol_msg.?, "hello channel") != null);

        // Alice should receive the success response (not the fan-out).
        var alice_buf: [8192]u8 = undefined;
        const alice_resp = readLine(stream_a, &alice_buf, 2000);
        try std.testing.expect(alice_resp != null);
        try std.testing.expect(try envelopeOk(alloc, alice_resp.?));
    }
}

test "e2e: RunServer IPC send through daemon to Hub delivers to target" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h = try startHub();
    defer stopHub(h);

    // Connect "bob" as a raw TCP agent to the Hub.
    const bob_stream = try connectAndRegister(alloc, h.port, "bob");
    defer bob_stream.close();
    try std.testing.expect(waitForRegistered(h.server, "bob", 2000));

    // Start a RunServer for "alice" connected to the same Hub.
    var server = try run.RunServer.init(alloc, "alice", "127.0.0.1", h.port);
    defer server.deinit();
    const threads = try server.startThreads();
    defer server.stopThreads(threads);
    try std.testing.expect(waitForRegistered(h.server, "alice", 2000));

    // Use IPC client to send a DM from alice to bob through the daemon.
    {
        var client = try ipc.IpcClient.connect(server.socket_path);
        defer client.deinit();
        const req = try protocol.serializeIpcRequest(alloc, .{
            .action = .send,
            .target = "bob",
            .text = "hello from daemon",
        });
        try client.send(req);
        // Read IPC response — should indicate success.
        var resp_buf: [8192]u8 = undefined;
        const resp_line = try client.recv(&resp_buf);
        try std.testing.expect(resp_line != null);
        try std.testing.expect(mem.indexOf(u8, resp_line.?, "\"success\":true") != null);
    }

    // Bob should have received the DM via the Hub.
    var bob_buf: [8192]u8 = undefined;
    const bob_msg = readLine(bob_stream, &bob_buf, 2000);
    try std.testing.expect(bob_msg != null);
    try std.testing.expect(mem.indexOf(u8, bob_msg.?, "hello from daemon") != null);
    try std.testing.expect(mem.indexOf(u8, bob_msg.?, "\"source\":\"alice\"") != null);

    // Use IPC client to list agents — parse nested Hub response structurally.
    {
        var client = try ipc.IpcClient.connect(server.socket_path);
        defer client.deinit();
        const req = try protocol.serializeIpcRequest(alloc, .{ .action = .agents });
        try client.send(req);
        var resp_buf: [16384]u8 = undefined;
        const resp_line = try client.recv(&resp_buf);
        try std.testing.expect(resp_line != null);

        const hub_env = try parseIpcData(alloc, resp_line.?);
        try std.testing.expect(hub_env == .object);
        const payload = hub_env.object.get("payload") orelse return error.TestUnexpectedResult;
        try std.testing.expect(payload == .object);
        const agents_val = payload.object.get("agents") orelse return error.TestUnexpectedResult;
        try std.testing.expect(agents_val == .array);
        // Both alice and bob must be present as distinct agent entries.
        try std.testing.expect(findAgentInList(agents_val.array, "alice") != null);
        try std.testing.expect(findAgentInList(agents_val.array, "bob") != null);
    }
}

test "e2e: RunServer IPC recv retrieves messages sent to daemon agent" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h = try startHub();
    defer stopHub(h);

    // Start RunServer for "alice".
    var server = try run.RunServer.init(alloc, "alice", "127.0.0.1", h.port);
    defer server.deinit();
    const threads = try server.startThreads();
    defer server.stopThreads(threads);
    try std.testing.expect(waitForRegistered(h.server, "alice", 2000));

    // Connect "bob" as raw TCP and send a DM to alice.
    const bob_stream = try connectAndRegister(alloc, h.port, "bob");
    defer bob_stream.close();
    try std.testing.expect(waitForRegistered(h.server, "bob", 2000));

    var payload_obj = json.ObjectMap.init(alloc);
    try payload_obj.put("text", .{ .string = "msg for alice" });
    const raw = try protocol.serializeEnvelope(alloc, .{
        .@"type" = "dm",
        .id = "dm-to-alice",
        .source = "bob",
        .target = "alice",
        .payload = .{ .object = payload_obj },
    });
    try bob_stream.writeAll(raw);
    try bob_stream.writeAll("\n");

    // Poll IPC recv until the message appears (no fixed sleep).
    {
        const deadline = std.time.milliTimestamp() + 2000;
        var found = false;
        while (std.time.milliTimestamp() < deadline) {
            // Scoped block ensures IPC client is closed each iteration.
            {
                var client = try ipc.IpcClient.connect(server.socket_path);
                defer client.deinit();
                const req = try protocol.serializeIpcRequest(alloc, .{ .action = .recv });
                try client.send(req);
                var resp_buf: [16384]u8 = undefined;
                const resp_line = try client.recv(&resp_buf);
                if (resp_line) |resp_str| {
                    // Parse the IPC data field (a JSON array of raw message strings).
                    const data = parseIpcData(alloc, resp_str) catch continue;
                    if (data != .array) continue;
                    for (data.array.items) |msg_val| {
                        if (msg_val != .string) continue;
                        // Parse each queued message as an envelope.
                        const env = json.parseFromSlice(json.Value, alloc, msg_val.string, .{ .allocate = .alloc_always }) catch continue;
                        if (env.value != .object) continue;
                        const source = env.value.object.get("source") orelse continue;
                        const payload = env.value.object.get("payload") orelse continue;
                        if (source == .string and mem.eql(u8, source.string, "bob")) {
                            if (payload == .object) {
                                const text_val = payload.object.get("text") orelse continue;
                                if (text_val == .string and mem.eql(u8, text_val.string, "msg for alice")) {
                                    // Verify envelope structure.
                                    const target = env.value.object.get("target") orelse continue;
                                    try std.testing.expect(target == .string);
                                    try std.testing.expectEqualStrings("alice", target.string);
                                    const msg_type = env.value.object.get("type") orelse continue;
                                    try std.testing.expect(msg_type == .string);
                                    try std.testing.expectEqualStrings("dm", msg_type.string);
                                    found = true;
                                    break;
                                }
                            }
                        }
                    }
                    if (found) break;
                }
            }
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
        try std.testing.expect(found);
    }
}

test "e2e: RunServer IPC register updates agent metadata on Hub" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h = try startHub();
    defer stopHub(h);

    // Start RunServer for "alice".
    var server = try run.RunServer.init(alloc, "alice", "127.0.0.1", h.port);
    defer server.deinit();
    const threads = try server.startThreads();
    defer server.stopThreads(threads);
    try std.testing.expect(waitForRegistered(h.server, "alice", 2000));

    // Use IPC register to set agent metadata.
    {
        var client = try ipc.IpcClient.connect(server.socket_path);
        defer client.deinit();
        const req = try protocol.serializeIpcRequest(alloc, .{
            .action = .register,
            .tool = "claude",
            .project = "/test/project",
            .session = "e2e test",
        });
        try client.send(req);
        var resp_buf: [8192]u8 = undefined;
        const resp_line = try client.recv(&resp_buf);
        try std.testing.expect(resp_line != null);
        try std.testing.expect(mem.indexOf(u8, resp_line.?, "\"success\":true") != null);
    }

    // Verify metadata via list_agents — parse nested Hub response structurally.
    {
        var client = try ipc.IpcClient.connect(server.socket_path);
        defer client.deinit();
        const req = try protocol.serializeIpcRequest(alloc, .{ .action = .agents });
        try client.send(req);
        var resp_buf: [16384]u8 = undefined;
        const resp_line = try client.recv(&resp_buf);
        try std.testing.expect(resp_line != null);

        // Parse IPC data → Hub envelope → payload.agents array.
        const hub_env = try parseIpcData(alloc, resp_line.?);
        try std.testing.expect(hub_env == .object);
        const payload = hub_env.object.get("payload") orelse return error.TestUnexpectedResult;
        try std.testing.expect(payload == .object);
        const ok_val = payload.object.get("ok") orelse return error.TestUnexpectedResult;
        try std.testing.expect(ok_val == .bool and ok_val.bool);
        const agents_val = payload.object.get("agents") orelse return error.TestUnexpectedResult;
        try std.testing.expect(agents_val == .array);

        // Find alice's entry and verify metadata fields.
        const alice_obj = findAgentInList(agents_val.array, "alice") orelse return error.TestUnexpectedResult;
        const tool_val = alice_obj.get("tool") orelse return error.TestUnexpectedResult;
        try std.testing.expect(tool_val == .string);
        try std.testing.expectEqualStrings("claude", tool_val.string);
        const proj_val = alice_obj.get("project") orelse return error.TestUnexpectedResult;
        try std.testing.expect(proj_val == .string);
        try std.testing.expectEqualStrings("/test/project", proj_val.string);
        const sess_val = alice_obj.get("session") orelse return error.TestUnexpectedResult;
        try std.testing.expect(sess_val == .string);
        try std.testing.expectEqualStrings("e2e test", sess_val.string);
    }
}

test "e2e: RunServer IPC channel create and send through daemon" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h = try startHub();
    defer stopHub(h);

    // Start RunServer for "alice".
    var srv_alice = try run.RunServer.init(alloc, "alice", "127.0.0.1", h.port);
    defer srv_alice.deinit();
    const threads_alice = try srv_alice.startThreads();
    defer srv_alice.stopThreads(threads_alice);
    try std.testing.expect(waitForRegistered(h.server, "alice", 2000));

    // Connect "bob" as raw TCP.
    const bob_stream = try connectAndRegister(alloc, h.port, "bob");
    defer bob_stream.close();
    try std.testing.expect(waitForRegistered(h.server, "bob", 2000));

    // Alice creates a channel via IPC.
    {
        var client = try ipc.IpcClient.connect(srv_alice.socket_path);
        defer client.deinit();
        const req = try protocol.serializeIpcRequest(alloc, .{
            .action = .channel_create,
            .channel = "ipc-chan",
            .description = "daemon channel test",
        });
        try client.send(req);
        var resp_buf: [8192]u8 = undefined;
        const resp_line = try client.recv(&resp_buf);
        try std.testing.expect(resp_line != null);
        try std.testing.expect(mem.indexOf(u8, resp_line.?, "\"success\":true") != null);
    }

    // Alice invites bob via IPC.
    {
        var client = try ipc.IpcClient.connect(srv_alice.socket_path);
        defer client.deinit();
        const req = try protocol.serializeIpcRequest(alloc, .{
            .action = .channel_invite,
            .channel = "ipc-chan",
            .agent_id = "bob",
        });
        try client.send(req);
        var resp_buf: [8192]u8 = undefined;
        const resp_line = try client.recv(&resp_buf);
        try std.testing.expect(resp_line != null);
        try std.testing.expect(mem.indexOf(u8, resp_line.?, "\"success\":true") != null);
    }

    // Bob should receive invite event — parse structurally.
    var inv_buf: [8192]u8 = undefined;
    const inv_line = readLine(bob_stream, &inv_buf, 2000);
    try std.testing.expect(inv_line != null);
    {
        var inv_parsed = try protocol.parseEnvelope(alloc, inv_line.?);
        _ = &inv_parsed;
        try std.testing.expectEqualStrings("channel_event", inv_parsed.value.@"type");
        try std.testing.expectEqualStrings("bob", inv_parsed.value.target);
        try std.testing.expect(inv_parsed.value.payload == .object);
        const inv_payload = inv_parsed.value.payload.object;
        const event_val = inv_payload.get("event") orelse return error.TestUnexpectedResult;
        try std.testing.expect(event_val == .string);
        try std.testing.expectEqualStrings("invited", event_val.string);
        const ch_val = inv_payload.get("channel") orelse return error.TestUnexpectedResult;
        try std.testing.expect(ch_val == .string);
        try std.testing.expectEqualStrings("ipc-chan", ch_val.string);
        const by_val = inv_payload.get("by") orelse return error.TestUnexpectedResult;
        try std.testing.expect(by_val == .string);
        try std.testing.expectEqualStrings("alice", by_val.string);
    }

    // Alice sends a channel message via IPC send with channel: prefix.
    {
        var client = try ipc.IpcClient.connect(srv_alice.socket_path);
        defer client.deinit();
        const req = try protocol.serializeIpcRequest(alloc, .{
            .action = .send,
            .target = "channel:ipc-chan",
            .text = "hello via daemon channel",
        });
        try client.send(req);
        var resp_buf: [8192]u8 = undefined;
        const resp_line = try client.recv(&resp_buf);
        try std.testing.expect(resp_line != null);
        try std.testing.expect(mem.indexOf(u8, resp_line.?, "\"success\":true") != null);
    }

    // Bob should receive the channel message — parse structurally.
    var bob_buf: [8192]u8 = undefined;
    const bob_line = readLine(bob_stream, &bob_buf, 2000);
    try std.testing.expect(bob_line != null);
    {
        var msg_parsed = try protocol.parseEnvelope(alloc, bob_line.?);
        _ = &msg_parsed;
        try std.testing.expectEqualStrings("channel_msg", msg_parsed.value.@"type");
        try std.testing.expectEqualStrings("alice", msg_parsed.value.source);
        try std.testing.expectEqualStrings("channel:ipc-chan", msg_parsed.value.target);
        try std.testing.expect(msg_parsed.value.payload == .object);
        const text_val = msg_parsed.value.payload.object.get("text") orelse return error.TestUnexpectedResult;
        try std.testing.expect(text_val == .string);
        try std.testing.expectEqualStrings("hello via daemon channel", text_val.string);
    }
}
