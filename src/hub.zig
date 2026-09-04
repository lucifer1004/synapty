const std = @import("std");
const io_mod = @import("io");
const json = std.json;
const protocol = @import("protocol");

// ---------------------------------------------------------------------------
// Sub-module re-exports
// ---------------------------------------------------------------------------

pub const Connection = @import("hub/connection.zig").Connection;
/// Running a hub as a service: port ladder, discovery file, supervision
/// ([[ADR-0008]]). Re-exported so the CLI entry point can reach it
/// without importing module-internal files directly.
pub const service = @import("hub/service.zig");
pub const handlers = @import("hub/handlers.zig");
pub const state_store = @import("hub/state_store.zig");
/// [[RFC-0009]] peer directory, forwarding spool, delivery vocabulary.
pub const federation = @import("hub/federation.zig");
/// [[RFC-0009]] outbound relay link (the dialing half of a peer link).
pub const peer = @import("hub/peer.zig");
/// [[RFC-0010]] C-PEER-IDENTITY: this machine's minted, persisted name.
pub const identity_store = @import("hub/identity_store.zig");
pub const HubServer = @import("hub/server.zig").HubServer;
pub const HubState = @import("hub/registry.zig").HubState;

// Pull in tests from sub-modules.
comptime {
    _ = @import("hub/connection.zig");
    _ = @import("hub/session.zig");
    _ = @import("hub/registry.zig");
    _ = @import("hub/handlers.zig");
    _ = @import("hub/server.zig");
    _ = @import("hub/events.zig");
    _ = @import("hub/service.zig");
    _ = @import("hub/state_store.zig");
    _ = @import("hub/federation.zig");
    _ = @import("hub/peer.zig");
    _ = @import("hub/identity_store.zig");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "HubServer.init succeeds and listener is bound" {
    // Ephemeral port (WI-2026-08-09-023 drive-by): the old default-port
    // init made this test fail whenever a real hub (the running GUI's)
    // held 9000 — the NORMAL state of a dev machine.
    var server = try HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();

    // Verify the listener is bound by checking its address port is non-zero.
    try std.testing.expect(server.bound_port != 0);
}

test "HubServer.registeredAgents returns empty list initially" {
    var server = try HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();

    const agents = try server.registeredAgents(std.testing.allocator);
    defer std.testing.allocator.free(agents);

    try std.testing.expectEqual(@as(usize, 0), agents.len);
}

// ---------------------------------------------------------------------------
// E2E: subscribe → snapshot → pushed presence events (RFC-0004)
// ---------------------------------------------------------------------------

const sys = @import("sys");

/// Connect a test client to the hub's loopback port.
fn testConnect(port: u16) !sys.fd_t {
    const fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    errdefer sys.close(fd);
    const addr4 = try std.Io.net.Ip4Address.parse("127.0.0.1", port);
    const sa = sys.sockaddr_in.init(@bitCast(addr4.bytes), port);
    try sys.connect(fd, &sa, @sizeOf(sys.sockaddr_in));
    // Receive timeout so a broken push FAILS the test instead of hanging.
    const timeout = std.posix.timeval{ .sec = 5, .usec = 0 };
    try std.posix.setsockopt(fd, sys.SOL.SOCKET, sys.SO.RCVTIMEO, std.mem.asBytes(&timeout));
    return fd;
}

/// Read newline-delimited frames until `needle` appears in one, returning
/// that full line (allocated). Bounded by the socket receive timeout.
fn readLineContaining(alloc: std.mem.Allocator, fd: sys.fd_t, buf: []u8, fill: *usize, needle: []const u8) ![]u8 {
    while (true) {
        // Scan buffered content for a complete line first.
        while (std.mem.indexOfScalar(u8, buf[0..fill.*], '\n')) |nl| {
            const line = try alloc.dupe(u8, buf[0..nl]);
            std.mem.copyForwards(u8, buf, buf[nl + 1 .. fill.*]);
            fill.* -= nl + 1;
            if (std.mem.indexOf(u8, line, needle) != null) return line;
            alloc.free(line);
        }
        const n = try sys.read(fd, buf[fill.*..]);
        if (n == 0) return error.EndOfStream;
        fill.* += n;
    }
}

test "subscribe delivers snapshot, then registered/status/unregistered events (RFC-0004 C-SUBSCRIPTION)" {
    var server = try HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();
    try server.startBackground();

    const alloc = std.testing.allocator;
    var buf: [16 * 1024]u8 = undefined;
    var fill: usize = 0;

    // Subscriber connects first and receives an EMPTY snapshot at seq 0.
    const sub_fd = try testConnect(server.bound_port);
    defer sys.close(sub_fd);
    try sys.writeAll(sub_fd, "{\"type\":\"subscribe\",\"id\":\"s1\",\"source\":\"gui\",\"target\":\"\"}\n");
    const snapshot = try readLineContaining(alloc, sub_fd, &buf, &fill, "\"agents\"");
    defer alloc.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"agents\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"seq\":0") != null);

    // Agent connects: register + explicit waiting signal.
    const ag_fd = try testConnect(server.bound_port);
    try sys.writeAll(ag_fd, "{\"type\":\"register\",\"id\":\"r1\",\"source\":\"agent-e2e\",\"target\":\"\"}\n");
    try sys.writeAll(ag_fd, "{\"type\":\"agent_status\",\"id\":\"n1\",\"source\":\"agent-e2e\",\"target\":\"\",\"payload\":{\"state\":\"waiting\"}}\n");

    // The subscriber sees the registration (generation = creating seq = 1)
    // and the status change, in log order, without any polling.
    const reg_ev = try readLineContaining(alloc, sub_fd, &buf, &fill, "agent_registered");
    defer alloc.free(reg_ev);
    try std.testing.expect(std.mem.indexOf(u8, reg_ev, "\"agent\":\"agent-e2e\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reg_ev, "\"generation\":1") != null);

    const st_ev = try readLineContaining(alloc, sub_fd, &buf, &fill, "agent_status_changed");
    defer alloc.free(st_ev);
    try std.testing.expect(std.mem.indexOf(u8, st_ev, "\"old\":\"unknown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, st_ev, "\"new\":\"waiting\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, st_ev, "\"class\":\"explicit\"") != null);

    // Agent disconnect ends the generation: agent_unregistered is pushed.
    sys.close(ag_fd);
    const unreg_ev = try readLineContaining(alloc, sub_fd, &buf, &fill, "agent_unregistered");
    defer alloc.free(unreg_ev);
    try std.testing.expect(std.mem.indexOf(u8, unreg_ev, "\"agent\":\"agent-e2e\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, unreg_ev, "\"generation\":1") != null);
}

