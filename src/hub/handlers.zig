const std = @import("std");
const io_mod = @import("io");
const mem = std.mem;
const json = std.json;
const protocol = @import("protocol");
const identity = @import("identity.zig");
const Allocator = mem.Allocator;
const Connection = @import("connection.zig").Connection;
const registry = @import("registry.zig");
const tools = @import("tools");
const HubState = registry.HubState;
const AgentInfo = registry.AgentInfo;
const log = @import("diag").scoped(.hub);
const federation = @import("federation.zig");
const diag = @import("diag");

// ---------------------------------------------------------------------------
// Response helper
// ---------------------------------------------------------------------------

/// Build and enqueue a hub response envelope — the shared implementation
/// behind sendResponse and sendToolResponse, which differ only in the
/// envelope type (they were byte-identical copies; WI-2026-08-08-038).
fn sendHubEnvelope(arena: Allocator, conn: *Connection, req_id: []const u8, target: []const u8, ok: bool, data: ?json.Value, err_msg: ?[]const u8, resp_type: []const u8) !void {
    var payload_obj = json.ObjectMap.empty;
    try payload_obj.put(arena, "ok", .{ .bool = ok });
    if (data) |d| try payload_obj.put(arena, "data", d);
    if (err_msg) |e| try payload_obj.put(arena, "error", .{ .string = e });

    const resp = protocol.Envelope{
        .@"type" = resp_type,
        .id = req_id,
        .source = "hub",
        .target = target,
        .payload = .{ .object = payload_obj },
    };
    try conn.enqueueEnvelope(arena, resp);
}

pub fn sendResponse(arena: Allocator, conn: *Connection, req_id: []const u8, target: []const u8, ok: bool, data: ?json.Value, err_msg: ?[]const u8) !void {
    try sendHubEnvelope(arena, conn, req_id, target, ok, data, err_msg, "response");
}

// ---------------------------------------------------------------------------
// Handler: list_agents per [[RFC-0003:C-CLI-TOOLS]] (daemon socket)
// ---------------------------------------------------------------------------

/// Build the shared agents array (list_agents response AND subscription
/// snapshot). CALLER MUST HOLD presence_mutex: neither the generations map
/// nor the [[RFC-0009]] peer directory has an inner lock, and iterating the
/// directory while a relay link advertises into it would be a data race.
/// (Lock order holds: presence_mutex is the outer lock, and this then takes
/// routing_table.mutex and agent_registry.mutex beneath it.)
fn buildAgentsArray(state: *HubState, arena: Allocator, with_generations: bool) !json.Value {
    const agent_ids = try state.routing_table.agentIds(arena);

    var arr = json.Array.init(arena);
    for (agent_ids) |id| {
        var agent_obj = json.ObjectMap.empty;
        try agent_obj.put(arena, "id", .{ .string = id });
        const info = state.agent_registry.get(id, arena);
        try agent_obj.put(arena, "tool", .{ .string = if (info) |i| i.tool orelse "-" else "-" });
        try agent_obj.put(arena, "project", .{ .string = if (info) |i| i.project orelse "-" else "-" });
        try agent_obj.put(arena, "session", .{ .string = if (info) |i| i.session orelse "-" else "-" });
        // Merged presence state (RFC-0004 C-VOCABULARY); never-signaled
        // agents are honestly "unknown".
        const status: protocol.Status = if (info) |i| i.status else .unknown;
        try agent_obj.put(arena, "status", .{ .string = status.toString() });
        // RFC-0006 C-RESUME-PLAN: the workbench composes resume
        // incantations from this (after its own allowlist validation).
        if (info) |i| {
            if (i.resume_ref) |r| try agent_obj.put(arena, "resume_ref", .{ .string = r });
        }
        if (with_generations) {
            const gen = state.generations.get(id) orelse 0;
            try agent_obj.put(arena, "generation", .{ .integer = @intCast(gen) });
        }
        // [[RFC-0009]] C-PRESENCE: a consumer must be able to tell local
        // presence (evidence this machine can re-check right now) from
        // relayed presence (a report that was true when the peer sent it),
        // and must key identity-continuity on (hosting_peer, generation) —
        // two hubs' sequence spaces are unrelated, so comparing generations
        // across them is meaningless even where it type-checks.
        // BOTH ABSENT, which is how the row says "local". Filling them
        // with this hub's own id and `true` makes every row look relayed,
        // so the distinction the two fields exist to carry — evidence
        // this machine can re-check now, versus a peer's report — is not
        // in the payload at all.
        // NOT ON A LOCAL ROW. A local agent at `unknown` has exactly one
        // explanation — this hub looked and has nothing — so the field
        // carries no information here, and adding it would falsify what
        // [[RFC-0009]] C-PRESENCE and [[RFC-0004]] C-SUBSCRIPTION both
        // promise: that a single-hub snapshot is byte-for-byte what it
        // was before federation.
        try arr.append(.{ .object = agent_obj });
    }

    // Identities hosted by PEERS. Omitting them would leave the workbench
    // blind to every agent it does not host — addressable yet invisible —
    // which is the failure the review caught in the subscription model.
    //
    // TOOL, PROJECT AND SESSION ARE OMITTED, and this comment used to say
    // so while the three lines below wrote `"-"` into all of them. Only
    // identity, hosting peer and reachability cross a relay link
    // ([[RFC-0009]] C-DIRECTORY), so this hub has not learnt these facts
    // and has none to report.
    //
    // WHY `"-"` IS THE WRONG SPELLING **HERE** AND THE RIGHT ONE ABOVE.
    // On a local row `"-"` means "this agent registered without a tool" —
    // a fact, and one this hub established by looking ([[RFC-0008]]
    // C-REGISTRATION makes the field optional at every registration). On a
    // relayed row the same character would mean "I have no way to know",
    // which is a different fact, and giving two facts one spelling is
    // the confusion [[RFC-0010]] C-DIAGNOSABILITY exists to prevent.
    // `remote` does distinguish them for a consumer that reads it; a
    // field that is simply not there needs no such consumer.
    //
    // LOCAL ROWS ARE UNTOUCHED, deliberately: [[RFC-0004]]
    // C-SUBSCRIPTION promises a single-hub snapshot is byte-for-byte what
    // it was before federation, and these rows did not exist before it.
    var dir_it = state.directory.map.iterator();
    while (dir_it.next()) |e| {
        var remote_obj = json.ObjectMap.empty;
        try remote_obj.put(arena, "id", .{ .string = e.key_ptr.* });
        // Reachable: the hosting peer's relayed conclusion. Unreachable:
        // `unknown`, which RFC-0004 already defines as the honest answer
        // when there is no reliable evidence — and serving the last known
        // value instead would be indistinguishable from a fresh one.
        // A CONTESTED IDENTITY IS `unknown` WHATEVER EITHER CLAIMANT SAID.
        // Serving the first claimant's status would be that hub's report
        // about an identity it may not host, dressed as this hub's answer.
        const remote_status = if (e.value_ptr.conflicted())
            protocol.Status.unknown
        else if (e.value_ptr.reachable)
            e.value_ptr.status
        else
            protocol.Status.unknown;
        try remote_obj.put(arena, "status", .{ .string = remote_status.toString() });
        // WHY it is unknown, which is the difference between a fact about
        // the agent, a fact about the link, and a fact about the peer's
        // BUILD. Reading the third as the first is what cost a debugging
        // session on 2026-08-12.
        if (remote_status == .unknown and !e.value_ptr.conflicted()) {
            const cause: protocol.UnknownCause = if (!e.value_ptr.reachable)
                .peer_unreachable
            else if (state.peer_links.get(e.value_ptr.peer)) |link|
                (if (link.caps.has(.presence_relay)) .no_evidence else .peer_lacks_capability)
            else
                .peer_unreachable;
            try remote_obj.put(arena, "unknown_cause", .{ .string = cause.toString() });
        }
        if (e.value_ptr.conflicted()) {
            // ONE ROW, MARKED. Naming either claimant is the
            // winner-picking C-DIRECTORY forbids, and `peer_reachable`
            // names one peer where two are live, so there is nothing
            // true to put in it.
            try remote_obj.put(arena, "unknown_cause", .{
                .string = protocol.UnknownCause.contested.toString(),
            });
        } else {
            try remote_obj.put(arena, "hosting_peer", .{ .string = e.value_ptr.peer });
            try remote_obj.put(arena, "peer_reachable", .{ .bool = e.value_ptr.reachable });
        }
        try remote_obj.put(arena, "remote", .{ .bool = true });
        try arr.append(.{ .object = remote_obj });
    }
    return .{ .array = arr };
}

pub fn handleListAgents(state: *HubState, arena: Allocator, conn: *Connection, req: protocol.Envelope) !void {
    const agents = blk: {
        state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer state.presence_mutex.unlock(io_mod.get());
        break :blk try buildAgentsArray(state, arena, false);
    };

    var data_obj = json.ObjectMap.empty;
    try data_obj.put(arena, "ok", .{ .bool = true });
    try data_obj.put(arena, "agents", agents);

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
// Handler: subscribe per [[RFC-0004:C-SUBSCRIPTION]]
// ---------------------------------------------------------------------------

/// Snapshot-then-subscribe, atomically under presence_mutex: the snapshot
/// (agents + statuses + generations + latest seq) and the subscriber-add
/// happen in one critical section, so no event can fall between them —
/// the subscriber starts consistent without replaying history.
pub fn handleSubscribe(state: *HubState, arena: Allocator, conn: *Connection, req: protocol.Envelope) !void {
    state.presence_mutex.lock(io_mod.get()) catch unreachable;
    defer state.presence_mutex.unlock(io_mod.get());

    const agents = try buildAgentsArray(state, arena, true);
    var data_obj = json.ObjectMap.empty;
    try data_obj.put(arena, "agents", agents);
    try data_obj.put(arena, "seq", .{ .integer = @intCast(state.event_log.latestSeq()) });

    // Enqueue the snapshot BEFORE adding the subscriber: the connection's
    // outbound queue is FIFO, so every pushed event lands after it.
    try sendResponse(arena, conn, req.id, req.source, true, .{ .object = data_obj }, null);
    try state.event_log.addSubscriber(conn);
    log.info("event subscriber attached: {s}", .{req.source});
}

// ---------------------------------------------------------------------------
// Handler: agent_update per [[RFC-0003]] (agent identity)
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
        .resume_ref = if (payload.get("resume_ref")) |v| (if (v == .string) v.string else null) else null,
    };
    // RFC-0008: derive + bind the durable identity when the registration
    // carries a resume_ref. Transport gating (C-TRUST hardening 1):
    // durable claims only from wrapper/tunnel connections — a temporary
    // direct-TCP client keeps its temporary id.
    var final_id: []const u8 = try conn.boundIdDupe(arena) orelse envelope.source;
    if (info.tool != null and info.resume_ref != null and
        !protocol.isTempAgent(final_id))
    {
        switch (try identity.deriveDurableId(arena, info.tool.?, info.resume_ref.?)) {
            .id => |durable| {
                if (!std.mem.eql(u8, final_id, durable)) {
                    const outcome = try state.bindDurableIdTracked(conn, durable, info.resume_ref.?);
                    if (outcome != .collision) final_id = durable;
                }
            },
            // EVENTED, WHICH [[RFC-0008]] C-IDENTITY REQUIRES. The agent
            // goes on running under its pane id for the rest of its life;
            // without this the only trace was a `null` nobody could see,
            // and the reason it happened was never written down anywhere.
            .rejected => |why| state.recordIdentityRejected(final_id, why.toString()),
        }
    }
    try state.updateAgentTracked(final_id, info);
    // RFC-0008 C-IDENTITY: the register response returns the bound id —
    // the only way an agent learns who it is.
    var data_obj = json.ObjectMap.empty;
    try data_obj.put(arena, "agent_id", .{ .string = final_id });
    try sendResponse(arena, conn, envelope.id, envelope.source, true, .{ .object = data_obj }, null);
}

// ---------------------------------------------------------------------------
// Handler: agent_status per [[RFC-0004]] (presence signal ingest)
// ---------------------------------------------------------------------------

/// Ingest one presence signal. Payload: {state, class?, agent?} — class
/// defaults to "explicit" (agent self-report via notify), agent defaults
/// to the envelope source (workbench/detector signals name their subject).
/// The C-PRECEDENCE acceptance rules run at the registry; rejected
/// signals respond ok with accepted=false so callers can observe merges.
pub fn handleAgentStatus(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
    const payload = if (envelope.payload == .object) envelope.payload.object else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing payload");
        return;
    };
    const state_str = objGetString(payload, "state") orelse {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing state");
        return;
    };
    const new_status = protocol.Status.fromString(state_str) orelse {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "invalid state (working|waiting|done|idle|unknown)");
        return;
    };
    const class_str = objGetString(payload, "class") orelse "explicit";
    const class = protocol.SignalClass.fromString(class_str) orelse {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "invalid class (explicit|passive|lifecycle)");
        return;
    };
    // Subject resolution (WI-2026-08-11-019): a REGISTERED wrapper
    // connection's signals are attributed to its CURRENT bound identity
    // — the daemon stamps the id it captured at startup, which goes
    // stale after an identity upgrade (hook signals then landed on the
    // dead pane id, silently losing the explicit channel). The hub-side
    // resolution is unforgeable and needs no daemon protocol change.
    // Anonymous one-shots (workbench gaze, detector edges) keep the
    // payload `agent` override — the acceptance rules bound what those
    // can do.
    const subject = (try conn.boundIdDupe(arena)) orelse
        (objGetString(payload, "agent") orelse envelope.source);

    const result = try state.applyStatusSignal(subject, class, new_status);
    var data_obj = json.ObjectMap.empty;
    try data_obj.put(arena, "accepted", .{ .bool = result.accepted });
    try data_obj.put(arena, "status", .{ .string = result.new.toString() });
    try sendResponse(arena, conn, envelope.id, envelope.source, true, .{ .object = data_obj }, null);
}

// ---------------------------------------------------------------------------
// Handler: dm per [[RFC-0003]] (direct message envelope, legacy chat surface)
// ---------------------------------------------------------------------------

