const std = @import("std");
const sys = @import("sys");
const framing = @import("framing");
const io_mod = @import("io");
const tools = @import("tools");
const mem = std.mem;
const json = std.json;
const protocol = @import("protocol");
const ipc = @import("ipc");
const Allocator = mem.Allocator;
const transport = @import("transport.zig");
const holder = @import("holder");
const paths = @import("paths");
const run = @import("run");

// Import arg types from the shared types module (no circular import).
const types = @import("types.zig");
const hooks_mod = @import("hooks.zig");
const progress_mod = @import("progress.zig");
const RegisterArgs = types.RegisterArgs;
const SendArgs = types.SendArgs;
const RecvArgs = types.RecvArgs;
const IpcArgs = types.IpcArgs;

// ---------------------------------------------------------------------------
// IPC helper
// ---------------------------------------------------------------------------

/// Send an IPC request to the daemon and print the response.
///
/// Returns true when the daemon ANSWERED — not, as the contract read
/// before, whenever SYNAPTY_SOCK happened to be set. The two came apart
/// on a socket that accepted the request and closed without a word, and
/// every caller here treats this bool as "the verb did its work"
/// ([[WI-2026-09-03-007]]).
fn ipcRoundtrip(allocator: Allocator, request: protocol.IpcRequest) !bool {
    const resp = try ipcRoundtripCapture(allocator, request) orelse return false;
    defer allocator.free(resp);
    // Unconditional: a response that reaches here is a non-empty line by
    // construction, so there is no longer a path where success is silent.
    try io_mod.stdoutWriteAll(resp);
    try io_mod.stdoutWriteAll("\n");
    return true;
}

/// Same roundtrip, but hands the response back instead of printing it —
/// for callers that must inspect the outcome before deciding stdout vs
/// stderr and the exit code. null = no answer (see NoAnswer), which for
/// the pane-only verbs means "not in a session" and for send/agents means
/// "take the hub directly".
fn ipcRoundtripCapture(allocator: Allocator, request: protocol.IpcRequest) !?[]const u8 {
    const sock_env = sys.getenv("SYNAPTY_SOCK") orelse return null;
    return switch (try ipcAsk(allocator, sock_env, request)) {
        .answer => |a| a,
        .none => |why| {
            // SET BUT GONE is not an error to dump a trace over
            // ([[RFC-0003]] C-CLI-TOOLS; [[WI-2026-09-02-020]]). Said
            // once, here, and the caller takes its no-IPC path.
            io_mod.stderrWriteAll(why.sentence()) catch {};
            return null;
        },
    };
}

/// Why a round trip came back with nothing. SEPARATE FROM SAYING SO: the
/// decision is what the callers and the tests need, and routing every one
/// of these through stderr is what made the empty case below invisible
/// for as long as it was.
const NoAnswer = enum {
    /// Nothing is listening at the path — a crashed pane daemon, or a
    /// SYNAPTY_SOCK that came along into a shell it does not describe.
    unreachable_socket,
    /// Listening, and wedged.
    timed_out,
    /// Accepted the request, then closed without a word. What a socket
    /// speaking SOME OTHER PROTOCOL does — the holder's session socket
    /// sits one directory away under a nearly identical name.
    closed_silently,
    /// Answered, with nothing in the answer.
    empty_line,

    fn sentence(self: NoAnswer) []const u8 {
        return switch (self) {
            .unreachable_socket => "synapty: SYNAPTY_SOCK is set but no pane daemon answers there; continuing without it\n",
            .timed_out => "synapty: the pane daemon did not answer in time; continuing without it\n",
            .closed_silently => "synapty: the pane daemon accepted the request and closed without answering; continuing without it\n",
            .empty_line => "synapty: the pane daemon answered with an empty line; continuing without it\n",
        };
    }
};

const Answer = union(enum) { answer: []const u8, none: NoAnswer };

/// The round trip against a NAMED socket, reporting WHY when there is no
/// answer and saying nothing itself.
///
/// AN ANSWER IS A LINE WITH SOMETHING IN IT. Everything else is a failure
/// to get one, and not — as it was — a success with nothing to print:
/// silence came back as an empty response, which `ipcRoundtrip` printed
/// as nothing and reported as "the IPC path was used". `synapty register`
/// exited 0 having registered nothing, and the hub went on showing the
/// pane with no tool on it ([[WI-2026-09-03-007]]).
fn ipcAsk(allocator: Allocator, sock_path: []const u8, request: protocol.IpcRequest) !Answer {
    var client = ipc.IpcClient.connect(sock_path) catch return .{ .none = .unreachable_socket };
    defer client.deinit();
    const req = try protocol.serializeIpcRequest(allocator, request);
    defer allocator.free(req);
    try client.send(req);
    var buf: [64 * 1024]u8 = undefined;
    // A WAIT IS ALLOWED TO WAIT. The deadline is for a daemon that has
    // wedged; a `recv --wait` parked until mail arrives is the one request
    // that legitimately hears nothing for minutes ([[WI-2026-09-02-036]]).
    const deadline: i32 = if (request.wait == true) -1 else ipc.IpcClient.reply_timeout_ms;
    const reply = client.recvWithin(&buf, deadline) catch |err| switch (err) {
        // A daemon that is there and silent is treated like one that is
        // gone ([[WI-2026-09-02-033]]).
        error.Timeout => return .{ .none = .timed_out },
        else => return err,
    };
    const response = reply orelse return .{ .none = .closed_silently };
    if (response.len == 0) return .{ .none = .empty_line };
    return .{ .answer = try allocator.dupe(u8, response) };
}

/// Pull the [[RFC-0009]] C-DELIVERY status out of a send response. The
/// daemon nests the hub's own envelope inside its IPC reply, so this digs
/// through both. null when the field is absent — a pre-federation hub.
pub fn deliveryStatusOf(arena: Allocator, ipc_response: []const u8) ?[]const u8 {
    return deliveryStatusOfEnvelope(arena, unwrapIpc(arena, ipc_response) orelse return null);
}

/// The hub's envelope reaches the CLI two ways and only one of them is
/// wrapped: in a pane it arrives inside the daemon's IPC reply, and out of
/// one it arrives raw off the socket. Both answers mean the same thing, so
/// both read it with the same eyes — the out-of-pane path used to read it
/// with none at all and print "sent to X" whatever came back.
fn unwrapIpc(arena: Allocator, ipc_response: []const u8) ?[]const u8 {
    const parsed = json.parseFromSliceLeaky(json.Value, arena, ipc_response, .{}) catch return null;
    if (parsed != .object) return null;
    const inner_raw = parsed.object.get("data") orelse return null;
    if (inner_raw != .string) return null;
    return inner_raw.string;
}

pub fn deliveryStatusOfEnvelope(arena: Allocator, hub_envelope: []const u8) ?[]const u8 {
    const hub_env = json.parseFromSliceLeaky(json.Value, arena, hub_envelope, .{}) catch return null;
    if (hub_env != .object) return null;
    const payload = hub_env.object.get("payload") orelse return null;
    if (payload != .object) return null;
    const data = payload.object.get("data") orelse return null;
    if (data != .object) return null;
    const status = data.object.get("status") orelse return null;
    if (status != .string) return null;
    return status.string;
}

/// The hub's own verdict on a send, and its words for it — `null` when
/// the hub accepted the message.
///
/// ASKED OF THE HUB RATHER THAN MATCHED AGAINST A LIST. The caller used
/// to name the failures it knew (`unknown` and one other) and let
/// everything else through as success; the vocabulary has four failures
/// ([[RFC-0009]] C-DELIVERY), so a contested identity and a peer's
/// refusal both exited 0 with JSON on stdout. A list here is a list that
/// drifts from the enum that defines it — the answer already carries the
/// verdict, so read that.
pub fn deliveryFailureOf(arena: Allocator, ipc_response: []const u8) ?[]const u8 {
    return deliveryFailureOfEnvelope(arena, unwrapIpc(arena, ipc_response) orelse return null);
}

pub fn deliveryFailureOfEnvelope(arena: Allocator, hub_envelope: []const u8) ?[]const u8 {
    const hub_env = json.parseFromSliceLeaky(json.Value, arena, hub_envelope, .{}) catch return null;
    if (hub_env != .object) return null;
    const payload = hub_env.object.get("payload") orelse return null;
    if (payload != .object) return null;
    const ok = payload.object.get("ok") orelse return null;
    if (ok != .bool or ok.bool) return null;
    // A refusal with no words is still a refusal; saying nothing would
    // put the caller back where it started.
    const data = payload.object.get("data") orelse return "the hub did not accept it";
    if (data != .object) return "the hub did not accept it";
    const reason = data.object.get("reason") orelse return "the hub did not accept it";
    if (reason != .string) return "the hub did not accept it";
    return reason.string;
}

// ---------------------------------------------------------------------------
// Subcommand handlers
// ---------------------------------------------------------------------------

/// `synapty notify --state <s>` (WI-2026-08-09-022): report semantic
/// agent state. Identity is implicit — the run wrapper's daemon socket
/// stamps the envelope source.
pub fn runNotify(allocator: Allocator, args: types.NotifyArgs) !void {
    const used_ipc = try ipcRoundtrip(allocator, .{
        .action = .notify,
        .state = args.state,
    });
    if (!used_ipc) notInSession();
}

/// Agent registration per [[RFC-0003]] (agent identity). Routes through
/// IPC to the pane daemon, which forwards agent_update to the hub.
pub fn runRegister(allocator: Allocator, args: RegisterArgs) !void {
    const used_ipc = try ipcRoundtrip(allocator, .{
        .action = .register,
        .tool = args.tool,
        .project = args.project,
        .session = args.session,
        .resume_ref = args.resume_ref,
    });
    if (!used_ipc) notInSession();
}

/// Channel subcommand handler per [[RFC-0003:C-A2A-REDUCTION]] (legacy group-chat surface).
pub fn runChannel(allocator: Allocator, action: protocol.IpcAction, args: IpcArgs) !void {
    const used_ipc = try ipcRoundtrip(allocator, switch (action) {
        .channel_create => .{ .action = .channel_create, .channel = args.channel_create.name, .description = args.channel_create.description },
        .channel_invite => .{ .action = .channel_invite, .channel = args.channel_invite.channel, .agent_id = args.channel_invite.agent_id },
        .channel_leave => .{ .action = .channel_leave, .channel = args.channel_leave.channel },
        .channel_list => .{ .action = .channel_list },
        else => unreachable,
    });
    if (!used_ipc) notInSession();
}

pub fn runSend(allocator: Allocator, args: SendArgs) !void {
    if (try ipcRoundtripCapture(allocator, .{
        .action = .send,
        .target = args.target,
        .text = args.text,
    })) |resp| {
        defer allocator.free(resp);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        // [[RFC-0009]] C-DELIVERY: the CLI MUST expose the outcomes
        // distinctly, and RFC-0003 C-CLI-TOOLS makes that binary —
        // JSON on stdout with exit 0, or a human-readable error on
        // stderr with a non-zero exit. `spooled` is a SUCCESS: the hub
        // holds the message and will forward it when the link returns.
        // It is not `unknown`, and a script must be able to tell them
        // apart — one is a machine to see to, the other a typo to fix.
        if (deliveryFailureOf(arena.allocator(), resp)) |reason| {
            // The status name goes with the words: a script branches on
            // the name, a human reads the sentence, and neither is a
            // list this program maintains.
            try io_mod.stderrWriteAll("error: ");
            if (deliveryStatusOf(arena.allocator(), resp)) |status| {
                try io_mod.stderrWriteAll(status);
                try io_mod.stderrWriteAll(" — ");
            }
            try io_mod.stderrWriteAll(reason);
            try io_mod.stderrWriteAll("\n");
            std.process.exit(1);
        }
        try io_mod.stdoutWriteAll(resp);
        try io_mod.stdoutWriteAll("\n");
        return;
    }

    // Fallback: direct Hub TCP connection.
    // Build a temporary source ID for this one-shot send.
    const now_ms = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds();
    const source_id = try std.fmt.allocPrint(allocator, "{s}{d}", .{ protocol.temp_agent_prefix, now_ms });
    defer allocator.free(source_id);

    const fd = try transport.connectAndRegister(allocator, source_id);
    defer sys.close(fd);

    try writeSendEnvelope(allocator, fd, source_id, args.target, args.text);

    // THE HUB ALREADY ANSWERED AND NOBODY WAS READING IT. This path wrote
    // the envelope, printed "sent to X" and exited 0 — for a typo the hub
    // had answered `unknown` about, for a contested identity it had
    // answered `conflicted` about, for every failure the in-pane path
    // reports correctly. Every scripted send from outside a pane
    // succeeded on a name that does not exist.
    //
    // SILENCE IS NOT SUCCESS EITHER ([[RFC-0009]] C-DELIVERY: silence is
    // "unknown outcome, never success"). A hub that does not answer
    // inside the bound leaves this exiting non-zero, because the one
    // thing exit 0 has to mean here is that the message arrived.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const answer = readSendAnswer(arena.allocator(), fd) catch null;
    const resp = answer orelse {
        try io_mod.stderrWriteAll("error: the hub did not answer this send\n");
        std.process.exit(1);
    };
    if (deliveryFailureOfEnvelope(arena.allocator(), resp)) |reason| {
        try io_mod.stderrWriteAll("error: ");
        if (deliveryStatusOfEnvelope(arena.allocator(), resp)) |status| {
            try io_mod.stderrWriteAll(status);
            try io_mod.stderrWriteAll(" — ");
        }
        try io_mod.stderrWriteAll(reason);
        try io_mod.stderrWriteAll("\n");
        std.process.exit(1);
    }
    try io_mod.stdoutWriteAll(resp);
    try io_mod.stdoutWriteAll("\n");
}

/// Read the hub's answer to the send just written, correlating by the
/// request id so an unrelated frame arriving first is skipped rather than
/// mistaken for the answer.
///
/// BOUNDED WELL ABOVE THE HUB'S OWN BOUND. A cross-machine send waits for
/// a peer's acknowledgement before it can answer at all
/// (`forward_ack_bound_ms`, five seconds), so a bound under that would
/// turn every forwarded message into "the hub did not answer".
fn readSendAnswer(arena: Allocator, fd: sys.fd_t) !?[]const u8 {
    sys.setRecvTimeout(fd, 10_000) catch {};
    var line_buf: [64 * 1024]u8 = undefined;
    var lb = framing.LineBuffer.init(&line_buf);
    var seen: usize = 0;
    while (seen < 16) : (seen += 1) {
        const line = (lb.readLine(fd) catch return null) orelse return null;
        const parsed = json.parseFromSliceLeaky(json.Value, arena, line, .{}) catch continue;
        if (parsed != .object) continue;
        const id = parsed.object.get("id") orelse continue;
        if (id != .string or !std.mem.eql(u8, id.string, send_request_id)) continue;
        return try arena.dupe(u8, line);
    }
    return null;
}

/// The id the send envelope carries and the hub echoes on its response.
/// Named because two functions have to agree on it, and they used to
/// agree by both spelling the same literal — which is the arrangement
/// that survives right up until one of them is edited.
const send_request_id = "send-0";

/// Build and write a DM envelope with its newline terminator to `fd`
/// (WI-2026-08-08-004). The hub only processes newline-terminated lines;
/// an unterminated frame is dropped at EOF while the sender still reports
/// "sent to ...".
fn writeSendEnvelope(allocator: Allocator, fd: sys.fd_t, source_id: []const u8, target: []const u8, text: []const u8) !void {
    // Build the DM envelope per [[RFC-0003]] (direct message envelope, legacy chat surface).
    var payload_obj = json.ObjectMap.empty;
    try payload_obj.put(allocator, "text", .{ .string = text });
    const envelope = protocol.Envelope{
        .@"type" = "dm",
        .id = send_request_id,
        .source = source_id,
        .target = target,
        .payload = .{ .object = payload_obj },
    };
    const raw = try protocol.serializeEnvelope(allocator, envelope);
    defer allocator.free(raw);

    try sys.writeAll(fd, raw);
    try sys.writeAll(fd, "\n");
}

pub fn runRecv(allocator: Allocator, args: RecvArgs) !void {
    if (try ipcRoundtrip(allocator, .{ .action = .recv, .wait = args.wait })) return;
    // NO FALLBACK, BECAUSE THE ONE THAT WAS HERE COULD NOT WORK
    // ([[WI-2026-09-02-020]]): it registered a throwaway id and read from
    // its (always empty) mailbox, so `recv` printed "no messages" whatever
    // was waiting and `recv --wait` hung forever with zero chance of
    // success. A mailbox belongs to a registered agent, and the pane
    // daemon is what holds that identity — outside one there is nothing
    // to receive as. Said plainly, exit 2, like notify and register.
    try io_mod.stderrWriteAll("error: recv reads this pane's mailbox and needs a synapty session\n");
    notInSession();
}

fn readLineHub(fd: sys.fd_t, buf: []u8) !?[]const u8 {
    var lb = framing.LineBuffer.init(buf);
    return lb.readLine(fd);
}

pub fn runAgents(allocator: Allocator) !void {
    if (try ipcRoundtrip(allocator, .{ .action = .agents })) return;

    // Fallback: direct Hub TCP connection.
    const now_ms = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds();
    const source_id = try std.fmt.allocPrint(allocator, "{s}agents-{d}", .{ protocol.temp_agent_prefix, now_ms });
    defer allocator.free(source_id);

    // Anonymous query connection — no register envelope, so no temporary
    // agent churn in the hub routing table (WI-2026-03-31-004).
    const fd = try transport.connectToHub(transport.hub_addr, transport.resolveHubPort());
    defer sys.close(fd);

    // Send a list_agents request envelope.
    const envelope = protocol.Envelope{
        .@"type" = "list_agents",
        .id = "agents-0",
        .source = source_id,
        .target = "hub",
    };
    const raw = try protocol.serializeEnvelope(allocator, envelope);
    defer allocator.free(raw);

    try sys.writeAll(fd, raw);
    try sys.writeAll(fd, "\n");

    // Line-buffered so a frame split across TCP segments is not truncated
    // (WI-2026-08-08-028). BOUNDED, AND A FAILURE IS A FAILURE
    // ([[WI-2026-09-02-020]]): a hub that accepted and never answered hung
    // this forever, and no answer was printed to STDOUT with exit 0, where
    // a script reading the list could not tell it from data.
    sys.setRecvTimeout(fd, 10_000) catch {};
    var buf: [64 * 1024]u8 = undefined;
    const line = readLineHub(fd, &buf) catch null;
    if (line) |l| {
        const n = l.len;
        try io_mod.stdoutWriteAll(buf[0..n]);
        try io_mod.stdoutWriteAll("\n");
    } else {
        try io_mod.stderrWriteAll("error: the hub did not answer\n");
        std.process.exit(1);
    }
}