test "anonymous one-shot agent_status carries the workbench idle transition (RFC-0004 C-OWNERSHIP)" {
    var server = try HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();
    try server.startBackground();

    const alloc = std.testing.allocator;
    var buf: [16 * 1024]u8 = undefined;
    var fill: usize = 0;

    // Agent registers and reports done (attention-worthy).
    const ag_fd = try testConnect(server.bound_port);
    defer sys.close(ag_fd);
    try sys.writeAll(ag_fd, "{\"type\":\"register\",\"id\":\"r1\",\"source\":\"agent-gz\",\"target\":\"\"}\n");
    try sys.writeAll(ag_fd, "{\"type\":\"agent_status\",\"id\":\"n1\",\"source\":\"agent-gz\",\"target\":\"\",\"payload\":{\"state\":\"done\"}}\n");
    {
        var abuf: [4096]u8 = undefined;
        var afill: usize = 0;
        alloc.free(try readLineContaining(alloc, ag_fd, &abuf, &afill, "\"accepted\":true"));
    }

    // The workbench (anonymous, unregistered) asserts the gaze transition
    // as its FIRST message — no register, no routing churn.
    const wb_fd = try testConnect(server.bound_port);
    defer sys.close(wb_fd);
    try sys.writeAll(wb_fd, "{\"type\":\"agent_status\",\"id\":\"g1\",\"source\":\"workbench\",\"target\":\"\",\"payload\":{\"state\":\"idle\",\"class\":\"explicit\",\"agent\":\"agent-gz\"}}\n");
    const resp = try readLineContaining(alloc, wb_fd, &buf, &fill, "\"accepted\"");
    defer alloc.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"accepted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"status\":\"idle\"") != null);

    // Conditional acceptance: a second idle (prior is now idle, not done)
    // must be INERT (C-PRECEDENCE rule 1).
    const wb2_fd = try testConnect(server.bound_port);
    defer sys.close(wb2_fd);
    var fill2: usize = 0;
    try sys.writeAll(wb2_fd, "{\"type\":\"agent_status\",\"id\":\"g2\",\"source\":\"workbench\",\"target\":\"\",\"payload\":{\"state\":\"idle\",\"class\":\"explicit\",\"agent\":\"agent-gz\"}}\n");
    const resp2 = try readLineContaining(alloc, wb2_fd, &buf, &fill2, "\"accepted\"");
    defer alloc.free(resp2);
    try std.testing.expect(std.mem.indexOf(u8, resp2, "\"accepted\":false") != null);
}