/// How long a hub waits for a peer to acknowledge a forward before it
/// answers `spooled` ([[RFC-0009]] C-DELIVERY). Silence has to have a
/// length, or the sender waits on a link that may never answer.
/// Test seam: a five-second wait is not something a test can sit through,
/// and the mapping from an unanswered forward to `spooled` is exactly what
/// wants testing.
pub var forward_ack_bound_ms: i64 = 5000;

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

    // Log the message per [[RFC-0003]] (hub state).
    state.message_log.append(state.allocator, .{
        .from = envelope.source,
        .to = target,
        .channel = null,
        .text = text,
        .ts = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds(),
    }) catch {};

    // RFC-0008 C-MAILBOX: temporary direct-TCP receivers keep the old
    // push path — they read dm envelopes off their own connection and
    // can never re-home, so hub-side queueing would strand their mail.
    if (protocol.isTempAgent(target)) {
        if (state.routing_table.lookupAndRetain(target)) |tc| {
            defer tc.release();
            tc.enqueueEnvelope(arena, envelope) catch |err| {
                log.warn("failed to deliver dm to {s}: {any}", .{ target, err });
                try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "delivery failed");
                return;
            };
            state.noteMessageRouted(envelope.source, target);
            try sendResponse(arena, conn, envelope.id, envelope.source, true, null, null);
        } else {
            try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "agent not connected");
        }
        return;
    }

    // Everyone else: queue at the hub keyed by identity, nudge the live
    // home. Ack semantics are explicit (C-MAILBOX): queued for known
    // identities — online or offline — and a fast error for typos.
    const raw = try protocol.serializeEnvelope(arena, envelope);
    var result = try state.mailboxDeliver(target, envelope.id, raw, .submitted);

    // WRITTEN IS NOT TAKEN ([[RFC-0009]] C-DELIVERY). `forwarded` means
    // the peer acknowledged it, so the answer is not known until the peer
    // says so or the bound elapses. The wait happens HERE, outside
    // presence_mutex — five seconds under that lock would freeze the hub
    // for every other agent on this machine.
    var refusal: ?[]const u8 = null;
    if (result.forward_id) |borrowed| {
        // COPIED BEFORE THE WAIT, because the wait destroys what this
        // points at: `forward_id` is the pending table's own key, and
        // every exit from `awaitForward` runs `dropPendingLocked`, which
        // frees it. Nothing noticed while the id was only ever an
        // argument to that one call; the moment it had to outlive it —
        // to ride the held copy so the retry carries it again — the
        // silence branch was duping freed bytes into the spool, and the
        // frame that went out carried fifteen bytes of poison where an
        // id belonged.
        // ON OOM THE FALLBACK WAS THE BORROWED POINTER ITSELF, which the
        // wait frees on exit and the silence branch then writes into the
        // durable spool. No copy means no wait: spool under no forward
        // id, which is the first-attempt shape and dedupes as nothing
        // worse than a retry ([[WI-2026-09-02-014]]).
        const fid: ?[]const u8 = arena.dupe(u8, borrowed) catch null;
        switch (if (fid) |id| state.awaitForward(arena, id, forward_ack_bound_ms) else .silence) {
            .acked => {},
            .nacked => |code| {
                result.outcome = .refused;
                refusal = code;
            },
            .silence => {
                // Held after all, and flushed when the link next returns
                // — UNDER THE ID IT ALREADY WENT OUT WITH, so the peer
                // that may have received the first copy recognises the
                // retry as the same message.
                state.spoolAfterSilence(target, envelope.id, raw, fid);
                result.outcome = .spooled;
            },
        }
    }

    // [[RFC-0009]] C-DELIVERY wire shape: {status, reason?}.
    var data_obj = json.ObjectMap.empty;
    try data_obj.put(arena, "status", .{ .string = result.outcome.toString() });
    // NOTHING BESIDE `status` AND `reason` ([[RFC-0009]] C-DELIVERY's
    // wire shape). `hosted` said whether the target had a live connection
    // — which is presence, and presence has its own surface with its own
    // acceptance rules, so a delivery response reporting who is connected
    // smuggles a presence fact past them.

    if (refusal) |code| {
        // THE PEER'S OWN WORDS, carried through rather than replaced by
        // ours ([[RFC-0009]] C-DELIVERY): its code is the only place its
        // reason survives, and a refusal described in our vocabulary
        // tells the human about us instead of about the machine that
        // said no.
        try data_obj.put(arena, "reason", .{ .string = code });
        try sendResponse(arena, conn, envelope.id, envelope.source, false, .{ .object = data_obj }, code);
        return;
    }
    if (result.outcome.failureReason()) |reason| {
        // THE FAILURES ARE DISTINCT and the sender must be able to branch
        // on them: a typo is the sender's to fix, a partition is not, and
        // a contested name is neither. The status name carries the
        // difference for a script; the text carries it for a human. Both
        // come from the enum that defines the outcome, so a new outcome
        // cannot arrive here without words.
        try data_obj.put(arena, "reason", .{ .string = reason });
        try sendResponse(arena, conn, envelope.id, envelope.source, false, .{ .object = data_obj }, reason);
        return;
    }
    state.noteMessageRouted(envelope.source, target);
    try sendResponse(arena, conn, envelope.id, envelope.source, true, .{ .object = data_obj }, null);
}

// ---------------------------------------------------------------------------
// Handler: mailbox_recv per [[RFC-0008:C-MAILBOX]] (daemon relay drain)
// ---------------------------------------------------------------------------

pub fn handleMailboxRecv(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
    const msgs = try state.mailboxDrainFor(conn, arena);
    var array = json.Array.init(arena);
    for (msgs) |m| try array.append(.{ .string = m });
    var data_obj = json.ObjectMap.empty;
    try data_obj.put(arena, "messages", .{ .array = array });
    try sendResponse(arena, conn, envelope.id, envelope.source, true, .{ .object = data_obj }, null);
}

// ---------------------------------------------------------------------------
// Handlers: exec routing per [[RFC-0007:C-PRIMITIVES]]
// ---------------------------------------------------------------------------

/// exec_request (agent → hub): forward to the workbench control endpoint.
/// The agent stays connected (registered id) so the workbench's
/// exec_response routes back to it. Fail fast when no workbench listens.
pub fn handleExecRequest(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
    if (!state.execForward(envelope)) {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "no workbench available");
    }
    // Success is asynchronous: the workbench replies with exec_response
    // (routed via recordExecReceipt). No synchronous ok here.
}

/// exec_receipt (workbench → hub): record the receipt event and route
/// exec_response back to the requester. Anonymous one-shot, like
/// wake_report (workbench authority). Payload fields: kind, owner,
/// generation, pane, detail, requester, request_id, plus the response
/// data object echoed to the agent.
pub fn handleExecReceipt(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
    const payload = if (envelope.payload == .object) envelope.payload.object else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing payload");
        return;
    };
    const kind_str = objGetString(payload, "kind") orelse "";
    // read is DELIBERATELY NOT receipted (RFC-0007 C-PRIMITIVES: reads
    // are passive observation) — but its excerpt still routes back to the
    // agent. `exec_read` = route the response WITHOUT appending an event.
    const log_kind: ?registry.events.EventKind = if (mem.eql(u8, kind_str, "exec_pane_opened"))
        .exec_pane_opened
    else if (mem.eql(u8, kind_str, "exec_command_ran"))
        .exec_command_ran
    else if (mem.eql(u8, kind_str, "exec_wait_completed"))
        .exec_wait_completed
    else if (mem.eql(u8, kind_str, "exec_pane_closed"))
        .exec_pane_closed
    else if (mem.eql(u8, kind_str, "exec_read"))
        null // route-only, no event
    else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "invalid exec receipt kind");
        return;
    };
    const owner = objGetString(payload, "owner") orelse "";
    const requester = objGetString(payload, "requester") orelse "";
    const request_id = objGetString(payload, "request_id") orelse "exec";
    const pane = objGetString(payload, "pane");
    const detail = objGetString(payload, "detail");
    const gen: ?u64 = blk: {
        if (payload.get("generation")) |v| {
            if (v == .integer and v.integer >= 0) break :blk @intCast(v.integer);
        }
        break :blk null;
    };
    // The response echoed to the agent: the receipt's data object (outcome,
    // excerpt, pane handle) under the original request id.
    const data: ?json.Value = payload.get("data");
    var resp_payload = json.ObjectMap.empty;
    try resp_payload.put(arena, "ok", .{ .bool = true });
    if (data) |d| try resp_payload.put(arena, "data", d);
    const response = protocol.Envelope{
        .@"type" = "exec_response",
        .id = request_id,
        .source = "hub",
        .target = requester,
        .payload = .{ .object = resp_payload },
    };
    _ = state.recordExecReceipt(log_kind, owner, gen, pane, detail, requester, response);
    // Ack the workbench's one-shot.
    try sendResponse(arena, conn, envelope.id, envelope.source, true, null, null);
}

// ---------------------------------------------------------------------------
// Handler: hub_info per [[ADR-0008]] (adoption handshake)
// ---------------------------------------------------------------------------

/// Build identity of this hub, set once at startup by the entry point.
/// A workbench asks BEFORE adopting a listener, so version skew cannot be
/// adopted in silence ([[ADR-0008]], [[WI-2026-08-14-005]]).
pub var build_id: []const u8 = @import("build_options").build_id;
/// True when a workbench spawned us with --parent-pid. A workbench may
/// take over a stale hub it owns; a foreign listener it must not touch.
pub var workbench_spawned: bool = false;
/// Port actually bound (published so the asker never has to guess).
pub var bound_port: u16 = 0;

/// `set_log_level` — [[RFC-0012]] C-LEVEL-CONTROL.
///
/// A DEDICATED FRAME rather than a field on hub_info. Overloading the
/// query would have been one less frame and one more ambiguity: a frame
/// named for asking must not also set, or the next reader cannot tell
/// which calls are safe to repeat.
///
/// Takes effect immediately and without a restart, which is the whole
/// point — restarting a hub severs A2A for every agent working on that
/// machine, so "raise the level and reproduce it" would destroy the thing
/// being diagnosed.
pub fn handleSetLogLevel(
    state: *HubState,
    conn: *Connection,
    arena: Allocator,
    envelope: protocol.Envelope,
) !void {
    _ = state;
    const payload = if (envelope.payload == .object) envelope.payload.object else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing payload");
        return;
    };
    const raw = blk: {
        if (payload.get("level")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk "";
    };
    const level = diag.levelFromString(raw) orelse {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null,
            "level must be one of err, warn, info, debug");
        return;
    };
    // ANNOUNCE FIRST, THEN APPLY. Applying first filters the
    // announcement by the level it is announcing: setting `err`
    // suppresses the record of having set `err`, so the log goes quiet
    // with nothing saying why.
    //
    // At WARN, by this project's own severity rule rather than by
    // instinct. C-SEVERITY reserves err for a broken promise or a
    // capability that silently vanished, and a level change is neither —
    // it is warn's definition exactly: a deliberate degradation that
    // changes what you can expect. Ordering, not severity, was the fix.
    log.warn("log level set to {s}", .{@tagName(level)});
    diag.setLevel(level);
    var data = json.ObjectMap.empty;
    try data.put(arena, "level", .{ .string = @tagName(level) });
    try sendResponse(arena, conn, envelope.id, envelope.source, true, .{ .object = data }, null);
}

pub fn handleHubInfo(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
    var data = json.ObjectMap.empty;
    try data.put(arena, "build", .{ .string = build_id });
    try data.put(arena, "pid", .{ .integer = @intCast(std.c.getpid()) });
    try data.put(arena, "workbench_spawned", .{ .bool = workbench_spawned });
    // Live supervisor links, which is how a caller tells a STALE hub from
    // one another workbench is still using. A subscriber is a supervisor
    // ([[ADR-0008]]); a hub_info query is one-shot and never subscribes,
    // so asking does not inflate the answer.
    try data.put(arena, "supervisors", .{
        .integer = if (state.supervision) |sup| @intCast(sup.supervisorCount()) else 0,
    });
    try data.put(arena, "port", .{ .integer = @intCast(bound_port) });
    // WHAT THE HUB REPORTS IS AUTHORITATIVE ([[RFC-0010]]
    // C-PEER-IDENTITY). This said `hub --ensure` compares the id "against
    // the label it was asked to install" and reports a mismatch — which
    // is the rule that clause superseded: the id is `<label>-<suffix>`,
    // MINTED ONCE by the hub and persisted, and the label is half of it.
    // A rename must not change what directory entries, spooled messages
    // and qualified fallback ids are keyed on, so there is no mismatch to
    // report; a caller that provisioned this hub accepts what it reports
    // rather than proposing a value, which is why `peer_connect` refuses
    // to rename a hub that already has an identity.
    // The links this hub already holds. A workbench that just launched
    // needs these: the hub outlives it, so it is routinely already
    // federated while the workbench knows nothing about it.
    try data.put(arena, "peers", try state.peerLinksJson(arena));
    try data.put(arena, "peer_id", .{
        .string = (state.peerIdDupe(arena) catch null) orelse "",
    });
    try sendResponse(arena, conn, envelope.id, envelope.source, true, .{ .object = data }, null);
}

// ---------------------------------------------------------------------------
// Handler: wake_report per [[RFC-0005:C-WAKE-ACK]] (workbench receipts)
// ---------------------------------------------------------------------------

/// The workbench reports each injection's outcome so wake behavior is
/// debuggable from the same event log as presence: delivered (working
/// edge inside the ack window, resolves the candidate) or stalled
/// (no edge; the candidate stays outstanding — mail is still waiting).
pub fn handleWakeReport(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
    const payload = if (envelope.payload == .object) envelope.payload.object else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing payload");
        return;
    };
    const agent = objGetString(payload, "agent") orelse {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing agent");
        return;
    };
    const outcome_str = objGetString(payload, "outcome") orelse "";
    const outcome: registry.HubState.WakeOutcome = if (mem.eql(u8, outcome_str, "delivered"))
        .delivered
    else if (mem.eql(u8, outcome_str, "stalled"))
        .stalled
    else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "invalid outcome (delivered|stalled)");
        return;
    };
    const generation: ?u64 = blk: {
        if (payload.get("generation")) |v| {
            if (v == .integer and v.integer >= 0) break :blk @intCast(v.integer);
        }
        break :blk null;
    };
    state.recordWakeReport(agent, generation, outcome);
    try sendResponse(arena, conn, envelope.id, envelope.source, true, null, null);
}

