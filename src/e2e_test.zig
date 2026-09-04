const std = @import("std");
const sys = @import("sys");
const io_mod = @import("io");
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
    const port = server.bound_port;
    try server.startBackground();
    return .{ .server = server, .port = port };
}

/// Bind a hub on a SPECIFIC port — the reconnect e2e restarts the hub
/// in place (SO_REUSEADDR makes the immediate rebind safe).
fn startHubOn(port: u16) !TestHub {
    const allocator = std.heap.page_allocator;
    const server = try allocator.create(hub.HubServer);
    server.* = try hub.HubServer.initWithAddress("127.0.0.1", port);
    try server.startBackground();
    return .{ .server = server, .port = server.bound_port };
}

fn stopHub(h: TestHub) void {
    // deinit: closes listener → joins accept thread → joins client threads → frees state.
    h.server.deinit();
    std.heap.page_allocator.destroy(h.server);
}

/// Poll until an agent appears in the Hub's routing table (or timeout).
fn waitForRegistered(server: *hub.HubServer, agent_id: []const u8, timeout_ms: u64) bool {
    const alloc = std.heap.page_allocator;
    const deadline = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds() + @as(i64, @intCast(timeout_ms));
    while (std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds() < deadline) {
        const agents = server.registeredAgents(alloc) catch return false;
        defer {
            for (agents) |id| alloc.free(id);
            alloc.free(agents);
        }
        for (agents) |id| {
            if (mem.eql(u8, id, agent_id)) return true;
        }
        io_mod.get().sleep(std.Io.Duration.fromMilliseconds(2), .awake) catch {};
    }
    return false;
}

/// Poll until an agent is NOT in the Hub's routing table (or timeout).
fn waitForUnregistered(server: *hub.HubServer, agent_id: []const u8, timeout_ms: u64) bool {
    const alloc = std.heap.page_allocator;
    const deadline = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds() + @as(i64, @intCast(timeout_ms));
    while (std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds() < deadline) {
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
        io_mod.get().sleep(std.Io.Duration.fromMilliseconds(2), .awake) catch {};
    }
    return false;
}

/// Connect to Hub and send a register envelope. Returns the connected stream.
fn connectAndRegister(allocator: Allocator, port: u16, agent_id: []const u8) !sys.fd_t {
    const stream = try connectTcp(port);
    errdefer sys.close(stream);

    const reg = try protocol.makeRegisterEnvelope(allocator, agent_id, &.{});
    const raw = try protocol.serializeEnvelope(allocator, reg);
    defer allocator.free(raw);
    try sys.writeAll(stream, raw);
    try sys.writeAll(stream, "\n");
    return stream;
}

/// Open a TCP connection to the test Hub on 127.0.0.1:port.
fn connectTcp(port: u16) !sys.fd_t {
    const fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    errdefer sys.close(fd);
    const addr4 = std.Io.net.Ip4Address.loopback(port);
    const sa = sys.sockaddr_in.init(@bitCast(addr4.bytes), port);
    try sys.connect(fd, &sa, @sizeOf(sys.sockaddr_in));
    return fd;
}

/// Read a complete newline-terminated line from a stream with timeout.
/// Returns the line (without \n) or null on timeout.
/// A DEADLINE IS A BOUND, NOT A BUDGET. These waits ran at two seconds
/// and a GitHub runner under load lost one in five runs to them; a green
/// run finishes as soon as the line arrives, so slack costs nothing there
/// ([[WI-2026-09-02-038]]).
fn readLine(stream: sys.fd_t, buf: []u8, timeout_ms: u64) ?[]const u8 {
    const io = io_mod.get();
    const deadline = std.Io.Timestamp.now(io, .real).toMilliseconds() + @as(i64, @intCast(timeout_ms));
    var filled: usize = 0;
    // Set non-blocking for poll-style reads.
    sys.setNonblocking(stream) catch return null;

    while (std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds() < deadline) {
        if (filled >= buf.len) return null;
        const n = sys.read(stream, buf[filled..]) catch |err| switch (err) {
            error.WouldBlock => {
                io_mod.get().sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
                continue;
            },
            else => return null,
        };
        if (n == 0) return null;
        filled += n;
        if (mem.indexOfScalar(u8, buf[0..filled], '\n')) |nl| {
            return mem.trimEnd(u8, buf[0..nl], "\r ");
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
    defer sys.close(stream);

    try std.testing.expect(waitForRegistered(h.server, "agent-e2e-reg", 2000));
}

test "e2e: DM routing — message delivered to target agent" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h = try startHub();
    defer stopHub(h);

    const stream_a = try connectAndRegister(alloc, h.port, "alice");
    defer sys.close(stream_a);
    const stream_b = try connectAndRegister(alloc, h.port, "bob");
    defer sys.close(stream_b);
    try std.testing.expect(waitForRegistered(h.server, "bob", 2000));

    // Alice sends a DM to Bob.
    var payload_obj = json.ObjectMap.empty;
    try payload_obj.put(alloc, "text", .{ .string = "hello bob" });
    const raw = try protocol.serializeEnvelope(alloc, .{
        .@"type" = "dm",
        .id = "dm-1",
        .source = "alice",
        .target = "bob",
        .payload = .{ .object = payload_obj },
    });
    try sys.writeAll(stream_a, raw);
    try sys.writeAll(stream_a, "\n");

    // RFC-0008 C-MAILBOX: bob gets a NUDGE (content stays queued at the
    // hub until he drains it through his own connection).
    var bob_buf: [8192]u8 = undefined;
    const bob_line = readLine(stream_b, &bob_buf, 8000);
    try std.testing.expect(bob_line != null);
    try std.testing.expect(mem.indexOf(u8, bob_line.?, "mail_nudge") != null);

    // Alice's ack names the outcome ([[RFC-0009]] C-DELIVERY): `status`,
    // and nothing derived beside it — a boolean that answered true for a
    // spooled message was the overstatement that clause forbids.
    var alice_buf: [8192]u8 = undefined;
    const alice_line = readLine(stream_a, &alice_buf, 8000);
    try std.testing.expect(alice_line != null);
    try std.testing.expect(try envelopeOk(alloc, alice_line.?));
    try std.testing.expect(mem.indexOf(u8, alice_line.?, "\"status\":\"delivered\"") != null);
    try std.testing.expect(mem.indexOf(u8, alice_line.?, "\"queued\"") == null);
    // AND NOTHING BESIDE `status` AND `reason`. `hosted` went the same way
    // `queued` did: it reported whether the target had a live connection,
    // which is presence, and presence has its own surface with its own
    // acceptance rules ([[RFC-0009]] C-DELIVERY's wire shape).
    try std.testing.expect(mem.indexOf(u8, alice_line.?, "\"hosted\"") == null);

    // Bob drains the hub-side queue and receives the message content.
    try sys.writeAll(stream_b, "{\"type\":\"mailbox_recv\",\"id\":\"mr-1\",\"source\":\"bob\",\"target\":\"hub\"}\n");
    var drain_buf: [8192]u8 = undefined;
    const drained = readLine(stream_b, &drain_buf, 8000);
    try std.testing.expect(drained != null);
    try std.testing.expect(mem.indexOf(u8, drained.?, "hello bob") != null);
}

test "e2e: DM to unknown agent returns error response" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h = try startHub();
    defer stopHub(h);

    const stream = try connectAndRegister(alloc, h.port, "sender");
    defer sys.close(stream);
    try std.testing.expect(waitForRegistered(h.server, "sender", 2000));

    var payload_obj = json.ObjectMap.empty;
    try payload_obj.put(alloc, "text", .{ .string = "anyone there?" });
    const raw = try protocol.serializeEnvelope(alloc, .{
        .@"type" = "dm",
        .id = "dm-miss",
        .source = "sender",
        .target = "ghost",
        .payload = .{ .object = payload_obj },
    });
    try sys.writeAll(stream, raw);
    try sys.writeAll(stream, "\n");

    var buf: [8192]u8 = undefined;
    const line = readLine(stream, &buf, 8000);
    try std.testing.expect(line != null);
    try std.testing.expect(!try envelopeOk(alloc, line.?));
    try std.testing.expect(mem.indexOf(u8, line.?, "unknown target") != null);
}