test "late subscriber snapshot carries current agents, statuses, and generations" {
    var server = try HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();
    try server.startBackground();

    const alloc = std.testing.allocator;
    var buf: [16 * 1024]u8 = undefined;
    var fill: usize = 0;

    // Agent registers, reports metadata + status BEFORE anyone subscribes.
    const ag_fd = try testConnect(server.bound_port);
    defer sys.close(ag_fd);
    try sys.writeAll(ag_fd, "{\"type\":\"register\",\"id\":\"r1\",\"source\":\"agent-late\",\"target\":\"\"}\n");
    try sys.writeAll(ag_fd, "{\"type\":\"agent_update\",\"id\":\"u1\",\"source\":\"agent-late\",\"target\":\"\",\"payload\":{\"tool\":\"codex\"}}\n");
    try sys.writeAll(ag_fd, "{\"type\":\"agent_status\",\"id\":\"n1\",\"source\":\"agent-late\",\"target\":\"\",\"payload\":{\"state\":\"working\"}}\n");
    // Wait for the hub to process (the agent_status response confirms it).
    {
        var abuf: [4096]u8 = undefined;
        var afill: usize = 0;
        const resp = try readLineContaining(alloc, ag_fd, &abuf, &afill, "\"accepted\":true");
        alloc.free(resp);
    }

    // Late subscriber: snapshot must already contain the full picture —
    // this is what "covers truncation" means (C-EVENT-LOG V1 bounds).
    const sub_fd = try testConnect(server.bound_port);
    defer sys.close(sub_fd);
    try sys.writeAll(sub_fd, "{\"type\":\"subscribe\",\"id\":\"s1\",\"source\":\"gui\",\"target\":\"\"}\n");
    const snapshot = try readLineContaining(alloc, sub_fd, &buf, &fill, "\"agents\"");
    defer alloc.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"id\":\"agent-late\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"tool\":\"codex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"status\":\"working\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"generation\":1") != null);
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

    var obj = std.json.ObjectMap.empty;
    try obj.put(alloc, "agents", .{ .array = arr });

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

test {
    // identity.zig is reached only as a type source; referencing every
    // declaration is what collects its tests.
    std.testing.refAllDecls(@import("hub/identity.zig"));
}