// ---------------------------------------------------------------------------
// wait subcommand — RFC-0004 C-WAIT (event-driven cross-agent sync)
// ---------------------------------------------------------------------------

const wait_mod = @import("wait.zig");

/// `synapty wait --agent <id> --until <state> [--timeout <secs>]`.
/// A filtered subscription against the hub event stream — no polling.
/// Exit codes (stable, for scripts — RFC-0004 C-WAIT): 0 satisfied,
/// 2 target not registered at start, 3 timeout, 4 generation ended,
/// 1 transport/stream failure.
pub fn runWait(allocator: Allocator, args: types.WaitArgs) !void {
    // Parse already validated the state word.
    const until = protocol.Status.fromString(args.until) orelse unreachable;

    const fd = transport.connectToHub(transport.hub_addr, transport.resolveHubPort()) catch {
        try io_mod.stderrWriteAll("error: cannot reach the hub (is Synapty running?)\n");
        std.process.exit(1);
    };
    defer sys.close(fd);

    const timeout_ms: ?u64 = if (args.timeout_secs) |s| @as(u64, s) * 1000 else null;
    const result = wait_mod.waitOnHub(allocator, fd, args.agent, until, timeout_ms) catch {
        try io_mod.stderrWriteAll("error: hub stream failed while waiting\n");
        std.process.exit(1);
    };

    switch (result.outcome) {
        .satisfied => {
            const msg = try std.json.Stringify.valueAlloc(allocator, .{
                .ok = true,
                .agent = args.agent,
                .status = result.status.toString(),
                .generation = result.generation,
            }, .{});
            defer allocator.free(msg);
            try io_mod.stdoutWriteAll(msg);
            try io_mod.stdoutWriteAll("\n");
        },
        // EVERY FAILURE SPEAKS TO A SCRIPT AS WELL AS TO A HUMAN.
        // C-WAIT's exit-code set is CLOSED and federation adds nothing to
        // it — two of these share exit 2 — so the code alone cannot say
        // which happened, and the payload is where the difference has to
        // live. It goes to stdout beside the satisfied case's JSON; the
        // sentence for the human goes to stderr.
        .not_registered => {
            try failWait(allocator, args.agent, "not_registered", null,
                "error: agent is not registered\n", 2);
        },
        .unresolved => {
            // WHAT THE PRESENCE ROW WOULD HAVE SAID. Reporting the row's
            // own word rather than a second name for the same three states
            // is what C-WAIT asks for, and it is the word `list_agents`
            // already carries.
            const cause = result.cause orelse .no_evidence;
            const sentence = switch (cause) {
                .peer_unreachable => "error: the machine hosting that agent is not reachable from here — " ++
                    "nothing that would end this wait can arrive\n",
                .contested => "error: two peers claim that identity, so it is addressed by nobody — " ++
                    "nothing that would end this wait can arrive\n",
                .peer_lacks_capability => "error: that machine's build does not relay presence, so its " ++
                    "status will never change here — nothing that would end this wait can arrive\n",
                .no_evidence => "error: that agent's status cannot be resolved from here\n",
            };
            try failWait(allocator, args.agent, "unresolved", cause.toString(), sentence, 2);
        },
        .timeout => {
            try failWait(allocator, args.agent, "timeout", null,
                "error: timeout before the agent reached the requested state\n", 3);
        },
        .generation_ended => {
            try failWait(allocator, args.agent, "generation_ended", null,
                "error: agent unregistered while waiting (generation ended)\n", 4);
        },
        .protocol_error => {
            try failWait(allocator, args.agent, "protocol_error", null,
                "error: hub stream failed while waiting\n", 1);
        },
    }
}

/// A wait that did not succeed, said twice: once for a script and once
/// for a human. Never returns.
fn failWait(
    allocator: Allocator,
    agent: []const u8,
    reason: []const u8,
    cause: ?[]const u8,
    sentence: []const u8,
    code: u8,
) !void {
    const msg = if (cause) |c| try std.json.Stringify.valueAlloc(allocator, .{
        .ok = false,
        .agent = agent,
        .reason = reason,
        .cause = c,
    }, .{}) else try std.json.Stringify.valueAlloc(allocator, .{
        .ok = false,
        .agent = agent,
        .reason = reason,
    }, .{});
    defer allocator.free(msg);
    try io_mod.stdoutWriteAll(msg);
    try io_mod.stdoutWriteAll("\n");
    try io_mod.stderrWriteAll(sentence);
    std.process.exit(code);
}

// ---------------------------------------------------------------------------
// exec subcommand — RFC-0007 agent-initiated pane execution
// ---------------------------------------------------------------------------

/// `synapty exec open|run|wait-output|read|close` (RFC-0007). Routes an
/// exec_request through the hub to the workbench and prints the
/// exec_response. Owner identity is SYNAPTY_AGENT_ID (the pane wrapper's
/// stable id) so ownership holds across invocations; the exec pane is
/// single-owner by that id + generation (C-EXEC-SCOPE). Exit codes are
/// the closed terminal-outcome set (C-PRIMITIVES): 0 ok/matched,
/// 3 timed-out, 5 target-gone, 6 ownership-lost, 7 disarmed, 8 refused,
/// 1 transport, 2 usage.
pub fn runExec(allocator: Allocator, args: types.ExecArgs) !void {
    const owner = requireAgentId("exec");
    // run: workbench enforces the C0/C1 rule, but reject client-side too
    // (convenience — a raw hub connection gains nothing).
    if (args.verb == .run) {
        const cmd = args.command orelse {
            try io_mod.stderrWriteAll("error: run requires --cmd\n");
            std.process.exit(2);
        };
        if (!protocol.isValidExecCommand(cmd)) {
            try io_mod.stderrWriteAll("error: command must be a single line of printable characters\n");
            std.process.exit(2);
        }
    }

    const fd = transport.connectToHub(transport.hub_addr, transport.resolveHubPort()) catch {
        try io_mod.stderrWriteAll("error: cannot reach the hub (is Synapty running?)\n");
        std.process.exit(1);
    };
    defer sys.close(fd);

    // Register the requester id so the exec_response routes back. Owner
    // and requester are the same stable pane identity.
    // SERIALIZED ([[WI-2026-09-02-021]]): an id with a quote or a newline
    // in it interpolated here was a malformed frame, or two frames.
    const reg = try protocol.serializeEnvelope(allocator, .{
        .type = "register",
        .id = "exec-reg",
        .source = owner,
        .target = "",
    });
    defer allocator.free(reg);
    try sys.writeAll(fd, reg);
    try sys.writeAll(fd, "\n");

    // Build the exec_request payload.
    var payload = json.ObjectMap.empty;
    const verb_str = switch (args.verb) {
        .open => "open",
        .run => "run",
        .wait_output => "wait-output",
        .read => "read",
        .close => "close",
    };
    try payload.put(allocator, "verb", .{ .string = verb_str });
    try payload.put(allocator, "owner", .{ .string = owner });
    try payload.put(allocator, "requester", .{ .string = owner });
    try payload.put(allocator, "request_id", .{ .string = "exec-1" });
    if (args.pane) |p| try payload.put(allocator, "pane", .{ .string = p });
    if (args.command) |c| try payload.put(allocator, "command", .{ .string = c });
    if (args.follow_up) try payload.put(allocator, "follow_up", .{ .bool = true });
    if (args.cwd) |c| try payload.put(allocator, "cwd", .{ .string = c });
    if (args.pattern) |p| try payload.put(allocator, "pattern", .{ .string = p });
    if (args.verb == .wait_output) try payload.put(allocator, "timeout_secs", .{ .integer = @intCast(args.timeout_secs) });
    if (args.verb == .read) try payload.put(allocator, "rows", .{ .integer = @intCast(args.rows) });

    const envelope = protocol.Envelope{
        .@"type" = "exec_request",
        .id = "exec-1",
        .source = owner,
        .target = "workbench",
        .payload = .{ .object = payload },
    };
    const raw = try protocol.serializeEnvelope(allocator, envelope);
    defer allocator.free(raw);
    try sys.writeAll(fd, raw);
    try sys.writeAll(fd, "\n");

    // Wait for exec_response (or the hub's fast "no workbench" error).
    // wait-output can legitimately take up to its timeout; give the read
    // an extra margin over the requested timeout.
    const deadline_ms: u64 = (@as(u64, args.timeout_secs) + 10) * 1000;
    var tv = std.posix.timeval{ .sec = @intCast(@divFloor(deadline_ms, 1000)), .usec = 0 };
    std.posix.setsockopt(fd, sys.SOL.SOCKET, sys.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    _ = &tv;

    var buf: [64 * 1024]u8 = undefined;
    var lb = framing.LineBuffer.init(&buf);
    while (true) {
        const line = (lb.readLine(fd) catch {
            try io_mod.stderrWriteAll("error: no response from workbench (exec timed out)\n");
            std.process.exit(1);
        }) orelse {
            try io_mod.stderrWriteAll("error: hub closed the connection\n");
            std.process.exit(1);
        };
        const trimmed = mem.trimEnd(u8, line, "\r ");
        if (trimmed.len == 0) continue;
        // Skip the register ack; act on exec_response or an error response.
        const parsed = json.parseFromSlice(json.Value, allocator, trimmed, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const typ = if (parsed.value.object.get("type")) |t| (if (t == .string) t.string else "") else "";
        if (mem.eql(u8, typ, "exec_response")) {
            try io_mod.stdoutWriteAll(trimmed);
            try io_mod.stdoutWriteAll("\n");
            std.process.exit(execExitCode(parsed.value));
        }
        if (mem.eql(u8, typ, "response")) {
            // The hub's synchronous error path (e.g. "no workbench").
            const pl = parsed.value.object.get("payload");
            if (pl != null and pl.? == .object) {
                const okv = pl.?.object.get("ok");
                if (okv != null and okv.? == .bool and !okv.?.bool) {
                    const err = if (pl.?.object.get("error")) |e| (if (e == .string) e.string else "exec failed") else "exec failed";
                    try io_mod.stderrWriteAll("error: ");
                    try io_mod.stderrWriteAll(err);
                    try io_mod.stderrWriteAll("\n");
                    std.process.exit(8);
                }
            }
        }
    }
}

/// Map an exec_response's outcome field to the closed exit-code set.
fn execExitCode(resp: json.Value) u8 {
    const pl = resp.object.get("payload") orelse return 0;
    if (pl != .object) return 0;
    const data = pl.object.get("data") orelse return 0;
    if (data != .object) return 0;
    const outcome = data.object.get("outcome") orelse return 0;
    if (outcome != .string) return 0;
    const o = outcome.string;
    if (mem.eql(u8, o, "matched") or mem.eql(u8, o, "ok") or mem.eql(u8, o, "opened") or mem.eql(u8, o, "ran") or mem.eql(u8, o, "closed")) return 0;
    if (mem.eql(u8, o, "timed-out")) return 3;
    if (mem.eql(u8, o, "target-gone")) return 5;
    if (mem.eql(u8, o, "ownership-lost")) return 6;
    if (mem.eql(u8, o, "disarmed")) return 7;
    if (mem.eql(u8, o, "refused")) return 8;
    return 0;
}

// ---------------------------------------------------------------------------
// github subcommand — RFC-0003 C-AUTH (login device only)
// ---------------------------------------------------------------------------

const github = @import("github");

/// Prompt on stdin for a line of input (trimmed).
fn promptLine(allocator: Allocator, prompt: []const u8) !?[]const u8 {
    try io_mod.stdoutWriteAll(prompt);
    try io_mod.stdoutWriteAll(": ");
    var buf: [4096]u8 = undefined;
    const n = sys.read(0, &buf) catch return null;
    if (n == 0) return null;
    const line = std.mem.trim(u8, buf[0..n], "\r\n");
    if (line.len == 0) return null;
    const d = try allocator.dupe(u8, line);
    return @as(?[]const u8, d);
}

/// `synapty github login` — configure hub repo + store PAT in Keychain.
pub fn runGithubLogin(allocator: Allocator, args: types.GithubArgs) !void {
    const owner = args.owner orelse (try promptLine(allocator, "Hub repo owner (GitHub username/org)")) orelse {
        try io_mod.stderrWriteAll("error: owner required\n");
        std.process.exit(1);
    };
    const repo = args.repo orelse (try promptLine(allocator, "Hub repo name")) orelse {
        try io_mod.stderrWriteAll("error: repo required\n");
        std.process.exit(1);
    };
    const token = args.token orelse (try promptSecret(allocator, "Fine-grained PAT (Issues read/write on the hub repo)")) orelse {
        try io_mod.stderrWriteAll("error: token required\n");
        std.process.exit(1);
    };

    // Verify credentials against the API before storing anything.
    var config = github.Config{ .owner = owner, .repo = repo };
    const api = github.Api{ .allocator = allocator, .owner = owner, .repo = repo, .token = token };
    const check = api.request(.GET, "/rate_limit", null) catch {
        try io_mod.stderrWriteAll("error: token verification failed — check the token scope and repo name\n");
        std.process.exit(1);
    };
    allocator.free(check);

    // Record the GitHub username (issue assignee identity for task.claim).
    if (api.request(.GET, "/user", null)) |user_body| {
        defer allocator.free(user_body);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = json.parseFromSlice(json.Value, arena.allocator(), user_body, .{ .allocate = .alloc_always }) catch null;
        if (parsed) |p| {
            switch (p.value) {
                .object => |obj| if (obj.get("login")) |login| switch (login) {
                    .string => |l| config.username = try allocator.dupe(u8, l),
                    else => {},
                },
                else => {},
            }
        }
    } else |_| {}

    try config.save(allocator);
    try github.storeToken(allocator, accountOf(allocator, owner, repo), token);
    try io_mod.stdoutWriteAll("Saved. Hub repo: ");
    try io_mod.stdoutWriteAll(owner);
    try io_mod.stdoutWriteAll("/");
    try io_mod.stdoutWriteAll(repo);
    try io_mod.stdoutWriteAll("\n");
}

fn accountOf(allocator: Allocator, owner: []const u8, repo: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ owner, repo }) catch "github";
}

/// `synapty github logout` — unbind the bridge: delete the Keychain
/// credential AND the config binding (owner/repo/username). The ONLY
/// removal path for the stored PAT (WI-2026-08-08-043).
pub fn runGithubLogout(allocator: Allocator) !void {
    const config = try github.Config.load(allocator);
    if (config) |c| {
        const account = accountOf(allocator, c.owner, c.repo);
        defer allocator.free(account);
        const deleted = try github.deleteToken(allocator, account);
        if (deleted) {
            try io_mod.stdoutWriteAll("Removed GitHub credential for ");
            try io_mod.stdoutWriteAll(c.owner);
            try io_mod.stdoutWriteAll("/");
            try io_mod.stdoutWriteAll(c.repo);
            try io_mod.stdoutWriteAll("\n");
        } else {
            try io_mod.stdoutWriteAll("No stored credential found — clearing the binding anyway.\n");
        }
        // The config file only carries the github binding — remove it.
        if (try github.Config.configPath(allocator)) |path| {
            defer allocator.free(path);
            sys.unlink(path);
        }
        try io_mod.stdoutWriteAll("GitHub bridge unbound.\n");
    } else {
        try io_mod.stdoutWriteAll("GitHub bridge is not configured.\n");
    }
}

/// `synapty github status` — print the current binding as JSON for the
/// GUI: {configured, owner, repo, username?, hasToken} (WI-2026-08-08-043).
pub fn runGithubStatus(allocator: Allocator) !void {
    var payload = json.ObjectMap.empty;
    const config = try github.Config.load(allocator);
    if (config) |c| {
        const account = accountOf(allocator, c.owner, c.repo);
        defer allocator.free(account);
        const has_token = (try github.loadToken(allocator, account)) != null;
        try payload.put(allocator, "configured", .{ .bool = has_token });
        try payload.put(allocator, "owner", .{ .string = c.owner });
        try payload.put(allocator, "repo", .{ .string = c.repo });
        if (c.username) |u| try payload.put(allocator, "username", .{ .string = u });
        try payload.put(allocator, "hasToken", .{ .bool = has_token });
    } else {
        try payload.put(allocator, "configured", .{ .bool = false });
    }
    const raw = try json.Stringify.valueAlloc(allocator, json.Value{ .object = payload }, .{});
    defer allocator.free(raw);
    try io_mod.stdoutWriteAll(raw);
    try io_mod.stdoutWriteAll("\n");
}

// ---------------------------------------------------------------------------
// task subcommand — RFC-0003 C-CLI-TOOLS
// ---------------------------------------------------------------------------

/// Send a tool_request envelope to the hub and print the tool_response.
/// Uses an anonymous connection — no register envelope, so no temporary
/// agent appears in the hub's routing table (WI-2026-03-31-004).
fn toolRoundtrip(allocator: Allocator, tool: []const u8, args_obj: json.ObjectMap) !void {
    const now_ms = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds();
    const source_id = try std.fmt.allocPrint(allocator, "{s}task-{d}", .{ protocol.temp_agent_prefix, now_ms });
    defer allocator.free(source_id);
    return toolRoundtripFrom(allocator, source_id, tool, args_obj);
}

/// The same round trip under a REAL agent identity, so the hub's activity
/// record names who asked rather than a throwaway connection id.
fn toolRoundtripAs(allocator: Allocator, agent: []const u8, tool: []const u8, args_obj: json.ObjectMap) !void {
    return toolRoundtripFrom(allocator, agent, tool, args_obj);
}

/// What a tool_response says happened, as a pure function of the line.
///
/// AN ERROR MUST NOT EXIT 0. The round trip used to print the hub's
/// envelope and return, so a refused transfer and a completed one were
/// indistinguishable to `$?` — an agent checking the exit code alone
/// reported deliveries that never happened.
///
/// THREE OUTCOMES, NOT TWO, and the third is the point. A transfer
/// waiting on a human to approve its route is not a failure to give up
/// on; retrying after they answer is exactly right, while retrying "no
/// such host" is a loop. Distinguished by a MARKER the workbench sets,
/// not by matching the message — a reworded refusal must not silently
/// change what callers do.
///
/// Same reasoning as `ask` exiting 3 on a timeout ([[WI-2026-08-15-012]]):
/// a caller has to tell "nobody answered" from "the answer was no".
pub const ToolOutcome = enum(u8) {
    ok = 0,
    /// A human has been asked and has not answered yet. Retry later.
    awaiting_human = 3,
    /// The workbench will not do this as asked. Retrying changes nothing.
    refused = 4,
};

