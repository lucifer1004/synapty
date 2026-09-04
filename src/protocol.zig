const std = @import("std");
const mem = std.mem;
const json = std.json;
const Allocator = mem.Allocator;

// ---------------------------------------------------------------------------
// A2A JSON Routing Envelope
// ---------------------------------------------------------------------------

/// The canonical A2A routing envelope, one per newline-framed line on the
/// hub's TCP connections and the pane daemon's IPC socket.
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
// Agent presence — per [[RFC-0004]]
// ---------------------------------------------------------------------------

/// The five wire states of [[RFC-0004:C-VOCABULARY]]. Tag names ARE the
/// protocol strings — every surface uses them verbatim.
pub const Status = enum {
    working,
    waiting,
    done,
    idle,
    unknown,

    pub fn fromString(s: []const u8) ?Status {
        inline for (@typeInfo(Status).@"enum".fields) |f| {
            if (mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }

    pub fn toString(self: Status) []const u8 {
        return @tagName(self);
    }
};

/// Signal classes of [[RFC-0004:C-OWNERSHIP]]: explicit (agent notify or
/// the workbench gaze transition), passive (screen detector), lifecycle
/// (process exit / unregistration).
pub const SignalClass = enum {
    explicit,
    passive,
    lifecycle,

    pub fn fromString(s: []const u8) ?SignalClass {
        inline for (@typeInfo(SignalClass).@"enum".fields) |f| {
            if (mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }

    pub fn toString(self: SignalClass) []const u8 {
        return @tagName(self);
    }
};

/// The merge acceptance rules of [[RFC-0004:C-PRECEDENCE]]. Pure function
/// so every surface (hub ingest, tests, future consumers) shares one
/// implementation. `current` is the prior MERGED status.
/// WHY A STATUS IS `unknown` ([[RFC-0010]] C-DIAGNOSABILITY). Wire
/// vocabulary, so it lives beside `Status` rather than in the hub: the
/// hub writes these onto presence rows and the CLI reads them back —
/// `synapty wait` decides on them, because a wait that cannot receive the
/// event that would end it must fail rather than block ([[RFC-0004]]
/// C-WAIT). A second spelling on the reading side would be a second thing
/// to keep in step with the writing side.
pub const UnknownCause = enum {
    no_evidence,
    peer_unreachable,
    peer_lacks_capability,
    /// Two live peers claim the identity ([[RFC-0009]] C-DIRECTORY), so
    /// it has no single hosting peer to name and no status anyone can
    /// report for it. A fourth cause rather than a fifth STATUS: the
    /// vocabulary stays closed at five and the attribution rides beside
    /// it, which is the rule C-DIAGNOSABILITY set for the third.
    contested,

    pub fn fromString(s: []const u8) ?UnknownCause {
        inline for (@typeInfo(UnknownCause).@"enum".fields) |f| {
            if (mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }

    pub fn toString(self: UnknownCause) []const u8 {
        return @tagName(self);
    }
};


pub fn acceptSignal(current: Status, class: SignalClass, new: Status) bool {
    return switch (class) {
        .explicit => switch (new) {
            // Rule 1: agent notify always accepted; the workbench `idle`
            // only lands on a `done` prior — closes the stale-view race
            // where gaze would clear a fresh `waiting`.
            .working, .waiting, .done => true,
            .idle => current == .done,
            // No writer may assert unknown explicitly (C-OWNERSHIP).
            .unknown => false,
        },
        .passive => switch (new) {
            // Rule 3: activity claims accepted from any prior.
            .working, .waiting => true,
            // Rule 4: rest-prompt matches must not manufacture attention.
            .done => current == .working or current == .waiting,
            // C-OWNERSHIP: no gaze evidence, no-match is inert.
            .idle, .unknown => false,
        },
        // Lifecycle signals carry exactly one state.
        .lifecycle => new == .unknown,
    };
}

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

/// A ONE-SHOT CLI INVOCATION ANNOUNCES ITSELF UNDER THIS PREFIX, and such
/// an id names a CONNECTION rather than an agent. Three consequences hang
/// off it and all three are the hub's: it withholds durable identity from
/// such an id ([[RFC-0008]] C-IDENTITY — the connection dies before it
/// could ever re-home under a bound one), it pushes a dm down the
/// connection instead of into the mailbox, and the workbench filters such
/// agents' own polling out of the activity stream.
///
/// HERE RATHER THAN IN THE CLI, because the hub is the party that acts on
/// it and cannot import the CLI. It was declared in `cli/transport.zig`,
/// where only the four minting sites could reach it, so the hub and a
/// fifth mint each wrote the literal out again ([[WI-2026-08-30-006]]).
/// Swift cannot import this either; Sources/Services/TaskMonitor.swift
/// restates it and must change with it.
pub const temp_agent_prefix = "cli-tmp-";

/// True when `id` names a one-shot CLI connection.
pub fn isTempAgent(id: []const u8) bool {
    return mem.startsWith(u8, id, temp_agent_prefix);
}

/// IPC actions per [[RFC-0003:C-CLI-TOOLS]] (the daemon socket the task CLI routes through).
pub const IpcAction = enum {
    notify,
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
    // register (RFC-0008 C-IDENTITY / RFC-0006 C-RESUME-PLAN): the
    // harness-native session identity — identity derivation input and
    // resume incantation input; distinct from the free-text `session`.
    resume_ref: ?[]const u8 = null,
    // notify: signal class (explicit when absent; "lifecycle" carries
    // the SessionEnd unknown — WI-2026-08-11-016).
    class: ?[]const u8 = null,
    // channel_create / channel_invite / channel_leave / channel_list
    channel: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    description: ?[]const u8 = null,
    // notify (agent_status, WI-2026-08-09-022): working | waiting | done
    state: ?[]const u8 = null,
    // recv (WI-2026-08-10-001): block until a message arrives. Without
    // this field the pane IPC path could not express blocking receive at
    // all — `recv --wait` silently no-opped inside panes (found live by
    // agents local-2c69/local-4194, hub issue #2).
    wait: ?bool = null,
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

/// Build a register envelope with a UNIQUE id so multiple register frames
/// from one connection stay distinguishable (WI-2026-08-08-028). The id is
/// allocator-owned (arena pattern — callers serialize immediately). The
/// payload is null: the hub's register path reads only the source field
/// and does not consume a capabilities payload — the earlier emission was
/// dead code with a false contract (WI-2026-08-08-029).
pub fn makeRegisterEnvelope(allocator: Allocator, agent_id: []const u8, capabilities: []const []const u8) !Envelope {
    _ = capabilities;
    const seq = register_seq.fetchAdd(1, .monotonic);
    const id = try std.fmt.allocPrint(allocator, "reg-{d}", .{seq});
    return Envelope{
        .@"type" = "register",
        .id = id,
        .source = agent_id,
        .target = "",
        .payload = .null,
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
    const start = mem.indexOf(u8, data, osc_prefix) orelse return null;
    const after_prefix = start + osc_prefix.len;

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

test "Status and SignalClass wire strings round-trip" {
    inline for (@typeInfo(Status).@"enum".fields) |f| {
        const st: Status = @enumFromInt(f.value);
        try std.testing.expectEqual(st, Status.fromString(st.toString()).?);
    }
    try std.testing.expect(Status.fromString("blocked") == null);
    try std.testing.expect(Status.fromString("") == null);
    inline for (@typeInfo(SignalClass).@"enum".fields) |f| {
        const cl: SignalClass = @enumFromInt(f.value);
        try std.testing.expectEqual(cl, SignalClass.fromString(cl.toString()).?);
    }
}

test "acceptSignal acceptance table (RFC-0004 C-PRECEDENCE)" {
    const all = [_]Status{ .working, .waiting, .done, .idle, .unknown };

    // Explicit working/waiting/done: accepted from ANY prior (rule 1).
    for (all) |prior| {
        try std.testing.expect(acceptSignal(prior, .explicit, .working));
        try std.testing.expect(acceptSignal(prior, .explicit, .waiting));
        try std.testing.expect(acceptSignal(prior, .explicit, .done));
    }
    // Explicit idle: ONLY from done — the stale-view race guard.
    try std.testing.expect(acceptSignal(.done, .explicit, .idle));
    try std.testing.expect(!acceptSignal(.waiting, .explicit, .idle));
    try std.testing.expect(!acceptSignal(.working, .explicit, .idle));
    try std.testing.expect(!acceptSignal(.unknown, .explicit, .idle));
    try std.testing.expect(!acceptSignal(.idle, .explicit, .idle));
    // Explicit unknown: never.
    for (all) |prior| try std.testing.expect(!acceptSignal(prior, .explicit, .unknown));

    // Passive working/waiting: accepted from any prior (rule 3).
    for (all) |prior| {
        try std.testing.expect(acceptSignal(prior, .passive, .working));
        try std.testing.expect(acceptSignal(prior, .passive, .waiting));
    }
    // Passive done: only from observed prior work (rule 4).
    try std.testing.expect(acceptSignal(.working, .passive, .done));
    try std.testing.expect(acceptSignal(.waiting, .passive, .done));
    try std.testing.expect(!acceptSignal(.unknown, .passive, .done));
    try std.testing.expect(!acceptSignal(.idle, .passive, .done));
    try std.testing.expect(!acceptSignal(.done, .passive, .done));
    // Passive idle/unknown: never (no gaze evidence; no-match is inert).
    for (all) |prior| {
        try std.testing.expect(!acceptSignal(prior, .passive, .idle));
        try std.testing.expect(!acceptSignal(prior, .passive, .unknown));
    }

    // Lifecycle: unknown only.
    for (all) |prior| {
        try std.testing.expect(acceptSignal(prior, .lifecycle, .unknown));
        try std.testing.expect(!acceptSignal(prior, .lifecycle, .working));
        try std.testing.expect(!acceptSignal(prior, .lifecycle, .idle));
    }
}

/// HOW LONG EACH RUNG OF A NESTED TOOL REQUEST WAITS.
///
/// A CALLER MUST OUTLAST WHAT IT IS WAITING ON, at every hop, or it gives
/// up while the work is still running and the answer it asked for lands on
/// nobody. Three processes hold a rung — the workbench running the tool,
/// the hub holding the requester's connection parked, and the CLI waiting
/// on the reply — and each stated its own number with a paragraph of prose
/// explaining how it related to the others. Prose is not a relation:
/// change one and nothing checks the ladder is still a ladder
/// ([[WI-2026-08-30-010]]).
///
/// TWO FACTS AND ONE DERIVATION. The budget is what the workbench gives a
/// tool; the slack is what the hub is willing to pin a file descriptor for
/// beyond it, which is a different decision about a different resource.
/// The CLI's wait is then the hub's park plus enough to hear the hub's own
/// honest "it expired" rather than to give up first.
///
/// SWIFT HOLDS THE FIRST RUNG AND CANNOT IMPORT THIS: ToolBridge names the
/// budget in seconds, so a change here is a change there as well.
pub const tool_exec_budget_ms: i64 = 60_000;
pub const tool_park_slack_ms: i64 = 120_000;
pub const tool_park_ms: i64 = tool_exec_budget_ms + tool_park_slack_ms;
pub const tool_wait_ms: i64 = tool_park_ms + 20_000;

test "the deadline ladder only goes one way" {
    // THE PROPERTY, not the numbers: each rung strictly outlasts the one
    // inside it. A ladder that inverts is a caller giving up on work that
    // is still running.
    try std.testing.expect(tool_park_ms > tool_exec_budget_ms);
    try std.testing.expect(tool_wait_ms > tool_park_ms);
}

/// RFC-0007 C-PRIMITIVES run validation: a run command line MUST be a
/// SINGLE line of printable characters — CR, LF, and every other C0
/// control byte plus DEL are rejected. Empty is invalid.
///
/// MIRRORED, NOT SHARED, and the difference matters. This is the CLI's
/// convenience check; the ENFORCEMENT is
/// `Sources/Services/ExecController.swift`'s `ExecCommandValidator`,
/// because an agent can reach the workbench over a raw hub connection
/// without passing through this at all. Swift cannot import this
/// function, so the two are kept identical by holding the same list of
/// cases — the test below and `ExecValidationTests` assert the same
/// boundaries, and tightening one without the other takes the other's
/// list red ([[WI-2026-08-30-009]]). C1 controls (U+0080-U+009F) in valid UTF-8 text are
/// multi-byte (0xC2 0x80..0x9F) and are not detectable at the raw-byte
/// level without decoding; the raw bytes 0x80-0x9F are UTF-8
/// continuation bytes, so they pass — the load-bearing defense is
/// single-line (no CR/LF) + no C0, which seals the submit/escape
/// vectors this rule exists for.
pub fn isValidExecCommand(cmd: []const u8) bool {
    if (cmd.len == 0) return false;
    for (cmd) |c| {
        if (c < 0x20 or c == 0x7F) return false;
    }
    return true;
}

test "isValidExecCommand rejects control bytes and empties (RFC-0007)" {
    try std.testing.expect(isValidExecCommand("ls -la && echo DONE-42"));
    try std.testing.expect(isValidExecCommand("cargo build"));
    try std.testing.expect(isValidExecCommand("echo caf\xc3\xa9")); // UTF-8 ok
    try std.testing.expect(!isValidExecCommand(""));
    try std.testing.expect(!isValidExecCommand("a\nb")); // LF
    try std.testing.expect(!isValidExecCommand("a\rb")); // CR
    try std.testing.expect(!isValidExecCommand("a\tb")); // TAB
    try std.testing.expect(!isValidExecCommand("a\x1bb")); // ESC
    try std.testing.expect(!isValidExecCommand("a\x07b")); // BEL
    try std.testing.expect(!isValidExecCommand("a\x7fb")); // DEL
}

test "IpcRequest notify round-trip" {
    const req = IpcRequest{ .action = .notify, .state = "waiting" };
    const raw = try serializeIpcRequest(std.testing.allocator, req);
    defer std.testing.allocator.free(raw);
    const parsed = try parseIpcRequest(std.testing.allocator, raw);
    defer parsed.deinit();
    try std.testing.expectEqual(IpcAction.notify, parsed.value.action);
    try std.testing.expectEqualStrings("waiting", parsed.value.state.?);
}