test "e2e: disconnect cleanup — agent removed from routing" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h = try startHub();
    defer stopHub(h);

    const stream = try connectAndRegister(alloc, h.port, "ephemeral");
    try std.testing.expect(waitForRegistered(h.server, "ephemeral", 2000));

    sys.close(stream);
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
    defer sys.close(stream_a);
    const stream_b = try connectAndRegister(alloc, h.port, "ch-bob");
    defer sys.close(stream_b);
    const stream_c = try connectAndRegister(alloc, h.port, "ch-carol");
    defer sys.close(stream_c);
    try std.testing.expect(waitForRegistered(h.server, "ch-carol", 2000));

    // Alice creates a channel.
    {
        var p = json.ObjectMap.empty;
        try p.put(alloc, "name", .{ .string = "test-chan" });
        try p.put(alloc, "description", .{ .string = "e2e test" });
        const env = protocol.Envelope{
            .@"type" = "channel_create",
            .id = "cc-1",
            .source = "ch-alice",
            .target = "hub",
            .payload = .{ .object = p },
        };
        const raw = try protocol.serializeEnvelope(alloc, env);

        try sys.writeAll(stream_a, raw);
        try sys.writeAll(stream_a, "\n");
        // Read success response.
        var buf: [8192]u8 = undefined;
        const resp = readLine(stream_a, &buf, 8000);
        try std.testing.expect(resp != null);
        try std.testing.expect(try envelopeOk(alloc, resp.?));
    }

    // Alice invites Bob and Carol.
    inline for (.{ "ch-bob", "ch-carol" }) |invitee| {
        var p = json.ObjectMap.empty;
        try p.put(alloc, "channel", .{ .string = "test-chan" });
        try p.put(alloc, "agent_id", .{ .string = invitee });
        const env = protocol.Envelope{
            .@"type" = "channel_invite",
            .id = "ci-" ++ invitee,
            .source = "ch-alice",
            .target = "hub",
            .payload = .{ .object = p },
        };
        const raw = try protocol.serializeEnvelope(alloc, env);

        try sys.writeAll(stream_a, raw);
        try sys.writeAll(stream_a, "\n");
        // Verify invite response has ok=true.
        var buf: [8192]u8 = undefined;
        const invite_resp = readLine(stream_a, &buf, 8000);
        try std.testing.expect(invite_resp != null);
        try std.testing.expect(try envelopeOk(alloc, invite_resp.?));
        // Verify invitee receives channel_event with "invited".
        var inv_buf: [8192]u8 = undefined;
        const inv_stream = if (mem.eql(u8, invitee, "ch-bob")) stream_b else stream_c;
        const inv_event = readLine(inv_stream, &inv_buf, 8000);
        try std.testing.expect(inv_event != null);
        try std.testing.expect(mem.indexOf(u8, inv_event.?, "\"event\":\"invited\"") != null);
        try std.testing.expect(mem.indexOf(u8, inv_event.?, "test-chan") != null);
    }

    // Alice sends a channel message.
    {
        var p = json.ObjectMap.empty;
        try p.put(alloc, "text", .{ .string = "hello channel" });
        const env = protocol.Envelope{
            .@"type" = "channel_msg",
            .id = "cm-1",
            .source = "ch-alice",
            .target = "channel:test-chan",
            .payload = .{ .object = p },
        };
        const raw = try protocol.serializeEnvelope(alloc, env);

        try sys.writeAll(stream_a, raw);
        try sys.writeAll(stream_a, "\n");

        // Bob and Carol should each receive the fan-out.
        var bob_buf: [8192]u8 = undefined;
        const bob_msg = readLine(stream_b, &bob_buf, 8000);
        try std.testing.expect(bob_msg != null);
        try std.testing.expect(mem.indexOf(u8, bob_msg.?, "hello channel") != null);

        var carol_buf: [8192]u8 = undefined;
        const carol_msg = readLine(stream_c, &carol_buf, 8000);
        try std.testing.expect(carol_msg != null);
        try std.testing.expect(mem.indexOf(u8, carol_msg.?, "hello channel") != null);

        // Alice should receive the success response (not the fan-out).
        var alice_buf: [8192]u8 = undefined;
        const alice_resp = readLine(stream_a, &alice_buf, 8000);
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
    defer sys.close(bob_stream);
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

    // Bob is nudged (RFC-0008 C-MAILBOX), then drains the hub-side
    // queue over his own connection to get the content.
    var bob_buf: [8192]u8 = undefined;
    const bob_nudge = readLine(bob_stream, &bob_buf, 8000);
    try std.testing.expect(bob_nudge != null);
    try std.testing.expect(mem.indexOf(u8, bob_nudge.?, "mail_nudge") != null);
    try sys.writeAll(bob_stream, "{\"type\":\"mailbox_recv\",\"id\":\"mr-2\",\"source\":\"bob\",\"target\":\"hub\"}\n");
    var bob_drain_buf: [8192]u8 = undefined;
    const bob_msg = readLine(bob_stream, &bob_drain_buf, 8000);
    try std.testing.expect(bob_msg != null);
    try std.testing.expect(mem.indexOf(u8, bob_msg.?, "hello from daemon") != null);

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
    defer sys.close(bob_stream);
    try std.testing.expect(waitForRegistered(h.server, "bob", 2000));

    var payload_obj = json.ObjectMap.empty;
    try payload_obj.put(alloc, "text", .{ .string = "msg for alice" });
    const raw = try protocol.serializeEnvelope(alloc, .{
        .@"type" = "dm",
        .id = "dm-to-alice",
        .source = "bob",
        .target = "alice",
        .payload = .{ .object = payload_obj },
    });
    try sys.writeAll(bob_stream, raw);
    try sys.writeAll(bob_stream, "\n");

    // Poll IPC recv until the message appears (no fixed sleep).
    {
        const deadline = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds() + 2000;
        var found = false;
        // Per-retry arena — reset each iteration so parse allocations don't accumulate.
        var retry_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer retry_arena.deinit();
        while (std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds() < deadline) {
            _ = retry_arena.reset(.retain_capacity);
            const retry_alloc = retry_arena.allocator();
            // Scoped block ensures IPC client is closed each iteration.
            {
                var client = try ipc.IpcClient.connect(server.socket_path);
                defer client.deinit();
                const req = try protocol.serializeIpcRequest(retry_alloc, .{ .action = .recv });
                try client.send(req);
                var resp_buf: [16384]u8 = undefined;
                const resp_line = try client.recv(&resp_buf);
                if (resp_line) |resp_str| {
                    // Parse the IPC data field (a JSON array of raw message strings).
                    const data = parseIpcData(retry_alloc, resp_str) catch continue;
                    if (data != .array) continue;
                    for (data.array.items) |msg_val| {
                        if (msg_val != .string) continue;
                        // Parse each queued message as an envelope.
                        const env = json.parseFromSlice(json.Value, retry_alloc, msg_val.string, .{ .allocate = .alloc_always }) catch continue;
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
            io_mod.get().sleep(std.Io.Duration.fromMilliseconds(5), .awake) catch {};
        }
        try std.testing.expect(found);
    }
}

test "e2e: wrapper survives hub restart — reconnect + durable identity re-claim (WI-2026-08-11-017)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h = try startHub();
    var h_stopped = false;
    defer if (!h_stopped) stopHub(h);
    const port = h.port;

    var server = try run.RunServer.init(alloc, "local-rcn1", "127.0.0.1", port);
    defer server.deinit();
    const threads = try server.startThreads();
    defer server.stopThreads(threads);
    try std.testing.expect(waitForRegistered(h.server, "local-rcn1", 2000));

    // Claim a durable identity through the pane daemon (RFC-0008).
    {
        var client = try ipc.IpcClient.connect(server.socket_path);
        defer client.deinit();
        const req = try protocol.serializeIpcRequest(alloc, .{
            .action = .register,
            .tool = "claude",
            .project = "reconnect-e2e",
            .resume_ref = "rcn1abcd-9999-0000",
        });
        try client.send(req);
        var resp_buf: [8192]u8 = undefined;
        _ = try client.recv(&resp_buf);
    }
    try std.testing.expect(waitForRegistered(h.server, "claude-rcn1abcd", 2000));

    // The embedded hub restarts IN PLACE on the same port.
    stopHub(h);
    h_stopped = true;
    const h2 = try startHubOn(port);
    defer stopHub(h2);

    // The wrapper reconnects with backoff, re-registers its pane id and
    // replays the cached identity claim — the DURABLE id returns under a
    // fresh generation, without pane recreation.
    try std.testing.expect(waitForRegistered(h2.server, "claude-rcn1abcd", 8000));

    // In-pane CLI works again through the same daemon socket.
    {
        var client = try ipc.IpcClient.connect(server.socket_path);
        defer client.deinit();
        const req = try protocol.serializeIpcRequest(alloc, .{ .action = .agents });
        try client.send(req);
        var resp_buf: [16384]u8 = undefined;
        const resp_line = try client.recv(&resp_buf);
        try std.testing.expect(resp_line != null);
        try std.testing.expect(mem.indexOf(u8, resp_line.?, "claude-rcn1abcd") != null);
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
    defer sys.close(bob_stream);
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
    const inv_line = readLine(bob_stream, &inv_buf, 8000);
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
    const bob_line = readLine(bob_stream, &bob_buf, 8000);
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

test "e2e: line buffering — two frames in one write are both processed" {
    // The hub's reader is line-buffered: a single TCP write carrying two
    // newline-terminated envelopes must yield two processed messages
    // (the integration test the 2026-03-28 e2e work item claims but never
    // shipped; WI-2026-08-08-022).
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h = try startHub();
    defer stopHub(h);

    // Raw client — write register + a DM in ONE write.
    const fd = try connectTcp(h.port);
    defer sys.close(fd);

    const reg = try protocol.makeRegisterEnvelope(alloc, "alice", &.{});
    const reg_raw = try protocol.serializeEnvelope(alloc, reg);
    defer alloc.free(reg_raw);

    var payload_obj = json.ObjectMap.empty;
    try payload_obj.put(alloc, "text", .{ .string = "buffered dm" });
    const dm_raw = try protocol.serializeEnvelope(alloc, .{
        .@"type" = "dm",
        .id = "dm-buf-1",
        .source = "alice",
        .target = "hub",
        .payload = .{ .object = payload_obj },
    });
    defer alloc.free(dm_raw);

    // LITERALLY one write carrying both newline-terminated frames
    // (WI-2026-08-08-034): the hub's line-buffered reader must process
    // both, including a frame split mid-buffer.
    var burst = std.ArrayList(u8).empty;
    defer burst.deinit(alloc);
    try burst.appendSlice(alloc, reg_raw);
    try burst.append(alloc, '\n');
    try burst.appendSlice(alloc, dm_raw);
    try burst.append(alloc, '\n');
    try sys.writeAll(fd, burst.items);

    // The register frame must have been processed despite sharing the
    // write with the DM frame.
    try std.testing.expect(waitForRegistered(h.server, "alice", 2000));

    // The DM frame must be processed too: read the response line and
    // assert its envelope id is dm-buf-1 — a vacuous pass (any line)
    // would not prove the DM was handled (WI-2026-08-08-034).
    var buf: [8192]u8 = undefined;
    const line = readLine(fd, &buf, 8000);
    try std.testing.expect(line != null);
    const parsed = try protocol.parseEnvelope(alloc, line.?);
    try std.testing.expectEqualStrings("dm-buf-1", parsed.value.id);
}

test "e2e: RunServer.init survives the app-start race (hub binds late)" {
    // WI-2026-08-09-025 root cause: the GUI starts its hub subprocess and
    // spawns panes concurrently, so the pane's run wrapper regularly
    // connects BEFORE the hub binds — historically masked by leftover
    // hubs already holding the port. The wrapper's bounded retry must
    // absorb this window instead of degrading the pane to a bare shell.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Reserve an ephemeral port, then FREE it so the wrapper's first
    // connect attempts hit ConnectionRefused.
    const probe = try startHub();
    const port = probe.port;
    stopHub(probe);

    const Ctx = struct {
        alloc: std.mem.Allocator,
        port: u16,
        server: ?run.RunServer = null,
        failed: bool = false,

        fn initLate(self: *@This()) void {
            self.server = run.RunServer.init(self.alloc, "late-agent", "127.0.0.1", self.port) catch {
                self.failed = true;
                return;
            };
        }
    };
    var ctx = Ctx{ .alloc = alloc, .port = port };
    const t = try std.Thread.spawn(.{}, Ctx.initLate, .{&ctx});

    // Let the wrapper burn a few refused attempts, THEN bind the hub.
    io_mod.get().sleep(std.Io.Duration.fromMilliseconds(600), .awake) catch {};
    const allocator = std.heap.page_allocator;
    const server = try allocator.create(hub.HubServer);
    server.* = try hub.HubServer.initWithAddress("127.0.0.1", port);
    try server.startBackground();
    const h = TestHub{ .server = server, .port = port };
    defer stopHub(h);

    t.join();
    try std.testing.expect(!ctx.failed);
    var rs = ctx.server.?;
    defer rs.deinit();
    // The retried connect registered the agent on the late hub.
    try std.testing.expect(waitForRegistered(h.server, "late-agent", 3000));
}

test "e2e: recv --wait BLOCKS over the pane IPC path until a dm arrives (WI-2026-08-10-001)" {
    // The bug this pins: runRecv's IPC fast path returned an empty drain
    // immediately, silently ignoring --wait — two live agents found their
    // replies landing in a mailbox nobody was watching (hub issue #2).
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h = try startHub();
    defer stopHub(h);

    const bob_stream = try connectAndRegister(alloc, h.port, "bob-blk");
    defer sys.close(bob_stream);
    try std.testing.expect(waitForRegistered(h.server, "bob-blk", 2000));

    var server = try run.RunServer.init(alloc, "alice-blk", "127.0.0.1", h.port);
    defer server.deinit();
    const threads = try server.startThreads();
    try std.testing.expect(waitForRegistered(h.server, "alice-blk", 2000));

    const Ctx = struct {
        socket_path: []const u8,
        done: std.atomic.Value(bool) = .init(false),
        got: [8 * 1024]u8 = undefined,
        got_len: usize = 0,
        failed: bool = false,

        fn waitRecv(self: *@This()) void {
            defer self.done.store(true, .release);
            var client = ipc.IpcClient.connect(self.socket_path) catch {
                self.failed = true;
                return;
            };
            defer client.deinit();
            const req = "{\"action\":\"recv\",\"wait\":true}";
            client.send(req) catch {
                self.failed = true;
                return;
            };
            var buf: [8 * 1024]u8 = undefined;
            const resp = client.recv(&buf) catch {
                self.failed = true;
                return;
            } orelse {
                self.failed = true;
                return;
            };
            self.got_len = @min(resp.len, self.got.len);
            @memcpy(self.got[0..self.got_len], resp[0..self.got_len]);
        }
    };
    var ctx = Ctx{ .socket_path = server.socket_path };
    const waiter = try std.Thread.spawn(.{}, Ctx.waitRecv, .{&ctx});

    // The waiter must still be BLOCKED with an empty queue — this is the
    // behavioral assertion the old tests lacked (they checked flag
    // parsing only, and the TCP path where --wait already worked).
    io_mod.get().sleep(std.Io.Duration.fromMilliseconds(500), .awake) catch {};
    try std.testing.expect(!ctx.done.load(.acquire));

    // bob sends a dm — the parked waiter must wake and deliver it.
    const dm = "{\"type\":\"dm\",\"id\":\"d1\",\"source\":\"bob-blk\",\"target\":\"alice-blk\",\"payload\":{\"text\":\"hello-blocking\"}}\n";
    try sys.writeAll(bob_stream, dm);

    waiter.join();
    server.stopThreads(threads);

    try std.testing.expect(!ctx.failed);
    try std.testing.expect(std.mem.indexOf(u8, ctx.got[0..ctx.got_len], "hello-blocking") != null);
}

test "e2e: daemon shutdown wakes a parked recv --wait instead of hanging (WI-2026-08-10-001)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h = try startHub();
    defer stopHub(h);

    var server = try run.RunServer.init(alloc, "alice-shut", "127.0.0.1", h.port);
    defer server.deinit();
    const threads = try server.startThreads();
    try std.testing.expect(waitForRegistered(h.server, "alice-shut", 2000));

    const Ctx = struct {
        socket_path: []const u8,
        done: std.atomic.Value(bool) = .init(false),

        fn waitRecv(self: *@This()) void {
            defer self.done.store(true, .release);
            var client = ipc.IpcClient.connect(self.socket_path) catch return;
            defer client.deinit();
            client.send("{\"action\":\"recv\",\"wait\":true}") catch return;
            var buf: [4 * 1024]u8 = undefined;
            _ = client.recv(&buf) catch return;
        }
    };
    var ctx = Ctx{ .socket_path = server.socket_path };
    const waiter = try std.Thread.spawn(.{}, Ctx.waitRecv, .{&ctx});
    io_mod.get().sleep(std.Io.Duration.fromMilliseconds(300), .awake) catch {};
    try std.testing.expect(!ctx.done.load(.acquire));

    // Shutdown must broadcast the queue closed and JOIN the parked
    // connection thread — if it hangs, this test times out (the failure).
    server.stopThreads(threads);
    waiter.join();
    try std.testing.expect(ctx.done.load(.acquire));
}

test "e2e: identity_displaced terminates a parked recv --wait with the stable error (RFC-0008 C-MAILBOX)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h = try startHub();
    defer stopHub(h);

    var server = try run.RunServer.init(alloc, "alice-disp", "127.0.0.1", h.port);
    defer server.deinit();
    const threads = try server.startThreads();
    defer server.stopThreads(threads);
    try std.testing.expect(waitForRegistered(h.server, "alice-disp", 2000));

    const Ctx = struct {
        socket_path: []const u8,
        done: std.atomic.Value(bool) = .init(false),
        got_displaced: std.atomic.Value(bool) = .init(false),

        fn waitRecv(self: *@This()) void {
            defer self.done.store(true, .release);
            var client = ipc.IpcClient.connect(self.socket_path) catch return;
            defer client.deinit();
            client.send("{\"action\":\"recv\",\"wait\":true}") catch return;
            var buf: [4 * 1024]u8 = undefined;
            const resp = client.recv(&buf) catch return;
            if (resp) |r| {
                if (mem.indexOf(u8, r, "identity displaced") != null and
                    mem.indexOf(u8, r, "\"success\":false") != null)
                {
                    self.got_displaced.store(true, .release);
                }
            }
        }
    };
    var ctx = Ctx{ .socket_path = server.socket_path };
    const waiter = try std.Thread.spawn(.{}, Ctx.waitRecv, .{&ctx});
    io_mod.get().sleep(std.Io.Duration.fromMilliseconds(300), .awake) catch {};
    try std.testing.expect(!ctx.done.load(.acquire));

    // A displacement notice lands on the daemon's signal channel (in
    // production, pushed by the hub during a re-home).
    try server.message_queue.push("{\"type\":\"identity_displaced\",\"id\":\"hub-displace\",\"source\":\"hub\",\"target\":\"local-x\"}");
    waiter.join();
    try std.testing.expect(ctx.done.load(.acquire));
    try std.testing.expect(ctx.got_displaced.load(.acquire));
}

// ---------------------------------------------------------------------------
// [[RFC-0009]] hub federation — two hubs, one relay link
// ---------------------------------------------------------------------------

/// Poll until `identity` shows up in `server`'s peer directory.
fn waitForDirectory(server: *hub.HubServer, identity: []const u8, timeout_ms: u64) bool {
    const deadline = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds() + @as(i64, @intCast(timeout_ms));
    while (std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds() < deadline) {
        if (server.state.directory.lookup(identity) != null) return true;
        io_mod.get().sleep(std.Io.Duration.fromMilliseconds(2), .awake) catch {};
    }
    return false;
}

fn waitForMail(server: *hub.HubServer, identity: []const u8, want: usize, timeout_ms: u64) bool {
    const deadline = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds() + @as(i64, @intCast(timeout_ms));
    while (std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds() < deadline) {
        if (server.state.mailbox.count(identity) >= want) return true;
        io_mod.get().sleep(std.Io.Duration.fromMilliseconds(2), .awake) catch {};
    }
    return false;
}

test "e2e RFC-0009: two hubs federate — forward, spool on outage, flush in order, local A2A never stops" {
    std.testing.log_level = .err;
    var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup_arena.deinit();
    const alloc = setup_arena.allocator();

    var hub_a = try startHub();
    defer stopHub(hub_a);
    var hub_b = try startHub();
    defer stopHub(hub_b);

    try hub_a.server.state.setPeerId("alpha");
    try hub_b.server.state.setPeerId("beta");

    // One agent on each machine, plus a second on A so local A2A has
    // somewhere to go while the link is down.
    const a1 = try connectAndRegister(alloc, hub_a.port, "claude-alpha001");
    defer sys.close(a1);
    const a2 = try connectAndRegister(alloc, hub_a.port, "claude-alpha002");
    defer sys.close(a2);
    const b1 = try connectAndRegister(alloc, hub_b.port, "claude-beta0001");
    defer sys.close(b1);
    try std.testing.expect(waitForRegistered(hub_a.server, "claude-alpha001", 5000));
    try std.testing.expect(waitForRegistered(hub_b.server, "claude-beta0001", 5000));

    // A dials B. In production `port` is the local end of the SSH tunnel
    // the human already established — there is no separate credential.
    const link1 = try std.Thread.spawn(.{}, hub.peer.dialAndServe, .{
        hub.peer.DialArgs{ .state = &hub_a.server.state, .port = hub_b.port },
    });

    // Directory exchange in BOTH directions: each hub advertises the full
    // set on connect, so a fresh link starts consistent.
    try std.testing.expect(waitForDirectory(hub_a.server, "claude-beta0001", 8000));
    try std.testing.expect(waitForDirectory(hub_b.server, "claude-alpha001", 8000));

    // Cross-hub delivery: A forwards, B queues it in ITS mailbox.
    const fwd = try hub_a.server.state.mailboxDeliver("claude-beta0001", "x1", "{\"msg\":\"across\"}", .submitted);
    try std.testing.expectEqual(hub.federation.DeliveryOutcome.forwarded, fwd.outcome);
    try std.testing.expect(waitForMail(hub_b.server, "claude-beta0001", 1, 8000));

    // --- the link drops -------------------------------------------------
    hub_b.server.state.closeAllPeerLinks();
    link1.join();

    // The entry is TOMBSTONED, not discarded — which is the only reason
    // the next send can name a peer to spool toward.
    const entry = hub_a.server.state.directory.lookup("claude-beta0001").?;
    try std.testing.expect(!entry.reachable);
    try std.testing.expectEqualStrings("beta", entry.peer);

    const s1 = try hub_a.server.state.mailboxDeliver("claude-beta0001", "x2", "{\"n\":2}", .submitted);
    try std.testing.expectEqual(hub.federation.DeliveryOutcome.spooled, s1.outcome);
    const s2 = try hub_a.server.state.mailboxDeliver("claude-beta0001", "x3", "{\"n\":3}", .submitted);
    try std.testing.expectEqual(hub.federation.DeliveryOutcome.spooled, s2.outcome);
    try std.testing.expectEqual(@as(usize, 2), hub_a.server.state.spool.count("beta"));

    // An unrelated id is now INDETERMINATE, not unknown: with a peer
    // unreachable this hub cannot tell a typo from an identity it cannot
    // see, and answering "unknown" would turn a partition into a
    // permanent-looking error the sender would act on.
    const guess = try hub_a.server.state.mailboxDeliver("claude-whoknows", "x4", "{}", .submitted);
    try std.testing.expectEqual(hub.federation.DeliveryOutcome.unknown, guess.outcome);

    // THE PROPERTY THE WHOLE ARCHITECTURE EXISTS FOR: local A2A on each
    // hub keeps working throughout the outage.
    const local_a = try hub_a.server.state.mailboxDeliver("claude-alpha002", "x5", "{\"local\":true}", .submitted);
    try std.testing.expectEqual(hub.federation.DeliveryOutcome.delivered, local_a.outcome);
    const local_b = try hub_b.server.state.mailboxDeliver("claude-beta0001", "x6", "{\"local\":true}", .submitted);
    try std.testing.expectEqual(hub.federation.DeliveryOutcome.delivered, local_b.outcome);

    // --- reconnect ------------------------------------------------------
    const link2 = try std.Thread.spawn(.{}, hub.peer.dialAndServe, .{
        hub.peer.DialArgs{ .state = &hub_a.server.state, .port = hub_b.port },
    });
    // 1 forwarded + 1 local + 2 spooled = 4 in B's mailbox once flushed.
    try std.testing.expect(waitForMail(hub_b.server, "claude-beta0001", 4, 10000));
    try std.testing.expectEqual(@as(usize, 0), hub_a.server.state.spool.count("beta"));

    // Flush ORDER: spooled traffic precedes new traffic, so the sender's
    // earlier message is never overtaken by its later one.
    const mail = try hub_b.server.state.mailbox.drainInto(alloc, "claude-beta0001");
    try std.testing.expectEqual(@as(usize, 4), mail.len);
    try std.testing.expect(mem.indexOf(u8, mail[2], "\"n\":2") != null);
    try std.testing.expect(mem.indexOf(u8, mail[3], "\"n\":3") != null);

    hub_b.server.state.closeAllPeerLinks();
    link2.join();
}

// ---------------------------------------------------------------------------
// [[ADR-0008]] decision 6 — task tools execute at the WORKBENCH
// ---------------------------------------------------------------------------

/// Open a subscriber connection, standing in for the workbench.
fn connectSubscriber(allocator: Allocator, port: u16) !sys.fd_t {
    const fd = try connectTcp(port);
    errdefer sys.close(fd);
    const raw = try protocol.serializeEnvelope(allocator, .{
        .@"type" = "subscribe",
        .id = "sub-0",
        .source = "workbench",
        .target = "",
        .payload = .null,
    });
    try sys.writeAll(fd, raw);
    try sys.writeAll(fd, "\n");
    return fd;
}

test "e2e ADR-0008: tool_request round-trips hub -> workbench -> agent, and fails fast with no workbench" {
    std.testing.log_level = .err;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var h = try startHub();
    defer stopHub(h);

    const agent = try connectAndRegister(alloc, h.port, "claude-tooltest");
    defer sys.close(agent);
    try std.testing.expect(waitForRegistered(h.server, "claude-tooltest", 1000));

    // --- no workbench: FAIL FAST, never queue --------------------------
    // A task claimed hours after it was asked for is worse than a
    // refusal, because the world has moved on. This is deliberately the
    // opposite of the mailbox rule.
    const req_raw = try protocol.serializeEnvelope(alloc, .{
        .@"type" = "tool_request",
        .id = "t-1",
        .source = "claude-tooltest",
        .target = "",
        .payload = blk: {
            var p = json.ObjectMap.empty;
            try p.put(alloc, "tool", .{ .string = "task.list" });
            break :blk .{ .object = p };
        },
    });
    try sys.writeAll(agent, req_raw);
    try sys.writeAll(agent, "\n");

    var buf: [64 * 1024]u8 = undefined;
    const refusal = readLine(agent, &buf, 8000) orelse return error.NoRefusal;
    try std.testing.expect(mem.indexOf(u8, refusal, "no workbench available") != null);

    // --- with a workbench: forwarded, executed there, routed back ------
    const wb = try connectSubscriber(alloc, h.port);
    defer sys.close(wb);
    // Drain the snapshot so the next line we read is the forwarded frame.
    var wb_buf: [64 * 1024]u8 = undefined;
    _ = readLine(wb, &wb_buf, 8000) orelse return error.NoSnapshot;

    const req2 = try protocol.serializeEnvelope(alloc, .{
        .@"type" = "tool_request",
        .id = "t-2",
        .source = "claude-tooltest",
        .target = "",
        .payload = blk: {
            var p = json.ObjectMap.empty;
            try p.put(alloc, "tool", .{ .string = "task.claim" });
            var a = json.ObjectMap.empty;
            try a.put(alloc, "number", .{ .integer = 7 });
            try p.put(alloc, "args", .{ .object = a });
            break :blk .{ .object = p };
        },
    });
    try sys.writeAll(agent, req2);
    try sys.writeAll(agent, "\n");

    // The workbench sees the forwarded control frame. Events also flow on
    // this connection, so skip anything that is not ours.
    const forwarded = blk: {
        var attempts: usize = 0;
        while (attempts < 40) : (attempts += 1) {
            const line = readLine(wb, &wb_buf, 8000) orelse return error.NoForward;
            const parsed = json.parseFromSliceLeaky(json.Value, alloc, line, .{}) catch continue;
            if (parsed != .object) continue;
            const t = parsed.object.get("type") orelse continue;
            if (t == .string and mem.eql(u8, t.string, "tool_request")) break :blk parsed;
        }
        return error.NoForward;
    };
    const fwd_payload = forwarded.object.get("payload").?.object;
    try std.testing.expectEqualStrings("task.claim", fwd_payload.get("tool").?.string);
    try std.testing.expectEqualStrings("claude-tooltest", fwd_payload.get("requester").?.string);
    try std.testing.expectEqualStrings("t-2", fwd_payload.get("request_id").?.string);
    // The args survive the hop — the executor gets what the agent asked for.
    try std.testing.expectEqual(@as(i64, 7), fwd_payload.get("args").?.object.get("number").?.integer);

    // The workbench answers on a one-shot tool_receipt, as it would after
    // running `synapty tools exec`.
    const rcpt_fd = try connectTcp(h.port);
    defer sys.close(rcpt_fd);
    const rcpt = try protocol.serializeEnvelope(alloc, .{
        .@"type" = "tool_receipt",
        .id = "tool-rcpt",
        .source = "workbench",
        .target = "",
        .payload = blk: {
            var p = json.ObjectMap.empty;
            try p.put(alloc, "request_id", .{ .string = "t-2" });
            try p.put(alloc, "requester", .{ .string = "claude-tooltest" });
            try p.put(alloc, "ok", .{ .bool = true });
            var d = json.ObjectMap.empty;
            try d.put(alloc, "number", .{ .integer = 7 });
            try d.put(alloc, "state", .{ .string = "open" });
            try p.put(alloc, "data", .{ .object = d });
            break :blk .{ .object = p };
        },
    });
    try sys.writeAll(rcpt_fd, rcpt);
    try sys.writeAll(rcpt_fd, "\n");

    // ...and the agent gets its answer, under its ORIGINAL request id.
    const answer = blk: {
        var attempts: usize = 0;
        while (attempts < 40) : (attempts += 1) {
            const line = readLine(agent, &buf, 3000) orelse return error.NoToolResponse;
            const parsed = json.parseFromSliceLeaky(json.Value, alloc, line, .{}) catch continue;
            if (parsed != .object) continue;
            const t = parsed.object.get("type") orelse continue;
            if (t == .string and mem.eql(u8, t.string, "tool_response")) break :blk parsed;
        }
        return error.NoToolResponse;
    };
    try std.testing.expectEqualStrings("t-2", answer.object.get("id").?.string);
    const ap = answer.object.get("payload").?.object;
    try std.testing.expect(ap.get("ok").?.bool);
    try std.testing.expectEqual(@as(i64, 7), ap.get("data").?.object.get("number").?.integer);

    // Nothing is left parked: a routed response releases its slot, or the
    // bound would fill with connections nobody is waiting on.
    try std.testing.expectEqual(@as(usize, 0), h.server.state.pending_tools.count());
}

test "e2e WI-2026-08-12-008: peer_connect makes the local hub dial its peer" {
    // Stands in for the real path: setup-host.sh brings up a hub on the
    // remote machine and an SSH -L forward to it, then the workbench tells
    // its LOCAL hub the loopback port that reaches the peer. Here the
    // "tunnel" is simply the second hub's own port, which is exactly what
    // the forward would resolve to.
    std.testing.log_level = .err;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var local = try startHub();
    defer stopHub(local);
    var remote = try startHub();
    defer stopHub(remote);
    try remote.server.state.setPeerId("remotehost");

    const remote_agent = try connectAndRegister(alloc, remote.port, "claude-remote001");
    defer sys.close(remote_agent);
    try std.testing.expect(waitForRegistered(remote.server, "claude-remote001", 1000));

    // The workbench's one-shot: "dial the peer at this loopback port, and
    // here is the name to introduce yourself by."
    const fd = try connectTcp(local.port);
    defer sys.close(fd);
    const raw = try protocol.serializeEnvelope(alloc, .{
        .@"type" = "peer_connect",
        .id = "pc-1",
        .source = "workbench",
        .target = "",
        .payload = blk: {
            var p = json.ObjectMap.empty;
            try p.put(alloc, "port", .{ .integer = @intCast(remote.port) });
            try p.put(alloc, "self_peer_id", .{ .string = "laptop" });
            break :blk .{ .object = p };
        },
    });
    try sys.writeAll(fd, raw);
    try sys.writeAll(fd, "\n");
    var buf: [8192]u8 = undefined;
    const ack = readLine(fd, &buf, 8000) orelse return error.NoPeerConnectAck;
    try std.testing.expect(try envelopeOk(alloc, ack));

    // The remote agent becomes addressable from the local hub — the whole
    // point of stage 3b, since it is no longer registered here.
    try std.testing.expect(waitForDirectory(local.server, "claude-remote001", 3000));
    const sent = try local.server.state.mailboxDeliver("claude-remote001", "x1", "{\"msg\":\"cross\"}", .submitted);
    try std.testing.expectEqual(hub.federation.DeliveryOutcome.forwarded, sent.outcome);
    try std.testing.expect(waitForMail(remote.server, "claude-remote001", 1, 2000));

    // A peer_connect without a port is refused rather than dialing
    // something arbitrary.
    const bad_fd = try connectTcp(local.port);
    defer sys.close(bad_fd);
    const bad = try protocol.serializeEnvelope(alloc, .{
        .@"type" = "peer_connect",
        .id = "pc-2",
        .source = "workbench",
        .target = "",
        .payload = .{ .object = json.ObjectMap.empty },
    });
    try sys.writeAll(bad_fd, bad);
    try sys.writeAll(bad_fd, "\n");
    const bad_ack = readLine(bad_fd, &buf, 8000) orelse return error.NoRefusal;
    try std.testing.expect(mem.indexOf(u8, bad_ack, "invalid port") != null);

    local.server.state.closeAllPeerLinks();
}

test "e2e WI-2026-08-12-009: a status change on one machine becomes visible on the other" {
    std.testing.log_level = .err;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var local = try startHub();
    defer stopHub(local);
    var remote = try startHub();
    defer stopHub(remote);
    try local.server.state.setPeerId("laptop");
    try remote.server.state.setPeerId("remotehost");

    const ra = try connectAndRegister(alloc, remote.port, "claude-remote001");
    defer sys.close(ra);
    try std.testing.expect(waitForRegistered(remote.server, "claude-remote001", 1000));

    // A status that predates the link: the link-up sweep must carry it,
    // or a waiting agent stays `unknown` on the peer until it moves — and
    // for a waiting agent that may be never.
    _ = try remote.server.state.applyStatusSignal("claude-remote001", .explicit, .waiting);

    const link = try std.Thread.spawn(.{}, hub.peer.dialAndServe, .{
        hub.peer.DialArgs{ .state = &local.server.state, .port = remote.port },
    });
    try std.testing.expect(waitForDirectory(local.server, "claude-remote001", 2000));

    // Relayed presence lands as a LOCAL event of a distinct kind — never
    // agent_status_changed, which would claim this hub observed evidence
    // it never saw (C-PRESENCE).
    try std.testing.expect(waitForRelayedStatus(local.server, "claude-remote001", .waiting, 3000));

    // ...and a later change propagates on its own edge.
    _ = try remote.server.state.applyStatusSignal("claude-remote001", .explicit, .working);
    try std.testing.expect(waitForRelayedStatus(local.server, "claude-remote001", .working, 3000));

    remote.server.state.closeAllPeerLinks();
    link.join();
}

/// Poll the local hub's event log for a relayed status conclusion.
fn waitForRelayedStatus(
    server: *hub.HubServer,
    identity: []const u8,
    want: protocol.Status,
    timeout_ms: u64,
) bool {
    const deadline = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds() + @as(i64, @intCast(timeout_ms));
    while (std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds() < deadline) {
        var latest: ?protocol.Status = null;
        for (server.state.event_log.entries.items) |e| {
            if (e.kind != .peer_presence_relayed) continue;
            if (!mem.eql(u8, e.agent, identity)) continue;
            latest = e.new_state;
        }
        if (latest) |s| {
            if (s == want) return true;
        }
        io_mod.get().sleep(std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
    return false;
}

test "e2e WI-2026-08-12-016: a peer lacking a capability still links; the behaviour is withheld" {
    // End to end, and NOT framed as "an old peer": a peer may lack any
    // capability for any reason, and after [[RFC-0010]] a hub
    // that omits the declaration entirely is refused rather than assumed
    // old. What is permanent is that a MISSING capability withholds a
    // behaviour without costing the link — a peer that cannot relay
    // presence is still worth exchanging mail with.
    std.testing.log_level = .err;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var local = try startHub();
    defer stopHub(local);
    var remote = try startHub();
    defer stopHub(remote);
    try local.server.state.setPeerId("laptop-0001");
    try remote.server.state.setPeerId("oldbuild-0001");

    const ra = try connectAndRegister(alloc, remote.port, "claude-remote001");
    defer sys.close(ra);
    try std.testing.expect(waitForRegistered(remote.server, "claude-remote001", 1000));

    const link = try std.Thread.spawn(.{}, hub.peer.dialAndServe, .{
        hub.peer.DialArgs{ .state = &local.server.state, .port = remote.port },
    });
    try std.testing.expect(waitForDirectory(local.server, "claude-remote001", 2000));

    // Both sides run this build, so both declare presence relay — what
    // matters is that the NEGOTIATED set is recorded per link, not
    // assumed from the build.
    {
        local.server.state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer local.server.state.presence_mutex.unlock(io_mod.get());
        const l = local.server.state.peer_links.get("oldbuild-0001").?;
        try std.testing.expect(l.caps.has(.presence_relay));
        try std.testing.expectEqual(hub.federation.protocol_max, l.version);
    }

    // Now the case directly: strip the capability from the
    // link and confirm a status change does NOT go out, while mail still
    // crosses. This is the assertion that would have caught the original
    // defect from the sending side.
    {
        local.server.state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer local.server.state.presence_mutex.unlock(io_mod.get());
        local.server.state.peer_links.getPtr("oldbuild-0001").?.caps = .{};
    }
    const sent = try local.server.state.mailboxDeliver("claude-remote001", "m1", "{\"msg\":\"still works\"}", .submitted);
    try std.testing.expectEqual(hub.federation.DeliveryOutcome.forwarded, sent.outcome);
    try std.testing.expect(waitForMail(remote.server, "claude-remote001", 1, 2000));

    remote.server.state.closeAllPeerLinks();
    link.join();
}

test "e2e C-BOUNDARIES: a real envelope survives the relay, and a forged origin does not" {
    // THE COVERAGE GAP THIS CLOSES. Every other federation e2e forwards an
    // opaque stub — `{"msg":"across"}` and friends — so the whole suite was
    // blind to anything about envelope CONTENT. That is precisely why a
    // missing origin check survived: the relay path was well covered for
    // routing and completely uncovered for attribution, and the two are
    // different questions. Discovered when adding the check turned three
    // of those tests red for a reason that had nothing to do with the bug.
    std.testing.log_level = .err;
    var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup_arena.deinit();
    const alloc = setup_arena.allocator();

    var hub_a = try startHub();
    defer stopHub(hub_a);
    var hub_b = try startHub();
    defer stopHub(hub_b);
    try hub_a.server.state.setPeerId("alpha");
    try hub_b.server.state.setPeerId("beta");

    const a1 = try connectAndRegister(alloc, hub_a.port, "claude-alpha001");
    defer sys.close(a1);
    const b1 = try connectAndRegister(alloc, hub_b.port, "claude-beta0001");
    defer sys.close(b1);
    try std.testing.expect(waitForRegistered(hub_b.server, "claude-beta0001", 1000));

    const link = try std.Thread.spawn(.{}, hub.peer.dialAndServe, .{
        hub.peer.DialArgs{ .state = &hub_a.server.state, .port = hub_b.port },
    });
    try std.testing.expect(waitForDirectory(hub_a.server, "claude-beta0001", 2000));
    try std.testing.expect(waitForDirectory(hub_b.server, "claude-alpha001", 2000));

    // A REAL envelope, with a real source, forwarded over the real link.
    const honest =
        "{\"type\":\"dm\",\"id\":\"e1\",\"source\":\"claude-alpha001\"," ++
        "\"target\":\"claude-beta0001\",\"payload\":{\"text\":\"hello\"}}";
    const fwd = try hub_a.server.state.mailboxDeliver("claude-beta0001", "e1", honest, .submitted);
    try std.testing.expectEqual(hub.federation.DeliveryOutcome.forwarded, fwd.outcome);
    try std.testing.expect(waitForMail(hub_b.server, "claude-beta0001", 1, 2000));

    // The attribution has to SURVIVE the crossing, not merely the routing.
    {
        hub_b.server.state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer hub_b.server.state.presence_mutex.unlock(io_mod.get());
        const q = hub_b.server.state.mailbox.map.get("claude-beta0001").?;
        try std.testing.expect(mem.indexOf(u8, q.items[0], "claude-alpha001") != null);
    }

    // Now the forgery: alpha's hub relays a frame claiming one of BETA's
    // OWN agents as the sender. Routing-wise it is impeccable — the target
    // really does live on beta — so only the origin rule can refuse it.
    const forged =
        "{\"type\":\"dm\",\"id\":\"e2\",\"source\":\"claude-beta0001\"," ++
        "\"target\":\"claude-beta0001\",\"payload\":{\"text\":\"from your neighbour\"}}";
    _ = hub_a.server.state.directoryAdvertise("beta", "claude-beta0001") catch {};
    var payload = json.ObjectMap.empty;
    try payload.put(alloc, "raw", .{ .string = forged });
    {
        hub_a.server.state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer hub_a.server.state.presence_mutex.unlock(io_mod.get());
        if (hub_a.server.state.peer_links.get("beta")) |pl| {
            try pl.conn.enqueueEnvelope(alloc, .{
                .@"type" = "relay_forward",
                .id = "e2",
                .source = "alpha",
                .target = "claude-beta0001",
                .payload = .{ .object = payload },
            });
        } else return error.NoPeerLink;
    }

    // Give it as long as the honest one took, then assert nothing arrived.
    var waited: usize = 0;
    while (waited < 1000) : (waited += 50) {
        io_mod.get().sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    }
    {
        hub_b.server.state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer hub_b.server.state.presence_mutex.unlock(io_mod.get());
        try std.testing.expectEqual(
            @as(usize, 1),
            hub_b.server.state.mailbox.count("claude-beta0001"),
        );
    }

    hub_a.server.state.closeAllPeerLinks();
    link.join();
}

test "e2e: a duplicate registration does not take the hub down when either connection leaves" {
    // [[WI-2026-08-17-005]]. Two connections under one name is not exotic:
    // a human's typo, a reconnect that races its predecessor, a script
    // that reuses a name. The hub is one per machine, so a crash here
    // takes A2A down for everything on the box.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h = try startHub();
    defer stopHub(h);

    const first = try connectAndRegister(alloc, h.port, "twin");
    try std.testing.expect(waitForRegistered(h.server, "twin", 2000));

    // The second registration displaces the first, which the hub answers
    // by interrupting the first connection's stream.
    const second = try connectAndRegister(alloc, h.port, "twin");
    io_mod.get().sleep(std.Io.Duration.fromMilliseconds(200), .awake) catch {};

    // The displaced connection goes away. Its teardown must not remove
    // the entry that now belongs to the second connection, and — the
    // defect this test exists for — must not leave the routing table
    // holding a name whose memory belonged to it.
    sys.close(first);
    io_mod.get().sleep(std.Io.Duration.fromMilliseconds(300), .awake) catch {};
    try std.testing.expect(waitForRegistered(h.server, "twin", 2000));

    // Now the survivor leaves. This is where the hub aborted.
    sys.close(second);
    try std.testing.expect(waitForUnregistered(h.server, "twin", 3000));

    // Still serving: a fresh registration works afterwards.
    const third = try connectAndRegister(alloc, h.port, "after-twins");
    defer sys.close(third);
    try std.testing.expect(waitForRegistered(h.server, "after-twins", 2000));
}

test "thirty probe connections leave no reader threads behind (WI-2026-09-02-015)" {
    const th = try startHub();
    defer stopHub(th);
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
        const addr4 = try std.Io.net.Ip4Address.parse("127.0.0.1", th.port);
        const sa = sys.sockaddr_in.init(@bitCast(addr4.bytes), th.port);
        try sys.connect(fd, &sa, @sizeOf(sys.sockaddr_in));
        sys.close(fd);
    }
    // ZERO, AND STILL ZERO. The accept loop can lag the thirty closes, so
    // a reader spawned after a momentary zero would fail an assertion made
    // on that zero; the count has to hold for a stretch before it counts
    // ([[WI-2026-09-02-036]]).
    var tries: usize = 0;
    var quiet: usize = 0;
    while (quiet < 20 and tries < 500) : (tries += 1) {
        quiet = if (th.server.liveReaderThreads() == 0) quiet + 1 else 0;
        io_mod.get().sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 0), th.server.liveReaderThreads());
}