pub fn classifyToolReply(allocator: Allocator, reply: []const u8) ToolOutcome {
    const parsed = json.parseFromSlice(json.Value, allocator, reply, .{}) catch return .refused;
    defer parsed.deinit();
    const payload = switch (parsed.value) {
        .object => |o| o.get("payload") orelse return .refused,
        else => return .refused,
    };
    const ok = switch (payload) {
        .object => |o| if (o.get("ok")) |v| (v == .bool and v.bool) else false,
        else => false,
    };
    if (ok) return .ok;
    // A malformed or absent marker means an ordinary refusal, which is the
    // safe way round: a caller told to retry forever is worse off than one
    // told to stop.
    if (extractDataField(allocator, reply, "state")) |state| {
        defer allocator.free(state);
        if (mem.eql(u8, state, "awaiting_approval")) return .awaiting_human;
    }
    return .refused;
}

fn toolRoundtripFrom(allocator: Allocator, source_id: []const u8, tool: []const u8, args_obj: json.ObjectMap) !void {
    const line = try toolExchange(allocator, source_id, tool, args_obj);
    defer allocator.free(line);
    try io_mod.stdoutWriteAll(line);
    try io_mod.stdoutWriteAll("\n");
    // BOTH CHANNELS, PER [[RFC-0003]] C-CLI-TOOLS: the JSON stays on
    // stdout for whatever is parsing it, and the reason goes to stderr as
    // a sentence for whoever is reading. The exit code says what to do
    // next. Printing only the envelope left a human running this by hand
    // to pick their answer out of a line of JSON.
    const outcome = classifyToolReply(allocator, line);
    if (outcome != .ok) {
        if (payloadError(allocator, line)) |why| {
            defer allocator.free(why);
            try io_mod.stderrWriteAll("error: ");
            try io_mod.stderrWriteAll(why);
            try io_mod.stderrWriteAll("\n");
        }
        std.process.exit(@intFromEnum(outcome));
    }
}

/// `payload.error` — the workbench's own sentence about what went wrong.
fn payloadError(allocator: Allocator, reply: []const u8) ?[]u8 {
    const parsed = json.parseFromSlice(json.Value, allocator, reply, .{}) catch return null;
    defer parsed.deinit();
    const payload = switch (parsed.value) {
        .object => |o| o.get("payload") orelse return null,
        else => return null,
    };
    const v = switch (payload) {
        .object => |o| o.get("error") orelse return null,
        else => return null,
    };
    return switch (v) {
        .string => |str| allocator.dupe(u8, str) catch null,
        else => null,
    };
}

/// `synapty put` / `synapty fetch` — move a file between machines through
/// the workbench ([[RFC-0013]] C-BROKER, [[WI-2026-08-15-010]]).
///
/// AN UNATTRIBUTABLE TRANSFER IS REFUSED, NOT PERFORMED ANONYMOUSLY. Every
/// transfer is recorded with its initiator ([[RFC-0013]] C-AUTHORIZATION),
/// and a record nobody can act on is not a record. SYNAPTY_AGENT_ID is the
/// pane wrapper's stable id, the same identity `exec` requires and for the
/// same reason.
pub fn runFile(allocator: Allocator, args: types.FileArgs) !void {
    const agent = requireAgentId("file transfers");

    var args_obj = json.ObjectMap.empty;
    try args_obj.put(allocator, "path", .{ .string = args.path });
    try args_obj.put(allocator, "host", .{ .string = args.host });
    if (args.into) |dir| try args_obj.put(allocator, "into", .{ .string = dir });

    const tool = switch (args.verb) {
        .put => "file.put",
        .fetch => "file.fetch",
    };
    try toolRoundtripAs(allocator, agent, tool, args_obj);
}

/// `synapty expose` / `synapty unexpose` — put something this agent is
/// running in front of a human, or take it back
/// ([[RFC-0013]] C-PRIMITIVES, [[WI-2026-08-15-011]]).
///
/// ATTRIBUTION IS REQUIRED, as for transfers: there is no anonymous
/// presented content, so a caller the workbench cannot name has nothing to
/// show. The view carries the agent's id wherever it appears.
pub fn runView(allocator: Allocator, args: types.ViewArgs) !void {
    const agent = requireAgentId("expose");

    var args_obj = json.ObjectMap.empty;
    try args_obj.put(allocator, "port", .{ .integer = @intCast(args.port) });
    if (args.title) |t| try args_obj.put(allocator, "title", .{ .string = t });
    if (args.path) |path| try args_obj.put(allocator, "path", .{ .string = path });
    if (args.at) |at| try args_obj.put(allocator, "at", .{ .string = at });

    const tool = switch (args.verb) {
        .expose => "view.expose",
        .withdraw => "view.withdraw",
        .present => "view.present",
    };
    try toolRoundtripAs(allocator, agent, tool, args_obj);
}

/// `synapty identify` — which machine and session this pane is in.
///
/// The workbench is the only party that knows: a shell can see its own
/// environment and nothing about the window it is drawn in.
pub fn runIdentify(allocator: Allocator) !void {
    const agent = requireAgentId("identify");
    try toolRoundtripAs(allocator, agent, "agent.identify", json.ObjectMap.empty);
}

/// `synapty exposed [<port>]` — what became of what this agent exposed.
///
/// ITS OWN, AND ONLY ITS OWN, for the same reason `unexpose` is: reading
/// back another agent's view is reading something it put in front of a
/// human, which is not this caller's to have.
pub fn runExposed(allocator: Allocator, args: types.ExposedArgs) !void {
    const agent = requireAgentId("exposed");
    var args_obj = json.ObjectMap.empty;
    if (args.port) |p| try args_obj.put(allocator, "port", .{ .integer = @intCast(p) });
    try toolRoundtripAs(allocator, agent, "view.status", args_obj);
}

/// `synapty ask` — put a decision in front of a human and wait for it.
///
/// TWO PHASES, NOT ONE LONG ONE. The hub parks a forwarded request for 180
/// seconds and then reaps it, because a parked request holds a connection
/// and its file descriptor until the hub exits. A human who steps away
/// outlasts that. So this posts the question, returns, and then polls —
/// each poll a short round trip well inside the bound, rather than one long
/// one that stretches a mechanism past what it was built for.
///
/// The patience is the AGENT'S to choose: only it knows what it is holding
/// open while it waits. Exit 3 on timeout, matching `exec`'s terminal
/// outcome set, so a caller can tell "nobody answered" from "the answer was
/// no".
pub fn runAsk(allocator: Allocator, args: types.AskArgs) !void {
    const agent = requireAgentId("ask");

    var post_args = json.ObjectMap.empty;
    try post_args.put(allocator, "question", .{ .string = args.question });
    var opts = json.Array.init(allocator);
    for (args.options()) |o| try opts.append(.{ .string = o });
    try post_args.put(allocator, "options", .{ .array = opts });

    const posted = try toolExchange(allocator, agent, "view.ask", post_args);
    defer allocator.free(posted);
    const question_id = extractDataField(allocator, posted, "question_id") orelse {
        try io_mod.stdoutWriteAll(posted);
        try io_mod.stdoutWriteAll("\n");
        std.process.exit(1);
    };
    defer allocator.free(question_id);

    const deadline_ms = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds() +
        @as(i64, args.timeout_secs) * 1000;
    var poll_failures: u32 = 0;
    while (std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds() < deadline_ms) {
        io_mod.get().sleep(std.Io.Duration.fromMilliseconds(1000), .awake) catch {};
        var poll_args = json.ObjectMap.empty;
        try poll_args.put(allocator, "question_id", .{ .string = question_id });
        // A FAILED POLL IS "NOT YET", up to a point ([[WI-2026-09-02-020]]):
        // a dropped connection mid-poll abandoned a question the human may
        // have just answered. Three in a row is the hub gone.
        const reply = toolExchange(allocator, agent, "view.answer", poll_args) catch |err| {
            poll_failures += 1;
            if (poll_failures >= 3) return err;
            continue;
        };
        poll_failures = 0;
        defer allocator.free(reply);
        if (extractDataField(allocator, reply, "answer")) |answer| {
            defer allocator.free(answer);
            try io_mod.stdoutWriteAll(answer);
            try io_mod.stdoutWriteAll("\n");
            return;
        }
    }
    try io_mod.stderrWriteAll("error: nobody answered in time\n");
    std.process.exit(3);
}

/// THE TOOL REQUEST ITSELF: sent, awaited, and its reply RETURNED rather
/// than printed.
///
/// THE OWNER OF THE WIRE, because there were two and only one of them was
/// careful. This form connected with a bare `try` — so `synapty ask` with
/// no hub propagated ConnectionRefused out of main as a stack trace, the
/// exact failure [[RFC-0003]] C-CLI-TOOLS asks the CLI not to produce —
/// and read with no deadline, so a request the hub parked and nobody
/// answered blocked here until the caller was killed
/// ([[WI-2026-08-30-006]]).
fn toolExchange(
    allocator: Allocator, source_id: []const u8, tool: []const u8, args_obj: json.ObjectMap,
) ![]u8 {
    // A DUMPED STACK TRACE IS NOT A HUMAN-READABLE ERROR, and
    // [[RFC-0003]] C-CLI-TOOLS asks for one. With no hub running, every
    // tool verb printed `error: ConnectionRefused` and eight frames of
    // this repository's own source paths — burying the one fact the
    // reader can act on.
    const fd = transport.connectToHub(transport.hub_addr, transport.resolveHubPort()) catch {
        try io_mod.stderrWriteAll("error: cannot reach the hub (is Synapty running?)\n");
        std.process.exit(@intFromEnum(ToolOutcome.refused));
    };
    defer sys.close(fd);

    var payload_obj = json.ObjectMap.empty;
    try payload_obj.put(allocator, "tool", .{ .string = tool });
    try payload_obj.put(allocator, "args", .{ .object = args_obj });
    // ONE REQUEST, ONE ID. Both forms sent a fixed literal — "task-0" and
    // "ask-0" — so two requests in flight from one caller were
    // indistinguishable on the wire to anything that wanted to correlate
    // them. Nothing correlates on it today; a constant is a trap laid for
    // whatever does first.
    const req_id = try std.fmt.allocPrint(allocator, "task-{d}", .{sys.nowMillis()});
    defer allocator.free(req_id);
    const envelope = protocol.Envelope{
        .@"type" = "tool_request",
        .id = req_id,
        .source = source_id,
        .target = "hub",
        .payload = .{ .object = payload_obj },
    };
    const raw = try protocol.serializeEnvelope(allocator, envelope);
    defer allocator.free(raw);
    try sys.writeAll(fd, raw);
    try sys.writeAll(fd, "\n");

    // A READ WITH NO DEADLINE IS A HANG WAITING FOR A REASON.
    //
    // Not hypothetical: a remote agent's request reached its own hub, was
    // parked, and nothing downstream ever replied — the caller sat in
    // this read until it was killed. The hub bounds its own park at 180s
    // and answers when that expires, so this waits somewhat LONGER than
    // the hub does: any shorter and the CLI would give up first, and the
    // honest answer the hub is about to send would never be read.
    sys.setRecvTimeout(fd, @intCast(protocol.tool_wait_ms)) catch {};
    var buf: [256 * 1024]u8 = undefined;
    const line = ipc.IpcServer.readLine(fd, &buf) catch |err| switch (err) {
        error.WouldBlock => {
            try io_mod.stderrWriteAll(
                "error: no answer from the hub — the request may still be parked there\n");
            std.process.exit(@intFromEnum(ToolOutcome.refused));
        },
        else => return err,
    } orelse {
        try io_mod.stdoutWriteAll("{\"ok\":false,\"error\":\"no response from hub\"}\n");
        std.process.exit(@intFromEnum(ToolOutcome.refused));
    };
    return allocator.dupe(u8, line);
}

/// Pull one string field out of a tool_response's `data`, which the
/// workbench sends as a JSON STRING rather than an object.
fn extractDataField(allocator: Allocator, reply: []const u8, field: []const u8) ?[]u8 {
    const parsed = json.parseFromSlice(json.Value, allocator, reply, .{}) catch return null;
    defer parsed.deinit();
    const payload = switch (parsed.value) {
        .object => |o| o.get("payload") orelse return null,
        else => return null,
    };
    const data_val = switch (payload) {
        .object => |o| o.get("data") orelse return null,
        else => return null,
    };
    const data_str = switch (data_val) {
        .string => |s| s,
        else => return null,
    };
    const inner = json.parseFromSlice(json.Value, allocator, data_str, .{}) catch return null;
    defer inner.deinit();
    const v = switch (inner.value) {
        .object => |o| o.get(field) orelse return null,
        else => return null,
    };
    return switch (v) {
        .string => |s| allocator.dupe(u8, s) catch null,
        else => null,
    };
}

pub fn runTaskList(allocator: Allocator, args: types.TaskListArgs) !void {
    var args_obj = json.ObjectMap.empty;
    if (args.project) |p| try args_obj.put(allocator, "labels", .{ .string = p });
    if (args.state) |st| try args_obj.put(allocator, "state", .{ .string = st });
    try toolRoundtrip(allocator, "task.list", args_obj);
}

pub fn runTaskShow(allocator: Allocator, args: types.TaskShowArgs) !void {
    var args_obj = json.ObjectMap.empty;
    try args_obj.put(allocator, "number", .{ .integer = args.number });
    try toolRoundtrip(allocator, "task.show", args_obj);
}

pub fn runTaskClaim(allocator: Allocator, args: types.TaskClaimArgs) !void {
    var args_obj = json.ObjectMap.empty;
    try args_obj.put(allocator, "number", .{ .integer = args.number });
    try toolRoundtrip(allocator, "task.claim", args_obj);
}

pub fn runTaskUpdate(allocator: Allocator, args: types.TaskUpdateArgs) !void {
    var args_obj = json.ObjectMap.empty;
    try args_obj.put(allocator, "number", .{ .integer = args.number });
    try args_obj.put(allocator, "status", .{ .string = args.status });
    try toolRoundtrip(allocator, "task.update", args_obj);
}

pub fn runTaskComment(allocator: Allocator, args: types.TaskCommentArgs) !void {
    var args_obj = json.ObjectMap.empty;
    try args_obj.put(allocator, "number", .{ .integer = args.number });
    try args_obj.put(allocator, "body", .{ .string = args.body });
    try toolRoundtrip(allocator, "task.comment", args_obj);
}

pub fn runTaskCreate(allocator: Allocator, args: types.TaskCreateArgs) !void {
    var args_obj = json.ObjectMap.empty;
    try args_obj.put(allocator, "title", .{ .string = args.title });
    if (args.project) |p| try args_obj.put(allocator, "project", .{ .string = p });
    if (args.body) |b| try args_obj.put(allocator, "body", .{ .string = b });
    try toolRoundtrip(allocator, "task.create", args_obj);
}

// ---------------------------------------------------------------------------
// skills subcommand — RFC-0003 C-SKILLS
// ---------------------------------------------------------------------------

/// The skill package, embedded at compile time (WI-2026-08-09-023):
/// SKILL.md is a progressive-disclosure ROUTER (core workflow only);
/// command details live in reference docs the agent reads on demand.
/// EVERY FILE IN `src/skills/`, and only what is there.
///
/// The subpaths come from [[build.skillManifestModule]], which walks the
/// directory; this block turns each into the pair the installer wants. A
/// file added to the tree is installed without anything here being
/// touched, which is the whole point: the array this replaced was a second
/// declaration, and a file present in one and not the other is either
/// uninstalled or a broken link in a SKILL.md ([[WI-2026-08-30-006]]).
const skill_files = blk: {
    const manifest = @import("skill_manifest");
    var list: [manifest.subpaths.len]struct { subpath: []const u8, content: []const u8 } = undefined;
    for (manifest.subpaths, 0..) |sp, i| {
        list[i] = .{ .subpath = sp, .content = @embedFile("../skills/" ++ sp) };
    }
    const frozen = list;
    break :blk frozen;
};

const skill_install_marker = "<!-- synapty:installed -->";

/// Write one skill file (creating parent dirs). Plain overwrite —
/// idempotent by construction and always current.
fn installSkillFile(path: []const u8, content: []const u8) !void {
    const io = io_mod.get();
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    var out = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer out.close(io);
    try out.writeStreamingAll(io, content);
}

/// Remove a previously appended marked section (old AGENTS.md / GEMINI.md
/// distribution) so global instruction files are not polluted.
fn stripSynaptySection(allocator: Allocator, path: []const u8) void {
    const io = io_mod.get();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);
    var existing = std.ArrayList(u8).empty;
    defer existing.deinit(allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{tmp[0..]}) catch break;
        if (n == 0) break;
        existing.appendSlice(allocator, tmp[0..n]) catch break;
    }
    const marker = std.mem.indexOf(u8, existing.items, skill_install_marker) orelse return;
    // Cut everything from the blank line before the marker.
    var cut = marker;
    while (cut > 0 and existing.items[cut - 1] == '\n') cut -= 1;
    // Rewrite without the section.
    var out = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer out.close(io);
    out.writeStreamingAll(io, existing.items[0..cut]) catch {};
}