// ---------------------------------------------------------------------------
// Handler: channel_create per [[RFC-0003:C-A2A-REDUCTION]] (legacy group-chat surface)
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
// Handler: channel_invite per [[RFC-0003:C-A2A-REDUCTION]] (legacy group-chat surface)
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
// Handler: channel_leave per [[RFC-0003:C-A2A-REDUCTION]] (legacy group-chat surface)
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
// Handler: channel_msg per [[RFC-0003:C-A2A-REDUCTION]] (legacy group-chat surface)
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

    // Log per [[RFC-0003]] (hub state).
    state.message_log.append(state.allocator, .{
        .from = envelope.source,
        .to = target,
        .channel = ch_name,
        .text = text,
        .ts = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds(),
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
// Handler: list_channels per [[RFC-0003:C-CLI-TOOLS]] (daemon socket)
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

/// [[RFC-0009]] C-BOUNDARIES: the OBSERVER vocabulary, which is the whole
/// of what a connection holding no identity may say.
///
/// ONE LIST, NOT TWO. The session loop classifies a connection by its
/// OPENING frame and this decides what may follow on it; when those were
/// two copies of the same names, only the opener was ever checked.
pub fn isObserverFrame(t: []const u8) bool {
    const vocabulary = [_][]const u8{
        "hub_info",     "list_agents",  "subscribe",    "tool_request",
        "agent_status", "wake_report",  "exec_receipt", "tool_receipt",
        "peer_connect", "set_log_level",
    };
    for (vocabulary) |v| if (std.mem.eql(u8, t, v)) return true;
    return false;
}

/// Dispatch on a connection that holds NO identity.
///
/// A one-shot connection may carry more than one frame — a client can put
/// two lines in one write — and every line after the first used to reach
/// the full dispatch. So `hub_info` followed by `dm` sent mail from an
/// unidentified connection, under whatever `source` the first frame had
/// named: the residual half of C-BOUNDARIES ("an observer connection is
/// refused EVERY frame outside the observer vocabulary") had no code.
pub fn dispatchObserverEnvelope(
    state: *HubState,
    arena: Allocator,
    conn: *Connection,
    bound_id: []const u8,
    envelope: protocol.Envelope,
) !void {
    if (!isObserverFrame(envelope.@"type")) {
        log.warn("observer connection sent '{s}', which is not its to send — refused", .{envelope.@"type"});
        return;
    }
    return dispatchEnvelope(state, arena, conn, bound_id, envelope);
}

pub fn dispatchEnvelope(state: *HubState, arena: Allocator, conn: *Connection, agent_id: []const u8, envelope: protocol.Envelope) void {
    const msg_type = envelope.@"type";

    const result: anyerror!void = if (mem.eql(u8, msg_type, "list_agents"))
        handleListAgents(state, arena, conn, envelope)
    else if (mem.eql(u8, msg_type, "list_channels"))
        handleListChannels(state, conn, arena, envelope)
    else if (mem.eql(u8, msg_type, "agent_update"))
        handleAgentUpdate(state, conn, arena, envelope)
    else if (mem.eql(u8, msg_type, "mailbox_recv"))
        handleMailboxRecv(state, conn, arena, envelope)
    else if (mem.eql(u8, msg_type, "wake_report"))
        handleWakeReport(state, conn, arena, envelope)
    else if (mem.eql(u8, msg_type, "set_log_level"))
        handleSetLogLevel(state, conn, arena, envelope)
    else if (mem.eql(u8, msg_type, "hub_info"))
        handleHubInfo(state, conn, arena, envelope)
    else if (mem.eql(u8, msg_type, "exec_request"))
        handleExecRequest(state, conn, arena, envelope)
    else if (mem.eql(u8, msg_type, "exec_receipt"))
        handleExecReceipt(state, conn, arena, envelope)
    else if (mem.eql(u8, msg_type, "tool_receipt"))
        handleToolReceipt(state, conn, arena, envelope)
    else if (mem.eql(u8, msg_type, "peer_connect"))
        handlePeerConnect(state, conn, arena, envelope)
    else if (mem.eql(u8, msg_type, "agent_status"))
        handleAgentStatus(state, conn, arena, envelope)
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

/// Per-connection receive buffer size (64 KiB).
pub const recv_buf_size = 64 * 1024;

// ---------------------------------------------------------------------------
// Tool requests — [[RFC-0003]] C-EVENTS, as amended
//
// THE HUB DOES NOT EXECUTE TASK TOOLS AND DOES NOT TOUCH THE KEYCHAIN.
// Loading the GitHub PAT here would make the hub non-relocatable
// regardless of any process boundary: a hub on a Linux server has no
// Keychain, no `security` CLI and no token. [[ADR-0008]] decision 6 — a
// hub routes; anything requiring the human's credentials executes at the
// workbench. There is deliberately no `@import("github")` in this file,
// so the property is visible at the import list rather than asserted in
// a comment.
//
// The forwarding shape is the one exec and wake already use: broadcast the
// control frame to the workbench subscriber and let it answer on a one-shot
// receipt. What does NOT move is attribution: RFC-0003 stamps the
// requesting CONNECTION's bound identity, and only the hub knows which
// identity a connection holds — an agent-composed signature would be
// forgeable prose, and an executor-composed one would be a claim the
// executor cannot verify. So the hub stamps, then forwards.
// ---------------------------------------------------------------------------

/// Send a tool_response envelope.
fn sendToolResponse(arena: Allocator, conn: *Connection, req_id: []const u8, target: []const u8, ok: bool, data: ?json.Value, err_msg: ?[]const u8) !void {
    try sendHubEnvelope(arena, conn, req_id, target, ok, data, err_msg, "tool_response");
}

/// Extract a string field from a JSON object.
fn objGetString(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// RFC-0003 1.1.0 attribution (WI-2026-08-11-018): stamp task-center
/// prose with the requesting connection's bound identity — HUB-side, so
/// agents cannot sign as each other. A visible one-line footer plus a hidden HTML
/// marker for machine parsing. Human-class requests pass through
/// unstamped: the PAT owner IS the human (tool==human, unregistered
/// connections, anonymous one-shots).
pub fn stampAttribution(arena: Allocator, state: *HubState, conn: *Connection, body: []const u8) []const u8 {
    const bound = (conn.boundIdDupe(arena) catch null) orelse return body;
    const info = state.agent_registry.get(bound, arena) orelse return body;
    const tool = info.tool orelse return body;
    if (mem.eql(u8, tool, "human") or mem.eql(u8, tool, "-")) return body;
    return std.fmt.allocPrint(
        arena,
        "{s}\n\n---\n\u{1F916} `{s}` · via Synapty\n<!-- synapty-agent: {s} -->",
        .{ body, bound, bound },
    ) catch body;
}

/// Short human-readable summary of tool args for the activity stream.
fn summarizeToolArgs(arena: Allocator, tool: []const u8, args: json.ObjectMap) []const u8 {
    if (mem.eql(u8, tool, "task.list")) {
        if (objGetString(args, "labels")) |l| {
            return std.fmt.allocPrint(arena, "list {s}", .{l}) catch "list";
        }
        return "list";
    }
    if (mem.eql(u8, tool, "task.claim") or mem.eql(u8, tool, "task.update") or
        mem.eql(u8, tool, "task.comment") or mem.eql(u8, tool, "task.show"))
    {
        const number = if (args.get("number")) |n| switch (n) {
            .integer => |i| std.fmt.allocPrint(arena, "{d}", .{i}) catch "?",
            else => "?",
        } else "?";
        if (mem.eql(u8, tool, "task.show")) return std.fmt.allocPrint(arena, "show #{s}", .{number}) catch "show";
        if (mem.eql(u8, tool, "task.claim")) return std.fmt.allocPrint(arena, "claim #{s}", .{number}) catch "claim";
        if (mem.eql(u8, tool, "task.update")) {
            const status = objGetString(args, "status") orelse "?";
            return std.fmt.allocPrint(arena, "update #{s} -> {s}", .{ number, status }) catch "update";
        }
        const body = objGetString(args, "body") orelse "";
        const short = if (body.len > 24) body[0..24] else body;
        return std.fmt.allocPrint(arena, "comment #{s}: {s}", .{ number, short }) catch "comment";
    }
    if (mem.eql(u8, tool, "task.create")) {
        const title = objGetString(args, "title") orelse "";
        const short = if (title.len > 32) title[0..32] else title;
        return std.fmt.allocPrint(arena, "create \"{s}\"", .{short}) catch "create";
    }
    return tool;
}

/// tool "activity.list" — return the recent activity stream.
fn handleActivityList(arena: Allocator, state: *HubState, conn: *Connection, req_id: []const u8, source: []const u8) !void {
    const data = try state.activity_log.toJson(arena, 50);
    try sendToolResponse(arena, conn, req_id, source, true, data, null);
}

/// Forward a credential-bound tool request to the workbench and leave the
/// requester waiting for the asynchronous tool_response. Attribution is
/// applied HERE, before the frame leaves, for the reason in this section's
/// header comment.
fn forwardToolRequest(
    state: *HubState,
    arena: Allocator,
    conn: *Connection,
    envelope: protocol.Envelope,
    tool: []const u8,
    args: json.ObjectMap,
) !void {
    var out_args = try args.clone(arena);
    if (mem.eql(u8, tool, "task.comment")) {
        const body = objGetString(args, "body") orelse "";
        try out_args.put(arena, "body", .{ .string = stampAttribution(arena, state, conn, body) });
    } else if (mem.eql(u8, tool, "task.create")) {
        // An absent body becomes footer-only: the attribution alone is
        // signal, and a created issue with no author is worse than a
        // one-line one.
        const stamped = stampAttribution(arena, state, conn, objGetString(args, "body") orelse "");
        if (stamped.len > 0) try out_args.put(arena, "body", .{ .string = stamped });
    }

    var payload = json.ObjectMap.empty;
    try payload.put(arena, "tool", .{ .string = tool });
    try payload.put(arena, "args", .{ .object = out_args });
    try payload.put(arena, "requester", .{ .string = envelope.source });
    try payload.put(arena, "request_id", .{ .string = envelope.id });

    const forwarded = protocol.Envelope{
        .@"type" = "tool_request",
        .id = envelope.id,
        .source = "hub",
        .target = "workbench",
        .payload = .{ .object = payload },
    };
    if (!state.toolForward(envelope.source, envelope.id, conn, forwarded)) {
        // FAIL FAST, never queue. A task claimed eight hours after it was
        // asked for is worse than a refusal, because the world has moved
        // on (the mailbox rule is the opposite, and registry says why).
        try sendToolResponse(arena, conn, envelope.id, envelope.source, false, null, "no workbench available");
    }
    // Success is asynchronous: the workbench answers with tool_receipt.
}

/// tool_receipt (workbench → hub): route tool_response back to the agent
/// that asked. Anonymous one-shot, same authority geometry as exec_receipt
/// and wake_report.
pub fn handleToolReceipt(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
    const payload = if (envelope.payload == .object) envelope.payload.object else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing payload");
        return;
    };
    const request_id = objGetString(payload, "request_id") orelse {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing request_id");
        return;
    };
    const requester = objGetString(payload, "requester") orelse "";
    const ok = if (payload.get("ok")) |v| (v == .bool and v.bool) else false;
    const data: ?json.Value = payload.get("data");
    const err_msg: ?[]const u8 = objGetString(payload, "error");

    var resp_payload = json.ObjectMap.empty;
    try resp_payload.put(arena, "ok", .{ .bool = ok });
    if (data) |d| try resp_payload.put(arena, "data", d);
    if (err_msg) |e| try resp_payload.put(arena, "error", .{ .string = e });

    const routed = state.routeToolResponse(request_id, .{
        .@"type" = "tool_response",
        .id = request_id,
        .source = "hub",
        .target = requester,
        .payload = .{ .object = resp_payload },
    });
    if (!routed) log.warn("tool_receipt for {s}: requester gone", .{request_id});
}

/// Relay-link frame dispatch, shared by BOTH halves of a link: the
/// accepting side (session.zig) and the dialing side (peer.zig). It lives
/// here because there were two copies of it — written by copy-paste when
/// the dialing half was added — and a duplicated dispatcher means every
/// new relay frame has to be remembered twice, with a miss producing no
/// compile error and no test failure (the tests only drove one side).
///
/// A DELIBERATELY SMALL vocabulary, disjoint from the submission one: a
/// peer can move mail, sync the directory and relay presence conclusions,
/// and nothing else. Notably absent — register, dm, exec_request,
/// tool_request — because a peer must not be able to act with a local
/// agent's authority or borrow this workbench's.
pub fn dispatchRelayFrame(
    state: *HubState,
    arena: Allocator,
    conn: *Connection,
    peer: []const u8,
    envelope: protocol.Envelope,
) void {
    const t = envelope.@"type";
    if (mem.eql(u8, t, "relay_advertise")) {
        handleRelayAdvertise(state, arena, conn, peer, envelope) catch {};
    } else if (mem.eql(u8, t, "relay_forward")) {
        handleRelayForward(state, arena, conn, peer, envelope) catch {};
    } else if (mem.eql(u8, t, "relay_presence")) {
        handleRelayPresence(state, peer, envelope);
    } else if (mem.eql(u8, t, "relay_ack")) {
        // THE ANSWER THE SENDER IS WAITING FOR. `forwarded` means the
        // peer took it, so this is where a written frame becomes a
        // delivered one ([[RFC-0009]] C-DELIVERY). The id is the forward
        // id the sender minted and this frame echoes.
        log.debug("relay: ack from {s} for {s}", .{ peer, envelope.id });
        state.completeForward(envelope.id, true, "");
        // AND THE HELD COPY IS FINISHED WITH. Released HERE and not
        // inside `completeForward`, which holds `forward_mutex` while the
        // spool needs `presence_mutex` — the established order is
        // presence then forward, and inverting it is a deadlock waiting
        // for two peers to answer at once.
        state.releaseSpooled(peer, envelope.id, true);
    } else if (mem.eql(u8, t, "relay_nack")) {
        const reason = if (envelope.payload == .object)
            (objGetString(envelope.payload.object, "error") orelse "unavailable")
        else
            "unavailable";
        log.warn("relay: {s} refused {s} ({s})", .{ peer, envelope.id, reason });
        state.completeForward(envelope.id, false, reason);
        state.releaseSpooled(peer, envelope.id, false);
    } else {
        log.warn("relay: unexpected frame '{s}' from {s} — ignored", .{ t, peer });
    }
}

/// peer_connect (workbench → hub): dial a peer hub reachable at
/// 127.0.0.1:<port> — the local end of an SSH tunnel the workbench
/// established.
///
/// NOTHING HERE VERIFIES THAT ([[RFC-0009]] C-BOUNDARIES, which retracted
/// the claim this comment used to make). A relay link is authenticated by
/// nothing a hub can check — it arrives on the same loopback listener as
/// every submission — so there is no credential to invent here AND none
/// to verify: that a human named this peer is the workbench's duty to
/// honour, and what this hub enforces is only what it can see, which is
/// that it dials what it was asked to and never a second link to a peer
/// id already held.
///
/// The workbench asks at CONNECT time rather than the hub reading a peer
/// list at startup, because which hosts are reachable is a fact only the
/// workbench has — it is the one holding the SSH machinery.
pub fn handlePeerConnect(state: *HubState, conn: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
    const payload = if (envelope.payload == .object) envelope.payload.object else {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing payload");
        return;
    };
    // `self_peer_id` MUST NOT OVERRIDE this hub's name. A hub that mints
    // `deskmac-2630`, reports it, and then answers to `deskmac` because a
    // workbench asked it to dial has discarded the identity every peer
    // keys its directory and spool on — silently, since both names look
    // plausible ([[RFC-0010]] C-PEER-IDENTITY).
    //
    // [[RFC-0010]] C-PEER-IDENTITY: a machine owns its name. The field is
    // accepted only when this hub has NO identity at all, which is a
    // state that should not occur — the hub mints at startup — and is
    // handled rather than assumed away.
    if (state.peer_id == null) {
        if (payload.get("self_peer_id")) |v| {
            if (v == .string) state.setPeerId(v.string) catch {};
        }
    }
    if (state.peer_id == null) {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "this hub has no peer id");
        return;
    }
    // Port validation AFTER the identity check: a hub with no name cannot
    // introduce itself no matter where it dials, so refusing on that is
    // the more fundamental answer — and it means a refused request spawns
    // no dial thread at all.
    const port: u16 = blk: {
        const v = payload.get("port") orelse break :blk 0;
        if (v == .integer and v.integer > 0 and v.integer <= 65535) break :blk @intCast(v.integer);
        break :blk 0;
    };
    if (port == 0) {
        try sendResponse(arena, conn, envelope.id, envelope.source, false, null, "missing or invalid port");
        return;
    }
    state.dialPeer(port);
    try sendResponse(arena, conn, envelope.id, envelope.source, true, null, null);
}

/// Dispatcher for tool_request envelopes.
fn handleToolRequest(state: *HubState, arena: Allocator, conn: *Connection, envelope: protocol.Envelope) !void {
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

    // Record the tool request in the activity stream (C-HUB-ROLE).
    const detail = summarizeToolArgs(arena, tool, args);
    state.activity_log.append(state.allocator, .{
        .ts = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds(),
        .agent = source,
        .tool = tool,
        .detail = detail,
    }) catch {};

    if (tools.isCredentialTool(tool))
        return forwardToolRequest(state, arena, conn, envelope, tool, args)
    else if (mem.eql(u8, tool, "activity.list"))
        return handleActivityList(arena, state, conn, req_id, source)
    else {
        try sendToolResponse(arena, conn, req_id, source, false, null, "unknown tool");
        return;
    }
}

test "stampAttribution: agents stamp, humans and unregistered pass through (WI-2026-08-11-018)" {
    std.testing.log_level = .err;
    const sys = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), testNoopRelease);
    defer conn.deinit();

    // Unregistered connection: pass-through.
    try std.testing.expectEqualStrings("hello", stampAttribution(a, &state, &conn, "hello"));

    // Registered as a human pane: pass-through (the PAT owner IS the human).
    _ = try state.registerAgentTracked("local-att1", &conn);
    try conn.setIdentity("local-att1");
    try state.updateAgentTracked("local-att1", .{ .tool = "human" });
    try std.testing.expectEqualStrings("hello", stampAttribution(a, &state, &conn, "hello"));

    // Durable agent identity: footer + hidden marker, hub-resolved (an
    // agent cannot sign as anyone but its own bound identity).
    _ = try state.bindDurableIdTracked(&conn, "claude-attest01", "attest01-ref-9999");
    try state.updateAgentTracked("claude-attest01", .{ .tool = "claude" });
    const stamped = stampAttribution(a, &state, &conn, "did the thing");
    try std.testing.expect(std.mem.startsWith(u8, stamped, "did the thing\n\n---\n"));
    try std.testing.expect(std.mem.indexOf(u8, stamped, "`claude-attest01` · via Synapty") != null);
    try std.testing.expect(std.mem.indexOf(u8, stamped, "<!-- synapty-agent: claude-attest01 -->") != null);
}

fn testNoopRelease(_: *anyopaque, _: *Connection) void {}