test "RFC-0008 e2e: identity upgrade over the wire — durable id in response, list, and event trail" {
    std.testing.log_level = .err;
    var server = try HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();
    try server.startBackground();

    const alloc = std.testing.allocator;
    var buf: [16 * 1024]u8 = undefined;
    var fill: usize = 0;

    // Wrapper-style wire registration (pane id).
    const ag_fd = try testConnect(server.bound_port);
    defer sys.close(ag_fd);
    try sys.writeAll(ag_fd, "{\"type\":\"register\",\"id\":\"r1\",\"source\":\"local-e2e1\",\"target\":\"\"}\n");
    // Session-bearing registration (hook-event shape): tool + resume_ref.
    try sys.writeAll(ag_fd, "{\"type\":\"agent_update\",\"id\":\"u1\",\"source\":\"local-e2e1\",\"target\":\"hub\",\"payload\":{\"tool\":\"claude\",\"project\":\"synapty\",\"resume_ref\":\"deadbeef-1234-5678\"}}\n");

    // Response returns the BOUND durable id.
    const resp = try readLineContaining(alloc, ag_fd, &buf, &fill, "agent_id");
    defer alloc.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"agent_id\":\"claude-deadbeef\"") != null);

    // list_agents shows the durable id (pane id upgraded away).
    var lbuf: [16 * 1024]u8 = undefined;
    var lfill: usize = 0;
    const q_fd = try testConnect(server.bound_port);
    defer sys.close(q_fd);
    try sys.writeAll(q_fd, "{\"type\":\"register\",\"id\":\"r2\",\"source\":\"cli-tmp-q\",\"target\":\"\"}\n");
    try sys.writeAll(q_fd, "{\"type\":\"list_agents\",\"id\":\"l1\",\"source\":\"cli-tmp-q\",\"target\":\"hub\"}\n");
    const list = try readLineContaining(alloc, q_fd, &lbuf, &lfill, "\"agents\"");
    defer alloc.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "claude-deadbeef") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "local-e2e1") == null);

    // Transport gating: a temporary direct-TCP client cannot claim a
    // durable identity — its register keeps the temporary id.
    try sys.writeAll(q_fd, "{\"type\":\"agent_update\",\"id\":\"u2\",\"source\":\"cli-tmp-q\",\"target\":\"hub\",\"payload\":{\"tool\":\"claude\",\"resume_ref\":\"cafebabe-9999-0000\"}}\n");
    const gate_resp = try readLineContaining(alloc, q_fd, &lbuf, &lfill, "agent_id");
    defer alloc.free(gate_resp);
    try std.testing.expect(std.mem.indexOf(u8, gate_resp, "\"agent_id\":\"cli-tmp-q\"") != null);

    // WI-2026-08-11-019: a status signal sent over the UPGRADED wrapper
    // connection with the STALE source id lands on the CURRENT bound
    // identity — never on the dead pane id, never as a phantom entry.
    try sys.writeAll(ag_fd, "{\"type\":\"agent_status\",\"id\":\"s9\",\"source\":\"local-e2e1\",\"target\":\"\",\"payload\":{\"state\":\"done\"}}\n");
    const st_resp = try readLineContaining(alloc, ag_fd, &buf, &fill, "\"accepted\"");
    defer alloc.free(st_resp);
    try std.testing.expect(std.mem.indexOf(u8, st_resp, "\"accepted\":true") != null);
    try sys.writeAll(q_fd, "{\"type\":\"list_agents\",\"id\":\"l2\",\"source\":\"cli-tmp-q\",\"target\":\"hub\"}\n");
    const list2 = try readLineContaining(alloc, q_fd, &lbuf, &lfill, "\"agents\"");
    defer alloc.free(list2);
    // The durable id carries the status; the stale pane id appears nowhere.
    try std.testing.expect(std.mem.indexOf(u8, list2, "\"id\":\"claude-deadbeef\",\"tool\":\"claude\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list2, "\"status\":\"done\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list2, "local-e2e1") == null);
}

test "RFC-0007 e2e: exec_request reaches the workbench; exec_receipt routes response back + logs receipt" {
    std.testing.log_level = .err;
    var server = try HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();
    try server.startBackground();

    const alloc = std.testing.allocator;
    var buf: [16 * 1024]u8 = undefined;
    var fill: usize = 0;

    // The workbench subscribes — it is the exec control endpoint.
    const wb_fd = try testConnect(server.bound_port);
    defer sys.close(wb_fd);
    try sys.writeAll(wb_fd, "{\"type\":\"subscribe\",\"id\":\"s1\",\"source\":\"workbench\",\"target\":\"\"}\n");
    alloc.free(try readLineContaining(alloc, wb_fd, &buf, &fill, "\"agents\""));

    // The agent registers and sends an exec_request (open).
    const ag_fd = try testConnect(server.bound_port);
    defer sys.close(ag_fd);
    try sys.writeAll(ag_fd, "{\"type\":\"register\",\"id\":\"r1\",\"source\":\"local-exec1\",\"target\":\"\"}\n");
    try sys.writeAll(ag_fd, "{\"type\":\"exec_request\",\"id\":\"exec-1\",\"source\":\"local-exec1\",\"target\":\"workbench\",\"payload\":{\"verb\":\"open\",\"owner\":\"local-exec1\",\"requester\":\"local-exec1\",\"request_id\":\"exec-1\",\"cwd\":\"/tmp\"}}\n");

    // The workbench receives the forwarded exec_request over its subscription.
    const fwd = try readLineContaining(alloc, wb_fd, &buf, &fill, "exec_request");
    defer alloc.free(fwd);
    try std.testing.expect(std.mem.indexOf(u8, fwd, "\"verb\":\"open\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fwd, "local-exec1") != null);

    // The workbench replies with an exec_receipt over a SEPARATE one-shot
    // connection (the subscription is push-only; receipts are anonymous
    // one-shots like wake_report).
    const rc_fd = try testConnect(server.bound_port);
    defer sys.close(rc_fd);
    try sys.writeAll(rc_fd, "{\"type\":\"exec_receipt\",\"id\":\"rcpt-1\",\"source\":\"workbench\",\"target\":\"\",\"payload\":{\"kind\":\"exec_pane_opened\",\"owner\":\"local-exec1\",\"requester\":\"local-exec1\",\"request_id\":\"exec-1\",\"pane\":\"exec-abc\",\"data\":{\"outcome\":\"opened\",\"pane\":\"exec-abc\"}}}\n");

    // The agent receives the exec_response routed back to it.
    var abuf: [16 * 1024]u8 = undefined;
    var afill: usize = 0;
    const resp = try readLineContaining(alloc, ag_fd, &abuf, &afill, "exec_response");
    defer alloc.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"outcome\":\"opened\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "exec-abc") != null);

    // The receipt is on the event log too (the subscriber saw it pushed).
    const ev = try readLineContaining(alloc, wb_fd, &buf, &fill, "exec_pane_opened");
    defer alloc.free(ev);
    try std.testing.expect(std.mem.indexOf(u8, ev, "\"agent\":\"local-exec1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ev, "exec-abc") != null);
}

test "RFC-0007 e2e: exec_read routes its excerpt back WITHOUT logging a receipt" {
    // Regression for the first-armed-smoke defect: `read` replies with
    // kind "exec_read", which the receipt handler rejected as invalid —
    // the excerpt never reached the agent. Reads are passive observation
    // (C-PRIMITIVES: deliberately NOT receipted), so the correct
    // behaviour is route-the-response, append-no-event.
    std.testing.log_level = .err;
    var server = try HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();
    try server.startBackground();

    const alloc = std.testing.allocator;
    var buf: [16 * 1024]u8 = undefined;
    var fill: usize = 0;

    const wb_fd = try testConnect(server.bound_port);
    defer sys.close(wb_fd);
    try sys.writeAll(wb_fd, "{\"type\":\"subscribe\",\"id\":\"s1\",\"source\":\"workbench\",\"target\":\"\"}\n");
    alloc.free(try readLineContaining(alloc, wb_fd, &buf, &fill, "\"agents\""));

    const ag_fd = try testConnect(server.bound_port);
    defer sys.close(ag_fd);
    try sys.writeAll(ag_fd, "{\"type\":\"register\",\"id\":\"r1\",\"source\":\"local-execr\",\"target\":\"\"}\n");
    // Sync point: sampling the seq before the hub has PROCESSED the
    // register would count that registration as our delta.
    alloc.free(try readLineContaining(alloc, wb_fd, &buf, &fill, "agent_registered"));

    const seq_before = blk: {
        server.state.presence_mutex.lock(@import("io").get()) catch unreachable;
        defer server.state.presence_mutex.unlock(@import("io").get());
        break :blk server.state.event_log.latestSeq();
    };

    const rc_fd = try testConnect(server.bound_port);
    defer sys.close(rc_fd);
    try sys.writeAll(rc_fd, "{\"type\":\"exec_receipt\",\"id\":\"rd-1\",\"source\":\"workbench\",\"target\":\"\",\"payload\":{\"kind\":\"exec_read\",\"owner\":\"local-execr\",\"requester\":\"local-execr\",\"request_id\":\"read-1\",\"pane\":\"exec-zzz\",\"data\":{\"outcome\":\"ran\",\"excerpt\":\"SMOKE-MARKER-7788\"}}}\n");

    // The excerpt reaches the requesting agent…
    var abuf: [16 * 1024]u8 = undefined;
    var afill: usize = 0;
    const resp = try readLineContaining(alloc, ag_fd, &abuf, &afill, "exec_response");
    defer alloc.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "SMOKE-MARKER-7788") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"id\":\"read-1\"") != null);

    // …and NO event was appended for it (reads change nothing).
    const seq_after = blk: {
        server.state.presence_mutex.lock(@import("io").get()) catch unreachable;
        defer server.state.presence_mutex.unlock(@import("io").get());
        break :blk server.state.event_log.latestSeq();
    };
    try std.testing.expectEqual(seq_before, seq_after);
}

test "RFC-0007 e2e: exec_request with no workbench fails fast" {
    std.testing.log_level = .err;
    var server = try HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();
    try server.startBackground();

    const alloc = std.testing.allocator;
    var buf: [16 * 1024]u8 = undefined;
    var fill: usize = 0;

    const ag_fd = try testConnect(server.bound_port);
    defer sys.close(ag_fd);
    try sys.writeAll(ag_fd, "{\"type\":\"register\",\"id\":\"r1\",\"source\":\"local-exec2\",\"target\":\"\"}\n");
    try sys.writeAll(ag_fd, "{\"type\":\"exec_request\",\"id\":\"exec-1\",\"source\":\"local-exec2\",\"target\":\"workbench\",\"payload\":{\"verb\":\"open\"}}\n");
    const resp = try readLineContaining(alloc, ag_fd, &buf, &fill, "no workbench");
    defer alloc.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
}

test "RFC-0005 e2e: wake candidate rides the subscription push; wake_report lands on the log" {
    std.testing.log_level = .err;
    var server = try HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();
    try server.startBackground();

    const alloc = std.testing.allocator;
    var buf: [16 * 1024]u8 = undefined;
    var fill: usize = 0;

    // The workbench subscribes (this is AgentMonitor's channel).
    const sub_fd = try testConnect(server.bound_port);
    defer sys.close(sub_fd);
    try sys.writeAll(sub_fd, "{\"type\":\"subscribe\",\"id\":\"s1\",\"source\":\"gui\",\"target\":\"\"}\n");
    alloc.free(try readLineContaining(alloc, sub_fd, &buf, &fill, "\"agents\""));

    // Recipient registers; a peer dm's it — the empty->non-empty edge
    // must reach the subscriber as a pushed wake_candidate event.
    const bob_fd = try testConnect(server.bound_port);
    defer sys.close(bob_fd);
    try sys.writeAll(bob_fd, "{\"type\":\"register\",\"id\":\"r1\",\"source\":\"local-wakee\",\"target\":\"\"}\n");
    // REGISTERED BEFORE THE DM IS SENT. Two connections have no order
    // between them: on a loaded runner the dm reached the hub before the
    // recipient's registration had, and there was no mailbox edge to
    // announce. The subscriber's registered event is the proof of order.
    alloc.free(try readLineContaining(alloc, sub_fd, &buf, &fill, "\"local-wakee\""));
    const alice_fd = try testConnect(server.bound_port);
    defer sys.close(alice_fd);
    try sys.writeAll(alice_fd, "{\"type\":\"register\",\"id\":\"r2\",\"source\":\"local-waker\",\"target\":\"\"}\n");
    alloc.free(try readLineContaining(alloc, sub_fd, &buf, &fill, "\"local-waker\""));
    try sys.writeAll(alice_fd, "{\"type\":\"dm\",\"id\":\"d1\",\"source\":\"local-waker\",\"target\":\"local-wakee\",\"payload\":{\"text\":\"ping\"}}\n");

    const cand = try readLineContaining(alloc, sub_fd, &buf, &fill, "wake_candidate");
    defer alloc.free(cand);
    try std.testing.expect(std.mem.indexOf(u8, cand, "\"agent\":\"local-wakee\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cand, "\"generation\":") != null);

    // The workbench reports the injection outcome; the receipt is pushed
    // back on the same log (C-WAKE-ACK: one source of truth).
    const wb_fd = try testConnect(server.bound_port);
    defer sys.close(wb_fd);
    try sys.writeAll(wb_fd, "{\"type\":\"wake_report\",\"id\":\"w1\",\"source\":\"workbench\",\"target\":\"\",\"payload\":{\"agent\":\"local-wakee\",\"outcome\":\"delivered\"}}\n");
    const receipt = try readLineContaining(alloc, sub_fd, &buf, &fill, "wake_delivered");
    defer alloc.free(receipt);
    try std.testing.expect(std.mem.indexOf(u8, receipt, "\"agent\":\"local-wakee\"") != null);
}