/// `synapty skills install` — copy the skill package to detected
/// platforms. All platforms use the skill-directory convention:
///   Claude Code: ~/.claude/skills/synapty/
///   Codex:       ~/.codex/skills/synapty/
///   Gemini CLI:  ~/.gemini/skills/synapty/
pub fn runSkillsInstall(allocator: Allocator) !void {
    const home = sys.getenv("HOME") orelse {
        try io_mod.stderrWriteAll("error: HOME not set\n");
        std.process.exit(1);
    };
    const io = io_mod.get();

    // Migration: remove the old appended sections from global instruction
    // files (AGENTS.md / GEMINI.md) if present.
    const codex_agents = try std.fmt.allocPrint(allocator, "{s}/.codex/AGENTS.md", .{home});
    defer allocator.free(codex_agents);
    stripSynaptySection(allocator, codex_agents);
    const gemini_md = try std.fmt.allocPrint(allocator, "{s}/.gemini/GEMINI.md", .{home});
    defer allocator.free(gemini_md);
    stripSynaptySection(allocator, gemini_md);

    const platforms = [_]struct { label: []const u8, root: []const u8 }{
        .{ .label = "Claude Code", .root = "{s}/.claude/skills" },
        .{ .label = "Codex", .root = "{s}/.codex/skills" },
        .{ .label = "Gemini CLI", .root = "{s}/.gemini/skills" },
    };
    inline for (platforms) |p| {
        const root = try std.fmt.allocPrint(allocator, p.root, .{home});
        defer allocator.free(root);

        // Migration: the skill was previously named synapty-task with a
        // single SKILL.md — remove it so both names don't load twice.
        const old_file = try std.fmt.allocPrint(allocator, "{s}/synapty-task/SKILL.md", .{root});
        defer allocator.free(old_file);
        std.Io.Dir.cwd().deleteFile(io, old_file) catch {};
        const old_dir = try std.fmt.allocPrint(allocator, "{s}/synapty-task", .{root});
        defer allocator.free(old_dir);
        std.Io.Dir.cwd().deleteDir(io, old_dir) catch {};

        // The presentation reference moved into its own skill; a stale
        // copy under the old name would load beside the new one and
        // disagree with it.
        const stale = try std.fmt.allocPrint(
            allocator, "{s}/synapty/references/presentation.md", .{root});
        defer allocator.free(stale);
        std.Io.Dir.cwd().deleteFile(io, stale) catch {};

        for (skill_files) |f| {
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, f.subpath });
            defer allocator.free(path);
            try installSkillFile(path, f.content);
        }
        try io_mod.stdoutWriteAll("installed: ");
        try io_mod.stdoutWriteAll(p.label);
        try io_mod.stdoutWriteAll(" skill package -> ");
        try io_mod.stdoutWriteAll(root);
        // COUNTED, NOT SPELLED OUT. It read "2 references" as a literal
        // and kept saying so after a third was embedded — a report that
        // cannot be wrong is worth the two lines.
        var count_buf: [96]u8 = undefined;
        const summary = try std.fmt.bufPrint(
            &count_buf, "/ (synapty + synapty-present, {d} files)\n", .{skill_files.len});
        try io_mod.stdoutWriteAll(summary);
    }
}

// ---------------------------------------------------------------------------
// activity subcommand — recent tool-request stream (RFC-0003 C-HUB-ROLE)
// ---------------------------------------------------------------------------

pub fn runActivity(allocator: Allocator) !void {
    try toolRoundtrip(allocator, "activity.list", json.ObjectMap.empty);
}

/// A NOTICE ONTO A SCREEN WHOSE PARSER STATE IS UNKNOWN. These are
/// written at exactly the moments the stream was cut — a gap, a dead
/// link, an end — and a cut can fall after an ESC. Seen: the log a pane
/// was tailing was coloured, the cut landed after its ESC, and the
/// terminal read the notice's "[s" as CSI s, rendering "ynapty: output
/// was lost…" ([[WI-2026-09-02-030]]). ST (ESC \) first: from ground it
/// is a no-op, from a pending ESC it completes to ST, and from inside a
/// CSI, OSC or DCS it ends the sequence — every state goes to ground.
const screen_notice_reset = "\x1b\\";

fn noticeBytes(buf: []u8, text: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}\r\n[synapty: {s}]\r\n", .{ screen_notice_reset, text }) catch
        screen_notice_reset ++ "\r\n[synapty]\r\n";
}

fn screenNotice(text: []const u8) !void {
    var buf: [160]u8 = undefined;
    try io_mod.stderrWriteAll(noticeBytes(&buf, text));
}

test "a screen notice returns the parser to ground before it says anything" {
    var buf: [160]u8 = undefined;
    const bytes = noticeBytes(&buf, "output was lost");
    try std.testing.expect(std.mem.startsWith(u8, bytes, "\x1b\\"));
    try std.testing.expectEqualStrings("\x1b\\\r\n[synapty: output was lost]\r\n", bytes);
}

test "writeSendEnvelope writes a newline-terminated dm frame (WI-2026-08-08-004)" {
    // Loopback listener mimics the hub's line-framed reader: without the
    // trailing newline the frame would be dropped at EOF (the regression
    // this test guards against).
    // Arena: json.ObjectMap.put allocates its key via the allocator, and
    // the envelope payload lives until the write completes.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const listener = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    defer sys.close(listener);
    const addr4 = std.Io.net.Ip4Address.loopback(0);
    var sa = sys.sockaddr_in.init(@bitCast(addr4.bytes), 0);
    try sys.bind(listener, &sa, @sizeOf(sys.sockaddr_in));
    try sys.listen(listener, 1);
    const port = try sys.boundPort(listener);

    const client = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    defer sys.close(client);
    const ca4 = std.Io.net.Ip4Address.loopback(port);
    const csa = sys.sockaddr_in.init(@bitCast(ca4.bytes), port);
    try sys.connect(client, &csa, @sizeOf(sys.sockaddr_in));

    const server_fd = try sys.accept(listener);
    defer sys.close(server_fd);

    try writeSendEnvelope(allocator, client, "cli-tmp-test", "bob", "hello direct");

    var buf: [4096]u8 = undefined;
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = try sys.read(server_fd, buf[filled..]);
        if (n == 0) break;
        filled += n;
        if (buf[filled - 1] == '\n') break;
    }
    try std.testing.expect(filled > 0);
    try std.testing.expectEqual(@as(u8, '\n'), buf[filled - 1]);

    var parsed = try protocol.parseEnvelope(allocator, buf[0 .. filled - 1]);
    try std.testing.expectEqualStrings("dm", parsed.value.@"type");
    try std.testing.expectEqualStrings("cli-tmp-test", parsed.value.source);
    try std.testing.expectEqualStrings("bob", parsed.value.target);
    try std.testing.expectEqualStrings("hello direct", parsed.value.payload.object.get("text").?.string);
}

// ---------------------------------------------------------------------------
// hooks subcommand (WI-2026-08-11-007 harness adapter packs)
// ---------------------------------------------------------------------------

/// Read a whole file, or null if it does not exist. Settings files are
/// small; 1 MiB is a generous ceiling.
fn readFileMaybe(allocator: Allocator, path: []const u8) !?[]const u8 {
    const io = io_mod.get();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    const buf = try allocator.alloc(u8, 1024 * 1024);
    errdefer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

fn writeFileAll(path: []const u8, content: []const u8) !void {
    const io = io_mod.get();
    if (std.fs.path.dirname(path)) |dir_path| {
        try std.Io.Dir.cwd().createDirPath(io, dir_path);
    }
    var out = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer out.close(io);
    try out.writeStreamingAll(io, content);
}

/// Consent gate for modifying the user's standing harness config: y/N
/// prompt on a TTY, --yes required non-interactively. Returns true when
/// the write may proceed.
fn hooksConsent(yes: bool) !bool {
    if (yes) return true;
    if (!sys.isatty(0)) {
        try io_mod.stderrWriteAll("error: refusing to modify user config non-interactively; pass --yes\n");
        std.process.exit(2);
    }
    try io_mod.stdoutWriteAll("Proceed? [y/N] ");
    var buf: [16]u8 = undefined;
    const n = sys.read(0, &buf) catch 0;
    const answer = mem.trim(u8, buf[0..n], " \t\r\n");
    return answer.len > 0 and (answer[0] == 'y' or answer[0] == 'Y');
}

/// `synapty hooks <install|uninstall|status> <tool>` — deterministic
/// explicit presence for cooperative harnesses (WI-2026-08-11-007).
pub fn runHooks(allocator: Allocator, args: types.HooksArgs) !void {
    const home = sys.getenv("HOME") orelse {
        try io_mod.stderrWriteAll("error: HOME not set\n");
        std.process.exit(1);
    };

    if (mem.eql(u8, args.tool, "claude")) {
        try runHooksClaude(allocator, home, args);
    } else if (mem.eql(u8, args.tool, "codex")) {
        try runHooksCodex(allocator, home, args);
    } else {
        try io_mod.stderrWriteAll("error: unsupported tool (supported: claude, codex)\n");
        std.process.exit(2);
    }
}

fn runHooksClaude(allocator: Allocator, home: []const u8, args: types.HooksArgs) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/.claude/settings.json", .{home});
    defer allocator.free(path);
    const existing = try readFileMaybe(allocator, path);
    defer if (existing) |e| allocator.free(e);

    switch (args.action) {
        .status => {
            const st = try hooks_mod.claudeStatus(allocator, existing);
            for (hooks_mod.claude_hook_events, st) |event, installed| {
                const line = try std.fmt.allocPrint(allocator, "{s}: {s}\n", .{
                    event, if (installed) "installed" else "absent",
                });
                defer allocator.free(line);
                try io_mod.stdoutWriteAll(line);
            }
        },
        .install => {
            const merged = hooks_mod.mergeClaudeHooks(allocator, existing) catch {
                try io_mod.stderrWriteAll("error: settings.json is not a JSON object — aborting, nothing written\n");
                std.process.exit(1);
            };
            const new_json = merged orelse {
                try io_mod.stdoutWriteAll("already installed\n");
                return;
            };
            defer allocator.free(new_json);
            try io_mod.stdoutWriteAll("will write these hook entries to ");
            try io_mod.stdoutWriteAll(path);
            try io_mod.stdoutWriteAll(":\n");
            for (hooks_mod.claude_hook_events) |event| {
                const line = try std.fmt.allocPrint(
                    allocator, "  {s}: {s}\n", .{ event, hooks_mod.claude_command });
                defer allocator.free(line);
                try io_mod.stdoutWriteAll(line);
            }
            if (!try hooksConsent(args.yes)) {
                try io_mod.stdoutWriteAll("aborted\n");
                return;
            }
            try writeFileAll(path, new_json);
            try io_mod.stdoutWriteAll("installed — claude sessions in Synapty panes now report presence via hooks\n");
        },
        .uninstall => {
            const current = existing orelse {
                try io_mod.stdoutWriteAll("nothing installed\n");
                return;
            };
            const removed = hooks_mod.removeClaudeHooks(allocator, current) catch {
                try io_mod.stderrWriteAll("error: settings.json is not a JSON object — aborting, nothing written\n");
                std.process.exit(1);
            };
            const new_json = removed orelse {
                try io_mod.stdoutWriteAll("nothing installed\n");
                return;
            };
            defer allocator.free(new_json);
            try io_mod.stdoutWriteAll("will remove synapty hook entries from ");
            try io_mod.stdoutWriteAll(path);
            try io_mod.stdoutWriteAll("\n");
            if (!try hooksConsent(args.yes)) {
                try io_mod.stdoutWriteAll("aborted\n");
                return;
            }
            try writeFileAll(path, new_json);
            try io_mod.stdoutWriteAll("uninstalled\n");
        },
    }
}

/// codex is instructed-manual: we own the adapter script under OUR
/// config dir, but never edit another tool's TOML — the user pastes one
/// `notify` line into ~/.codex/config.toml themselves.
fn runHooksCodex(allocator: Allocator, home: []const u8, args: types.HooksArgs) !void {
    const script_path = try std.fmt.allocPrint(
        allocator,
        "{s}/.config/synapty/hooks/codex-notify.sh",
        .{home},
    );
    defer allocator.free(script_path);

    switch (args.action) {
        .status => {
            const existing = try readFileMaybe(allocator, script_path);
            defer if (existing) |e| allocator.free(e);
            try io_mod.stdoutWriteAll(if (existing != null)
                "adapter script present (check ~/.codex/config.toml for the notify line)\n"
            else
                "absent\n");
        },
        .install => {
            try writeFileAll(script_path, hooks_mod.codex_script);
            // Make it executable — codex invokes it directly.
            const io = io_mod.get();
            var f = try std.Io.Dir.cwd().openFile(io, script_path, .{});
            defer f.close(io);
            try f.setPermissions(io, .fromMode(0o755));
            try io_mod.stdoutWriteAll("wrote ");
            try io_mod.stdoutWriteAll(script_path);
            try io_mod.stdoutWriteAll("\nadd this line to ~/.codex/config.toml yourself (we do not edit another tool's config):\n\n  notify = [\"");
            try io_mod.stdoutWriteAll(script_path);
            try io_mod.stdoutWriteAll("\"]\n");
        },
        .uninstall => {
            const io = io_mod.get();
            std.Io.Dir.cwd().deleteFile(io, script_path) catch |err| switch (err) {
                error.FileNotFound => {
                    try io_mod.stdoutWriteAll("nothing installed\n");
                    return;
                },
                else => return err,
            };
            try io_mod.stdoutWriteAll("removed adapter script — also remove the notify line from ~/.codex/config.toml\n");
        },
    }
}

/// `synapty hook-event <tool>` (WI-2026-08-11-009): read the harness
/// hook's stdin JSON and dispatch. HOOK DISCIPLINE: never write stdout
/// (SessionStart/UserPromptSubmit stdout is injected into the model's
/// context) and never exit nonzero (exit 2 would block the harness) —
/// every failure path is a silent no-op.
pub fn runHookEvent(allocator: Allocator, args: types.HookEventArgs) !void {
    var buf: [64 * 1024]u8 = undefined;
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = sys.read(0, buf[filled..]) catch break;
        if (n == 0) break;
        filled += n;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const plan: hooks_mod.HookPlan = if (mem.eql(u8, args.tool, "claude"))
        hooks_mod.planClaudeHookEvent(arena.allocator(), buf[0..filled])
    else if (mem.eql(u8, args.tool, "codex"))
        hooks_mod.planCodexHookEvent(arena.allocator(), buf[0..filled])
    else
        .none;
    switch (plan) {
        .none => {},
        .register => |r| hookIpc(allocator, .{
            .action = .register,
            .tool = args.tool,
            .project = if (r.project.len > 0) r.project else null,
            .resume_ref = if (r.resume_ref.len > 0) r.resume_ref else null,
        }),
        .notify => |n| hookIpc(allocator, .{ .action = .notify, .state = n.state, .class = n.class }),
        // codex: one payload carries identity AND the done edge —
        // register first so the status lands on the fresh binding.
        .register_notify => |rn| {
            hookIpc(allocator, .{
                .action = .register,
                .tool = args.tool,
                .project = if (rn.project.len > 0) rn.project else null,
                .resume_ref = if (rn.resume_ref.len > 0) rn.resume_ref else null,
            });
            hookIpc(allocator, .{ .action = .notify, .state = rn.state });
        },
    }
}

/// IPC for hook context: response discarded, all errors swallowed.
fn hookIpc(allocator: Allocator, request: protocol.IpcRequest) void {
    const sock_env = sys.getenv("SYNAPTY_SOCK") orelse return;
    var client = ipc.IpcClient.connect(sock_env) catch return;
    defer client.deinit();
    const req = protocol.serializeIpcRequest(allocator, request) catch return;
    defer allocator.free(req);
    client.send(req) catch return;
    var buf: [64 * 1024]u8 = undefined;
    _ = client.recv(&buf) catch return;
}

test "RFC-0009: send digs the delivery status out of the nested IPC reply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The daemon nests the hub's whole envelope as a STRING under `data`,
    // so a naive one-level parse finds nothing and every outcome reads as
    // success — which is exactly how a partition would be reported as a
    // delivered message.
    const nested =
        \\{"success":false,"data":"{\"type\":\"response\",\"payload\":{\"ok\":false,\"data\":{\"status\":\"conflicted\"}}}"}
    ;
    try std.testing.expectEqualStrings("conflicted", deliveryStatusOf(a, nested).?);

    const ok =
        \\{"success":true,"data":"{\"type\":\"response\",\"payload\":{\"ok\":true,\"data\":{\"status\":\"spooled\"}}}"}
    ;
    try std.testing.expectEqualStrings("spooled", deliveryStatusOf(a, ok).?);

    // A REMOTE hub older than this client sends no status, and the
    // caller falls through rather than treating absence as failure.
    // This is binary-to-binary version skew, which is real and stays
    // ([[RFC-0014]] C-VERSION's reasoning) — unlike the `queued` boolean
    // this hub used to send ITSELF, which was compatibility with nothing.
    const legacy =
        \\{"success":true,"data":"{\"type\":\"response\",\"payload\":{\"ok\":true,\"data\":{\"queued\":true}}}"}
    ;
    try std.testing.expect(deliveryStatusOf(a, legacy) == null);
    try std.testing.expect(deliveryStatusOf(a, "not json") == null);
}


test "RFC-0009: a send the hub did not accept is a failure, whatever it is called" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // THE CLIENT MUST NOT HOLD ITS OWN LIST OF FAILURE NAMES. It held
    // two of them by name, and the vocabulary has more than two,
    // so a contested identity and a peer's refusal both printed JSON on
    // stdout and exited 0: a message nobody has, reported as sent.
    const contested =
        \\{"success":false,"data":"{\"type\":\"response\",\"payload\":{\"ok\":false,\"data\":{\"status\":\"conflicted\",\"reason\":\"contested: two peer hubs claim this identity\"}}}"}
    ;
    try std.testing.expectEqualStrings(
        "contested: two peer hubs claim this identity",
        deliveryFailureOf(a, contested).?,
    );

    // A hub that refuses without saying why is still a refusal.
    const mute =
        \\{"success":false,"data":"{\"type\":\"response\",\"payload\":{\"ok\":false,\"data\":{\"status\":\"refused\"}}}"}
    ;
    try std.testing.expect(deliveryFailureOf(a, mute) != null);

    // And the successes stay successes — `spooled` above all, which is a
    // message the hub is holding and will forward.
    const spooled =
        \\{"success":true,"data":"{\"type\":\"response\",\"payload\":{\"ok\":true,\"data\":{\"status\":\"spooled\"}}}"}
    ;
    try std.testing.expect(deliveryFailureOf(a, spooled) == null);
    try std.testing.expect(deliveryFailureOf(a, "not json") == null);
}

/// `synapty tools exec` — run a credential-bound task tool HERE, with the
/// local credential, and print the result as JSON. This is the workbench
/// half of [[ADR-0008]] decision 6: the hub forwards a tool_request and
/// something on this machine has to actually make the GitHub call.
///
/// Always exits 0 with a JSON body, including on tool failure. The caller
/// is the workbench relaying an answer back to an agent through the hub,
/// and it needs the structured `{ok:false, error:...}` to relay — an exit
/// code and a bare stderr line would lose the reason.
pub fn runToolsExec(allocator: Allocator, args: types.ToolsExecArgs) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed_args: json.ObjectMap = blk: {
        const v = json.parseFromSliceLeaky(json.Value, a, args.args_json, .{}) catch
            break :blk json.ObjectMap.empty;
        break :blk if (v == .object) v.object else json.ObjectMap.empty;
    };

    const result = tools.exec(a, args.tool, parsed_args);
    const value = try tools.resultToJson(a, result);
    const text = try json.Stringify.valueAlloc(a, value, .{});
    try io_mod.stdoutWriteAll(text);
    try io_mod.stdoutWriteAll("\n");
}