// ---------------------------------------------------------------------------
// Handlers: relay link — [[RFC-0009]] C-BOUNDARIES / C-DIRECTORY / C-DELIVERY
//
// A relay link is the OTHER kind of connection: it carries MANY identities,
// authenticated by nothing this hub can check, where a submission
// connection carries exactly one for its lifetime. The two are distinguished by the first frame and
// nothing else, so a hub never has to guess which rule set it is under —
// which is why relay_hello is mandatory and why these handlers are never
// reachable from dispatchEnvelope.
// ---------------------------------------------------------------------------

/// Peer id + protocol version exchange. Returns the validated peer id
/// (arena-owned) or null when the handshake must be refused.
pub fn handleRelayHello(
    state: *HubState,
    arena: Allocator,
    conn: *Connection,
    envelope: protocol.Envelope,
) !?[]const u8 {
    const peer = envelope.source;
    if (!federation.validPeerId(peer)) {
        try sendRelayRefusal(state, arena, conn, envelope.id, peer, .invalid_peer_id,
            "the peer id is not a valid identifier");
        return null;
    }
    // Negotiate BEFORE bringing the link up: a link we cannot interpret
    // must be refused here, not discovered frame by frame.
    const their = parseHelloVersioning(envelope) orelse {
        try sendRelayRefusal(state, arena, conn, envelope.id, peer, .malformed_hello,
            "relay_hello must carry protocol_min, protocol_max and capabilities");
        return null;
    };
    const agreed = federation.negotiateVersion(their.min, their.max) orelse {
        try sendVersionRefusal(state, arena, conn, envelope.id, peer, their.min, their.max);
        return null;
    };
    state.peerLinkUp(peer, conn, 0, agreed, their.caps) catch |err| switch (err) {
        // Two machines answering to one name misroutes every message
        // between them. Surface it; never rename either side.
        error.PeerIdInUse => {
            try sendRelayRefusal(state, arena, conn, envelope.id, peer, .peer_id_in_use,
                "another machine is already linked under this peer id — " ++
                    "re-mint the id on one of them (`synapty hub --remint`); " ++
                    "renaming will not help, the label and the id are independent");
            return null;
        },
        else => return err,
    };
    // THE UNDO BELONGS NEXT TO THE DO. Everything below can fail, and
    // until this errdefer existed the only teardown was the caller's
    // `defer`, which is not installed until this function returns — so
    // the whole tail ran unguarded. The dialing caller in peer.zig never
    // had the window because its defer sits on the line after peerLinkUp;
    // this caller does, and the asymmetry is exactly the kind that
    // survives review. A failure here must leave no PeerLink pointing at
    // a Connection that is about to be destroyed.
    errdefer state.peerLinkDown(peer);
    var data = json.ObjectMap.empty;
    // Read under the lock: setPeerId frees the old value, and the null→set
    // transition is exactly when a relay hello can arrive.
    try data.put(arena, "peer", .{ .string = (try state.peerIdDupe(arena)) orelse "" });
    try putVersioning(arena, &data);
    try sendHubEnvelope(arena, conn, envelope.id, peer, true, .{ .object = data }, null, "relay_hello");
    // Start consistent: the full set, then incremental changes.
    state.advertiseAllTo(conn);
    // Statuses too, or an agent that reached `waiting` before the link
    // came up stays `unknown` on the peer until it moves again — and only
    // if the peer declared it can receive them.
    state.relayPresenceAllTo(conn, their.caps);
    // C-DELIVERY flush order: spooled traffic precedes new traffic.
    _ = state.flushSpoolTo(peer);
    return try arena.dupe(u8, peer);
}

pub const HelloVersioning = struct {
    min: u16 = federation.protocol_min,
    max: u16 = federation.protocol_min,
    caps: federation.CapabilitySet = .{},
    unknown_caps: usize = 0,
};

/// Read the version range and capability set off a relay_hello. REQUIRED,
/// not optional: a hello without them is MALFORMED and is refused.
///
/// An earlier version of this accepted a hello with no versioning and read
/// it as "the oldest version with no capabilities", to be kind to
/// pre-negotiation builds. Synapty is unreleased, so no such build exists
/// to be kind to — and the leniency was itself a silent-failure path of
/// exactly the kind this negotiation exists to remove: any future bug that
/// dropped the capability field would present as "that peer is older"
/// rather than "that handshake is broken". Loud beats lenient when there
/// is nothing legacy to carry.
pub fn parseHelloVersioning(envelope: protocol.Envelope) ?HelloVersioning {
    var out = HelloVersioning{};
    const obj = blk: {
        if (envelope.payload != .object) break :blk null;
        // The accepting side answers inside `data`; an opening hello puts
        // them at the top level.
        if (envelope.payload.object.get("data")) |d| {
            if (d == .object) break :blk d.object;
        }
        break :blk envelope.payload.object;
    } orelse return null;

    const min_v = obj.get("protocol_min") orelse return null;
    const max_v = obj.get("protocol_max") orelse return null;
    if (min_v != .integer or max_v != .integer) return null;
    if (min_v.integer < 0 or max_v.integer < 0) return null;
    out.min = @intCast(@min(min_v.integer, 65535));
    out.max = @intCast(@min(max_v.integer, 65535));
    // An inverted range is a malformed hello, not a range to repair — a
    // silent repair here would hide whatever produced it.
    if (out.max < out.min) return null;

    // The capability list is REQUIRED and may be empty. Empty says "I
    // provide nothing optional", which is a real and different statement
    // from "I did not say" — and only the first is something a peer can
    // act on.
    const caps_v = obj.get("capabilities") orelse return null;
    if (caps_v != .array) return null;
    var names_buf: [32][]const u8 = undefined;
    var n: usize = 0;
    for (caps_v.array.items) |item| {
        if (item != .string or n >= names_buf.len) continue;
        names_buf[n] = item.string;
        n += 1;
    }
    out.caps = federation.CapabilitySet.fromNames(names_buf[0..n], &out.unknown_caps);
    return out;
}

/// Put this build's range and capabilities on an outgoing hello.
pub fn putVersioning(arena: Allocator, obj: *json.ObjectMap) !void {
    try obj.put(arena, "protocol_min", .{ .integer = federation.protocol_min });
    try obj.put(arena, "protocol_max", .{ .integer = federation.protocol_max });
    var caps = json.Array.init(arena);
    for (federation.local_capabilities) |c| try caps.append(.{ .string = c.toString() });
    try obj.put(arena, "capabilities", .{ .array = caps });
}

/// A version refusal carries BOTH ranges, so a human can see which side
/// has to move rather than being told only that it failed.
fn sendVersionRefusal(
    state: *HubState,
    arena: Allocator,
    conn: *Connection,
    req_id: []const u8,
    peer: []const u8,
    their_min: u16,
    their_max: u16,
) !void {
    var data = json.ObjectMap.empty;
    try data.put(arena, "reason", .{ .string = federation.RefusalReason.version_incompatible.toString() });
    try data.put(arena, "their_min", .{ .integer = @intCast(their_min) });
    try data.put(arena, "their_max", .{ .integer = @intCast(their_max) });
    try data.put(arena, "our_min", .{ .integer = federation.protocol_min });
    try data.put(arena, "our_max", .{ .integer = federation.protocol_max });
    recordRefusal(state, peer, .version_incompatible);
    try sendHubEnvelope(arena, conn, req_id, "", false, .{ .object = data },
        "no protocol version in common — one side needs upgrading", "relay_refused");
}

/// THE LOCAL HALF OF A REFUSAL ([[RFC-0009]] C-EVENT-LOCALITY).
///
/// Minted HERE, beside the frame, and not at the call sites: the refusal
/// frame travels to the DIALLING side, which in a peer id collision is the
/// machine at fault — so the hub that knows is the one with no record, and
/// an operator reading the machine that reported nothing is reading the
/// only machine with the answer. A refusal reason added later cannot
/// forget this, because the only way to send one is through these two
/// functions.
fn recordRefusal(state: *HubState, peer: []const u8, reason: federation.RefusalReason) void {
    // THE LOG IS CALLER-LOCKED (events.zig: "callers hold
    // HubState.presence_mutex so the append is atomic with the state
    // mutation it records"), and this was the one append that did not —
    // it runs on the relay reader thread during the handshake, racing
    // every locked append with a reallocating list ([[WI-2026-09-02-014]]).
    // Neither caller holds the mutex here (both refuse before any peer
    // state is touched), so it is taken and released in this function.
    state.presence_mutex.lock(io_mod.get()) catch unreachable;
    defer state.presence_mutex.unlock(io_mod.get());
    _ = state.event_log.append(.{
        .kind = .peer_link_refused,
        // The id the DIALLER CLAIMED, which for `invalid_peer_id` is a
        // claim rather than an identity — and is still the only thing
        // that identifies who was turned away.
        .agent = peer,
        .peer = peer,
        .reason = reason.toString(),
    }) catch 0;
}

/// A refused relay handshake, as its own frame type rather than a generic
/// response ([[RFC-0010]] C-COLLISION). The dialing side previously saw
/// "not a relay_hello", logged it and closed, so a human got a link that
/// simply did not come up and no statement of why. The `reason` code is
/// machine-readable and the reasons stay distinct because the
/// human's next action differs for each: re-mint an id, fix a
/// configuration, upgrade a build.
fn sendRelayRefusal(
    state: *HubState,
    arena: Allocator,
    conn: *Connection,
    req_id: []const u8,
    peer: []const u8,
    reason: federation.RefusalReason,
    detail: []const u8,
) !void {
    var data = json.ObjectMap.empty;
    try data.put(arena, "reason", .{ .string = reason.toString() });
    recordRefusal(state, peer, reason);
    try sendHubEnvelope(arena, conn, req_id, "", false, .{ .object = data }, detail, "relay_refused");
}

/// Directory exchange. `added` / `removed` are arrays of qualified ids.
/// THE LINK SAYS WHICH PEER, AND NOTHING ELSE DOES ([[RFC-0009]]
/// C-DIRECTORY). Where an advertised id carries a qualifier, that
/// qualifier MUST name the sending peer or the entry is REFUSED —
/// otherwise a peer could attribute identities to a machine it has no
/// relationship with, and every later boundary keyed on the qualifier
/// would honour the attribution: a forward stamped with that source is
/// admitted, and a send to it is routed to whoever claimed it.
///
/// AN UNQUALIFIED ID IS NOT A VIOLATION. Durable ids are advertised
/// unqualified by design (C-IDENTITY-SCOPE: qualification is for the
/// machine-scoped `local-` fallback), so absence of a qualifier says the
/// sending peer hosts it, which is what the link already said.
fn qualifierNamesSender(peer: []const u8, advertised: []const u8) bool {
    const q = federation.splitQualifier(advertised);
    const named = q.peer orelse return true;
    if (mem.eql(u8, named, peer)) return true;
    log.warn(
        "relay: {s} advertised '{s}', whose qualifier names {s} — refused (C-DIRECTORY)",
        .{ peer, advertised, named },
    );
    return false;
}

/// The peer hosts more identities than this hub will record for one
/// peer, so the LINK goes rather than the surplus identity ([[RFC-0009]]
/// C-DIRECTORY, [[RFC-0010]] C-COLLISION `directory_overflow`).
///
/// The entries already learnt are TOMBSTONED by the teardown rather than
/// discarded, so mail for what this hub did learn is still spooled where
/// it belongs — which is the difference between a link that will not come
/// up and a directory that quietly lies.
fn refuseForOverflow(
    state: *HubState,
    arena: Allocator,
    conn: *Connection,
    peer: []const u8,
    req_id: []const u8,
) !void {
    try sendRelayRefusal(state, arena, conn, req_id, peer, .directory_overflow,
        "that peer hosts more identities than this hub will record for one peer — " ++
            "the link is refused rather than its directory served incomplete");
    state.peerLinkDown(peer);
}

pub fn handleRelayAdvertise(
    state: *HubState,
    arena: Allocator,
    conn: *Connection,
    peer: []const u8,
    envelope: protocol.Envelope,
) !void {
    if (envelope.payload != .object) return;
    // `{op, identities}` ([[RFC-0009]] C-DIRECTORY). One frame does three
    // jobs and the op is the only thing that tells them apart: without it
    // the receiver either never performs the replace — which is what
    // happened, so a restarted peer's stale entries went on attracting
    // mail — or performs it on every update and deletes what the peer did
    // not mention.
    const op = objGetString(envelope.payload.object, "op") orelse {
        log.warn("relay: advertisement from {s} names no op — ignored", .{peer});
        return;
    };
    const list = envelope.payload.object.get("identities") orelse return;
    if (list != .array) return;

    if (mem.eql(u8, op, "replace")) {
        var ids: std.ArrayList([]const u8) = .empty;
        for (list.array.items) |item| {
            if (item != .string) continue;
            if (!qualifierNamesSender(peer, item.string)) continue;
            try ids.append(arena, item.string);
        }
        state.directoryReplace(arena, peer, ids.items) catch |err| switch (err) {
            error.DirectoryOverflow => try refuseForOverflow(state, arena, conn, peer, envelope.id),
            else => return err,
        };
        return;
    }
    if (mem.eql(u8, op, "remove")) {
        for (list.array.items) |item| {
            if (item != .string) continue;
            if (!qualifierNamesSender(peer, item.string)) continue;
            _ = state.directoryWithdraw(peer, item.string);
        }
        return;
    }
    if (!mem.eql(u8, op, "add")) {
        log.warn("relay: advertisement from {s} names op '{s}' — ignored", .{ peer, op });
        return;
    }
    {
        {
            for (list.array.items) |item| {
                if (item != .string) continue;
                if (!qualifierNamesSender(peer, item.string)) continue;
                const result = state.directoryAdvertise(peer, item.string) catch continue;
                switch (result) {
                    // BOTH CLAIMS KEPT, NOBODY ROUTED TO. Refusing the
                    // second would leave the first routable, which is
                    // picking a winner ([[RFC-0009]] C-DIRECTORY).
                    .conflict => log.warn(
                        "relay: {s} claims '{s}', which another peer also claims — " ++
                            "nobody routes to it until one of them stops",
                        .{ peer, item.string },
                    ),
                    // The old claimant's link was gone, so this is a move
                    // rather than a disagreement ([[RFC-0008]] C-REHOME).
                    .moved => log.info(
                        "relay: '{s}' moved to {s}",
                        .{ item.string, peer },
                    ),
                    // A FACT ABOUT THE LINK, NOT ABOUT THE IDENTITY. This
                    // logged and dropped the entry, and a later send to
                    // that identity was answered `unknown` — "no peer
                    // advertises it", when a peer did and this hub
                    // declined to record it. C-DIRECTORY: a hub MUST NOT
                    // serve a view it knows is incomplete.
                    .at_capacity => return refuseForOverflow(state, arena, conn, peer, envelope.id),
                    // The one that must never be silent: a peer speaking
                    // for something standing right here. Distinguished
                    // from `conflict` because the remedies differ — that
                    // one is a disagreement between two OTHER machines,
                    // this one says the peer and this hub both believe
                    // they host the identity, which C-IDENTITY-SCOPE
                    // resolves as a refusal and never as a migration.
                    .local_conflict => log.warn(
                        "relay: {s} claims '{s}', which THIS hub hosts — refused (C-BOUNDARIES)",
                        .{ peer, item.string },
                    ),
                    .added, .refreshed => {},
                }
            }
        }
    }
}

