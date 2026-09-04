const std = @import("std");
const io_mod = @import("io");
const mem = std.mem;
const json = std.json;
const protocol = @import("protocol");
const Allocator = mem.Allocator;
const Connection = @import("connection.zig").Connection;
const log = @import("diag").scoped(.hub);

// ---------------------------------------------------------------------------
// Hub Event Log — per [[RFC-0004:C-EVENT-LOG]]
//
// Append-only bounded ring with monotonic sequence numbers. Presence facts
// and message activity share this one log; every externally visible
// presence change is appended AT THE MOMENT it is applied (the registry is
// a materialized view maintained in the same critical section — see
// HubState.presence_mutex, the OUTER lock for all presence mutations).
// ---------------------------------------------------------------------------

pub const EventKind = enum {
    agent_registered,
    agent_unregistered,
    agent_status_changed,
    message_routed,
    /// RFC-0008 C-REHOME: a durable identity moved to a new connection;
    /// `agent` is the durable id, `peer` the displaced pane fallback.
    identity_displaced,
    /// RFC-0008 C-REHOME identity upgrade: `agent` is the durable id,
    /// `peer` the pane id it replaced — the GUI uses this to remap its
    /// pane->agent association without guessing.
    identity_upgraded,
    /// RFC-0005 C-WAKE-TRIGGER: the agent's mailbox went empty→non-empty
    /// (or it registered/re-homed with mail waiting — the fresh-edge
    /// rule). One candidate per edge; the workbench gates and injects.
    /// `generation` is the registration generation the candidate was
    /// born under. Extends RFC-0004 C-EVENT-LOG per its extensibility rule.
    wake_candidate,
    /// RFC-0005 C-WAKE-ACK: workbench receipt — injection produced a
    /// working edge inside the ack window.
    wake_delivered,
    /// RFC-0005 C-WAKE-ACK: workbench receipt — no edge inside the ack
    /// window; the candidate stays outstanding (mail is still waiting).
    wake_stalled,
    /// RFC-0005 C-WAKE-TRIGGER: a pending candidate died — self-read to
    /// empty, unregister, or generation change (no inherited wake debt).
    wake_cancelled,
    /// RFC-0007 C-PRIMITIVES receipts — agent-initiated pane execution.
    /// `agent` = owning registration, `generation` = its id+gen, `peer` =
    /// the exec pane handle, `session` = free detail (command line for
    /// exec_command_ran, outcome+pattern for exec_wait_completed). Extend
    /// RFC-0004 C-EVENT-LOG per its extensibility rule; unknown-kind
    /// clients ignore.
    exec_pane_opened,
    exec_command_ran,
    exec_wait_completed,
    exec_pane_closed,
    /// [[RFC-0009]] C-EVENT-LOCALITY. These are LOCAL observations about a
    /// peer, minted with THIS hub's sequence numbers — foreign sequence
    /// numbers never enter this log. They exist because RFC-0004
    /// C-EVENT-LOG requires anything that can alter a list_agents response
    /// to be logged at the moment it is applied, and because without them
    /// `synapty wait` on a remote identity would block forever with
    /// nothing to wake it and the workbench would be blind to every agent
    /// it does not host. Their kinds are DISTINCT from the local
    /// agent-lifecycle kinds they resemble so no consumer mistakes a
    /// directory fact for a local registration. `peer` carries the peer id.
    peer_link_up,
    peer_link_down,
    directory_identity_added,
    directory_identity_removed,
    /// A peer's merged status conclusion, relayed. NOT agent_status_changed:
    /// this hub did not observe the evidence and did not run the
    /// acceptance rules (C-PRESENCE).
    peer_presence_relayed,
    /// C-DELIVERY: a spooled message hit its TTL. Logged because a message
    /// that vanishes silently is indistinguishable from one delivered.
    spool_expired,
    /// C-DELIVERY: a spooled message dropped to make room for a newer
    /// one. A DIFFERENT FACT FROM `spool_expired` and deliberately not
    /// folded into it: one says a machine never came back, the other says
    /// this hub broke a promise under pressure while the machine was fine.
    /// Reporting the second as the first sends the human after the peer.
    spool_evicted,
    /// C-EVENT-LOCALITY: a relay handshake THIS hub refused. The
    /// `relay_refused` frame travels to the DIALLING side, which in a peer
    /// id collision is the machine at fault — so without a local event the
    /// hub that knows has no way to say so, and an operator looking at the
    /// machine that reported nothing is looking at the only machine with
    /// the answer. `peer` carries the id the dialler claimed, which for
    /// `invalid_peer_id` is the claim rather than an identity.
    peer_link_refused,
    /// C-EVENT-LOCALITY: a relayed status this hub DECLINED to apply.
    /// A refused handshake at least sends a `relay_refused` somewhere; a
    /// declined presence relay sends nothing — the frame is dropped where
    /// it lands, so neither machine says anything and the silence is
    /// total. What is being declined is usually a peer speaking for an
    /// identity it does not host, which C-BOUNDARIES refuses on purpose,
    /// and an operator who cannot see the attempt cannot tell a
    /// misconfigured peer from a quiet one. NOT `peer_presence_relayed`:
    /// that kind says this hub TOOK a peer's conclusion, and a consumer
    /// counting it would count the ones it threw away.
    peer_presence_refused,
    /// [[RFC-0008]] C-IDENTITY: a durable derivation this hub REFUSED, so
    /// the registration keeps its pane-identity fallback. Named by that
    /// clause "because a MUST-be-evented with no kind is a MUST two
    /// implementers spell differently, and because the consequence
    /// outlives the record by orders of magnitude: an agent runs its
    /// whole life under a fallback id while the ring entry explaining why
    /// is evicted in minutes". `reason` carries which refusal it was.
    identity_rejected,

    pub fn toString(self: EventKind) []const u8 {
        return @tagName(self);
    }
};