test "a refused tool call is not a successful one (WI-2026-08-15-011)" {
    const alloc = std.testing.allocator;

    // The shape a real hub sends back, observed rather than assumed.
    const refused =
        \\{"type":"tool_response","id":"task-0","source":"hub","target":"a",
        \\"payload":{"ok":false,"error":"no host called prod-9"}}
    ;
    try std.testing.expectEqual(ToolOutcome.refused, classifyToolReply(alloc, refused));

    const done =
        \\{"type":"tool_response","id":"task-0","source":"hub","target":"a",
        \\"payload":{"ok":true,"data":"{\"transfer_id\":\"x\",\"state\":\"queued\"}"}}
    ;
    try std.testing.expectEqual(ToolOutcome.ok, classifyToolReply(alloc, done));
}

test "waiting on a human is retryable and a refusal is not (WI-2026-08-15-011)" {
    const alloc = std.testing.allocator;

    // A route the human has been asked about. Retrying once they answer is
    // exactly right, so it must not look like "no such host".
    const waiting =
        \\{"type":"tool_response","id":"task-0","source":"hub","target":"a",
        \\"payload":{"ok":false,"data":"{\"state\":\"awaiting_approval\"}",
        \\"error":"waiting for approval to send from A to B — a human has been asked"}}
    ;
    try std.testing.expectEqual(ToolOutcome.awaiting_human, classifyToolReply(alloc, waiting));

    // THE MARKER DECIDES, NOT THE MESSAGE. The same words without it are
    // an ordinary refusal — otherwise rewording a sentence would silently
    // change what every caller does next.
    const lookalike =
        \\{"type":"tool_response","id":"task-0","source":"hub","target":"a",
        \\"payload":{"ok":false,"error":"waiting for approval to send from A to B"}}
    ;
    try std.testing.expectEqual(ToolOutcome.refused, classifyToolReply(alloc, lookalike));
}

test "garbage from the hub is a refusal, never a success (WI-2026-08-15-011)" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        "not json at all",
        "{}",
        "{\"payload\":\"a string\"}",
        "{\"payload\":{}}",
        "{\"payload\":{\"ok\":\"true\"}}", // a string, not a bool
    }) |bad| {
        try std.testing.expectEqual(ToolOutcome.refused, classifyToolReply(alloc, bad));
    }
}


// ---------------------------------------------------------------------------
// attach ([[RFC-0014]], [[WI-2026-08-17-003]])
// ---------------------------------------------------------------------------

const AttachState = struct {
    fd: sys.fd_t,
    running: bool = true,
    /// The byte that means "leave without ending this" ([[Detach]]).
    detach_key: u8 = Detach.default_key,
    /// Set when the session ended on its own terms, so the client can
    /// say which of the three things happened rather than just stopping.
    ended: enum { detached, displaced, child_exited } = .detached,
    exit_kind: u8 = 0,
    exit_value: u8 = 0,
    /// The label of the client that took the seat, from the displaced
    /// frame ([[RFC-0014]] C-CLIENT-LABEL); empty if it gave none.
    displaced_by: [holder.label_max]u8 = undefined,
    displaced_by_len: u8 = 0,
};

/// `kind@host:pid` — what this process tells a holder it is
/// ([[RFC-0014]] C-CLIENT-LABEL). The kind is the caller's word (the
/// workbench says `gui`, a shell says `cli`); the machine and pid are
/// this process's own.
pub fn clientLabel(buf: *[holder.label_max]u8, kind: []const u8) []const u8 {
    var host_buf: [256]u8 = undefined;
    const host = sys.hostName(&host_buf) orelse "?";
    return std.fmt.bufPrint(buf, "{s}@{s}:{d}", .{ kind, host, std.c.getpid() }) catch buf[0..0];
}

/// `synapty name --id X --name "…"` ([[RFC-0014]] C-SESSION-NAME).
pub fn runName(args: types.NameArgs) !void {
    var path_buf: [1024]u8 = undefined;
    const path = try holder.socketPath(&path_buf, args.agent_id);
    if (!holder.requestName(path, args.name)) {
        try io_mod.stderrWriteAll("synapty name: no session named ");
        try io_mod.stderrWriteAll(args.agent_id);
        try io_mod.stderrWriteAll(", or its holder keeps no names\n");
        std.process.exit(2);
    }
}

/// SKEW IS VISIBLE, NEVER SILENT, and it names both versions
/// ([[RFC-0014]] C-VERSION). `sessions` and `end` are deliberately NOT
/// refused on this ground — the clause requires enumerating and ending a
/// holder to survive a mismatch, which is what keeps a running session
/// from becoming unreachable AND unclearable.
fn reportVersionMismatch(theirs: u8) !void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf,
        "error: this session speaks holder protocol {d}, and this build speaks {d}.\n" ++
        "       The binary on one side was replaced and the other has not been.\n" ++
        "       'synapty sessions' and 'synapty end' still work across this.\n",
        .{ theirs, holder.protocol_version }) catch return;
    try io_mod.stderrWriteAll(line);
    std.process.exit(1);
}

/// How one attach ended ([[WI-2026-09-02-013]]): the chooser loops on
/// every value but `gone` says so and lists again; a `--id` attach exits
/// on all of them, as it always did.
pub const AttachOutcome = enum { detached, displaced, child_exited, gone };

pub fn runAttach(allocator: Allocator, args: types.AttachArgs) !void {
    if (args.relay) return runRelay(args.agent_id);
    if (args.through.len > 0) return runAttachThrough(allocator, args);
    if (try attachHere(allocator, args) == .gone) std.process.exit(2);
}

/// ONE ATTACH, START TO END, on this machine's own socket. Prints what
/// the human needs to read on the way; returns how it ended so a caller
/// can decide what comes next.
/// Join a session that already exists.
///
/// This process is a pipe with a terminal on each end. Everything it does
/// is in service of not being noticed: the local tty goes raw so that no
/// key is interpreted twice, and the size is followed so the far side is
/// always the shape of the window the human is looking at.
fn attachHere(allocator: Allocator, args: types.AttachArgs) !AttachOutcome {
    // THE SOCKET IS NAMED RELATIVELY, from inside the sessions directory
    // ([[holder.openSocket]]): the kernel bounds what it is handed at 104
    // bytes and a configuration root can be deeper than that, which is
    // how every terminal pane in this application's own UI harness came
    // to die with a Zig stack trace printed into it.
    var path_buf: [1024]u8 = undefined;
    const path = try holder.socketPath(&path_buf, args.agent_id);
    const fd = holder.socketCall(path, .connect) catch {
        // NOT CREATED HERE ([[RFC-0014]] C-START and C-HOLDER): a client
        // asking to return to a session that is gone is told it is gone,
        // never handed a fresh shell wearing its name.
        try io_mod.stderrWriteAll("synapty attach: no session named ");
        try io_mod.stderrWriteAll(args.agent_id);
        try io_mod.stderrWriteAll("\n");
        return .gone;
    };

    const stdin_fd: sys.fd_t = 0;
    const stdout_fd: sys.fd_t = 1;
    const is_tty = sys.isatty(stdin_fd);
    // A SIZE THE HOLDER CAN PAINT INTO, and never a degenerate one.
    //
    // [[RFC-0014]] C-RESTORE: an attach that sets dimensions has them
    // applied BEFORE the restoration is produced, "so the description a
    // client receives is in the geometry it asked for". A terminal that
    // has not been laid out yet answers 0x0, and a restoration produced
    // in that geometry describes nothing — the client asked for a screen
    // with no rows and was correctly given one. A pane reattaching to a
    // live session came back blank because of it.
    //
    // WAITED FOR, BRIEFLY. The surface is sized within a frame or two of
    // being created, and the alternative — sending 24x80 and letting the
    // size loop correct it — repaints nothing: the restoration has
    // already been produced and is not sent twice.
    var ws = sys.winsize{ .ws_row = 24, .ws_col = 80 };
    if (is_tty) {
        var waited: usize = 0;
        while (waited < 100) : (waited += 1) {
            const now = sys.winsizeOf(stdin_fd) catch break;
            if (now.ws_row > 0 and now.ws_col > 0) {
                ws = now;
                break;
            }
            io_mod.get().sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch break;
        }
    }

    // WHO IS ATTACHING ([[RFC-0014]] C-CLIENT-LABEL): kind, machine, pid,
    // after a zero position — the holder reads zero as "nothing to
    // resume", and what follows as the label.
    var label_buf: [holder.label_max]u8 = undefined;
    const label = clientLabel(&label_buf, args.client);
    var hello: [22 + holder.label_max]u8 = [_]u8{0} ** (22 + holder.label_max);
    hello[0] = holder.protocol_version;
    std.mem.writeInt(u16, hello[1..3], ws.ws_row, .little);
    std.mem.writeInt(u16, hello[3..5], ws.ws_col, .little);
    hello[21] = @intCast(label.len);
    @memcpy(hello[22 .. 22 + label.len], label);
    try holder.writeFrame(fd, .hello, hello[0 .. 22 + label.len]);
    var wbuf: [64]u8 = undefined;
    var theirs: u8 = 0;
    _ = holder.readWelcome(fd, &wbuf, &theirs) catch |err| {
        if (err == error.VersionMismatch) {
            try reportVersionMismatch(theirs);
            return .gone;
        }
        return err;
    };

    var saved: ?sys.Termios = null;
    if (is_tty) saved = sys.makeRaw(stdin_fd) catch null;
    defer if (saved) |t| sys.setTermios(stdin_fd, &t) catch {};

    var state = AttachState{ .fd = fd, .detach_key = detachKey() };

    // SAID ON THE WAY IN, because a key nobody knows about is not a way
    // out. This is also the whole of what tells a human they are in a
    // synapty session at all: an attached shell is otherwise
    // indistinguishable from the one they would have got by typing
    // `zsh`, and the session's name — the thing `end` and `sessions`
    // take — appears nowhere.
    //
    // ONE LINE, ON THE WAY IN ONLY. What follows belongs to the child,
    // and a client that kept talking over it would be the second
    // terminal interpreting the session that [[sys.Termios]]'s note is
    // about.
    if (is_tty) {
        var kbuf: [2]u8 = undefined;
        const shown = Detach.display(state.detach_key, &kbuf);
        var line: [320]u8 = undefined;
        // THE NAME THE HUMAN GAVE, when there is one ([[RFC-0014]]
        // C-SESSION-NAME), so the banner calls the session what the
        // workbench calls it.
        var scratch: holder.StatusBuffers = .{};
        const known = holder.queryStatusInto(path, &scratch);
        const shown_name: []const u8 = if (known) |k| k.session_name else "";
        const text = if (shown_name.len > 0)
            std.fmt.bufPrint(
                &line,
                "synapty · {s} ({s}) — {s} detaches, and what is running keeps running\r\n",
                .{ shown_name, args.agent_id, shown },
            ) catch ""
        else
            std.fmt.bufPrint(
                &line,
                "synapty · {s} — {s} detaches, and what is running keeps running\r\n",
                .{ args.agent_id, shown },
            ) catch "";
        sys.writeAll(stdout_fd, text) catch {};
    }

    const in_thread = try std.Thread.spawn(.{}, attachInputLoop, .{ &state, stdin_fd });
    const size_thread = try std.Thread.spawn(.{}, attachSizeLoop, .{ &state, stdin_fd, ws });

    // Output, on this thread: it is the one that must not be starved.
    var buf: [16384]u8 = undefined;
    while (state.running) {
        const frame = (holder.readFrameAlloc(allocator, fd, &buf) catch break) orelse break;
        defer frame.deinit(allocator);
        switch (frame.kind) {
            .data => sys.writeAll(stdout_fd, frame.payload) catch break,
            .restore => {
                // WHAT THE SCREEN WAS, handed to a client that had
                // nothing ([[RFC-0014]] C-RESTORE). Written to the
                // terminal exactly as the child would have written it —
                // the paint reproduces the screen, so the local emulator
                // does the rendering it was going to do anyway.
                //
                // ONTO A CLEARED SCREEN. The paint covers every row, so
                // this is not what makes it land correctly; it is what
                // makes the pane's scrollback stop where the restoration
                // starts, instead of the human scrolling up into the
                // connection that died.
                //
                // THE CURSOR IS THE PAINT'S, not this client's to place:
                // it has to land after the addressing modes the paint
                // restores, and only the paint knows what those were.
                if (frame.payload.len > 10) {
                    sys.writeAll(stdout_fd, "\x1b[H\x1b[2J") catch break;
                    sys.writeAll(stdout_fd, frame.payload[10..]) catch break;
                }
            },
            .gap => {
                // SAID, NOT SILENT: the human's scrollback has a hole and
                // the only honest thing is to mark where.
                screenNotice("output was lost while this client was away") catch {};
            },
            .exit => {
                state.ended = .child_exited;
                if (frame.payload.len >= 2) {
                    state.exit_kind = frame.payload[0];
                    state.exit_value = frame.payload[1];
                }
                break;
            },
            .displaced => {
                state.ended = .displaced;
                const kept: usize = @min(frame.payload.len, state.displaced_by.len);
                @memcpy(state.displaced_by[0..kept], frame.payload[0..kept]);
                state.displaced_by_len = @intCast(kept);
                break;
            },
            else => {},
        }
    }
    state.running = false;
    sys.shutdown(fd, sys.SHUT.RDWR);
    in_thread.join();
    size_thread.join();
    sys.close(fd);

    if (saved) |t| {
        sys.setTermios(stdin_fd, &t) catch {};
        saved = null;
    }
    switch (state.ended) {
        .displaced => {
            // BY WHOM, when the newcomer said ([[RFC-0014]] C-ONE-CLIENT).
            if (state.displaced_by_len > 0) {
                var msg: [160]u8 = undefined;
                const text = std.fmt.bufPrint(&msg, "this session was taken by {s}", .{state.displaced_by[0..state.displaced_by_len]}) catch
                    "this session was taken by another client";
                try screenNotice(text);
            } else {
                try screenNotice("this session was taken by another client");
            }
        },
        .child_exited => {
            var msg: [64]u8 = undefined;
            const text = if (state.exit_kind == 1)
                std.fmt.bufPrint(&msg, "session ended (signal {d})", .{state.exit_value}) catch "session ended"
            else
                std.fmt.bufPrint(&msg, "session ended (exit {d})", .{state.exit_value}) catch "session ended";
            try screenNotice(text);
        },
        // A LOST CONNECTION SAYS NOTHING ABOUT THE SESSION ([[RFC-0014]]
        // C-EXIT-SIGNAL). The child is presumed alive and waiting.
        .detached => try screenNotice("detached"),
    }
    return switch (state.ended) {
        .detached => .detached,
        .displaced => .displaced,
        .child_exited => .child_exited,
    };
}

/// The far side of a transport: frames in, frames out, nothing else.
///
/// IT HOLDS NO STATE AND TOUCHES NO TERMINAL. Everything that has to
/// remember something — the position, the size, what has been rendered —
/// belongs to the client, and the client is on the other end of this
/// pipe ([[WI-2026-08-17-009]]). A relay that decided anything would be
/// a second client with a worse view.
fn runRelay(agent_id: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const path = try holder.socketPath(&path_buf, agent_id);
    const fd = try sys.socket(sys.AF.UNIX, sys.SOCK.STREAM, 0);
    defer sys.close(fd);
    const addr = sys.sockaddr_un.init(path) orelse return error.NameTooLong;
    sys.connect(fd, &addr, addr.len()) catch {
        try io_mod.stderrWriteAll("synapty attach --relay: no session named ");
        try io_mod.stderrWriteAll(agent_id);
        try io_mod.stderrWriteAll("\n");
        std.process.exit(2);
    };

    var state = RelayState{ .sock = fd };
    const up = try std.Thread.spawn(.{}, relayToSocket, .{&state});
    // Socket to stdout on this thread: it carries the session, and the
    // one that carries the session is the one that must not wait.
    var buf: [16384]u8 = undefined;
    while (state.running) {
        const n = sys.read(fd, &buf) catch break;
        if (n == 0) break;
        sys.writeAll(1, buf[0..n]) catch break;
    }
    state.running = false;
    sys.shutdown(fd, sys.SHUT.RDWR);
    up.join();
}

const RelayState = struct {
    sock: sys.fd_t,
    running: bool = true,
};

fn relayToSocket(state: *RelayState) void {
    var buf: [16384]u8 = undefined;
    while (state.running) {
        // Polled, so the relay exits when the SESSION ends and not when the
        // human next types: a bare read here parked until a keystroke
        // arrived on a stdin ssh kept open ([[WI-2026-09-02-020]]).
        const ready = sys.waitReadable(0, input_poll_ms) catch break;
        if (!ready) continue;
        const n = sys.read(0, &buf) catch break;
        if (n == 0) break;
        sys.writeAll(state.sock, buf[0..n]) catch break;
    }
    state.running = false;
    sys.shutdown(state.sock, sys.SHUT.RDWR);
}

fn attachInputLoop(state: *AttachState, stdin_fd: sys.fd_t) void {
    var buf: [4096]u8 = undefined;
    var out: [4096]u8 = undefined;
    var detach = Detach{ .key = state.detach_key };
    while (state.running) {
        const ready = sys.waitReadable(stdin_fd, input_poll_ms) catch break;
        if (!ready) continue;
        const n = sys.read(stdin_fd, &buf) catch break;
        if (n == 0) break;
        // EVERY BYTE PASSES THROUGH HERE AND ALMOST ALL OF THEM PASS
        // STRAIGHT ON. One does not: the key that means "leave without
        // ending this", which [[RFC-0014]] C-DETACH requires a client to
        // offer and which this had no way to express — the only exits
        // were the child dying, which is ending, and killing this process
        // from somewhere else.
        const step = detach.step(buf[0..n], &out);
        if (step.forward.len > 0) {
            holder.writeFrame(state.fd, .input, step.forward) catch break;
        }
        if (step.detach) {
            state.ended = .detached;
            state.running = false;
            return;
        }
    }
}

/// POLLED, NOT SIGNALLED. A SIGWINCH handler would have to hand the size
/// to a thread anyway, and a handler that can only set a flag is a poll
/// with extra machinery. Resizes are rare and a quarter of a second late
/// is invisible; a signal handler that got this wrong would not be.
fn attachSizeLoop(state: *AttachState, stdin_fd: sys.fd_t, initial: sys.winsize) void {
    var last = initial;
    while (state.running) {
        io_mod.get().sleep(std.Io.Duration.fromMilliseconds(250), .awake) catch return;
        const now = sys.winsizeOf(stdin_fd) catch continue;
        if (now.ws_row == last.ws_row and now.ws_col == last.ws_col) continue;
        last = now;
        var p: [4]u8 = undefined;
        std.mem.writeInt(u16, p[0..2], now.ws_row, .little);
        std.mem.writeInt(u16, p[2..4], now.ws_col, .little);
        holder.writeFrame(state.fd, .resize, &p) catch return;
    }
}