/// A message the peer forwarded to an identity WE host. Acked per message,
/// with an explicit nack on refusal — silence is "unknown outcome", never
/// success, so the sender must never be able to read it as delivered.
pub fn handleRelayForward(
    state: *HubState,
    arena: Allocator,
    conn: *Connection,
    peer: []const u8,
    envelope: protocol.Envelope,
) !void {
    // C-IDENTITY-SCOPE: STRIP ON THE WAY IN, BUT ONLY WHERE THE QUALIFIER
    // NAMES US. Without a strip a frame for `local-ab12@laptop` never
    // matches our own `local-ab12`, and the anti-impersonation rule below
    // would fire on exactly the collisions qualification exists to
    // prevent. Stripping UNCONDITIONALLY was worse than not stripping:
    // `local-ab12@somewhere-else` also became `local-ab12` and landed in
    // OUR pane of that name, acknowledged as success, with the intended
    // recipient never told and no record that it happened. Fallback ids
    // are four hex digits per machine, so that collision is routine by
    // construction rather than contrived.
    //
    // The clause states the rule the code was missing: "A TARGET
    // QUALIFIER NAMING A THIRD PEER MUST BE REFUSED: non-transitivity
    // forbids forwarding it and the qualifier is not ours to strip."
    // Refused rather than dropped, because a third-peer qualifier is
    // never going to become deliverable here and a sender that retries
    // is a sender nobody has told.
    const qualified = federation.splitQualifier(envelope.target);
    const target = qualified.base;
    const obj: ?json.ObjectMap = if (envelope.payload == .object) envelope.payload.object else null;
    const raw = blk: {
        const o = obj orelse break :blk "";
        const v = o.get("envelope") orelse break :blk "";
        if (v != .string) break :blk "";
        break :blk v.string;
    };
    const forward_id = blk: {
        const o = obj orelse break :blk "";
        const v = o.get("forward_id") orelse break :blk "";
        if (v != .string) break :blk "";
        break :blk v.string;
    };
    if (raw.len == 0 or forward_id.len == 0) {
        try sendRelayAck(state, arena, conn, forward_id, false, "malformed");
        return;
    }
    // BEFORE THE DEDUPE TABLE, deliberately: a frame this hub will never
    // accept should not spend an entry that a frame it might accept
    // needs, and refusing the retry identically is the correct answer
    // anyway.
    if (qualified.peer) |named| {
        const me = state.peer_id orelse "";
        if (!std.mem.eql(u8, named, me)) {
            log.warn(
                "relay: {s} forwarded a frame for '{s}', whose qualifier names neither us nor the sender — refused",
                .{ peer, envelope.target },
            );
            try sendRelayAck(state, arena, conn, forward_id, false, "target_refused");
            return;
        }
    }
    // ALREADY ACCEPTED? Then acknowledge it AGAIN and do not queue it a
    // second time ([[RFC-0009]] C-DELIVERY). Holding a copy until it is
    // acknowledged is what makes a lost acknowledgement produce a second
    // forward, so the rule that prevents loss has to answer for
    // duplication — and at the bound it answers NOTHING, leaving the
    // message with the sender that is still holding it.
    switch (state.admitForward(peer, forward_id)) {
        .duplicate => {
            try sendRelayAck(state, arena, conn, forward_id, true, null);
            return;
        },
        .at_capacity => {
            log.warn("relay: forward table full — {s} keeps its copy of {s}", .{ peer, forward_id });
            return;
        },
        .fresh => {},
    }
    // C-BOUNDARIES half two: a peer speaks for the identities IT hosts.
    // The TARGET being ours is what makes this frame deliverable; the
    // SOURCE is what makes it attributable, and nothing was checking it.
    // A peer could therefore name one of our own agents as the sender and
    // the recipient would read it as mail from the pane beside it —
    // `synapty recv` prints that source verbatim. Qualifier stripped
    // first, per C-IDENTITY-SCOPE, or a legitimately qualified remote
    // sender would trip the very rule qualification exists to avoid.
    //
    // Scoped to frames that actually CLAIM an origin. A raw payload that
    // does not parse as an envelope carries no source, so there is nothing
    // to impersonate with and nothing here to refuse — and refusing it
    // anyway would be a separate policy ("relayed payloads must be
    // envelopes") that no clause states and that this fix has no business
    // smuggling in. The mailbox stores raw strings and hands them back
    // verbatim; opaque payloads forward today and keep forwarding.
    const claimed_source: []const u8 = blk: {
        const parsed = protocol.parseEnvelope(arena, raw) catch break :blk "";
        break :blk parsed.value.source;
    };
    // AS CLAIMED, NOT AS SPLIT. A peer advertises a pane id QUALIFIED
    // ([[RFC-0009]] C-IDENTITY-SCOPE), so the qualified string is the
    // directory key and the name to admit it by. Splitting first was
    // right while this was a residual check — it kept a remote
    // `local-1a2b@peer` from colliding with our own `local-1a2b` — and
    // wrong the moment the rule became "the advertisement admits the
    // identity", since the base is a key the directory never holds.
    // The local-host half needs no split either: this hub does not
    // qualify its own ids, so a qualified name is never one of ours.
    const origin = claimed_source;
    if (origin.len > 0 and !state.peerMaySpeakFor(peer, origin)) {
        log.warn(
            "relay: {s} forwarded a frame claiming to be from '{s}', which it does not host — refused",
            .{ peer, origin },
        );
        try sendRelayAck(state, arena, conn, forward_id, false, "origin_refused");
        return;
    }
    // RELAYED, WHICH IS WHAT STOPS THE SECOND HOP (mailboxDeliver says why).
    const result = state.mailboxDeliver(target, envelope.id, raw, .relayed) catch {
        try sendRelayAck(state, arena, conn, forward_id, false, "unavailable");
        return;
    };
    switch (result.outcome) {
        // Only a LOCAL delivery is a legitimate outcome for a relayed
        // frame. Anything else means the peer's directory disagrees with
        // ours, and re-forwarding would be the multi-hop routing this
        // version deliberately does not specify.
        .delivered => try sendRelayAck(state, arena, conn, forward_id, true, null),
        else => {
            log.warn("relay: {s} forwarded for '{s}' which we do not host", .{ peer, target });
            try sendRelayAck(state, arena, conn, forward_id, false, "not_hosted");
        },
    }
}

fn sendRelayAck(
    state: *HubState,
    arena: Allocator,
    conn: *Connection,
    msg_id: []const u8,
    ok: bool,
    reason: ?[]const u8,
) !void {
    try sendHubEnvelope(
        arena,
        conn,
        msg_id,
        state.peer_id orelse "hub",
        ok,
        null,
        reason,
        if (ok) "relay_ack" else "relay_nack",
    );
}

/// A peer's merged status CONCLUSION. Not re-merged here: this hub never
/// saw the evidence (C-PRESENCE).
pub fn handleRelayPresence(
    state: *HubState,
    peer: []const u8,
    envelope: protocol.Envelope,
) void {
    if (envelope.payload != .object) return;
    const raw_state = envelope.payload.object.get("state") orelse return;
    if (raw_state != .string) return;
    const status = protocol.Status.fromString(raw_state.string) orelse .unknown;
    // Keyed by the id AS ADVERTISED (qualified for fallbacks): that is
    // what our directory holds, and the peer speaks the same encoding.
    state.relayPresence(peer, envelope.target, status);
}

test "RFC-0010: a hello without versioning is MALFORMED, not an old peer" {
    // Reversed deliberately. The first version of this read a bare hello
    // as "oldest version, no capabilities", to be kind to pre-negotiation
    // builds — but Synapty is unreleased, so there are none to be kind to,
    // and the leniency was itself a silent-failure path of exactly the
    // kind this negotiation removes: any future bug dropping the
    // capability field would have presented as "that peer is older"
    // instead of "that handshake is broken".
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expect(parseHelloVersioning(.{
        .@"type" = "relay_hello", .id = "h", .source = "bare-0001", .target = "", .payload = .null,
    }) == null);

    // The OLD single-field shape is also refused now: it is not a legacy
    // peer, it is a frame this protocol does not define.
    var legacy = json.ObjectMap.empty;
    try legacy.put(a, "protocol", .{ .integer = 1 });
    try std.testing.expect(parseHelloVersioning(.{
        .@"type" = "relay_hello", .id = "h", .source = "old-0001", .target = "",
        .payload = .{ .object = legacy },
    }) == null);

    // A range without capabilities is malformed too: "I provide nothing"
    // and "I did not say" are different statements and only the first can
    // be acted on.
    var no_caps = json.ObjectMap.empty;
    try no_caps.put(a, "protocol_min", .{ .integer = 1 });
    try no_caps.put(a, "protocol_max", .{ .integer = 1 });
    try std.testing.expect(parseHelloVersioning(.{
        .@"type" = "relay_hello", .id = "h", .source = "x-0001", .target = "",
        .payload = .{ .object = no_caps },
    }) == null);

    // An inverted range is malformed rather than repaired — a silent
    // repair would hide whatever produced it.
    var inverted = json.ObjectMap.empty;
    try inverted.put(a, "protocol_min", .{ .integer = 5 });
    try inverted.put(a, "protocol_max", .{ .integer = 2 });
    try inverted.put(a, "capabilities", .{ .array = json.Array.init(a) });
    try std.testing.expect(parseHelloVersioning(.{
        .@"type" = "relay_hello", .id = "h", .source = "y-0001", .target = "",
        .payload = .{ .object = inverted },
    }) == null);
}

test "RFC-0010: an EMPTY capability list is a valid statement, not a missing one" {
    // The distinction the required-field rule protects: a peer that
    // provides nothing optional is a peer a hub can reason about.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var obj = json.ObjectMap.empty;
    try obj.put(a, "protocol_min", .{ .integer = federation.protocol_min });
    try obj.put(a, "protocol_max", .{ .integer = federation.protocol_max });
    try obj.put(a, "capabilities", .{ .array = json.Array.init(a) });
    const v = parseHelloVersioning(.{
        .@"type" = "relay_hello", .id = "h", .source = "spare-0001", .target = "",
        .payload = .{ .object = obj },
    }).?;
    try std.testing.expect(!v.caps.has(.presence_relay));
    try std.testing.expect(federation.negotiateVersion(v.min, v.max) != null);
}

test "RFC-0010: versioning round-trips through the wire shape both sides use" {
    // The accepting side answers inside `data` and an opening hello puts
    // the fields at the top level. A parser that handled only one would
    // silently read every peer from one direction as capability-less.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var top = json.ObjectMap.empty;
    try putVersioning(a, &top);
    const opener = parseHelloVersioning(.{
        .@"type" = "relay_hello", .id = "h", .source = "peer-0001", .target = "",
        .payload = .{ .object = top },
    }).?;
    try std.testing.expect(opener.caps.has(.presence_relay));
    try std.testing.expectEqual(federation.protocol_max, opener.max);

    var inner = json.ObjectMap.empty;
    try putVersioning(a, &inner);
    var wrapped = json.ObjectMap.empty;
    try wrapped.put(a, "data", .{ .object = inner });
    const answer = parseHelloVersioning(.{
        .@"type" = "relay_hello", .id = "h", .source = "hub", .target = "",
        .payload = .{ .object = wrapped },
    }).?;
    try std.testing.expect(answer.caps.has(.presence_relay));
    try std.testing.expectEqual(federation.protocol_max, answer.max);
}

test "RFC-0010 C-DIAGNOSABILITY: the three causes of `unknown` are distinguishable" {
    // The test the whole RFC is for. It fails if a capability-absent
    // unknown is reported as an evidence-absent one — the exact confusion
    // that sent a debugging session into the receiving side while the
    // receiving side was correct.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), testNoopRelease);
    defer conn.deinit();

    // A peer that CAN relay presence but has told us nothing yet.
    try state.peerLinkUp("modern-0001", &conn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    _ = try state.directoryAdvertise("modern-0001", "claude-quiet0001");
    // A peer whose BUILD does not relay presence at all.
    try state.peerLinkUp("oldbuild-0001", &conn, 9201, federation.protocol_min, .{});
    _ = try state.directoryAdvertise("oldbuild-0001", "claude-mute00001");

    const text = blk: {
        state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer state.presence_mutex.unlock(io_mod.get());
        break :blk try json.Stringify.valueAlloc(a, try buildAgentsArray(&state, a, false), .{});
    };

    // Both agents read `unknown`; only the CAUSE tells them apart.
    try std.testing.expect(mem.indexOf(u8, text, "peer_lacks_capability") != null);
    try std.testing.expect(mem.indexOf(u8, text, "no_evidence") != null);

    // And a dropped link is a third, distinct fact — about the LINK, not
    // the agent and not the peer's software.
    state.peerLinkDown("modern-0001");
    const after = blk: {
        state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer state.presence_mutex.unlock(io_mod.get());
        break :blk try json.Stringify.valueAlloc(a, try buildAgentsArray(&state, a, false), .{});
    };
    try std.testing.expect(mem.indexOf(u8, after, "peer_unreachable") != null);

    state.peerLinkDown("oldbuild-0001");
}

test "RFC-0010: peer_connect cannot rename a hub that already has an identity" {
    // The wrap-up bug. WI-015 stopped PROVISIONING from imposing a name
    // and left this path imposing one, so a hub that minted `deskmac-2630`
    // answered to `deskmac` as soon as the workbench asked it to dial —
    // silently discarding the identity every peer keys its directory and
    // spool on. A machine owns its name; a request to dial is not a
    // request to be renamed.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("deskmac-2630");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), testNoopRelease);
    defer conn.deinit();

    // No port on purpose: the request is refused before any dial is
    // spawned, so this test never touches the network and cannot
    // accidentally reach a real peer (an earlier version dialed 9200 and
    // found the operator's live SSH forward listening on it).
    var payload = json.ObjectMap.empty;
    try payload.put(a, "self_peer_id", .{ .string = "deskmac" });
    try handlePeerConnect(&state, &conn, a, .{
        .@"type" = "peer_connect", .id = "pc", .source = "workbench", .target = "",
        .payload = .{ .object = payload },
    });

    try std.testing.expectEqualStrings("deskmac-2630", state.peer_id.?);
}

test "a relay_hello that fails AFTER the link came up must not leave the peer linked" {
    // Found in a quality round. handleRelayHello brings the link UP and
    // then does four more fallible things; the caller's `defer
    // peerLinkDown` is only installed once this function RETURNS, so
    // every one of those four sat in an unguarded window. The trigger is
    // not OOM: Connection.enqueue answers `error.ConnectionClosed`, so a
    // peer whose process dies between its hello and our answer takes that
    // path on an ordinary day.
    //
    // Consequences, worst first: the stale PeerLink keeps a pointer to a
    // Connection that is about to be destroyed, and forwarding writes
    // through it; the peer can NEVER reconnect, because every later hello
    // is refused with PeerIdInUse; and the refusal advises re-minting the
    // peer id, which under [[RFC-0010]] C-COLLISION invalidates directory
    // entries, spooled mail and qualified ids on machines that were never
    // involved. Following the advice makes it worse.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), testNoopRelease);
    defer conn.deinit();
    // The peer went away between its hello and our answer. Nothing exotic:
    // this is what a dropped tunnel or a killed remote hub looks like from
    // here, and it is the state the writer thread leaves behind.
    conn.shutdown();

    var payload = json.ObjectMap.empty;
    try putVersioning(a, &payload);
    const hello = protocol.Envelope{
        .@"type" = "relay_hello",
        .id = "h1",
        .source = "remotehost-4e84",
        .target = "",
        .payload = .{ .object = payload },
    };

    // The handshake fails — that part is correct and expected.
    try std.testing.expectError(
        error.ConnectionClosed,
        handleRelayHello(&state, a, &conn, hello),
    );

    // What must ALSO be true: it left nothing behind. A peer stranded in
    // peer_links makes the next reconnect a refusal.
    state.presence_mutex.lock(io_mod.get()) catch unreachable;
    const still_linked = state.peer_links.contains("remotehost-4e84");
    state.presence_mutex.unlock(io_mod.get());
    try std.testing.expect(!still_linked);
}

test "C-BOUNDARIES: a peer may not speak for an identity this hub hosts locally" {
    // The clause states one MUST with two halves: a hub rejects relayed
    // traffic whose claimed origin identity is one this hub hosts
    // locally, OR one another peer has advertised. Only the second half
    // was implemented — Directory.advertise refuses a peer-vs-peer
    // collision and nothing compared against the LOCAL registry.
    //
    // The advertise half produced a phantom: a second entry for an agent
    // this machine hosts, whose status came from the peer rather than
    // from the agent. The forward half is worse — a peer could inject a
    // frame whose `source` names a local agent, and the recipient reads
    // it as mail from the pane next to it.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), testNoopRelease);
    defer conn.deinit();

    // A local agent, and a peer link.
    _ = try state.registerAgentTracked("claude-local001", &conn);
    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), testNoopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");

    // HALF ONE — the peer advertises a name we host. Refused.
    const result = try state.directoryAdvertise("remotehost-4e84", "claude-local001");
    try std.testing.expect(result == .local_conflict);
    {
        state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer state.presence_mutex.unlock(io_mod.get());
        try std.testing.expect(state.directory.lookup("claude-local001") == null);
    }

    // A name we do NOT host still goes through — the check must be a
    // collision test, not a blanket refusal.
    try std.testing.expect(try state.directoryAdvertise("remotehost-4e84", "claude-remote01") == .added);

    // HALF TWO — the peer forwards a frame CLAIMING to be from our own
    // agent. The target is legitimately ours, so only the source makes it
    // refusable, and refusing it is the whole point.
    _ = try state.registerAgentTracked("claude-victim01", &conn);
    var fwd_payload = json.ObjectMap.empty;
    try fwd_payload.put(a, "forward_id", .{ .string = "t-1" });
    try fwd_payload.put(a, "envelope", .{ .string = "{\"type\":\"dm\",\"id\":\"m1\",\"source\":\"claude-local001\",\"target\":\"claude-victim01\",\"payload\":{}}" });
    try handleRelayForward(&state, a, &pconn, "remotehost-4e84", .{
        .@"type" = "relay_forward",
        .id = "m1",
        .source = "remotehost-4e84",
        .target = "claude-victim01",
        .payload = .{ .object = fwd_payload },
    });
    {
        state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer state.presence_mutex.unlock(io_mod.get());
        try std.testing.expectEqual(@as(usize, 0), state.mailbox.count("claude-victim01"));
    }
}