pub const Event = struct {
    seq: u64,
    ts: i64,
    kind: EventKind,
    /// Subject agent id (owned by the log's allocator).
    agent: []const u8,
    /// agent_registered: the registration generation (== the seq of the
    /// event that CREATED the registration; re-registers carry it forward).
    generation: ?u64 = null,
    /// agent_registered: metadata snapshot at emission time (owned) — the
    /// pushed event must carry what the subscription snapshot would, so
    /// subscribers never need a follow-up query (C-SUBSCRIPTION).
    tool: ?[]const u8 = null,
    project: ?[]const u8 = null,
    session: ?[]const u8 = null,
    /// RFC-0006: harness session identity, for workbench resume plans.
    resume_ref: ?[]const u8 = null,
    /// agent_status_changed:
    old_state: ?protocol.Status = null,
    new_state: ?protocol.Status = null,
    class: ?protocol.SignalClass = null,
    /// message_routed: target agent id (owned).
    peer: ?[]const u8 = null,
    /// peer_link_refused: the refusal code, which is the same value the
    /// `relay_refused` frame carried (owned).
    reason: ?[]const u8 = null,
};

/// Fields callers pass to append(); strings are duped into the log.
pub const EventInput = struct {
    kind: EventKind,
    agent: []const u8,
    generation: ?u64 = null,
    tool: ?[]const u8 = null,
    project: ?[]const u8 = null,
    session: ?[]const u8 = null,
    resume_ref: ?[]const u8 = null,
    old_state: ?protocol.Status = null,
    new_state: ?protocol.Status = null,
    class: ?protocol.SignalClass = null,
    peer: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

pub const EventLog = struct {
    entries: std.ArrayList(Event),
    max_entries: usize,
    next_seq: u64,
    subscribers: std.ArrayList(*Connection),
    allocator: Allocator,

    pub fn init(allocator: Allocator, max_entries: usize) EventLog {
        return .{
            .entries = std.ArrayList(Event).empty,
            .max_entries = max_entries,
            .next_seq = 1,
            .subscribers = std.ArrayList(*Connection).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EventLog) void {
        for (self.entries.items) |ev| self.freeEvent(ev);
        self.entries.deinit(self.allocator);
        // Release any subscribers whose readers did not clean up.
        for (self.subscribers.items) |conn| conn.release();
        self.subscribers.deinit(self.allocator);
    }

    fn freeEvent(self: *EventLog, ev: Event) void {
        self.allocator.free(ev.agent);
        if (ev.tool) |t| self.allocator.free(t);
        if (ev.project) |p| self.allocator.free(p);
        if (ev.session) |s| self.allocator.free(s);
        if (ev.resume_ref) |r| self.allocator.free(r);
        if (ev.peer) |p| self.allocator.free(p);
        if (ev.reason) |r| self.allocator.free(r);
    }

    /// Sequence number of the newest appended event (0 when empty).
    pub fn latestSeq(self: *const EventLog) u64 {
        return self.next_seq - 1;
    }

    /// Append an event and push it to every subscriber. Returns the
    /// assigned sequence number. NOT internally locked — callers hold
    /// HubState.presence_mutex so the append is atomic with the state
    /// mutation it records (the write-time invariant of C-EVENT-LOG).
    pub fn append(self: *EventLog, input: EventInput) !u64 {
        const seq = self.next_seq;
        const owned = Event{
            .seq = seq,
            .ts = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds(),
            .kind = input.kind,
            .agent = try self.allocator.dupe(u8, input.agent),
            .generation = input.generation,
            .tool = if (input.tool) |t| try self.allocator.dupe(u8, t) else null,
            .project = if (input.project) |p| try self.allocator.dupe(u8, p) else null,
            .session = if (input.session) |s| try self.allocator.dupe(u8, s) else null,
            .resume_ref = if (input.resume_ref) |r| try self.allocator.dupe(u8, r) else null,
            .old_state = input.old_state,
            .new_state = input.new_state,
            .class = input.class,
            .peer = if (input.peer) |p| try self.allocator.dupe(u8, p) else null,
            .reason = if (input.reason) |r| try self.allocator.dupe(u8, r) else null,
        };
        errdefer self.freeEvent(owned);
        try self.entries.append(self.allocator, owned);
        self.next_seq += 1;
        // Ring bound: evict oldest. The subscription snapshot covers
        // truncation for late subscribers (C-EVENT-LOG V1 bounds).
        if (self.entries.items.len > self.max_entries) {
            const evicted = self.entries.orderedRemove(0);
            self.freeEvent(evicted);
        }
        self.pushToSubscribers(owned);
        return seq;
    }

    /// Serialize `ev` as a pushed envelope and enqueue to all subscribers.
    /// Dead subscribers (closed connections) are dropped and released.
    fn pushToSubscribers(self: *EventLog, ev: Event) void {
        if (self.subscribers.items.len == 0) return;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const envelope = self.eventEnvelope(arena, ev) catch return;

        var i: usize = 0;
        while (i < self.subscribers.items.len) {
            const conn = self.subscribers.items[i];
            conn.enqueueEnvelope(arena, envelope) catch {
                _ = self.subscribers.swapRemove(i);
                conn.release();
                continue; // swapRemove moved a new item into slot i
            };
            i += 1;
        }
    }

    /// Build the pushed `event` envelope for a log entry.
    pub fn eventEnvelope(self: *EventLog, arena: Allocator, ev: Event) !protocol.Envelope {
        _ = self;
        var payload = json.ObjectMap.empty;
        try payload.put(arena, "seq", .{ .integer = @intCast(ev.seq) });
        try payload.put(arena, "ts", .{ .integer = ev.ts });
        try payload.put(arena, "kind", .{ .string = ev.kind.toString() });
        try payload.put(arena, "agent", .{ .string = try arena.dupe(u8, ev.agent) });
        if (ev.generation) |g| try payload.put(arena, "generation", .{ .integer = @intCast(g) });
        if (ev.tool) |t| try payload.put(arena, "tool", .{ .string = try arena.dupe(u8, t) });
        if (ev.project) |p| try payload.put(arena, "project", .{ .string = try arena.dupe(u8, p) });
        if (ev.session) |s| try payload.put(arena, "session", .{ .string = try arena.dupe(u8, s) });
        if (ev.resume_ref) |r| try payload.put(arena, "resume_ref", .{ .string = try arena.dupe(u8, r) });
        if (ev.old_state) |s| try payload.put(arena, "old", .{ .string = s.toString() });
        if (ev.new_state) |s| try payload.put(arena, "new", .{ .string = s.toString() });
        if (ev.class) |c| try payload.put(arena, "class", .{ .string = c.toString() });
        if (ev.peer) |p| try payload.put(arena, "peer", .{ .string = try arena.dupe(u8, p) });
        if (ev.reason) |r| try payload.put(arena, "reason", .{ .string = try arena.dupe(u8, r) });
        const id = try std.fmt.allocPrint(arena, "evt-{d}", .{ev.seq});
        return protocol.Envelope{
            .@"type" = "event",
            .id = id,
            .source = "hub",
            .target = "",
            .payload = .{ .object = payload },
        };
    }

    /// SEND A REQUEST TO EXACTLY ONE SUBSCRIBER ([[RFC-0003:C-HUB-ROLE]]).
    ///
    /// `broadcast` above is for EVENTS, which every workbench should see.
    /// A request is different in kind: each workbench that receives one
    /// PERFORMS it. Both of broadcast's non-event callers were requests,
    /// so on a hub with a laptop and a desktop attached every comment was
    /// written twice, every claim PATCHed twice, and `synapty exec`
    /// opened two panes and ran the command twice
    /// ([[WI-2026-09-03-014]]).
    ///
    /// Returns false when nobody took it, so the caller can say so rather
    /// than park a requester nothing will answer. A dead subscriber is
    /// dropped and the next one tried — that is not a second EXECUTION,
    /// because a connection that could not be written to never received
    /// the first.
    ///
    /// THE OLDEST SUBSCRIBER, so repeated requests land in the same place
    /// while it lives. Choosing the newest would move the work every time
    /// a window opened.
    pub fn dispatchOne(self: *EventLog, envelope: protocol.Envelope) bool {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        while (self.subscribers.items.len > 0) {
            const conn = self.subscribers.items[0];
            conn.enqueueEnvelope(arena, envelope) catch {
                _ = self.subscribers.orderedRemove(0);
                conn.release();
                continue;
            };
            return true;
        }
        return false;
    }

    /// Number of attached subscribers (RFC-0007: an exec_request with no
    /// workbench listening must fail fast, not hang the agent).
    pub fn subscriberCount(self: *const EventLog) usize {
        return self.subscribers.items.len;
    }

    /// Add a subscriber (retains the connection). Caller holds presence_mutex.
    pub fn addSubscriber(self: *EventLog, conn: *Connection) !void {
        try self.subscribers.append(self.allocator, conn);
        conn.retain();
    }

    /// Remove a subscriber if present (releases the retained reference).
    /// Caller holds presence_mutex.
    pub fn removeSubscriber(self: *EventLog, conn: *Connection) void {
        for (self.subscribers.items, 0..) |c, idx| {
            if (c == conn) {
                _ = self.subscribers.swapRemove(idx);
                conn.release();
                return;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const sys = @import("sys");

test "EventLog append assigns monotonic seqs and evicts FIFO" {
    var elog = EventLog.init(std.testing.allocator, 3);
    defer elog.deinit();

    try std.testing.expectEqual(@as(u64, 0), elog.latestSeq());
    const s1 = try elog.append(.{ .kind = .agent_registered, .agent = "a", .generation = 1 });
    const s2 = try elog.append(.{ .kind = .agent_status_changed, .agent = "a", .old_state = .unknown, .new_state = .working, .class = .explicit });
    const s3 = try elog.append(.{ .kind = .message_routed, .agent = "a", .peer = "b" });
    try std.testing.expectEqual(@as(u64, 1), s1);
    try std.testing.expectEqual(@as(u64, 2), s2);
    try std.testing.expectEqual(@as(u64, 3), s3);
    try std.testing.expectEqual(@as(u64, 3), elog.latestSeq());
    try std.testing.expectEqual(@as(usize, 3), elog.entries.items.len);

    // 4th evicts the 1st, but seq keeps counting — eviction never rewinds
    // the clock the subscription snapshot hands out.
    const s4 = try elog.append(.{ .kind = .agent_unregistered, .agent = "a" });
    try std.testing.expectEqual(@as(u64, 4), s4);
    try std.testing.expectEqual(@as(usize, 3), elog.entries.items.len);
    try std.testing.expectEqual(@as(u64, 2), elog.entries.items[0].seq);
}

test "EventLog pushes appended events to subscribers over the wire" {
    var elog = EventLog.init(std.testing.allocator, 100);
    defer elog.deinit();

    // A real socketpair: subscriber conn wraps one end, the test reads
    // the other end like a client would.
    var fds: [2]sys.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(sys.AF.UNIX, sys.SOCK.STREAM, 0, &fds));
    const conn = try std.testing.allocator.create(Connection);
    conn.* = Connection.init(std.testing.allocator, fds[0], @ptrCast(conn), testRelease);
    defer sys.close(fds[1]);

    const writer = try std.Thread.spawn(.{}, @import("connection.zig").writerThread, .{conn});

    try elog.addSubscriber(conn);
    _ = try elog.append(.{ .kind = .agent_registered, .agent = "agent-x", .generation = 7, .tool = "claude" });
    _ = try elog.append(.{ .kind = .agent_status_changed, .agent = "agent-x", .old_state = .unknown, .new_state = .waiting, .class = .passive });

    // Read both pushed lines from the client end.
    var buf: [4096]u8 = undefined;
    var got: usize = 0;
    var newlines: usize = 0;
    while (newlines < 2) {
        const n = try sys.read(fds[1], buf[got..]);
        if (n == 0) break;
        for (buf[got .. got + n]) |ch| {
            if (ch == '\n') newlines += 1;
        }
        got += n;
    }
    const text = buf[0..got];
    try std.testing.expect(mem.indexOf(u8, text, "\"agent_registered\"") != null);
    try std.testing.expect(mem.indexOf(u8, text, "\"generation\":7") != null);
    try std.testing.expect(mem.indexOf(u8, text, "\"claude\"") != null);
    try std.testing.expect(mem.indexOf(u8, text, "\"agent_status_changed\"") != null);
    try std.testing.expect(mem.indexOf(u8, text, "\"new\":\"waiting\"") != null);
    try std.testing.expect(mem.indexOf(u8, text, "\"class\":\"passive\"") != null);
    try std.testing.expect(mem.indexOf(u8, text, "\"seq\":1") != null);
    try std.testing.expect(mem.indexOf(u8, text, "\"seq\":2") != null);

    // Cleanup: remove subscriber (releases ref), then drain the writer.
    elog.removeSubscriber(conn);
    conn.shutdown();
    writer.join();
    conn.deinit();
    std.testing.allocator.destroy(conn);
}

test "EventLog drops a dead subscriber instead of failing appends" {
    var elog = EventLog.init(std.testing.allocator, 100);
    defer elog.deinit();

    var fds: [2]sys.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(sys.AF.UNIX, sys.SOCK.STREAM, 0, &fds));
    const conn = try std.testing.allocator.create(Connection);
    conn.* = Connection.init(std.testing.allocator, fds[0], @ptrCast(conn), testRelease);
    defer sys.close(fds[1]);

    try elog.addSubscriber(conn);
    // Poison the connection (what a dead writer does) — enqueue now fails.
    conn.shutdown();
    _ = try elog.append(.{ .kind = .agent_registered, .agent = "a", .generation = 1 });
    try std.testing.expectEqual(@as(usize, 0), elog.subscribers.items.len);

    conn.deinit();
    std.testing.allocator.destroy(conn);
}

fn testRelease(_: *anyopaque, _: *Connection) void {
    // Test connections are freed manually; release is a no-op.
}

test "a request reaches exactly one subscriber, however many are attached" {
    // [[RFC-0003:C-HUB-ROLE]]: events fan out, requests do not. Every
    // workbench that receives a request PERFORMS it, so a fan-out wrote
    // every comment twice on a hub two of them were attached to
    // ([[WI-2026-09-03-014]]).
    var elog = EventLog.init(std.testing.allocator, 100);
    defer elog.deinit();

    var conns: [2]*Connection = undefined;
    var client: [2]sys.fd_t = undefined;
    var writers: [2]std.Thread = undefined;
    for (0..2) |i| {
        var fds: [2]sys.fd_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(sys.AF.UNIX, sys.SOCK.STREAM, 0, &fds));
        const c = try std.testing.allocator.create(Connection);
        c.* = Connection.init(std.testing.allocator, fds[0], @ptrCast(c), testRelease);
        conns[i] = c;
        client[i] = fds[1];
        writers[i] = try std.Thread.spawn(.{}, @import("connection.zig").writerThread, .{c});
        try elog.addSubscriber(c);
    }
    defer {
        for (0..2) |i| {
            elog.removeSubscriber(conns[i]);
            conns[i].shutdown();
            writers[i].join();
            conns[i].deinit();
            std.testing.allocator.destroy(conns[i]);
            sys.close(client[i]);
        }
    }

    const request = protocol.Envelope{
        .@"type" = "tool_request",
        .id = "req-1",
        .source = "hub",
        .target = "workbench",
        .payload = .{ .object = json.ObjectMap.empty },
    };
    try std.testing.expect(elog.dispatchOne(request));

    // Exactly one end has bytes waiting. Asked without blocking, because
    // the point is that the other end has NOTHING and a read there would
    // wait for it forever.
    var served: usize = 0;
    for (0..2) |i| {
        if (sys.waitReadable(client[i], 250) catch false) served += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), served);
}

test "a subscriber that cannot be written to is passed over, not counted as served" {
    // Dropping a dead subscriber and trying the next is not a second
    // EXECUTION: a connection the envelope never reached never performed
    // anything ([[WI-2026-09-03-014]]).
    var elog = EventLog.init(std.testing.allocator, 100);
    defer elog.deinit();

    var conns: [2]*Connection = undefined;
    var client: [2]sys.fd_t = undefined;
    var writers: [2]std.Thread = undefined;
    for (0..2) |i| {
        var fds: [2]sys.fd_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(sys.AF.UNIX, sys.SOCK.STREAM, 0, &fds));
        const c = try std.testing.allocator.create(Connection);
        c.* = Connection.init(std.testing.allocator, fds[0], @ptrCast(c), testRelease);
        conns[i] = c;
        client[i] = fds[1];
        writers[i] = try std.Thread.spawn(.{}, @import("connection.zig").writerThread, .{c});
        try elog.addSubscriber(c);
    }
    // The oldest is the one dispatchOne would pick, and it is shut: its
    // enqueue answers ConnectionClosed.
    conns[0].shutdown();
    writers[0].join();

    const request = protocol.Envelope{
        .@"type" = "tool_request",
        .id = "req-1",
        .source = "hub",
        .target = "workbench",
        .payload = .{ .object = json.ObjectMap.empty },
    };
    try std.testing.expect(elog.dispatchOne(request));
    // The live one got it, and the dead one is no longer on the list.
    try std.testing.expect(sys.waitReadable(client[1], 250) catch false);
    try std.testing.expectEqual(@as(usize, 1), elog.subscriberCount());

    elog.removeSubscriber(conns[1]);
    conns[1].shutdown();
    writers[1].join();
    for (0..2) |i| {
        conns[i].deinit();
        std.testing.allocator.destroy(conns[i]);
        sys.close(client[i]);
    }
}

test "a dispatch with nobody attached is a failure, not a silent drop" {
    var elog = EventLog.init(std.testing.allocator, 100);
    defer elog.deinit();
    const request = protocol.Envelope{
        .@"type" = "tool_request",
        .id = "req-1",
        .source = "hub",
        .target = "workbench",
        .payload = .{ .object = json.ObjectMap.empty },
    };
    // The caller has to be able to say "no workbench available" rather
    // than park a requester nothing will ever answer.
    try std.testing.expect(!elog.dispatchOne(request));
}