/// Wait for a session to start answering. The caller of a detaching
/// start returns only once this is true: reporting success for a holder
/// that then fails to bind would send the next line of a script at a
/// socket that will never exist.
pub fn waitUntilHeld(agent_id: []const u8, ms: u64) bool {
    var waited: u64 = 0;
    while (waited < ms) : (waited += 50) {
        // THE CLAIM, WHICH IS ALSO THE BETTER READINESS SIGNAL. A connect
        // succeeds the moment `listen` runs, which is before the child is
        // on the terminal — so a start reported success and the next line
        // of a script attached to a session with nothing in it. The claim
        // is taken once the child IS on the terminal.
        if (holder.claimState(agent_id) == .held) return true;
        io_mod.get().sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch break;
    }
    return false;
}

/// Is this name already a session? A START MUST NOT JOIN ([[RFC-0014]]
/// C-START), and the question is asked before anything else happens: a
/// socket file left by a dead holder is not a session, and one that
/// answers is.
pub fn holdRefused(agent_id: []const u8) bool {
    // ASKED OF THE CLAIM, NOT THE SOCKET ([[holder.claimState]]). Built on
    // `connect`, this read a LIVE holder whose backlog was full as absent,
    // and the start it then let through unlinks that session's socket
    // before binding its own — so a busy session became unattachable by
    // any client. `absent` and `free` both mean nothing is holding the
    // name, and only `held` is a session a start would be joining.
    return holder.startWouldJoin(agent_id);
}

/// `synapty run --hold` — start a session and hold it.
///
/// The child is put on a pseudoterminal this process owns, and the hub
/// and pane-IPC threads run beside it exactly as they do for an inherited
/// child: holding a terminal changes where the bytes go, not what the
/// wrapper is.
///
/// THIS BLOCKS. Leaving the caller behind is `--detach`'s job and is done
/// in cli.zig before this runs, because the descriptors the server's init
/// opens must not be inherited across the fork.
pub fn runHold(allocator: Allocator, server: *run.RunServer, args: types.RunArgs) !void {
    var path_buf: [256]u8 = undefined;
    const path = try holder.socketPath(&path_buf, args.agent_id);

    var argv_store = try std.ArrayList([:0]u8).initCapacity(allocator, args.child_argv.len);
    defer {
        for (argv_store.items) |a| allocator.free(a);
        argv_store.deinit(allocator);
    }
    var argv = try std.ArrayList([*:0]const u8).initCapacity(allocator, args.child_argv.len);
    defer argv.deinit(allocator);
    for (args.child_argv) |a| {
        const z = try allocator.dupeZ(u8, a);
        try argv_store.append(allocator, z);
        try argv.append(allocator, z.ptr);
    }

    // The pane's own variables, as an inherited child would have been
    // given them.
    var env_store: [2][:0]u8 = undefined;
    env_store[0] = try std.fmt.allocPrintSentinel(allocator, "SYNAPTY_AGENT_ID={s}", .{args.agent_id}, 0);
    defer allocator.free(env_store[0]);
    env_store[1] = try std.fmt.allocPrintSentinel(allocator, "SYNAPTY_SOCK={s}", .{server.socket_path}, 0);
    defer allocator.free(env_store[1]);
    const env = [_][*:0]const u8{ env_store[0].ptr, env_store[1].ptr };

    var h = try holder.Holder.init(allocator, path);
    try h.start(argv.items, &env, .{ .ws_row = 24, .ws_col = 80 });
    defer h.stop();

    const threads = try server.startThreads();
    defer server.stopThreads(threads);

    // Until the child goes, or a human ends the session. Clients
    // attaching and leaving are not events this loop has an opinion about
    // ([[RFC-0014]] C-DETACH).
    while (!h.childState().exited and !h.isEnding()) {
        io_mod.get().sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch break;
    }
    if (h.isEnding()) h.endChild();
}


/// One session's line, for a caller that knows which one it means. This
/// is the shape the workbench asks in: it has a name and wants a
/// destination, not a listing to search.
pub fn runSessionOne(agent_id: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const path = try holder.socketPath(&path_buf, agent_id);
    var scratch: holder.StatusBuffers = .{};
    const status = holder.queryStatusInto(path, &scratch) orelse {
        try io_mod.stderrWriteAll("synapty sessions: no session named ");
        try io_mod.stderrWriteAll(agent_id);
        try io_mod.stderrWriteAll("\n");
        std.process.exit(2);
    };
    // A SIXTH COLUMN, APPENDED ([[WI-2026-08-18-004]]): the SHELL's own
    // directory, beside the foreground group's. They differ whenever the
    // session is running anything that has `cd`d, and a reader that opens
    // a pane wants this one — appended rather than inserted so nothing
    // counting from the left has to move.
    var line: [2900]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{
        agent_id,
        if (status.attached) "attached" else "detached",
        if (status.child_exited) "child-exited" else "running",
        if (status.cwd.len > 0) status.cwd else "-",
        if (status.command.len > 0) status.command else "-",
        if (status.shell_cwd.len > 0) status.shell_cwd else "-",
        if (status.client_label.len > 0) status.client_label else "-",
        if (status.session_name.len > 0) status.session_name else "-",
    }) catch return;
    io_mod.stdoutWriteAll(text) catch return;
}

/// One session as this machine knows it — what `sessions` prints and the
/// chooser lists, gathered once ([[WI-2026-09-02-013]]). Owned buffers,
/// because the status reply's slices point into a scratch that does not
/// outlive the query.
pub const SessionRow = struct {
    name_buf: [128]u8 = undefined,
    name_len: u8 = 0,
    reachable: bool = false,
    attached: bool = false,
    ever_attached: bool = false,
    child_exited: bool = false,
    unattached_s: u64 = 0,
    pid: i32 = 0,
    socket_missing: bool = false,
    cwd_buf: [1024]u8 = undefined,
    cwd_len: u16 = 0,
    command_buf: [256]u8 = undefined,
    command_len: u16 = 0,
    shell_cwd_buf: [1024]u8 = undefined,
    shell_cwd_len: u16 = 0,
    label_buf: [holder.label_max]u8 = undefined,
    label_len: u8 = 0,
    human_buf: [holder.label_max]u8 = undefined,
    human_len: u8 = 0,

    pub fn name(self: *const SessionRow) []const u8 { return self.name_buf[0..self.name_len]; }
    pub fn cwd(self: *const SessionRow) []const u8 { return self.cwd_buf[0..self.cwd_len]; }
    pub fn command(self: *const SessionRow) []const u8 { return self.command_buf[0..self.command_len]; }
    pub fn shellCwd(self: *const SessionRow) []const u8 { return self.shell_cwd_buf[0..self.shell_cwd_len]; }
    pub fn label(self: *const SessionRow) []const u8 { return self.label_buf[0..self.label_len]; }
    pub fn humanName(self: *const SessionRow) []const u8 { return self.human_buf[0..self.human_len]; }

    fn put(dst: []u8, src: []const u8) u16 {
        const n: usize = @min(dst.len, src.len);
        @memcpy(dst[0..n], src[0..n]);
        return @intCast(n);
    }
};

/// Every session this machine holds a record for, ended ones swept.
/// `out` is filled in directory order; the count is returned.
pub fn collectSessions(allocator: Allocator, out: []SessionRow) usize {
    var dir_buf: [1024]u8 = undefined;
    const records = paths.sessionsDir(&dir_buf) orelse return 0;
    var dir = std.Io.Dir.cwd().openDir(io_mod.get(), records, .{ .iterate = true }) catch return 0;
    defer dir.close(io_mod.get());

    var found: usize = 0;
    var it = dir.iterate();
    while (it.next(io_mod.get()) catch null) |entry| {
        if (found >= out.len) break;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const name = entry.name[0 .. entry.name.len - 5];
        if (holder.sweepEnded(allocator, name)) continue;
        const record = holder.Record.read(allocator, name) orelse continue;

        var row: SessionRow = .{};
        row.name_len = @intCast(SessionRow.put(&row.name_buf, name));
        row.pid = record.pid;
        row.human_len = @intCast(SessionRow.put(&row.human_buf, record.sessionName()));

        var path_buf: [256]u8 = undefined;
        const path = holder.socketPath(&path_buf, name) catch {
            row.socket_missing = true;
            out[found] = row;
            found += 1;
            continue;
        };
        var scratch: holder.StatusBuffers = .{};
        if (holder.queryStatusInto(path, &scratch)) |status| {
            row.reachable = true;
            row.attached = status.attached;
            row.ever_attached = status.ever_attached;
            row.child_exited = status.child_exited;
            row.unattached_s = status.unattached_ms / 1000;
            row.cwd_len = SessionRow.put(&row.cwd_buf, status.cwd);
            row.command_len = SessionRow.put(&row.command_buf, status.command);
            row.shell_cwd_len = SessionRow.put(&row.shell_cwd_buf, status.shell_cwd);
            row.label_len = @intCast(SessionRow.put(&row.label_buf, status.client_label));
            // The holder's name wins over the record's: it is the live one.
            if (status.session_name.len > 0)
                row.human_len = @intCast(SessionRow.put(&row.human_buf, status.session_name));
        }
        out[found] = row;
        found += 1;
    }
    return found;
}

fn dash(s: []const u8) []const u8 {
    return if (s.len > 0) s else "-";
}

/// `synapty sessions` — what is running on this host, for this account.
///
/// THE RECORDS ARE THE LIST, and the kernel and the socket answer about
/// each in turn ([[holder.Record]]). Enumerating sockets instead made the
/// list and the naming one thing, so a session whose socket was swept out
/// of `/tmp` disappeared from the only surface that could have found it,
/// while its holder and child ran on.
pub fn runSessions(allocator: Allocator) !void {
    var dir_buf: [1024]u8 = undefined;
    if (paths.sessionsDir(&dir_buf) == null) {
        try io_mod.stderrWriteAll("synapty sessions: cannot locate this machine's state\n");
        std.process.exit(1);
    }
    const rows = try allocator.alloc(SessionRow, max_listed_sessions);
    defer allocator.free(rows);
    const found = collectSessions(allocator, rows);
    if (found == 0) {
        io_mod.stdoutWriteAll("no sessions\n") catch return;
        return;
    }
    for (rows[0..found]) |*row| {
        var line: [3000]u8 = undefined;
        const text = if (row.socket_missing)
            std.fmt.bufPrint(&line, "{s}\tunreachable\t-\t-\t-\tno path for its socket\t-\t-\t-\t{s}\n", .{ row.name(), dash(row.humanName()) }) catch continue
        else if (!row.reachable)
            // Unreachable, but the record still knows what it was called.
            std.fmt.bufPrint(&line, "{s}\tunreachable\t-\t-\t-\tpid {d}\t-\t-\t-\t{s}\n", .{ row.name(), row.pid, dash(row.humanName()) }) catch continue
        else
            // TWO TRAILING COLUMNS ([[RFC-0014]] C-CLIENT-LABEL, C-SESSION-NAME):
            // who is attached, and what the human calls the session. At the
            // end, so a reader of the eight that were here reads them still.
            std.fmt.bufPrint(&line, "{s}\t{s}\t{s}\t{s}\t{d}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{
                row.name(),
                if (row.attached) "attached" else "detached",
                if (row.ever_attached) "seen" else "unclaimed",
                if (row.child_exited) "child-exited" else "running",
                row.unattached_s,
                dash(row.cwd()),
                dash(row.command()),
                dash(row.shellCwd()),
                dash(row.label()),
                dash(row.humanName()),
            }) catch continue;
        // A READER THAT STOPPED READING IS NOT AN ERROR. `sessions |
        // grep -q` closes the pipe on its first match, and a listing that
        // treated that as a failure would exit non-zero for the most
        // ordinary use it has.
        io_mod.stdoutWriteAll(text) catch return;
    }
    var line: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "policy\t{s}\n", .{holder.never_reaped}) catch return;
    io_mod.stdoutWriteAll(text) catch return;
}

/// More than this many holders on one machine is not a listing problem.
const max_listed_sessions: usize = 256;

// ---------------------------------------------------------------------------
// The chooser: a bare `synapty attach` ([[WI-2026-09-02-013]])
// ---------------------------------------------------------------------------

/// KEYS TO ACTIONS, and nothing else — the state machine is the whole of
/// the chooser's interaction, in the shape of [[Detach.step]] so it can
/// be pinned without a terminal. Arrows arrive as ESC [ A/B and are
/// carried across reads; a lone ESC is quit, as in every picker.
pub const Chooser = struct {
    pub const Action = enum { none, up, down, select, quit, refresh };

    esc: u8 = 0, // 0 idle, 1 saw ESC, 2 saw ESC [

    pub fn step(self: *Chooser, byte: u8) Action {
        switch (self.esc) {
            1 => {
                if (byte == '[') {
                    self.esc = 2;
                    return .none;
                }
                self.esc = 0;
                return .quit;
            },
            2 => {
                self.esc = 0;
                return switch (byte) {
                    'A' => .up,
                    'B' => .down,
                    else => .none,
                };
            },
            else => {},
        }
        return switch (byte) {
            0x1b => blk: {
                self.esc = 1;
                break :blk .none;
            },
            'k' => .up,
            'j' => .down,
            '\r', '\n' => .select,
            'q', 0x03 => .quit,
            'r' => .refresh,
            else => .none,
        };
    }

    /// A lone ESC with no bracket following is a quit; the caller says so
    /// when its read returned nothing more.
    pub fn flush(self: *Chooser) Action {
        defer self.esc = 0;
        return if (self.esc == 1) .quit else .none;
    }
};

/// What comes after an attach ends: the chooser lists again, whatever
/// happened; a `--id` attach exits. Keyed on how the attach was begun, so
/// the pane the workbench runs (`exec synapty attach --client gui --id X`)
/// still exits and the pane closes ([[WI-2026-09-02-013]]).
pub fn afterAttach(outcome: AttachOutcome, interactive: bool) enum { list, exit } {
    _ = outcome;
    return if (interactive) .list else .exit;
}

/// One row of the list: name (or id), state, what is running, where.
pub fn formatRow(row: *const SessionRow, selected: bool, buf: []u8) []const u8 {
    const state: []const u8 = if (row.socket_missing or !row.reachable) "unreachable" else if (row.child_exited) "ended" else if (row.attached) "attached" else "detached";
    const shown: []const u8 = if (row.humanName().len > 0) row.humanName() else row.name();
    const id_part: []const u8 = if (row.humanName().len > 0) row.name() else "";
    return std.fmt.bufPrint(buf, "{s} {s}{s}{s}{s}  {s}{s}{s}{s}{s}\r\n", .{
        if (selected) ">" else " ",
        shown,
        if (id_part.len > 0) " (" else "",
        id_part,
        if (id_part.len > 0) ")" else "",
        state,
        if (row.attached and row.label().len > 0) " by " else "",
        if (row.attached) row.label() else "",
        if (row.command().len > 0) " · " else "",
        row.command(),
    }) catch buf[0..0];
}

/// A bare `synapty attach`: list, pick, attach, and on the way out list
/// again ([[WI-2026-09-02-013]]). Not a multiplexer — one session at a
/// time, one client, no layout; the screen is cleared on return because
/// the previous session's last frame is no longer live and leaving it
/// visible reads as still being in the session.
pub fn runAttachChooser(allocator: Allocator) !void {
    const stdin_fd: sys.fd_t = 0;
    const stdout_fd: sys.fd_t = 1;
    if (!sys.isatty(stdin_fd)) {
        try io_mod.stderrWriteAll("synapty attach: no --id given and stdin is not a terminal\n");
        std.process.exit(2);
    }
    const rows = try allocator.alloc(SessionRow, max_listed_sessions);
    defer allocator.free(rows);

    var selected: usize = 0;
    outer: while (true) {
        const found = collectSessions(allocator, rows);
        if (found == 0) {
            try io_mod.stderrWriteAll("synapty attach: no sessions on this machine\n");
            return;
        }
        if (selected >= found) selected = found - 1;

        const saved = sys.makeRaw(stdin_fd) catch null;
        var chooser = Chooser{};
        var pick: ?usize = null;
        draw(stdout_fd, rows[0..found], selected);
        while (pick == null) {
            var buf: [64]u8 = undefined;
            const n = sys.read(stdin_fd, &buf) catch break :outer;
            if (n == 0) break :outer;
            var redraw = false;
            for (buf[0..n]) |byte| {
                switch (chooser.step(byte)) {
                    .none => {},
                    .up => {
                        if (selected > 0) selected -= 1;
                        redraw = true;
                    },
                    .down => {
                        if (selected + 1 < found) selected += 1;
                        redraw = true;
                    },
                    .select => pick = selected,
                    .refresh => {
                        if (saved) |t| sys.setTermios(stdin_fd, &t) catch {};
                        continue :outer;
                    },
                    .quit => {
                        if (saved) |t| sys.setTermios(stdin_fd, &t) catch {};
                        sys.writeAll(stdout_fd, "\x1b[H\x1b[2J") catch {};
                        return;
                    },
                }
            }
            if (chooser.flush() == .quit) {
                if (saved) |t| sys.setTermios(stdin_fd, &t) catch {};
                sys.writeAll(stdout_fd, "\x1b[H\x1b[2J") catch {};
                return;
            }
            if (redraw and pick == null) draw(stdout_fd, rows[0..found], selected);
        }
        const chosen = &rows[pick.?];
        // NOT AN UNANNOUNCED DISPLACEMENT ([[RFC-0014]] C-ONE-CLIENT): a
        // session with somebody in the seat asks first, naming them.
        if (chosen.attached) {
            var q: [256]u8 = undefined;
            const text = std.fmt.bufPrint(&q, "\r\n{s} is attached{s}{s}. Take the seat? [y/N] ", .{
                chosen.name(),
                if (chosen.label().len > 0) " by " else "",
                chosen.label(),
            }) catch "";
            sys.writeAll(stdout_fd, text) catch {};
            var yn: [8]u8 = undefined;
            const m = sys.read(stdin_fd, &yn) catch 0;
            if (m == 0 or (yn[0] != 'y' and yn[0] != 'Y')) {
                if (saved) |t| sys.setTermios(stdin_fd, &t) catch {};
                continue :outer;
            }
        }
        if (saved) |t| sys.setTermios(stdin_fd, &t) catch {};
        sys.writeAll(stdout_fd, "\x1b[H\x1b[2J") catch {};

        var id_buf: [128]u8 = undefined;
        @memcpy(id_buf[0..chosen.name_len], chosen.name());
        const outcome = try attachHere(allocator, .{ .agent_id = id_buf[0..chosen.name_len] });
        switch (afterAttach(outcome, true)) {
            .list => {
                sys.writeAll(stdout_fd, "\x1b[H\x1b[2J") catch {};
                continue :outer;
            },
            .exit => return,
        }
    }
}