test "RFC-0012 C-LEVEL-CONTROL: the level changes on a RUNNING hub, and a bad value is refused" {
    // A level that needs a restart is unusable on the machines that
    // matter: restarting a hub severs A2A for every agent working there,
    // so "raise it and reproduce" would destroy the thing being
    // diagnosed.
    //
    std.testing.log_level = .err;
    // diag's own level is what logFn filters on, not the test runner's —
    // so silencing the handler's announcement means setting THIS.
    diag.setLevel(.err);
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), testNoopRelease);
    defer conn.deinit();

    const before = diag.currentLevel();
    defer diag.setLevel(before);

    var ok_payload = json.ObjectMap.empty;
    try ok_payload.put(a, "level", .{ .string = "debug" });
    try handleSetLogLevel(&state, &conn, a, .{
        .@"type" = "set_log_level", .id = "1", .source = "workbench", .target = "",
        .payload = .{ .object = ok_payload },
    });
    try std.testing.expectEqual(std.log.Level.debug, diag.currentLevel());

    // A word nobody defined must be refused rather than silently mapped
    // to a default — a level that quietly did not take is the same shape
    // as one that never arrived.
    var bad_payload = json.ObjectMap.empty;
    try bad_payload.put(a, "level", .{ .string = "chatty" });
    try handleSetLogLevel(&state, &conn, a, .{
        .@"type" = "set_log_level", .id = "2", .source = "workbench", .target = "",
        .payload = .{ .object = bad_payload },
    });
    try std.testing.expectEqual(std.log.Level.debug, diag.currentLevel());
}

test "C-DELIVERY: a contested identity answers the sender rather than taking the hub down" {
    // `conflicted` is not a hypothetical: mailboxDeliver returns it the
    // moment two live peers claim one identity, which is the case
    // C-DIRECTORY refuses to resolve silently. The switch that turns a
    // failed outcome into words covered two of the failures
    // and answered `else => unreachable` for the rest — so a send to a
    // contested identity took the whole hub down with it, and every
    // agent on the machine lost A2A because two OTHER machines disagreed.
    //
    // `refused` sits behind the same door for whoever builds relay acks.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), testNoopRelease);
    defer conn.deinit();

    const p1fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var p1 = Connection.init(std.testing.allocator, p1fd, @ptrCast(&dummy), testNoopRelease);
    defer p1.deinit();
    try state.peerLinkUp("remotehost-4e84", &p1, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");

    const p2fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var p2 = Connection.init(std.testing.allocator, p2fd, @ptrCast(&dummy), testNoopRelease);
    defer p2.deinit();
    try state.peerLinkUp("buildbox-11f2", &p2, 9201, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("buildbox-11f2");

    try std.testing.expect(try state.directoryAdvertise("remotehost-4e84", "claude-shared01") == .added);
    try std.testing.expect(try state.directoryAdvertise("buildbox-11f2", "claude-shared01") == .conflict);

    var payload = json.ObjectMap.empty;
    try payload.put(a, "text", .{ .string = "hello" });
    try handleDm(&state, &conn, a, .{
        .@"type" = "dm",
        .id = "m1",
        .source = "claude-sender1",
        .target = "claude-shared01",
        .payload = .{ .object = payload },
    });

    // AND IT SAYS WHICH FAILURE IT WAS. Answering at all is the crash
    // fix; answering `unknown` would be a second defect wearing the
    // first one's clothes, since the identity plainly exists — twice.
    try std.testing.expectEqual(@as(usize, 1), conn.outbound.items.len);
    const said = conn.outbound.items[0];
    try std.testing.expect(std.mem.indexOf(u8, said, "conflicted") != null);
}

test "C-BOUNDARIES: a connection holding no identity cannot send mail by writing twice" {
    // A one-shot connection may carry more than one frame, and every line
    // after the first reached the full dispatch — so `hub_info\ndm\n` in a
    // single write posted mail from a connection that had registered
    // nothing, under whatever source the FIRST frame happened to name.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const rfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var recipient = Connection.init(std.testing.allocator, rfd, @ptrCast(&dummy), testNoopRelease);
    defer recipient.deinit();
    _ = try state.registerAgentTracked("claude-victim01", &recipient);

    const ofd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var observer = Connection.init(std.testing.allocator, ofd, @ptrCast(&dummy), testNoopRelease);
    defer observer.deinit();

    var payload = json.ObjectMap.empty;
    try payload.put(a, "text", .{ .string = "from nobody" });
    try dispatchObserverEnvelope(&state, a, &observer, "claude-liar0001", .{
        .@"type" = "dm",
        .id = "m1",
        .source = "claude-liar0001",
        .target = "claude-victim01",
        .payload = .{ .object = payload },
    });
    {
        state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer state.presence_mutex.unlock(io_mod.get());
        try std.testing.expectEqual(@as(usize, 0), state.mailbox.count("claude-victim01"));
    }

    // AND THE VOCABULARY STILL WORKS on the same connection — a guard
    // that refused everything would pass this test and break the surface.
    const q = json.ObjectMap.empty;
    try dispatchObserverEnvelope(&state, a, &observer, "", .{
        .@"type" = "list_agents",
        .id = "q1",
        .source = "",
        .target = "",
        .payload = .{ .object = q },
    });
    try std.testing.expect(observer.outbound.items.len == 1);
}

test "C-PRESENCE: a row says where an identity lives by what it OMITS" {
    // The clause names the wrong shape in as many words — a local agent
    // carries hosting_peer and peer_reachable ABSENT "rather than this
    // hub's own id and `true`" — and that was the shape being sent. A
    // consumer cannot then tell local presence it can re-check from a
    // peer's report, which is the whole distinction the fields exist for.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), testNoopRelease);
    defer conn.deinit();
    _ = try state.registerAgentTracked("claude-local001", &conn);

    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), testNoopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");
    const p2fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var p2conn = Connection.init(std.testing.allocator, p2fd, @ptrCast(&dummy), testNoopRelease);
    defer p2conn.deinit();
    try state.peerLinkUp("buildbox-11f2", &p2conn, 9201, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("buildbox-11f2");

    _ = try state.directoryAdvertise("remotehost-4e84", "claude-remote01");
    _ = try state.directoryAdvertise("remotehost-4e84", "claude-shared01");
    _ = try state.directoryAdvertise("buildbox-11f2", "claude-shared01");

    const rows = blk: {
        state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer state.presence_mutex.unlock(io_mod.get());
        break :blk try buildAgentsArray(&state, a, false);
    };

    var seen_local = false;
    var seen_remote = false;
    var seen_contested = false;
    for (rows.array.items) |row| {
        const o = row.object;
        const id = o.get("id").?.string;
        if (std.mem.eql(u8, id, "claude-local001")) {
            seen_local = true;
            // AND A LOCAL ROW KEEPS ITS `"-"`: C-SUBSCRIPTION promises a
            // single-hub snapshot is byte-for-byte what it was before
            // federation, so the shape federation did not create is not
            // federation's to change.
            try std.testing.expectEqualStrings("-", o.get("tool").?.string);
            try std.testing.expect(o.get("hosting_peer") == null);
            try std.testing.expect(o.get("peer_reachable") == null);
            // And not under the old spelling either.
            try std.testing.expect(o.get("reachable") == null);
        } else if (std.mem.eql(u8, id, "claude-remote01")) {
            seen_remote = true;
            // NAMED, NOT DESCRIBED: the clause spells this `peer_reachable`
            // and calls a differently-spelled field "one field two
            // implementers spell differently".
            try std.testing.expect(o.get("peer_reachable") != null);
            try std.testing.expect(o.get("reachable") == null);
            try std.testing.expectEqualStrings("remotehost-4e84", o.get("hosting_peer").?.string);
            // NOTHING THIS HUB DID NOT LEARN. `"-"` on a local row means
            // "registered without a tool", which is a fact; here it would
            // mean "I have no way to know", which is a different one.
            try std.testing.expect(o.get("tool") == null);
            try std.testing.expect(o.get("project") == null);
            try std.testing.expect(o.get("session") == null);
        } else if (std.mem.eql(u8, id, "claude-shared01")) {
            seen_contested = true;
            // ONE ROW, MARKED: naming either claimant would be the
            // winner-picking C-DIRECTORY forbids.
            try std.testing.expect(o.get("hosting_peer") == null);
            try std.testing.expect(o.get("peer_reachable") == null);
            try std.testing.expectEqualStrings("unknown", o.get("status").?.string);
            try std.testing.expectEqualStrings("contested", o.get("unknown_cause").?.string);
        }
    }
    try std.testing.expect(seen_local and seen_remote and seen_contested);
}

test "C-BOUNDARIES: a peer may not speak for a source nobody has advertised" {
    // The bound on a relayed source was a RESIDUAL — not hosted here, not
    // another peer's — so an identity NOBODY had ever claimed passed it.
    // A local agent then saw mail from a `from` no hub in the fleet
    // resolves, and a reply to it answers `unknown`.
    //
    // C-BOUNDARIES now says on this path what C-PRESENCE says on the
    // presence path: the advertisement is what admits an identity.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), testNoopRelease);
    defer conn.deinit();
    _ = try state.registerAgentTracked("claude-victim01", &conn);

    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), testNoopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");

    // A source this peer never advertised.
    var fwd = json.ObjectMap.empty;
    try fwd.put(a, "forward_id", .{ .string = "t-2" });
    try fwd.put(a, "envelope", .{ .string = "{\"type\":\"dm\",\"id\":\"m1\",\"source\":\"claude-ghost001\",\"target\":\"claude-victim01\",\"payload\":{}}" });
    try handleRelayForward(&state, a, &pconn, "remotehost-4e84", .{
        .@"type" = "relay_forward",
        .id = "m1",
        .source = "remotehost-4e84",
        .target = "claude-victim01",
        .payload = .{ .object = fwd },
    });
    {
        state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer state.presence_mutex.unlock(io_mod.get());
        try std.testing.expectEqual(@as(usize, 0), state.mailbox.count("claude-victim01"));
    }

    // AND THE ADVERTISED ONE STILL GOES THROUGH. A rule that refused
    // everything would pass the assertion above and break federation.
    _ = try state.directoryAdvertise("remotehost-4e84", "claude-real0001");
    var ok_fwd = json.ObjectMap.empty;
    try ok_fwd.put(a, "forward_id", .{ .string = "t-3" });
    try ok_fwd.put(a, "envelope", .{ .string = "{\"type\":\"dm\",\"id\":\"m2\",\"source\":\"claude-real0001\",\"target\":\"claude-victim01\",\"payload\":{}}" });
    try handleRelayForward(&state, a, &pconn, "remotehost-4e84", .{
        .@"type" = "relay_forward",
        .id = "m2",
        .source = "remotehost-4e84",
        .target = "claude-victim01",
        .payload = .{ .object = ok_fwd },
    });
    {
        state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer state.presence_mutex.unlock(io_mod.get());
        try std.testing.expectEqual(@as(usize, 1), state.mailbox.count("claude-victim01"));
    }
}

test "C-IDENTITY-SCOPE: a qualified remote sender is admitted by the name it was advertised under" {
    // The admission rule and the qualifier rule meet here. A peer
    // advertises a pane id QUALIFIED (`local-1a2b@remotehost`), so that
    // is the directory key — while the forward path split the qualifier
    // off before looking, which under the old residual rule was
    // harmless and under an admission rule refuses every qualified
    // sender. Look the identity up as CLAIMED.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), testNoopRelease);
    defer conn.deinit();
    _ = try state.registerAgentTracked("claude-victim01", &conn);
    // A LOCAL pane whose base name collides with the remote one, which is
    // what qualification exists to keep apart.
    _ = try state.registerAgentTracked("local-1a2b", &conn);

    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), testNoopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");
    _ = try state.directoryAdvertise("remotehost-4e84", "local-1a2b@remotehost-4e84");

    var fwd = json.ObjectMap.empty;
    try fwd.put(a, "forward_id", .{ .string = "t-4" });
    try fwd.put(a, "envelope", .{ .string = "{\"type\":\"dm\",\"id\":\"m1\",\"source\":\"local-1a2b@remotehost-4e84\",\"target\":\"claude-victim01\",\"payload\":{}}" });
    try handleRelayForward(&state, a, &pconn, "remotehost-4e84", .{
        .@"type" = "relay_forward",
        .id = "m1",
        .source = "remotehost-4e84",
        .target = "claude-victim01",
        .payload = .{ .object = fwd },
    });
    {
        state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer state.presence_mutex.unlock(io_mod.get());
        try std.testing.expectEqual(@as(usize, 1), state.mailbox.count("claude-victim01"));
    }
}

