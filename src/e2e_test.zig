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
    thread: std.Thread,
};

/// Start a Hub on an ephemeral port.
fn startHub() !TestHub {
    const allocator = std.heap.page_allocator;
    const server = try allocator.create(hub.HubServer);
    server.* = try hub.HubServer.initWithAddress("127.0.0.1", 0);
    const port = server.listener.listen_address.getPort();
    const thread = try std.Thread.spawn(.{}, hubRunWrapper, .{server});
    // Give the accept loop a moment to start.
    std.Thread.sleep(10 * std.time.ns_per_ms);
    return .{ .server = server, .port = port, .thread = thread };
}

/// Wrapper that swallows the expected ConnectionAborted on shutdown.
fn hubRunWrapper(server: *hub.HubServer) void {
    server.run() catch {};
}

fn stopHub(h: TestHub) void {
    // deinit closes listener (unblocks accept), joins all client handler threads,
    // then frees state — no sleep needed.
    h.server.deinit();
    h.thread.join();
    std.heap.page_allocator.destroy(h.server);
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

    std.Thread.sleep(20 * std.time.ns_per_ms);

    const agents = try h.server.registeredAgents(alloc);
    var found = false;
    for (agents) |id| {
        if (mem.eql(u8, id, "agent-e2e-reg")) found = true;
    }
    try std.testing.expect(found);
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
    std.Thread.sleep(20 * std.time.ns_per_ms);

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
    std.Thread.sleep(20 * std.time.ns_per_ms);

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
    std.Thread.sleep(20 * std.time.ns_per_ms);

    {
        const agents = try h.server.registeredAgents(alloc);
        var found = false;
        for (agents) |id| {
            if (mem.eql(u8, id, "ephemeral")) found = true;
        }
        try std.testing.expect(found);
    }

    stream.close();
    std.Thread.sleep(50 * std.time.ns_per_ms);

    {
        const agents = try h.server.registeredAgents(alloc);
        var found = false;
        for (agents) |id| {
            if (mem.eql(u8, id, "ephemeral")) found = true;
        }
        try std.testing.expect(!found);
    }
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
    std.Thread.sleep(20 * std.time.ns_per_ms);

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
    std.Thread.sleep(20 * std.time.ns_per_ms);

    // Start a RunServer for "alice" connected to the same Hub.
    var server = try run.RunServer.init(alloc, "alice", "127.0.0.1", h.port);
    defer server.deinit();
    const threads = try server.startThreads();
    defer server.stopThreads(threads);
    std.Thread.sleep(20 * std.time.ns_per_ms);

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

    // Use IPC client to list agents — should see both alice and bob.
    {
        var client = try ipc.IpcClient.connect(server.socket_path);
        defer client.deinit();
        const req = try protocol.serializeIpcRequest(alloc, .{ .action = .agents });
        try client.send(req);
        var resp_buf: [8192]u8 = undefined;
        const resp_line = try client.recv(&resp_buf);
        try std.testing.expect(resp_line != null);
        try std.testing.expect(mem.indexOf(u8, resp_line.?, "\"success\":true") != null);
    }
}