fn draw(fd: sys.fd_t, rows: []const SessionRow, selected: usize) void {
    sys.writeAll(fd, "\x1b[H\x1b[2J") catch {};
    sys.writeAll(fd, "synapty · sessions on this machine — ↑↓/jk move, ↩ attach, r refresh, q quit\r\n\r\n") catch {};
    for (rows, 0..) |*row, i| {
        var line: [1600]u8 = undefined;
        sys.writeAll(fd, formatRow(row, i == selected, &line)) catch {};
    }
    sys.writeAll(fd, "\r\nEnding a session is a separate act: synapty end --id <name>\r\n") catch {};
}

test "the chooser's keys: arrows and vi keys move, Enter picks, q and ^C quit, r refreshes (WI-2026-09-02-013)" {
    var c = Chooser{};
    try std.testing.expectEqual(Chooser.Action.down, c.step('j'));
    try std.testing.expectEqual(Chooser.Action.up, c.step('k'));
    try std.testing.expectEqual(Chooser.Action.select, c.step('\r'));
    try std.testing.expectEqual(Chooser.Action.quit, c.step('q'));
    try std.testing.expectEqual(Chooser.Action.quit, c.step(0x03));
    try std.testing.expectEqual(Chooser.Action.refresh, c.step('r'));
    // ESC [ A is up, carried across three bytes.
    try std.testing.expectEqual(Chooser.Action.none, c.step(0x1b));
    try std.testing.expectEqual(Chooser.Action.none, c.step('['));
    try std.testing.expectEqual(Chooser.Action.up, c.step('A'));
    try std.testing.expectEqual(Chooser.Action.none, c.step(0x1b));
    try std.testing.expectEqual(Chooser.Action.none, c.step('['));
    try std.testing.expectEqual(Chooser.Action.down, c.step('B'));
    // A lone ESC quits once the read is known to be over.
    try std.testing.expectEqual(Chooser.Action.none, c.step(0x1b));
    try std.testing.expectEqual(Chooser.Action.quit, c.flush());
    // ESC followed by something other than [ also quits.
    try std.testing.expectEqual(Chooser.Action.none, c.step(0x1b));
    try std.testing.expectEqual(Chooser.Action.quit, c.step('x'));
    try std.testing.expectEqual(Chooser.Action.none, c.step('z'));
}

test "after an attach the chooser lists again and a --id attach exits, whatever happened" {
    inline for (.{ AttachOutcome.detached, .displaced, .child_exited, .gone }) |o| {
        try std.testing.expectEqual(.list, afterAttach(o, true));
        try std.testing.expectEqual(.exit, afterAttach(o, false));
    }
}

test "a row shows the human name with the id beside it, the state, who sits in the seat and the command" {
    var row: SessionRow = .{ .reachable = true, .attached = true };
    row.name_len = @intCast(SessionRow.put(&row.name_buf, "local-1a2b"));
    row.human_len = @intCast(SessionRow.put(&row.human_buf, "the deploy one"));
    row.label_len = @intCast(SessionRow.put(&row.label_buf, "gui@deskmac:41"));
    row.command_len = SessionRow.put(&row.command_buf, "cargo test");
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("> the deploy one (local-1a2b)  attached by gui@deskmac:41 · cargo test\r\n", formatRow(&row, true, &buf));
    var bare: SessionRow = .{ .reachable = true };
    bare.name_len = @intCast(SessionRow.put(&bare.name_buf, "local-9f"));
    try std.testing.expectEqualStrings("  local-9f  detached\r\n", formatRow(&bare, false, &buf));
    var gone: SessionRow = .{};
    gone.name_len = @intCast(SessionRow.put(&gone.name_buf, "local-00"));
    try std.testing.expectEqualStrings("  local-00  unreachable\r\n", formatRow(&gone, false, &buf));
}

pub fn runEnd(allocator: Allocator, args: types.EndArgs) !void {
    var path_buf: [256]u8 = undefined;
    const path = try holder.socketPath(&path_buf, args.agent_id);
    if (!holder.requestEnd(path)) {
        // A stale socket file is not a session, but it is litter, and the
        // command a human reaches for to tidy up should tidy it up.
        sys.unlink(path);
        // THE SOCKET IS THE ONLY WAY IN, NOT THE ONLY WAY TO END IT. A
        // holder whose socket is gone still has a pid in its record, and
        // a session that can be seen and not ended is the orphan this
        // whole shape exists to prevent.
        if (holder.Record.read(allocator, args.agent_id)) |record| {
            // ASKED BEFORE THE RECORD GOES, because the claim is on the
            // file: unlink it first and there is nothing left to ask.
            //
            // AND ASKED OF THE CLAIM, NOT THE PID. A holder that died and
            // had its number handed to an unrelated process reads as
            // alive to `kill(pid, 0)`, and the line below would then have
            // signalled a stranger ([[holder.Record.ownerGone]]).
            const gone = holder.Record.ownerGone(args.agent_id);
            holder.Record.remove(args.agent_id);
            if (!gone) {
                _ = std.c.kill(record.pid, @enumFromInt(15));
                try io_mod.stdoutWriteAll("ended (unreachable: signalled its process)\n");
                return;
            }
            try io_mod.stdoutWriteAll("ended (it was already gone)\n");
            return;
        }
        try io_mod.stderrWriteAll("synapty end: no session named ");
        try io_mod.stderrWriteAll(args.agent_id);
        try io_mod.stderrWriteAll("\n");
        std.process.exit(2);
    }
    try io_mod.stdoutWriteAll("ended\n");
}

// ---------------------------------------------------------------------------
// The local client ([[WI-2026-08-17-009]])
// ---------------------------------------------------------------------------

/// What the client knows about a session it is watching. This is the
/// state that must survive a transport, and it survives because it lives
/// on this side of one.
const LocalSession = struct {
    incarnation: u64 = 0,
    /// BYTES THIS TERMINAL HAS ACTUALLY RENDERED. Not what the far side
    /// sent, and not what a relay read — those are both larger after a
    /// link dies mid-flight, and resuming from either would leave a hole
    /// in the human's scrollback that nothing announced.
    rendered: u64 = 0,
    have_position: bool = false,
};

/// Why an attempt over one transport ended.
const AttemptEnd = enum {
    /// The transport died. The session is presumed alive; try again.
    transport_lost,
    /// The child exited. There is nothing to come back to.
    child_exited,
    /// Another client took the session.
    displaced,
    /// This process was asked to stop.
    stopped,
    /// The session is not there at all.
    no_session,
    /// The two sides do not speak the same holder protocol. Terminal:
    /// retrying reaches the same disagreement, and the human has already
    /// been told which two versions ([[RFC-0014]] C-VERSION).
    version_mismatch,
};

/// Attach to a session through a transport, and keep attaching.
///
/// THE CLIENT IS HERE, and the terminal it owns is here, which is the
/// whole reason this exists ([[WI-2026-08-17-009]]). A relay on the far
/// side moves frames and remembers nothing; this end counts what it has
/// rendered, so a link that dies mid-frame costs a redraw rather than a
/// hole.
pub fn runAttachThrough(allocator: Allocator, args: types.AttachArgs) !void {
    const stdin_fd: sys.fd_t = 0;
    const is_tty = sys.isatty(stdin_fd);
    var saved: ?sys.Termios = null;
    if (is_tty) saved = sys.makeRaw(stdin_fd) catch null;
    defer if (saved) |t| sys.setTermios(stdin_fd, &t) catch {};

    // THE ACCOUNT OF THE CONNECTION GOES TO THE WORKBENCH, not onto the
    // pane the session is about to repaint ([[WI-2026-08-17-016]]). A
    // human who ran this in their own terminal named no channel, and then
    // nothing here changes.
    var account = progress_mod.Progress.fromEnv();
    defer account.close();
    if (args.through.len > 0) account.say(.start, args.through[0]);

    // THE SAME ONE LINE THE LOCAL ATTACH PRINTS, for the same reason: a
    // key nobody knows is not a way out. ONCE, here, and not inside the
    // attempt — a link that flaps would otherwise print it on every
    // reconnect ([[WI-2026-09-02-034]], [[WI-2026-09-02-036]]).
    if (is_tty) {
        var kbuf: [2]u8 = undefined;
        const shown = Detach.display(detachKey(), &kbuf);
        var line: [320]u8 = undefined;
        const text = std.fmt.bufPrint(
            &line,
            "synapty · {s} — {s} detaches, and what is running keeps running\r\n",
            .{ args.agent_id, shown },
        ) catch "";
        sys.writeAll(1, text) catch {};
    }

    var session = LocalSession{};
    var attempts: usize = 0;
    while (true) {
        const outcome = try attachOnce(allocator, args, &session, &account);
        switch (outcome) {
            // A MISMATCH IS TERMINAL, not a lost link. Retrying reaches
            // the same disagreement, and the human has already been told
            // which two versions ([[RFC-0014]] C-VERSION).
            .child_exited, .displaced, .no_session, .version_mismatch => {
                account.say(.end, @tagName(outcome));
                break;
            },
            .stopped => {
                // THE HUMAN PRESSED THE KEY THE BANNER NAMED, and the local
                // attach says so on the way out; this path said nothing and
                // a blank line where a session was reads as a crash
                // ([[WI-2026-09-02-036]]).
                account.say(.end, @tagName(outcome));
                if (!account.listening()) try screenNotice("detached");
                break;
            },
            .transport_lost => {
                attempts += 1;
                // SAID, NOT SILENT — and said where it does no damage.
                //
                // TO THE WORKBENCH IF ONE IS LISTENING. This was written
                // to the terminal as well, which is the session's own
                // screen: a full-screen program owns every cell of it, so
                // the words landed in the middle of a TUI and stayed
                // there, because a RESUMED attach continues from a
                // position and never repaints ([[WI-2026-08-29-004]]).
                // [[progress]]'s header already said narration is "told to
                // the workbench rather than written onto the session's
                // screen"; the workbench had simply stopped listening at
                // the first paint, and no longer does.
                //
                // AND TO THE TERMINAL IF ONE IS NOT. With no workbench
                // there is no other place, and the terminal is then not a
                // pane being drawn but the screen the human is watching.
                account.say(.lost, "the link died; dialling again");
                if (!account.listening()) {
                    try screenNotice("link lost — reconnecting");
                }
                // A short wait, because the usual cause is a network that
                // is already coming back and a tight loop would spend the
                // whole outage failing to dial.
                io_mod.get().sleep(std.Io.Duration.fromMilliseconds(1000), .awake) catch {};
            },
        }
    }
    if (saved) |t| sys.setTermios(stdin_fd, &t) catch {};
}

const ThroughState = struct {
    /// The detach key, and whether it was pressed — the local attach's
    /// hard-won lesson, inherited late ([[WI-2026-09-02-020]]): raw mode
    /// eats Ctrl-C, so without this the human is trapped in the session.
    detach_key: u8 = Detach.default_key,
    detached: bool = false,
    /// To the relay's stdin.
    out_fd: sys.fd_t,
    /// This attempt's own liveness, not the session's.
    running: bool = true,
};

fn attachOnce(
    allocator: Allocator,
    args: types.AttachArgs,
    session: *LocalSession,
    account: *const progress_mod.Progress,
) !AttemptEnd {
    var child = std.process.spawn(io_mod.get(), .{
        .argv = args.through,
        .stdin = .pipe,
        .stdout = .pipe,
        // The transport's own complaints reach the human: an ssh that
        // cannot resolve a host has something to say, and swallowing it
        // would turn a typo into a silent retry loop.
        //
        // WHERE THEY REACH THEM CHANGED ([[WI-2026-08-17-016]]). Onto the
        // pane, they are erased by the restoration a moment later and the
        // human sees them flash past. When the workbench is listening,
        // they go into the account instead — kept, timed, and shown for
        // as long as there is nothing truer to show. When it is not, they
        // go where they always went.
        .stderr = if (account.on()) .pipe else .inherit,
    }) catch return .transport_lost;
    // REAPED, NOT KILLED. The transport dying is the ordinary case here,
    // and `kill` on a child that has already gone is a panic rather than
    // an error. Closing our end of its input is what ends a relay that is
    // still alive — it reads until end of stream — so waiting is enough
    // for both.
    defer _ = std.process.Child.wait(&child, io_mod.get()) catch {};
    const to_relay: sys.fd_t = child.stdin.?.handle;
    const from_relay: sys.fd_t = child.stdout.?.handle;

    // The transport's words, read on their own thread: they arrive while
    // this one is waiting on the handshake, which is precisely when they
    // are worth having.
    var stderr_thread: ?std.Thread = null;
    if (child.stderr) |errf| {
        stderr_thread = std.Thread.spawn(
            .{},
            progress_mod.pumpLines,
            .{ account, errf.handle },
        ) catch null;
    }
    defer if (stderr_thread) |t| t.join();

    const stdin_fd: sys.fd_t = 0;
    const stdout_fd: sys.fd_t = 1;
    var ws = sys.winsize{ .ws_row = 24, .ws_col = 80 };
    if (sys.isatty(stdin_fd)) ws = sys.winsizeOf(stdin_fd) catch ws;
    account.say(.attach, args.agent_id);

    // The position goes in the greeting, so the far side answers with
    // what was missed before anything newer.
    var hello: [21]u8 = undefined;
    hello[0] = holder.protocol_version;
    std.mem.writeInt(u16, hello[1..3], ws.ws_row, .little);
    std.mem.writeInt(u16, hello[3..5], ws.ws_col, .little);
    var hello_len: usize = 5;
    if (session.have_position) {
        std.mem.writeInt(u64, hello[5..13], session.incarnation, .little);
        std.mem.writeInt(u64, hello[13..21], session.rendered, .little);
        hello_len = 21;
    }
    holder.writeFrame(to_relay, .hello, hello[0..hello_len]) catch return .transport_lost;

    var wbuf: [128]u8 = undefined;
    var theirs: u8 = 0;
    const welcome = holder.readWelcome(from_relay, &wbuf, &theirs) catch |err| {
        if (err == error.VersionMismatch) {
            reportVersionMismatch(theirs) catch {};
            return .version_mismatch;
        }
        return .no_session;
    };
    const answer = welcome.answer;
    session.incarnation = welcome.incarnation;
    session.rendered = welcome.position;
    session.have_position = true;
    if (answer == .unavailable) {
        // The position could not be honoured. The screen that follows is
        // a restoration, not a continuation, and the difference is the
        // human's to know.
        account.say(.lost, "too much happened to continue; showing the screen as it is now");
    }
    if (answer == .resumed) {
        // NOTHING WILL BE PAINTED, because nothing was lost: what follows
        // is the output this client missed, which is as much something to
        // show as a restoration would have been.
        account.say(.live, "returned to the session where it was left");
    }

    var state = ThroughState{ .out_fd = to_relay, .detach_key = detachKey() };
    const in_thread = std.Thread.spawn(.{}, throughInputLoop, .{ &state, stdin_fd }) catch
        return .transport_lost;
    // A CLIENT WHOSE INPUT IS NOT A TERMINAL HAS NO SIZE TO FOLLOW. Asking
    // one for its dimensions answers ENOTTY forever, which is a stack
    // trace every quarter of a second in a build with safety on.
    const follow_size = sys.isatty(stdin_fd);
    const size_thread = std.Thread.spawn(.{}, throughSizeLoop, .{ &state, stdin_fd, ws, follow_size }) catch {
        state.running = false;
        in_thread.join();
        return .transport_lost;
    };
    defer {
        state.running = false;
        // JOINED BEFORE THE DESCRIPTOR CLOSES, because both of these
        // threads write to it. Closing first left them writing to a
        // closed fd — EBADF, which `writeAll` does not map, so the
        // human's pane took a stack trace after a clean "session ended";
        // and a closed fd number is one the kernel may hand to the next
        // thing opened, which is a worse failure than the noisy one.
        in_thread.join();
        size_thread.join();
        // CLOSED THROUGH THE CHILD THAT OWNS IT. Closing the descriptor
        // directly and then letting the child's cleanup close it again is
        // a double close, which this platform reports as a use-after-free
        // and the standard library turns into a panic.
        if (child.stdin) |f| {
            f.close(io_mod.get());
            child.stdin = null;
        }
    }

    var buf: [32768]u8 = undefined;
    while (true) {
        // POLL, DON'T BLOCK: a thread parked in read cannot be told the
        // human pressed ^]. The input loop drops `running`; this loop sees
        // it within a poll and returns .stopped, and the deferred cleanup
        // ends the relay ([[WI-2026-09-02-020]]).
        while (state.running) {
            const ready = sys.waitReadable(from_relay, input_poll_ms) catch return .transport_lost;
            if (ready) break;
        }
        if (!state.running) return if (state.detached) .stopped else .transport_lost;
        const frame = (holder.readFrameAlloc(allocator, from_relay, &buf) catch return .transport_lost) orelse
            return .transport_lost;
        defer frame.deinit(allocator);
        switch (frame.kind) {
            .data => {
                sys.writeAll(stdout_fd, frame.payload) catch return .stopped;
                // COUNTED AFTER IT IS WRITTEN. A byte counted before the
                // write is a byte the next attempt will not ask for and
                // the human never saw.
                session.rendered += frame.payload.len;
            },
            .restore => {
                if (frame.payload.len > 10) {
                    // A RESTORATION IS AN ABSOLUTE PAINT: it positions
                    // every row it writes and writes every row of the
                    // screen. Home and erase first anyway, so that the
                    // pane's scrollback ends where the restoration
                    // begins rather than trailing off into whatever the
                    // connection that died left behind.
                    //
                    // THE CURSOR TRAVELS IN THE PAINT, placed after the
                    // modes the paint restores — a client that placed it
                    // afterwards would be addressing rows by a rule the
                    // paint had just changed.
                    sys.writeAll(stdout_fd, "\x1b[H\x1b[2J") catch return .stopped;
                    sys.writeAll(stdout_fd, frame.payload[10..]) catch return .stopped;
                    // THE PANE NOW HAS SOMETHING TRUE ON IT, which is the
                    // moment the workbench stops showing progress in
                    // front of it ([[WI-2026-08-17-016]]).
                    account.say(.paint, "");
                }
            },
            .gap => {
                account.say(.lost, "output was lost while this client was away");
                if (frame.payload.len >= 8) {
                    // Resume the count from where the far side says live
                    // output starts, or every later position would be
                    // short by the size of the hole.
                    session.rendered = std.mem.readInt(u64, frame.payload[0..8], .little);
                }
            },
            // WRITTEN INTO THE SESSION'S SCREEN, and these two are the
            // only ones that may be ([[WI-2026-08-29-004]]).
            //
            // THE TEST IS WHETHER ANYTHING WILL DRAW THERE AGAIN. A
            // reconnect, a gap and a restoration are TRANSIENT: the
            // program on the far side still owns every cell and goes on
            // drawing, so a line put among them is wrong from the moment
            // it lands and stays wrong — a resumed attach continues from
            // a position and never repaints. An exit and a displacement
            // are TERMINAL: this client will draw nothing further, and the
            // words are the only account the pane itself will ever carry.
            // The transient ones go to the workbench through [[progress]],
            // which is what that channel is for.
            .exit => {
                if (frame.payload.len >= 2) {
                    var msg: [64]u8 = undefined;
                    const text = if (frame.payload[0] == 1)
                        std.fmt.bufPrint(&msg, "session ended (signal {d})", .{frame.payload[1]}) catch "session ended"
                    else
                        std.fmt.bufPrint(&msg, "session ended (exit {d})", .{frame.payload[1]}) catch "session ended";
                    try screenNotice(text);
                }
                return .child_exited;
            },
            .displaced => {
                try screenNotice("this session was taken by another client");
                return .displaced;
            },
            else => {},
        }
    }
}