test "C-EVENT-LOCALITY: every refused handshake reaches THIS hub's log, with its reason" {
    // THE REFUSAL GOES THE WRONG WAY FOR THE OPERATOR. `relay_refused`
    // travels to the DIALLING side, which in a peer id collision is the
    // machine at fault — so the hub that knows had no record at all, and
    // somebody debugging looked at the machine that reported nothing
    // while the only machine with the answer said it out loud to a
    // socket. `peer_link_refused` was named by the clause and minted
    // nowhere: `grep -rn peer_link_refused src/` returned nothing.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), testNoopRelease);
    defer conn.deinit();

    // 1. A peer id that is not one.
    try std.testing.expect(try handleRelayHello(&state, a, &conn, .{
        .@"type" = "relay_hello", .id = "h1", .source = "not a valid id!", .target = "",
        .payload = .null,
    }) == null);

    // 2. A hello carrying no versioning.
    try std.testing.expect(try handleRelayHello(&state, a, &conn, .{
        .@"type" = "relay_hello", .id = "h2", .source = "bare-0001", .target = "",
        .payload = .null,
    }) == null);

    // 3. No protocol version in common.
    var future = json.ObjectMap.empty;
    try future.put(a, "protocol_min", .{ .integer = federation.protocol_max + 7 });
    try future.put(a, "protocol_max", .{ .integer = federation.protocol_max + 9 });
    try future.put(a, "capabilities", .{ .array = json.Array.init(a) });
    try std.testing.expect(try handleRelayHello(&state, a, &conn, .{
        .@"type" = "relay_hello", .id = "h3", .source = "future-0001", .target = "",
        .payload = .{ .object = future },
    }) == null);

    // 4. Two machines answering to one name — the case the clause names.
    var ok_hello = json.ObjectMap.empty;
    try ok_hello.put(a, "protocol_min", .{ .integer = federation.protocol_min });
    try ok_hello.put(a, "protocol_max", .{ .integer = federation.protocol_max });
    try ok_hello.put(a, "capabilities", .{ .array = json.Array.init(a) });
    const first = try handleRelayHello(&state, a, &conn, .{
        .@"type" = "relay_hello", .id = "h4", .source = "twin-0001", .target = "",
        .payload = .{ .object = ok_hello },
    });
    try std.testing.expect(first != null);
    defer state.peerLinkDown("twin-0001");
    const fd2 = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var conn2 = Connection.init(std.testing.allocator, fd2, @ptrCast(&dummy), testNoopRelease);
    defer conn2.deinit();
    try std.testing.expect(try handleRelayHello(&state, a, &conn2, .{
        .@"type" = "relay_hello", .id = "h5", .source = "twin-0001", .target = "",
        .payload = .{ .object = ok_hello },
    }) == null);

    var seen_invalid = false;
    var seen_malformed = false;
    var seen_version = false;
    var seen_in_use = false;
    for (state.event_log.entries.items) |ev| {
        if (ev.kind != .peer_link_refused) continue;
        const reason = ev.reason orelse continue;
        // THE ID THE DIALLER CLAIMED, which is the only thing naming who
        // was turned away.
        try std.testing.expect(ev.peer != null);
        if (mem.eql(u8, reason, "invalid_peer_id")) seen_invalid = true;
        if (mem.eql(u8, reason, "malformed_hello")) seen_malformed = true;
        if (mem.eql(u8, reason, "version_incompatible")) seen_version = true;
        if (mem.eql(u8, reason, "peer_id_in_use")) {
            seen_in_use = true;
            try std.testing.expectEqualStrings("twin-0001", ev.peer.?);
        }
    }
    try std.testing.expect(seen_invalid);
    try std.testing.expect(seen_malformed);
    try std.testing.expect(seen_version);
    try std.testing.expect(seen_in_use);

    // AND THE TWO HALVES MUST AGREE. The refusal goes to the machine at
    // fault while the event stays with the hub that knows, so an operator
    // reading one and an operator reading the other have to be reading
    // about the same event. Four string literals at four call sites could
    // not promise that; one enum can.
    var wire_says_in_use = false;
    for (conn2.outbound.items) |frame| {
        if (mem.indexOf(u8, frame, "relay_refused") == null) continue;
        if (mem.indexOf(u8, frame, "peer_id_in_use") != null) wire_says_in_use = true;
    }
    try std.testing.expect(wire_says_in_use);
}

test "C-DELIVERY: a relayed frame for someone else's identity is not re-forwarded" {
    // ONE HOP, AND THE CHECK USED TO BE A COMMENT. `handleRelayForward`
    // said re-forwarding "would be the multi-hop routing this version
    // deliberately does not specify" — after `mailboxDeliver` had already
    // written the second hop, so the switch it introduced only decided
    // what to TELL the sender. The hub forwarded to a third peer AND
    // answered `not_hosted`, so the sending peer released its copy for a
    // message it believed refused.
    //
    // Only the QUALIFIED target was guarded (C-IDENTITY-SCOPE,
    // `target_refused`); a bare durable id — which that clause requires
    // be advertised UNQUALIFIED — walked straight through. One of two
    // sites owed the rule and the sibling never discharged it.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const afd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var sender_link = Connection.init(std.testing.allocator, afd, @ptrCast(&dummy), testNoopRelease);
    defer sender_link.deinit();
    const cfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var third_link = Connection.init(std.testing.allocator, cfd, @ptrCast(&dummy), testNoopRelease);
    defer third_link.deinit();
    try state.peerLinkUp("remotehost-4e84", &sender_link, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");
    try state.peerLinkUp("thirdbox-77aa", &third_link, 9201, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("thirdbox-77aa");
    _ = try state.directoryAdvertise("remotehost-4e84", "sender-9f01@remotehost-4e84");
    // A BARE durable id, hosted by a THIRD machine — the shape with no
    // qualifier to refuse on.
    _ = try state.directoryAdvertise("thirdbox-77aa", "claude-abcd1234");

    const before = third_link.outbound.items.len;
    var fwd = json.ObjectMap.empty;
    try fwd.put(a, "forward_id", .{ .string = "1000-1" });
    try fwd.put(a, "envelope", .{ .string =
        "{\"type\":\"dm\",\"id\":\"m1\",\"source\":\"sender-9f01@remotehost-4e84\"," ++
        "\"target\":\"claude-abcd1234\",\"payload\":{}}" });
    try handleRelayForward(&state, a, &sender_link, "remotehost-4e84", .{
        .@"type" = "relay_forward", .id = "r1", .source = "remotehost-4e84",
        .target = "claude-abcd1234", .payload = .{ .object = fwd },
    });

    // NOTHING WENT TO THE THIRD MACHINE. This is the assertion that
    // matters: the answer to the sender was already `not_hosted` before
    // the fix, so asserting the answer alone would have passed.
    for (third_link.outbound.items[before..]) |frame| {
        if (mem.indexOf(u8, frame, "relay_forward") != null) {
            return error.SecondHopSent;
        }
    }
    // AND NOTHING WAS HELD FOR IT EITHER — a spooled copy is a second hop
    // that has not left yet.
    {
        state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer state.presence_mutex.unlock(io_mod.get());
        try std.testing.expectEqual(@as(usize, 0), state.spool.count("thirdbox-77aa"));
    }
    // The sender is told, so it can stop holding its own copy.
    var said_not_hosted = false;
    for (sender_link.outbound.items) |frame| {
        if (mem.indexOf(u8, frame, "not_hosted") != null) said_not_hosted = true;
    }
    try std.testing.expect(said_not_hosted);
}

test "RFC-0008 C-IDENTITY: a refused derivation reaches the event log, through the register path" {
    // NAMED IN THE CORPUS AND APPENDED NOWHERE. C-IDENTITY names the kind
    // `identity_rejected` in as many words, and grepping for it returned
    // only the clause. The agent keeps its pane id and runs its whole
    // life under it; the only trace was a null nobody could see.
    //
    // DRIVEN THROUGH `handleAgentUpdate` AND NOT BY CALLING THE RECORDER,
    // because a first version of this test did the latter — and a
    // mutation deleting the call site left it green. Asserting that a
    // function works says nothing about whether the production path
    // reaches it.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), testNoopRelease);
    defer conn.deinit();
    try conn.setIdentity("local-1a2b");
    _ = try state.registerAgentTracked("local-1a2b", &conn);

    // A tool string carrying the qualifier separator: the agent chose it,
    // and the derivation must refuse rather than mint an id a peer would
    // split in the wrong place.
    var payload = json.ObjectMap.empty;
    try payload.put(a, "tool", .{ .string = "claude@evil" });
    try payload.put(a, "resume_ref", .{ .string = "abc12345-dead-beef" });
    try handleAgentUpdate(&state, &conn, a, .{
        .@"type" = "agent_update", .id = "u1", .source = "local-1a2b",
        .target = "hub", .payload = .{ .object = payload },
    });

    var found: ?@TypeOf(state.event_log.entries.items[0]) = null;
    for (state.event_log.entries.items) |e| {
        if (e.kind == .identity_rejected) found = e;
    }
    try std.testing.expect(found != null);
    // THE ID IT WILL KEEP ANSWERING TO, so the record names what a human
    // actually sees in `list_agents`.
    try std.testing.expectEqualStrings("local-1a2b", found.?.agent);
    try std.testing.expectEqualStrings("qualifier_separator", found.?.reason.?);
    // And the agent did NOT get a durable id.
    try std.testing.expect(state.routing_table.lookup("local-1a2b") == &conn);
}

test "C-BOUNDARIES: a peer claiming THIS hub's own id is refused" {
    // "A hub's own id is held by no LINK, so a rule about live links
    // alone would admit the one peer that must never be admitted" — the
    // clause spells out the gap in the sentence stating the rule, and
    // `peerLinkUp` guarded only `peer_links.contains(peer)`. The cause is
    // routine rather than adversarial: a disk image copied, a backup
    // restored onto other hardware, and neither machine mints a fresh id
    // because both already have one.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), testNoopRelease);
    defer conn.deinit();

    var hello = json.ObjectMap.empty;
    try hello.put(a, "protocol_min", .{ .integer = federation.protocol_min });
    try hello.put(a, "protocol_max", .{ .integer = federation.protocol_max });
    try hello.put(a, "capabilities", .{ .array = json.Array.init(a) });
    try std.testing.expect(try handleRelayHello(&state, a, &conn, .{
        .@"type" = "relay_hello", .id = "h", .source = "laptop-0001", .target = "",
        .payload = .{ .object = hello },
    }) == null);

    // AND IT IS THE COLLISION REASON, not a generic refusal: the human's
    // next action is to re-mint an id on one machine.
    var said_in_use = false;
    for (state.event_log.entries.items) |ev| {
        if (ev.kind != .peer_link_refused) continue;
        if (mem.eql(u8, ev.reason orelse "", "peer_id_in_use")) said_in_use = true;
    }
    try std.testing.expect(said_in_use);
    // No link came up under our own name.
    try std.testing.expectEqual(@as(usize, 0), state.peer_links.count());
}

test "C-DIRECTORY: an advertisement whose qualifier names a THIRD machine is refused" {
    // "THE LINK SAYS WHICH PEER, and nothing else does... that qualifier
    // MUST name the sending peer or the entry is REFUSED — otherwise a
    // peer could attribute identities to a machine it has no relationship
    // with." No branch on the advertise path inspected the qualifier, so
    // any peer could claim any other peer's pane ids and every later
    // boundary keyed on the qualifier would honour the attribution.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), testNoopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");

    var payload = json.ObjectMap.empty;
    var ids = json.Array.init(a);
    // Its own: admitted.
    try ids.append(.{ .string = "local-1a2b@remotehost-4e84" });
    // Somebody else's: refused.
    try ids.append(.{ .string = "local-3c4d@buildbox-11f2" });
    // Unqualified is not a violation — durable ids are advertised that
    // way by design, and absence says the sender hosts it.
    try ids.append(.{ .string = "claude-abc12345" });
    try payload.put(a, "op", .{ .string = "add" });
    try payload.put(a, "identities", .{ .array = ids });
    try handleRelayAdvertise(&state, a, &pconn, "remotehost-4e84", .{
        .@"type" = "relay_advertise", .id = "relay-adv",
        .source = "remotehost-4e84", .target = "", .payload = .{ .object = payload },
    });

    state.presence_mutex.lock(io_mod.get()) catch unreachable;
    defer state.presence_mutex.unlock(io_mod.get());
    try std.testing.expect(state.directory.lookup("local-1a2b@remotehost-4e84") != null);
    try std.testing.expect(state.directory.lookup("claude-abc12345") != null);
    try std.testing.expect(state.directory.lookup("local-3c4d@buildbox-11f2") == null);
}

test "C-DIRECTORY: a peer past the directory bound loses its LINK, not its surplus identity" {
    // THE HUB REPORTED ITS OWN TRUNCATION AS A TYPO. At the bound the
    // entry was dropped with a log line, and a later send to that
    // identity matched nothing — so with the peer perfectly reachable the
    // answer set forced `unknown`, whose definition is "no peer
    // advertises it and this hub does not host it". A peer DID advertise
    // it. None of C-DELIVERY's six describes what happened, and a seventh
    // is not available: `indeterminate` was removed once tombstoning
    // closed the gap it covered, and a cap re-opens the one case that
    // argument did not reach.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    state.directory.max_per_peer = 2;

    var dummy: u8 = 0;
    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), testNoopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());

    var payload = json.ObjectMap.empty;
    var ids = json.Array.init(a);
    try ids.append(.{ .string = "claude-aaaa1111" });
    try ids.append(.{ .string = "claude-bbbb2222" });
    try ids.append(.{ .string = "claude-cccc3333" });
    try payload.put(a, "op", .{ .string = "add" });
    try payload.put(a, "identities", .{ .array = ids });
    try handleRelayAdvertise(&state, a, &pconn, "remotehost-4e84", .{
        .@"type" = "relay_advertise", .id = "adv-1",
        .source = "remotehost-4e84", .target = "", .payload = .{ .object = payload },
    });

    // THE LINK IS GONE, and the dialling side was told why.
    try std.testing.expectEqual(@as(usize, 0), state.peer_links.count());
    var said_overflow = false;
    for (pconn.outbound.items) |frame| {
        if (mem.indexOf(u8, frame, "relay_refused") == null) continue;
        if (mem.indexOf(u8, frame, "directory_overflow") != null) said_overflow = true;
    }
    try std.testing.expect(said_overflow);
    // AND THIS HUB RECORDED IT, because the refusal travels to the
    // dialling side and the hub that knows would otherwise say nothing.
    var evented = false;
    for (state.event_log.entries.items) |e| {
        if (e.kind == .peer_link_refused and
            mem.eql(u8, e.reason orelse "", "directory_overflow")) evented = true;
    }
    try std.testing.expect(evented);

    // WHAT IT DID LEARN IS TOMBSTONED, NOT DISCARDED, so mail for those
    // identities is still spooled where it belongs.
    state.presence_mutex.lock(io_mod.get()) catch unreachable;
    defer state.presence_mutex.unlock(io_mod.get());
    try std.testing.expect(state.directory.lookup("claude-aaaa1111") != null);
    try std.testing.expect(state.directory.lookup("claude-cccc3333") == null);
}

test "C-DIRECTORY: a full advertisement REPLACES the receiver's view of that peer" {
    // THE DEFECT THIS PINS. `broadcastDirectoryLocked` and
    // `advertiseAllTo` emitted the same `{"added":[...]}` shape and
    // differed only in an envelope id string, so the receiver could not
    // tell an incremental update from the full set a link-up sends. The
    // replace therefore never happened: entries are TOMBSTONED when a
    // link drops rather than discarded, and the reconnect that was
    // supposed to correct the retained set instead added to it. An
    // identity that ended while the peer was away stayed in the
    // directory, stayed addressable, and mail sent to it was spooled for
    // a machine that would never claim it again.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), testNoopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");

    // What it hosted before it went away.
    _ = try state.directoryAdvertise("remotehost-4e84", "claude-stays001");
    _ = try state.directoryAdvertise("remotehost-4e84", "claude-ended001");

    // It comes back hosting only one of them, and says so with the full
    // set — which is the frame `advertiseAllTo` sends on link-up.
    var payload = json.ObjectMap.empty;
    var ids = json.Array.init(a);
    try ids.append(.{ .string = "claude-stays001" });
    try ids.append(.{ .string = "claude-fresh001" });
    try payload.put(a, "op", .{ .string = "replace" });
    try payload.put(a, "identities", .{ .array = ids });
    try handleRelayAdvertise(&state, a, &pconn, "remotehost-4e84", .{
        .@"type" = "relay_advertise",
        .id = "relay-adv-all",
        .source = "remotehost-4e84",
        .target = "",
        .payload = .{ .object = payload },
    });

    state.presence_mutex.lock(io_mod.get()) catch unreachable;
    defer state.presence_mutex.unlock(io_mod.get());
    try std.testing.expect(state.directory.lookup("claude-stays001") != null);
    try std.testing.expect(state.directory.lookup("claude-fresh001") != null);
    try std.testing.expect(state.directory.lookup("claude-ended001") == null);
}

test "C-DIRECTORY: an incremental update adds without deleting what it did not mention" {
    // THE OTHER HALF OF THE SAME DEFECT, and the one a careless fix
    // produces: a receiver that treats every advertisement as the full
    // set deletes everything the frame does not name, so one agent
    // registering on a peer would unregister every other agent on it.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), testNoopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");
    _ = try state.directoryAdvertise("remotehost-4e84", "claude-first001");

    var payload = json.ObjectMap.empty;
    var ids = json.Array.init(a);
    try ids.append(.{ .string = "claude-second01" });
    try payload.put(a, "op", .{ .string = "add" });
    try payload.put(a, "identities", .{ .array = ids });
    try handleRelayAdvertise(&state, a, &pconn, "remotehost-4e84", .{
        .@"type" = "relay_advertise",
        .id = "relay-adv",
        .source = "remotehost-4e84",
        .target = "",
        .payload = .{ .object = payload },
    });

    state.presence_mutex.lock(io_mod.get()) catch unreachable;
    defer state.presence_mutex.unlock(io_mod.get());
    try std.testing.expect(state.directory.lookup("claude-first001") != null);
    try std.testing.expect(state.directory.lookup("claude-second01") != null);
}