/// How long an input loop waits before looking at the flag that stops it.
/// Short enough that nobody sees the client linger, long enough that a
/// quiet terminal costs ten wakeups a second and nothing else.
const input_poll_ms: i32 = 100;

fn throughInputLoop(state: *ThroughState, stdin_fd: sys.fd_t) void {
    var buf: [4096]u8 = undefined;
    var out: [4096]u8 = undefined;
    var detach = Detach{ .key = state.detach_key };
    while (state.running) {
        const ready = sys.waitReadable(stdin_fd, input_poll_ms) catch break;
        if (!ready) continue;
        const n = sys.read(stdin_fd, &buf) catch break;
        if (n == 0) break;
        // THE SAME STATE MACHINE THE LOCAL ATTACH RUNS ([[WI-2026-09-02-020]]):
        // ^] leaves, ^]^] sends the byte, everything else goes through.
        const step = detach.step(buf[0..n], &out);
        if (step.forward.len > 0) {
            holder.writeFrame(state.out_fd, .input, step.forward) catch break;
        }
        if (step.detach) {
            state.detached = true;
            state.running = false;
            return;
        }
    }
}

fn throughSizeLoop(state: *ThroughState, stdin_fd: sys.fd_t, initial: sys.winsize, follow: bool) void {
    if (!follow) return;
    var last = initial;
    while (state.running) {
        io_mod.get().sleep(std.Io.Duration.fromMilliseconds(250), .awake) catch return;
        const now = sys.winsizeOf(stdin_fd) catch continue;
        if (now.ws_row == last.ws_row and now.ws_col == last.ws_col) continue;
        last = now;
        var p: [4]u8 = undefined;
        std.mem.writeInt(u16, p[0..2], now.ws_row, .little);
        std.mem.writeInt(u16, p[2..4], now.ws_col, .little);
        holder.writeFrame(state.out_fd, .resize, &p) catch return;
    }
}


/// THE KEY THIS RUN USES, from the environment or the default.
///
/// AN ENVIRONMENT VARIABLE AND NOT A CONFIG FILE. One setting does not
/// earn a file, a parser and a place to document the parser; ssh settled
/// the same question the same way with `EscapeChar`. A human who wants a
/// different key puts one line in their profile, which is also where the
/// shells that would fight over `^]` are configured.
///
/// AN UNREADABLE VALUE KEEPS THE DEFAULT RATHER THAN BINDING NOTHING. A
/// typo that left no way out would be the defect this whole feature
/// exists to remove.
fn detachKey() u8 {
    const text = sys.getenv("SYNAPTY_DETACH_KEY") orelse return Detach.default_key;
    return Detach.parse(text) orelse Detach.default_key;
}

/// WHAT A HUMAN PRESSES TO LEAVE WITHOUT ENDING ([[RFC-0014]] C-DETACH:
/// "a client MUST be able to leave without ending it, and to end it
/// explicitly. The two MUST be distinct acts.").
///
/// A BYTE, NOT A CHORD, and that is the terminal's doing rather than a
/// choice. `attach` puts the local tty in raw mode so no key is
/// interpreted twice, and a raw tty delivers BYTES: ⌘ combinations never
/// reach this process at all, and ⌥ ones arrive as escape sequences no
/// reader can tell from the real thing. What is left, and what every
/// multiplexer before this one settled on, is a control character.
///
/// `^]` BY DEFAULT because telnet spent thirty years teaching it and
/// almost nothing else uses it. `^A` and `^B` were the alternatives and
/// both are already somebody's prefix — screen's and tmux's — so a human
/// who uses either would have this one fighting muscle memory they
/// already have.
///
/// PRESSED TWICE, THE BYTE ITSELF GOES THROUGH. That is the escape hatch
/// for the rare child that wants it, and it is why the key rarely needs
/// configuring at all.
pub const Detach = struct {
    key: u8,
    /// Whether the previous byte was the key, still waiting to learn
    /// whether the human meant to leave or to send it. The doubling rule
    /// has to work ACROSS reads: a human pressing it twice quickly can
    /// have the two bytes arrive in separate buffers.
    armed: bool = false,

    pub const default_key: u8 = 0x1d; // ^]

    pub const Step = struct {
        /// What to forward to the holder.
        forward: []const u8,
        /// The human asked to leave.
        detach: bool,
    };

    /// Consume one buffer. `out` receives what should be forwarded and
    /// MUST be at least as long as `input`.
    pub fn step(self: *Detach, input: []const u8, out: []u8) Step {
        var n: usize = 0;
        for (input, 0..) |byte, i| {
            if (self.armed) {
                self.armed = false;
                if (byte == self.key) {
                    // Doubled: the child gets one, and the second is
                    // spent saying so.
                    out[n] = byte;
                    n += 1;
                    continue;
                }
                // A lone key, then something else: the human left, and
                // what follows belongs to whatever they land in rather
                // than to a session they have already gone from.
                _ = i;
                return .{ .forward = out[0..n], .detach = true };
            }
            if (byte == self.key) {
                self.armed = true;
                continue;
            }
            out[n] = byte;
            n += 1;
        }
        return .{ .forward = out[0..n], .detach = false };
    }

    /// A key written the way a human writes one: `^]`, `^a`, `^?`.
    ///
    /// CONTROL CHARACTERS ONLY. A printable key cannot be this: bound to
    /// `q`, every `q` the human types leaves the session, and the setting
    /// that did it would read as ordinary. Every multiplexer before this
    /// one reached the same place — screen, tmux and telnet all bind a
    /// control character, and ssh's `~` is special-cased to the start of
    /// a line for exactly this reason.
    ///
    /// Null for anything this cannot read, so a caller can say so rather
    /// than silently binding something else.
    pub fn parse(text: []const u8) ?u8 {
        if (text.len == 2 and text[0] == '^') {
            const c = std.ascii.toUpper(text[1]);
            // `^@` is 0x00 through `^_` at 0x1f — the control block, which
            // is the whole of what a raw tty can deliver unambiguously.
            if (c >= '@' and c <= '_') return c - '@';
            if (c == '?') return 0x7f;
        }
        return null;
    }

    /// How to write the key back to a human, so the line that announces
    /// it and the setting that names it read the same.
    pub fn display(key: u8, buf: []u8) []const u8 {
        if (key < 0x20) {
            buf[0] = '^';
            buf[1] = key + '@';
            return buf[0..2];
        }
        if (key == 0x7f) return "^?";
        buf[0] = key;
        return buf[0..1];
    }
};

const testing = std.testing;

test "a plain byte is forwarded" {
    var d = Detach{ .key = Detach.default_key };
    var out: [8]u8 = undefined;
    const r = d.step("hi", &out);
    try testing.expectEqualStrings("hi", r.forward);
    try testing.expect(!r.detach);
}

test "the key alone detaches and is not forwarded" {
    var d = Detach{ .key = 0x1d };
    var out: [8]u8 = undefined;
    // Armed by the key, then resolved by anything that is not it.
    _ = d.step("\x1d", &out);
    const r = d.step("x", &out);
    try testing.expect(r.detach);
    try testing.expectEqualStrings("", r.forward);
}

test "pressed twice the byte itself goes through" {
    var d = Detach{ .key = 0x1d };
    var out: [8]u8 = undefined;
    const r = d.step("\x1d\x1d", &out);
    try testing.expect(!r.detach);
    try testing.expectEqualStrings("\x1d", r.forward);
}

test "the doubling rule works across reads" {
    // A human pressing twice quickly can have the bytes land in separate
    // buffers, and a rule that only looked inside one would detach.
    var d = Detach{ .key = 0x1d };
    var out: [8]u8 = undefined;
    _ = d.step("\x1d", &out);
    const r = d.step("\x1d", &out);
    try testing.expect(!r.detach);
    try testing.expectEqualStrings("\x1d", r.forward);
}

test "what precedes the key is still forwarded" {
    var d = Detach{ .key = 0x1d };
    var out: [8]u8 = undefined;
    _ = d.step("abc\x1d", &out);
    const r = d.step("q", &out);
    try testing.expect(r.detach);
}

test "parse reads the ways a human writes a key" {
    try testing.expectEqual(@as(?u8, 0x1d), Detach.parse("^]"));
    try testing.expectEqual(@as(?u8, 0x01), Detach.parse("^a"));
    try testing.expectEqual(@as(?u8, 0x01), Detach.parse("^A"));
    try testing.expectEqual(@as(?u8, 0x7f), Detach.parse("^?"));
    try testing.expectEqual(@as(?u8, null), Detach.parse("nonsense"));
    try testing.expectEqual(@as(?u8, null), Detach.parse("^"));
    // A PRINTABLE KEY IS REFUSED. Bound to `q`, every `q` typed would
    // leave the session.
    try testing.expectEqual(@as(?u8, null), Detach.parse("q"));
}

test "display and parse agree, so the announcement names what is bound" {
    var buf: [2]u8 = undefined;
    for ([_][]const u8{ "^]", "^A", "^?", "^@", "^_" }) |written| {
        const key = Detach.parse(written).?;
        const shown = Detach.display(key, &buf);
        try testing.expectEqual(key, Detach.parse(shown).?);
    }
}

/// THE PANE-ONLY VERBS SAY ONE THING, ONCE ([[WI-2026-09-02-021]]). This
/// block was written out three times, comment included. "Not inside a
/// Synapty pane" exits 2 for every verb that reaches the workbench.
fn notInSession() noreturn {
    io_mod.stderrWriteAll(notInSessionSentence(sys.getenv("SYNAPTY_SOCK") != null)) catch {};
    std.process.exit(2);
}

/// TWO CONDITIONS, NOT ONE — and the refusal names the one it found.
/// Being outside a pane and being in a pane whose daemon has gone are
/// different problems with different remedies, and the single sentence
/// asserted the first no matter which had happened. Downstream of the
/// round trip's own line, that produced a pane reporting, in order, that
/// SYNAPTY_SOCK "is set but no pane daemon answers there" and then that
/// it was "not set" ([[WI-2026-09-03-007]]).
fn notInSessionSentence(sock_set: bool) []const u8 {
    return if (sock_set)
        "error: this pane's daemon is not answering, so the workbench cannot be reached from here\n"
    else
        "error: not in a synapty session (SYNAPTY_SOCK not set)\n";
}

/// The pane's agent id, or the exit-2 sentence naming the verb that
/// needed it — six copies with six wordings became one.
fn requireAgentId(verb: []const u8) []const u8 {
    return sys.getenv("SYNAPTY_AGENT_ID") orelse {
        io_mod.stderrWriteAll("error: ") catch {};
        io_mod.stderrWriteAll(verb) catch {};
        io_mod.stderrWriteAll(" must run inside a Synapty pane (SYNAPTY_AGENT_ID unset)\n") catch {};
        std.process.exit(2);
    };
}

/// A SECRET IS TYPED WITHOUT ECHO ([[WI-2026-09-02-021]]): the PAT prompt
/// used promptLine, which showed the token on the terminal as it was
/// typed. Raw mode for the duration, bytes gathered to the newline, the
/// terminal put back, and a newline printed for the one the human's
/// Return did not echo.
fn promptSecret(allocator: Allocator, prompt: []const u8) !?[]const u8 {
    try io_mod.stdoutWriteAll(prompt);
    try io_mod.stdoutWriteAll(": ");
    const saved = sys.makeRaw(0) catch null;
    defer if (saved) |t| sys.setTermios(0, &t) catch {};
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        var one: [1]u8 = undefined;
        const n = sys.read(0, &one) catch break;
        if (n == 0) break;
        if (one[0] == '\r' or one[0] == '\n') break;
        if (one[0] == 0x7f or one[0] == 0x08) {
            if (len > 0) len -= 1;
            continue;
        }
        buf[len] = one[0];
        len += 1;
    }
    try io_mod.stdoutWriteAll("\n");
    if (len == 0) return null;
    const d = try allocator.dupe(u8, buf[0..len]);
    return @as(?[]const u8, d);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Run a one-shot fake daemon on `path` for the duration of a round trip.
/// `reply` of null means: accept the connection, read the request, and
/// close without saying anything.
const FakeDaemon = struct {
    server: ipc.IpcServer,
    thread: std.Thread,

    /// A PATH OF THIS PROCESS'S OWN. A fixed name is shared with every
    /// other run on the machine — another test binary, a stale file from
    /// a crash — and the sweep in run.zig deletes socket files under
    /// /tmp by pid. Deriving it from the pid keeps two runs apart.
    fn pathFor(buf: []u8, tag: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "/tmp/synapty-test-{s}-{d}.sock", .{ tag, std.c.getpid() }) catch unreachable;
    }

    fn start(path: []const u8, reply: ?[]const u8) !FakeDaemon {
        sys.unlink(path);
        var server = try ipc.IpcServer.init(path);
        errdefer server.deinit();
        const thread = try std.Thread.spawn(.{}, serve, .{ &server, reply });
        return .{ .server = server, .thread = thread };
    }

    fn serve(server: *ipc.IpcServer, reply: ?[]const u8) void {
        const conn = server.accept() catch return;
        defer sys.close(conn);
        var buf: [4096]u8 = undefined;
        _ = ipc.IpcServer.readLine(conn, &buf) catch return;
        if (reply) |r| ipc.IpcServer.writeLine(conn, r) catch {};
    }

    fn stop(self: *FakeDaemon) void {
        self.thread.join();
        self.server.deinit();
    }
};

test "a daemon that closes without answering has not answered" {
    const a = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = FakeDaemon.pathFor(&pbuf, "mute");
    var daemon = try FakeDaemon.start(path, null);
    defer daemon.stop();

    // NOT AN EMPTY SUCCESS. This came back as a zero-length response,
    // which ipcRoundtrip printed as nothing and reported as "the IPC path
    // was used" — so `synapty register` exited 0 having registered
    // nothing ([[WI-2026-09-03-007]]).
    const got = try ipcAsk(a, path, .{ .action = .register, .tool = "claude" });
    try std.testing.expectEqual(NoAnswer.closed_silently, got.none);
}

test "a daemon that answers is heard" {
    const a = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = FakeDaemon.pathFor(&pbuf, "heard");
    var daemon = try FakeDaemon.start(path, "{\"success\":true}");
    defer daemon.stop();

    const got = try ipcAsk(a, path, .{ .action = .register, .tool = "claude" });
    // THE TAG BEFORE THE PAYLOAD. Reading `.answer` off a union that
    // holds `.none` is undefined behaviour, so a round trip that failed
    // for any reason crashed the runner instead of failing the test —
    // which is what it did on CI while passing here.
    switch (got) {
        // FAILS, AND SAYS WHICH SILENCE IT WAS. Tolerating a timeout here
        // would let the one thing this test exists to prove go green on
        // the day it stops being true.
        .none => |why| {
            std.debug.print("the fake daemon did not answer: {s}\n", .{@tagName(why)});
            return error.FakeDaemonDidNotAnswer;
        },
        .answer => |body| {
            defer a.free(body);
            try std.testing.expectEqualStrings("{\"success\":true}", body);
        },
    }
}

test "an empty line is not an answer either" {
    const a = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = FakeDaemon.pathFor(&pbuf, "blank");
    var daemon = try FakeDaemon.start(path, "");
    defer daemon.stop();

    const got = try ipcAsk(a, path, .{ .action = .register, .tool = "claude" });
    try std.testing.expectEqual(NoAnswer.empty_line, got.none);
}

test "a socket nothing is listening on is not a daemon" {
    const a = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = FakeDaemon.pathFor(&pbuf, "absent");
    sys.unlink(path);
    const got = try ipcAsk(a, path, .{ .action = .register, .tool = "claude" });
    try std.testing.expectEqual(NoAnswer.unreachable_socket, got.none);
}

test "every way of hearing nothing has something to say about it" {
    // The sentences are the CLI's whole account of this failure; an empty
    // one would put the caller back where it started.
    for ([_]NoAnswer{ .unreachable_socket, .timed_out, .closed_silently, .empty_line }) |why| {
        try std.testing.expect(why.sentence().len > 0);
        try std.testing.expect(std.mem.endsWith(u8, why.sentence(), "\n"));
    }
}

test "the refusal names the condition it found" {
    // A pane whose daemon has gone is not a shell outside a pane, and the
    // remedies differ. Saying "SYNAPTY_SOCK not set" to the first one
    // contradicted the round trip's own line about the variable being set
    // ([[WI-2026-09-03-007]]).
    const set = notInSessionSentence(true);
    const unset = notInSessionSentence(false);
    try std.testing.expect(std.mem.indexOf(u8, unset, "not set") != null);
    try std.testing.expect(std.mem.indexOf(u8, set, "not set") == null);
    try std.testing.expect(!std.mem.eql(u8, set, unset));
}