test "C-DIRECTORY: a replace speaks only for the peer that sent it" {
    // A full set is authoritative FOR THE SENDING PEER, which the
    // receiver knows because it holds the link. A replace that swept the
    // whole directory would let any peer retract another peer's
    // identities by reconnecting.
    //
    // WHERE THAT IS ENFORCED, stated because this test cannot tell you:
    // `Directory.withdraw` refuses a retraction from a peer that does not
    // claim the entry, so `directoryReplace` offers every unnamed entry to
    // it and lets it decide. This asserts the composed rule, which is the
    // observable one; it does not pin the guard's location, and a
    // mutation moving the guard would leave it green.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), testNoopRelease);
    defer pconn.deinit();
    const p2fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var p2conn = Connection.init(std.testing.allocator, p2fd, @ptrCast(&dummy), testNoopRelease);
    defer p2conn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");
    try state.peerLinkUp("buildbox-11f2", &p2conn, 9201, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("buildbox-11f2");
    _ = try state.directoryAdvertise("buildbox-11f2", "claude-theirs01");

    var payload = json.ObjectMap.empty;
    var ids = json.Array.init(a);
    try ids.append(.{ .string = "claude-mine0001" });
    try payload.put(a, "op", .{ .string = "replace" });
    try payload.put(a, "identities", .{ .array = ids });
    try handleRelayAdvertise(&state, a, &pconn, "remotehost-4e84", .{
        .@"type" = "relay_advertise",
        .id = "relay-adv-all",
        .source = "remotehost-4e84",
        .target = "",
        .payload = .{ .object = payload },
    });

    state.presence_mutex.lock(io_mod.get()) catch unreachable;
    defer state.presence_mutex.unlock(io_mod.get());
    try std.testing.expect(state.directory.lookup("claude-theirs01") != null);
    try std.testing.expect(state.directory.lookup("claude-mine0001") != null);
}

test "C-DELIVERY: the relay NACK reasons are the five the clause names" {
    // The reason a NACK carries is what `refused` hands the ORIGINAL
    // sender, so a hub that spells it differently produces a `refused`
    // nobody downstream can branch on. The clause names five; this drives
    // the three reachable without a second machine and pins the strings
    // the wire actually carries — not the ones the source happens to
    // contain, which is a different and worthless assertion.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), testNoopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");
    _ = try state.directoryAdvertise("remotehost-4e84", "sender-9f01@remotehost-4e84");

    const good_envelope = "{\"type\":\"dm\",\"id\":\"m1\",\"source\":\"sender-9f01@remotehost-4e84\",\"target\":\"whoever\",\"payload\":{}}";

    // `malformed` — a frame with no envelope to deliver.
    {
        var fwd = json.ObjectMap.empty;
        try fwd.put(a, "forward_id", .{ .string = "r-1" });
        try handleRelayForward(&state, a, &pconn, "remotehost-4e84", .{
            .@"type" = "relay_forward", .id = "m1",
            .source = "remotehost-4e84", .target = "whoever",
            .payload = .{ .object = fwd },
        });
    }
    // `target_refused` — a qualifier naming neither of us.
    {
        var fwd = json.ObjectMap.empty;
        try fwd.put(a, "forward_id", .{ .string = "r-2" });
        try fwd.put(a, "envelope", .{ .string = good_envelope });
        try handleRelayForward(&state, a, &pconn, "remotehost-4e84", .{
            .@"type" = "relay_forward", .id = "m2",
            .source = "remotehost-4e84", .target = "whoever@thirdbox-77aa",
            .payload = .{ .object = fwd },
        });
    }
    // `not_hosted` — a target this hub does not have.
    {
        var fwd = json.ObjectMap.empty;
        try fwd.put(a, "forward_id", .{ .string = "r-3" });
        try fwd.put(a, "envelope", .{ .string = good_envelope });
        try handleRelayForward(&state, a, &pconn, "remotehost-4e84", .{
            .@"type" = "relay_forward", .id = "m3",
            .source = "remotehost-4e84", .target = "nobody-here",
            .payload = .{ .object = fwd },
        });
    }

    var seen_malformed = false;
    var seen_target = false;
    var seen_not_hosted = false;
    for (pconn.outbound.items) |line| {
        if (std.mem.indexOf(u8, line, "malformed") != null) seen_malformed = true;
        if (std.mem.indexOf(u8, line, "target_refused") != null) seen_target = true;
        if (std.mem.indexOf(u8, line, "not_hosted") != null) seen_not_hosted = true;
    }
    try std.testing.expect(seen_malformed);
    try std.testing.expect(seen_target);
    try std.testing.expect(seen_not_hosted);
}

test "C-IDENTITY-SCOPE: a target qualifier naming a THIRD peer is refused, not stripped" {
    // The strip on the way in exists so `local-1a2b@us` reaches our own
    // `local-1a2b`. It was unconditional, so `local-1a2b@somewhere-else`
    // was stripped too and landed in OUR pane of that name — acked as
    // success, with the intended recipient never told and no record that
    // it happened. Fallback ids are four hex digits per machine, so the
    // collision is routine by construction rather than contrived.
    //
    // C-IDENTITY-SCOPE: "A TARGET QUALIFIER NAMING A THIRD PEER MUST BE
    // REFUSED: non-transitivity forbids forwarding it and the qualifier
    // is not ours to strip."
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), testNoopRelease);
    defer conn.deinit();
    // OUR pane, with the base name the qualified target happens to share.
    _ = try state.registerAgentTracked("local-1a2b", &conn);

    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), testNoopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");
    _ = try state.directoryAdvertise("remotehost-4e84", "sender-9f01@remotehost-4e84");

    var fwd = json.ObjectMap.empty;
    try fwd.put(a, "forward_id", .{ .string = "t-third" });
    try fwd.put(a, "envelope", .{ .string = "{\"type\":\"dm\",\"id\":\"m9\",\"source\":\"sender-9f01@remotehost-4e84\",\"target\":\"local-1a2b@thirdbox-77aa\",\"payload\":{}}" });
    try handleRelayForward(&state, a, &pconn, "remotehost-4e84", .{
        .@"type" = "relay_forward",
        .id = "m9",
        .source = "remotehost-4e84",
        .target = "local-1a2b@thirdbox-77aa",
        .payload = .{ .object = fwd },
    });
    {
        state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer state.presence_mutex.unlock(io_mod.get());
        try std.testing.expectEqual(
            @as(usize, 0),
            state.mailbox.count("local-1a2b"),
        );
    }
}

test "C-IDENTITY-SCOPE: a target qualifier naming US is still stripped and delivered" {
    // The other half, so the refusal above cannot be satisfied by
    // refusing everything qualified. A peer addresses one of our panes by
    // the name it advertises it under, which is qualified with OUR id.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), testNoopRelease);
    defer conn.deinit();
    _ = try state.registerAgentTracked("local-1a2b", &conn);

    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), testNoopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");
    _ = try state.directoryAdvertise("remotehost-4e84", "sender-9f01@remotehost-4e84");

    var fwd = json.ObjectMap.empty;
    try fwd.put(a, "forward_id", .{ .string = "t-ours" });
    try fwd.put(a, "envelope", .{ .string = "{\"type\":\"dm\",\"id\":\"m10\",\"source\":\"sender-9f01@remotehost-4e84\",\"target\":\"local-1a2b@laptop-0001\",\"payload\":{}}" });
    try handleRelayForward(&state, a, &pconn, "remotehost-4e84", .{
        .@"type" = "relay_forward",
        .id = "m10",
        .source = "remotehost-4e84",
        .target = "local-1a2b@laptop-0001",
        .payload = .{ .object = fwd },
    });
    {
        state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer state.presence_mutex.unlock(io_mod.get());
        try std.testing.expectEqual(@as(usize, 1), state.mailbox.count("local-1a2b"));
    }
}

test "C-DELIVERY: a retry after a lost acknowledgement is acknowledged, not delivered twice" {
    // Holding a copy until it is acknowledged is what makes a LOST
    // ACKNOWLEDGEMENT produce a second forward, so the rule that prevents
    // loss has to answer for duplication. Before the forward id there was
    // nothing to answer with: the frame's envelope id was the literal
    // "relay-fwd" for every message, so no acknowledgement on a link was
    // attributable to any message and the receiver had no way to know it
    // had seen this one.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), testNoopRelease);
    defer conn.deinit();
    _ = try state.registerAgentTracked("claude-victim01", &conn);

    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), testNoopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");
    _ = try state.directoryAdvertise("remotehost-4e84", "claude-sender01");

    const raw = "{\"type\":\"dm\",\"id\":\"m1\",\"source\":\"claude-sender01\",\"target\":\"claude-victim01\",\"payload\":{}}";
    for (0..2) |_| {
        var fwd = json.ObjectMap.empty;
        try fwd.put(a, "forward_id", .{ .string = "1000-1" });
        try fwd.put(a, "envelope", .{ .string = raw });
        try handleRelayForward(&state, a, &pconn, "remotehost-4e84", .{
            .@"type" = "relay_forward",
            .id = "relay-fwd",
            .source = "remotehost-4e84",
            .target = "claude-victim01",
            .payload = .{ .object = fwd },
        });
    }

    {
        state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer state.presence_mutex.unlock(io_mod.get());
        try std.testing.expectEqual(@as(usize, 1), state.mailbox.count("claude-victim01"));
    }

    // AND BOTH WERE ACKNOWLEDGED, carrying the forward id. Acknowledging
    // only the first would leave the sender holding a copy forever, which
    // is the loss this rule trades duplication against.
    try std.testing.expectEqual(@as(usize, 2), pconn.outbound.items.len);
    for (pconn.outbound.items) |line| {
        try std.testing.expect(std.mem.indexOf(u8, line, "relay_ack") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "1000-1") != null);
    }
}

test "C-DELIVERY: a retry after a lost acknowledgement carries the SAME forward id" {
    // THE HALF NOTHING PINNED. The receiver's dedupe table is correct and
    // tested — but its tests hand-write one id twice, so they pass no
    // matter what the SENDER does, and the sender minted a fresh id on
    // every attempt: `forward_seq += 1` ran unconditionally at its only
    // mint site. A lost acknowledgement therefore delivered the message
    // twice, because the retry was a message the receiver had no way to
    // recognise as the same one.
    //
    // This drives the real path end to end: a peer that never acks, the
    // silence that holds the copy, the flush that sends it again — and
    // then replays BOTH frames into a second hub, which is where a
    // duplicate would actually appear.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    const saved = forward_ack_bound_ms;
    forward_ack_bound_ms = 40;
    defer forward_ack_bound_ms = saved;

    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var sender = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), testNoopRelease);
    defer sender.deinit();
    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), testNoopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");
    _ = try state.directoryAdvertise("remotehost-4e84", "claude-remote01");

    var payload = json.ObjectMap.empty;
    try payload.put(a, "text", .{ .string = "hello" });
    try handleDm(&state, &sender, a, .{
        .@"type" = "dm", .id = "m1", .source = "claude-sender1",
        .target = "claude-remote01", .payload = .{ .object = payload },
    });
    // Nobody answered, so the copy is held. Now the link is usable again.
    _ = state.flushSpoolTo("remotehost-4e84");

    // The two frames the peer actually saw.
    var forwards = std.ArrayList([]const u8).empty;
    defer forwards.deinit(a);
    for (pconn.outbound.items) |frame| {
        if (mem.indexOf(u8, frame, "relay_forward") == null) continue;
        try forwards.append(a, frame);
    }
    try std.testing.expectEqual(@as(usize, 2), forwards.items.len);

    const first = try forwardIdOf(a, forwards.items[0]);
    const retry = try forwardIdOf(a, forwards.items[1]);
    try std.testing.expectEqualStrings(first, retry);

    // AND THE RECEIVER MUST QUEUE ONE. The id equality is the mechanism;
    // this is the promise, and asserting only the first would pass a
    // dedupe table that ignored the id entirely.
    var peer_state = HubState.init(std.testing.allocator);
    defer peer_state.deinit();
    try peer_state.setPeerId("remotehost-4e84");
    const rfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var rconn = Connection.init(std.testing.allocator, rfd, @ptrCast(&dummy), testNoopRelease);
    defer rconn.deinit();
    try peer_state.peerLinkUp("laptop-0001", &rconn, 9201, federation.protocol_max, federation.CapabilitySet.local());
    defer peer_state.peerLinkDown("laptop-0001");
    var pdummy: u8 = 0;
    const afd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var agent_conn = Connection.init(std.testing.allocator, afd, @ptrCast(&pdummy), testNoopRelease);
    defer agent_conn.deinit();
    _ = try peer_state.registerAgentTracked("claude-remote01", &agent_conn);
    // THE SENDER HAS TO BE SOMEBODY THE PEER HAS HEARD OF: a relayed
    // frame whose stamped source this hub holds no directory entry for is
    // refused ([[RFC-0009]] C-BOUNDARIES), which is why the first replay
    // delivered nothing until this line existed.
    _ = try peer_state.directoryAdvertise("laptop-0001", "claude-sender1");

    for (forwards.items) |frame| {
        const parsed = try json.parseFromSlice(json.Value, a, frame, .{});
        const env = parsed.value.object;
        try handleRelayForward(&peer_state, a, &rconn, "laptop-0001", .{
            .@"type" = "relay_forward",
            .id = env.get("id").?.string,
            .source = "laptop-0001",
            .target = env.get("target").?.string,
            .payload = env.get("payload").?,
        });
    }
    {
        peer_state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer peer_state.presence_mutex.unlock(io_mod.get());
        try std.testing.expectEqual(
            @as(usize, 1),
            peer_state.mailbox.count("claude-remote01"),
        );
    }
}

/// The `forward_id` inside a serialized relay_forward frame.
fn forwardIdOf(a: Allocator, frame: []const u8) ![]const u8 {
    const parsed = try json.parseFromSlice(json.Value, a, frame, .{});
    const payload = parsed.value.object.get("payload") orelse return error.NoPayload;
    const fid = payload.object.get("forward_id") orelse return error.NoForwardId;
    return fid.string;
}

test "C-DELIVERY: an unanswered forward answers the sender `spooled`, not `forwarded`" {
    // The wait is in handleDm rather than in mailboxDeliver because it
    // must happen OUTSIDE presence_mutex — five seconds under that lock
    // would freeze every other agent on this machine. That placement is
    // what this test pins: remove the mapping and the sender is told
    // `forwarded` for a message no peer has answered for.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    const saved = forward_ack_bound_ms;
    forward_ack_bound_ms = 40;
    defer forward_ack_bound_ms = saved;

    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy: u8 = 0;
    const fd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var sender = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), testNoopRelease);
    defer sender.deinit();

    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), testNoopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");
    _ = try state.directoryAdvertise("remotehost-4e84", "claude-remote01");

    var payload = json.ObjectMap.empty;
    try payload.put(a, "text", .{ .string = "hello" });
    try handleDm(&state, &sender, a, .{
        .@"type" = "dm",
        .id = "m1",
        .source = "claude-sender1",
        .target = "claude-remote01",
        .payload = .{ .object = payload },
    });

    try std.testing.expect(sender.outbound.items.len >= 1);
    const answer = sender.outbound.items[sender.outbound.items.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"status\":\"spooled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "forwarded") == null);

    // AND THE COPY IS ACTUALLY HELD. Answering `spooled` without holding
    // anything is the lie this whole contract exists to prevent.
    {
        state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer state.presence_mutex.unlock(io_mod.get());
        try std.testing.expectEqual(@as(usize, 1), state.spool.count("remotehost-4e84"));
    }
}
