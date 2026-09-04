const std = @import("std");
const mem = std.mem;
const clap = @import("clap");
const types = @import("types.zig");
const Subcommand = types.Subcommand;
const ParseError = types.ParseError;
const Allocator = mem.Allocator;

/// Parse process args (excluding argv[0]) into a Subcommand.
/// Uses zig-clap for structured flag/option parsing per [[ADR-0003]].
pub fn parseArgs(allocator: Allocator, args: []const []const u8) !Subcommand {
    if (args.len == 0) return ParseError.MissingSubcommand;

    const sub = args[0];
    const rest = args[1..];

    // Top-level --help before subcommand dispatch.
    if (mem.eql(u8, sub, "--help") or mem.eql(u8, sub, "-h")) return ParseError.HelpRequested;

    if (mem.eql(u8, sub, "version") or mem.eql(u8, sub, "--version")) return .version;

    // THE GATE. Everything below dispatches a name this has already
    // admitted, so [[types]]`.subcommands` is what the CLI accepts rather
    // than a list someone remembered to update ([[WI-2026-08-28-017]]).
    if (!types.isSubcommand(sub)) return ParseError.UnknownSubcommand;

    if (mem.eql(u8, sub, "register")) return parseRegister(allocator, rest);
    if (mem.eql(u8, sub, "notify")) return parseNotify(allocator, rest);
    if (mem.eql(u8, sub, "wait")) return parseWait(allocator, rest);
    if (mem.eql(u8, sub, "send")) return parseSend(allocator, rest);
    if (mem.eql(u8, sub, "recv")) return parseRecv(allocator, rest);
    if (mem.eql(u8, sub, "agents")) return parseNoArgs(allocator, rest, .agents);
    if (mem.eql(u8, sub, "run")) return parseRun(allocator, rest);
    if (mem.eql(u8, sub, "attach")) return parseAttach(allocator, rest);
    if (mem.eql(u8, sub, "sessions")) return parseSessions(allocator, rest);
    if (mem.eql(u8, sub, "end")) return parseEnd(allocator, rest);
    if (mem.eql(u8, sub, "name")) return parseName(allocator, rest);
    if (mem.eql(u8, sub, "hub")) return parseHub(allocator, rest);
    if (mem.eql(u8, sub, "channel")) return parseChannel(allocator, rest);
    if (mem.eql(u8, sub, "mcp-serve")) return parseMcpServe(allocator, rest);
    if (mem.eql(u8, sub, "github")) return parseGithub(allocator, rest);
    if (mem.eql(u8, sub, "task")) return parseTask(allocator, rest);
    if (mem.eql(u8, sub, "skills")) return parseSkills(allocator, rest);
    if (mem.eql(u8, sub, "activity")) return parseActivity(allocator, rest);
    if (mem.eql(u8, sub, "hooks")) return parseHooks(allocator, rest);
    if (mem.eql(u8, sub, "hook-event")) return parseHookEvent(allocator, rest);
    if (mem.eql(u8, sub, "exec")) return parseExec(allocator, rest);
    if (mem.eql(u8, sub, "put")) return parseFile(allocator, rest, .put);
    if (mem.eql(u8, sub, "fetch")) return parseFile(allocator, rest, .fetch);
    if (mem.eql(u8, sub, "expose")) return parseView(allocator, rest, .expose);
    if (mem.eql(u8, sub, "unexpose")) return parseView(allocator, rest, .withdraw);
    if (mem.eql(u8, sub, "present")) return parsePresent(allocator, rest);
    if (mem.eql(u8, sub, "ask")) return parseAsk(rest);
    if (mem.eql(u8, sub, "identify")) {
        if (wantsHelp(rest)) return ParseError.HelpRequested;
        // TRAILING WORDS ARE A MISTAKE, NOT NOISE ([[WI-2026-09-02-021]]):
        // the bug class `skills install --harness` was fixed for, applied
        // to its neighbours.
        if (rest.len > 0) return ParseError.TooManyArguments;
        return .identify;
    }
    if (mem.eql(u8, sub, "exposed")) return parseExposed(rest);
    if (mem.eql(u8, sub, "tools")) return parseTools(allocator, rest);

    return ParseError.UnknownSubcommand;
}

// ---------------------------------------------------------------------------
// hooks subcommand (WI-2026-08-11-007 harness adapter packs)
// ---------------------------------------------------------------------------

fn parseHooks(allocator: Allocator, args: []const []const u8) !Subcommand {
    _ = allocator;
    if (args.len == 0) return ParseError.MissingSubcommand;
    if (wantsHelp(args)) return ParseError.HelpRequested;

    // THE SAME FACT THE HELP LINE IS BUILT FROM ([[types.actionList]]), so
    // a word the help offers is a word this accepts.
    const action = types.actionFrom(types.HooksArgs.Action, args[0]) orelse
        return ParseError.UnknownSubcommand;

    if (args.len < 2) return ParseError.MissingArgument;
    var out = types.HooksArgs{ .action = action, .tool = args[1] };
    for (args[2..]) |arg| {
        if (mem.eql(u8, arg, "--yes") or mem.eql(u8, arg, "-y")) {
            out.yes = true;
        } else if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
            return ParseError.HelpRequested;
        } else {
            return ParseError.UnknownSubcommand;
        }
    }
    return .{ .hooks = out };
}

fn parseActivity(allocator: Allocator, args: []const []const u8) !Subcommand {
    _ = allocator;
    if (wantsHelp(args)) return ParseError.HelpRequested;
    if (args.len > 0) return ParseError.TooManyArguments;
    return .{ .activity = {} };
}

// ---------------------------------------------------------------------------
// skills subcommand (RFC-0003 C-SKILLS)
// ---------------------------------------------------------------------------

fn parseSkills(allocator: Allocator, args: []const []const u8) !Subcommand {
    _ = allocator;
    if (args.len == 0) return ParseError.MissingSubcommand;
    if (wantsHelp(args)) return ParseError.HelpRequested;
    const action = types.actionFrom(types.SkillsArgs.Action, args[0]) orelse
        return ParseError.UnknownSubcommand;
    if (args.len > 1 and (mem.eql(u8, args[1], "--help") or mem.eql(u8, args[1], "-h"))) {
        return ParseError.HelpRequested;
    }
    // NOT SWALLOWED. `skills install --harness codex` was accepted and the
    // flag ignored, so a caller believed it had installed to one harness
    // when it had installed to every one detected ([[WI-2026-08-30-005]]).
    if (args.len > 1) return ParseError.UnknownSubcommand;
    return .{ .skills = .{ .action = action } };
}

// ---------------------------------------------------------------------------
// github subcommand (RFC-0003 C-AUTH)
// ---------------------------------------------------------------------------

fn parseGithub(allocator: Allocator, args: []const []const u8) !Subcommand {
    if (args.len == 0) return ParseError.MissingSubcommand;
    if (wantsHelp(args)) return ParseError.HelpRequested;

    // Subcommands (WI-2026-08-08-043): login | logout | status.
    const action = types.actionFrom(types.GithubArgs.Action, args[0]) orelse
        return ParseError.UnknownSubcommand;
    if (action != .login) {
        // logout and status take nothing; a word after them is a mistake.
        if (args.len > 1) return ParseError.TooManyArguments;
        return .{ .github = .{ .action = action } };
    }
    const rest = args[1..];

    const params = comptime clap.parseParamsComptime(types.paramsFor("github"));
    var iter = clap.args.SliceIterator{ .args = rest };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    return .{ .github = .{
        .action = .login,
        .owner = res.args.owner,
        .repo = res.args.repo,
        .token = res.args.token,
    } };
}

// ---------------------------------------------------------------------------
// task subcommand (RFC-0003 C-CLI-TOOLS)
// ---------------------------------------------------------------------------

fn parseTask(allocator: Allocator, args: []const []const u8) !Subcommand {
    if (args.len == 0) return ParseError.MissingSubcommand;
    const action = args[0];
    const rest = args[1..];
    if (mem.eql(u8, action, "--help") or mem.eql(u8, action, "-h")) return ParseError.HelpRequested;

    if (mem.eql(u8, action, "list")) {
        const params = comptime clap.parseParamsComptime(
            \\    --project <str>  Project label (p:<name>).
            \\    --state <str>    Issue state filter (open|closed|all).
            \\-h, --help          Display help and exit.
            \\
        );
        var iter = clap.args.SliceIterator{ .args = rest };
        var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
            .allocator = allocator,
        }) catch |err| return usageError(err);
        defer res.deinit();
        if (res.args.help != 0) return ParseError.HelpRequested;
        return .{ .task = .{ .list = .{ .project = res.args.project, .state = res.args.state } } };
    }
    if (mem.eql(u8, action, "show")) {
        if (wantsHelp(rest)) return ParseError.HelpRequested;
        if (rest.len < 1) return ParseError.MissingArgument;
        if (rest.len > 1) return ParseError.TooManyArguments;
        const number = std.fmt.parseInt(u32, rest[0], 10) catch return ParseError.MissingArgument;
        return .{ .task = .{ .show = .{ .number = number } } };
    }
    if (mem.eql(u8, action, "claim")) {
        if (wantsHelp(rest)) return ParseError.HelpRequested;
        if (rest.len < 1) return ParseError.MissingArgument;
        if (rest.len > 1) return ParseError.TooManyArguments;
        const number = std.fmt.parseInt(u32, rest[0], 10) catch return ParseError.MissingArgument;
        return .{ .task = .{ .claim = .{ .number = number } } };
    }
    if (mem.eql(u8, action, "update")) {
        // --help before parseInt: `task update --help` used to report a
        // missing argument ([[WI-2026-09-02-021]]).
        if (wantsHelp(rest)) return ParseError.HelpRequested;
        if (rest.len < 2) return ParseError.MissingArgument;
        if (rest.len > 2) return ParseError.TooManyArguments;
        const number = std.fmt.parseInt(u32, rest[0], 10) catch return ParseError.MissingArgument;
        return .{ .task = .{ .update = .{ .number = number, .status = rest[1] } } };
    }
    if (mem.eql(u8, action, "comment")) {
        if (wantsHelp(rest)) return ParseError.HelpRequested;
        if (rest.len < 2) return ParseError.MissingArgument;
        if (rest.len > 2) return ParseError.TooManyArguments;
        const number = std.fmt.parseInt(u32, rest[0], 10) catch return ParseError.MissingArgument;
        return .{ .task = .{ .comment = .{ .number = number, .body = rest[1] } } };
    }
    if (mem.eql(u8, action, "create")) {
        if (rest.len < 1) return ParseError.MissingArgument;
        if (mem.eql(u8, rest[0], "--help") or mem.eql(u8, rest[0], "-h")) return ParseError.HelpRequested;
        const title = rest[0];
        const params = comptime clap.parseParamsComptime(
            \\    --project <str>  Project label (p:<name>).
            \\    --body <str>     Issue body text.
            \\-h, --help          Display help and exit.
            \\
        );
        var iter = clap.args.SliceIterator{ .args = rest[1..] };
        var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
            .allocator = allocator,
        }) catch |err| return usageError(err);
        defer res.deinit();
        if (res.args.help != 0) return ParseError.HelpRequested;
        return .{ .task = .{ .create = .{
            .title = title,
            .project = res.args.project,
            .body = res.args.body,
        } } };
    }
    return ParseError.UnknownSubcommand;
}

// ---------------------------------------------------------------------------
// Per-subcommand parsers
// ---------------------------------------------------------------------------

/// `notify --state working|waiting|done` (WI-2026-08-09-022).
fn parseNotify(allocator: Allocator, args: []const []const u8) !Subcommand {
    const params = comptime clap.parseParamsComptime(types.paramsFor("notify"));
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    const state = res.args.state orelse return ParseError.MissingArgument;
    const valid = std.mem.eql(u8, state, "working") or
        std.mem.eql(u8, state, "waiting") or
        std.mem.eql(u8, state, "done");
    if (!valid) return ParseError.MissingArgument;
    return .{ .ipc = .{
        .action = .notify,
        .args = .{ .notify = .{ .state = state } },
    } };
}

/// `wait --agent <id> --until <state> [--timeout <secs>]` (RFC-0004 C-WAIT).
fn parseWait(allocator: Allocator, args: []const []const u8) !Subcommand {
    const params = comptime clap.parseParamsComptime(types.paramsFor("wait"));
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    const agent = res.args.agent orelse return ParseError.MissingArgument;
    const until = res.args.until orelse return ParseError.MissingArgument;
    // Validated against the ENUM, not against a second copy of the word
    // list. runWait does `Status.fromString(until) orelse unreachable` on
    // the strength of this check, so a list spelled out here would put
    // the vocabulary in two files — and a sixth state added to RFC-0004
    // would turn a rejected argument into a panic. `unknown` is excluded
    // deliberately: "the
    // agent went away" is the exit-4 pinning failure, not a state to wait
    // for (C-WAIT).
    const parsed_state = @import("protocol").Status.fromString(until) orelse return ParseError.MissingArgument;
    if (parsed_state == .unknown) return ParseError.MissingArgument;
    return .{ .wait = .{
        .agent = agent,
        .until = until,
        .timeout_secs = res.args.timeout,
    } };
}

fn parseRegister(allocator: Allocator, args: []const []const u8) !Subcommand {
    const params = comptime clap.parseParamsComptime(types.paramsFor("register"));
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    const tool = res.args.tool orelse return ParseError.MissingArgument;
    return .{ .ipc = .{
        .action = .register,
        .args = .{ .register = .{
            .tool = tool,
            .project = res.args.project,
            .session = res.args.session,
            .resume_ref = res.args.@"resume-ref",
        } },
    } };
}

fn parseSend(allocator: Allocator, args: []const []const u8) !Subcommand {
    const params = comptime clap.parseParamsComptime(types.paramsFor("send"));
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    const target = res.positionals[0] orelse return ParseError.MissingArgument;
    const text = res.positionals[1] orelse return ParseError.MissingArgument;
    return .{ .ipc = .{
        .action = .send,
        .args = .{ .send = .{ .target = target, .text = text } },
    } };
}

fn parseRecv(allocator: Allocator, args: []const []const u8) !Subcommand {
    const params = comptime clap.parseParamsComptime(types.paramsFor("recv"));
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    return .{ .ipc = .{
        .action = .recv,
        .args = .{ .recv = .{ .wait = res.args.wait != 0 } },
    } };
}

/// `synapty attach --id <name>` — join a session that already exists.
///
/// It takes no child command, and that absence is the contract rather
/// than an omission: an attach never creates a session ([[RFC-0014]]
/// C-START), so there is nothing for it to describe.
fn parseAttach(allocator: Allocator, args: []const []const u8) !Subcommand {
    for (args) |arg| {
        if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) return ParseError.HelpRequested;
        if (mem.eql(u8, arg, "--")) break;
    }
    // Everything after `--` is the transport command, verbatim: it is an
    // ssh invocation with its own flags, and re-parsing it here would be
    // this program having opinions about another program's arguments.
    var sep: ?usize = null;
    for (args, 0..) |arg, i| {
        if (mem.eql(u8, arg, "--")) {
            sep = i;
            break;
        }
    }
    const flag_args = if (sep) |i| args[0..i] else args;
    const through = if (sep) |i| args[i + 1 ..] else &[_][]const u8{};

    const params = comptime clap.parseParamsComptime(types.paramsFor("attach"));
    var iter = clap.args.SliceIterator{ .args = flag_args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();
    // NO --id AND NO TRANSPORT: the chooser ([[WI-2026-09-02-013]]). A
    // relay or a --through attach always names its session.
    const agent_id = res.args.id orelse {
        if (res.args.relay != 0 or through.len > 0) return ParseError.MissingArgument;
        return .attach_choose;
    };
    return .{ .attach = .{
        .agent_id = agent_id,
        .client = res.args.client orelse "cli",
        .relay = res.args.relay != 0,
        .through = through,
    } };
}

fn parseName(allocator: Allocator, args: []const []const u8) !Subcommand {
    for (args) |arg| {
        if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) return ParseError.HelpRequested;
    }
    const params = comptime clap.parseParamsComptime(types.paramsFor("name"));
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();
    const agent_id = res.args.id orelse return ParseError.MissingArgument;
    const name = res.args.name orelse return ParseError.MissingArgument;
    return .{ .name = .{ .agent_id = agent_id, .name = name } };
}

/// `synapty sessions [--id <name>]`. With a name it answers about one
/// session, which is how a caller that already knows which one it means
/// asks — the workbench wanting a pane's working directory, not a
/// listing to search.
fn parseSessions(allocator: Allocator, args: []const []const u8) !Subcommand {
    for (args) |arg| {
        if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) return ParseError.HelpRequested;
    }
    if (args.len == 0) return .{ .sessions = .{} };
    const params = comptime clap.parseParamsComptime(types.paramsFor("sessions"));
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();
    return .{ .sessions = .{ .agent_id = res.args.id } };
}

/// `synapty end --id <name>` ([[RFC-0014]] C-END).
fn parseEnd(allocator: Allocator, args: []const []const u8) !Subcommand {
    for (args) |arg| {
        if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) return ParseError.HelpRequested;
    }
    const params = comptime clap.parseParamsComptime(types.paramsFor("end"));
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();
    const agent_id = res.args.id orelse return ParseError.MissingArgument;
    return .{ .end = .{ .agent_id = agent_id } };
}

fn parseRun(allocator: Allocator, args: []const []const u8) !Subcommand {
    // Check for --help before scanning for -- (so `run --help` works without --).
    for (args) |arg| {
        if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) return ParseError.HelpRequested;
        if (mem.eql(u8, arg, "--")) break;
    }

    var sep: ?usize = null;
    for (args, 0..) |arg, i| {
        if (mem.eql(u8, arg, "--")) {
            sep = i;
            break;
        }
    }
    const dash_pos = sep orelse return ParseError.MissingArgument;
    if (dash_pos + 1 >= args.len) return ParseError.MissingArgument;

    const flag_args = args[0..dash_pos];
    const child_argv = args[dash_pos + 1 ..];

    const params = comptime clap.parseParamsComptime(types.paramsFor("run"));
    var iter = clap.args.SliceIterator{ .args = flag_args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();

    const agent_id = res.args.id orelse return ParseError.MissingArgument;

    // Parse optional --hub host:port. Without the flag (a manually
    // launched wrapper — the app always passes it), resolve like a bare
    // CLI: SYNAPTY_HUB_PORT, then the discovery file, then 9000
    // (WI-2026-08-11-017).
    var hub_addr: []const u8 = "127.0.0.1";
    var hub_port: u16 = @import("transport.zig").resolveHubPort();
    if (res.args.hub) |hub_str| {
        const colon_idx = mem.lastIndexOfScalar(u8, hub_str, ':') orelse return ParseError.MissingArgument;
        const host = hub_str[0..colon_idx];
        const port_str = hub_str[colon_idx + 1 ..];
        if (host.len == 0 or port_str.len == 0) return ParseError.MissingArgument;
        hub_port = std.fmt.parseInt(u16, port_str, 10) catch return ParseError.MissingArgument;
        hub_addr = host;
    }

    return .{ .run = .{
        .agent_id = agent_id,
        .child_argv = child_argv,
        .hub_addr = hub_addr,
        .hub_port = hub_port,
        .parent_pid = res.args.@"parent-pid",
        .hold = res.args.hold != 0,
        .detach = res.args.detach != 0,
    } };
}

/// This machine's hub ([[ADR-0004]]; [[ADR-0008]]: a service hub when no
/// --parent-pid names a workbench that owns it).
fn parseHub(allocator: Allocator, args: []const []const u8) !Subcommand {
    const params = comptime clap.parseParamsComptime(types.paramsFor("hub"));
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    return .{ .hub = .{
        .ensure = res.args.ensure != 0,
        .peer_id = res.args.@"peer-id",
        .remint = res.args.remint != 0,
        .log = res.args.log != 0,
        .follow = res.args.follow != 0,
        .identity_path = res.args.@"identity-path",
        .port = res.args.port orelse 9000,
        .parent_pid = res.args.@"parent-pid",
        .grace_secs = res.args.@"grace-secs" orelse 30,
        .strict_port = res.args.@"strict-port" != 0,
        .discovery_path = res.args.@"discovery-path",
        .state_path = if (res.args.@"no-state" != 0) null else (res.args.@"state-path" orelse "default"),
    } };
}

/// Parser for subcommands with no arguments (agents, channel list).
/// Only checks for --help.
fn parseNoArgs(allocator: Allocator, args: []const []const u8, action: @import("protocol").IpcAction) !Subcommand {
    const params = comptime clap.parseParamsComptime(types.paramsFor("agents"));
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;

    return switch (action) {
        .agents => .{ .ipc = .{ .action = .agents, .args = .agents } },
        .channel_list => .{ .ipc = .{ .action = .channel_list, .args = .channel_list } },
        else => ParseError.UnknownSubcommand,
    };
}

fn parseMcpServe(allocator: Allocator, args: []const []const u8) !Subcommand {
    const params = comptime clap.parseParamsComptime(types.paramsFor("mcp-serve"));
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    return .mcp_serve;
}

fn parseChannel(allocator: Allocator, args: []const []const u8) !Subcommand {
    if (args.len == 0) return ParseError.MissingArgument;
    const action = args[0];
    const rest = args[1..];

    // ASKED FOR HELP, ANSWERED WITH HELP. Every sub-action below handles
    // this and the dispatcher did not, so `synapty channel --help` — the
    // one spelling a human reaches for when they do not know the
    // sub-actions — answered "unknown subcommand", which is the least
    // useful sentence available for that question.
    if (wantsHelp(args)) return ParseError.HelpRequested;

    if (mem.eql(u8, action, "create")) return parseChannelCreate(allocator, rest);
    if (mem.eql(u8, action, "invite")) return parseChannelInvite(allocator, rest);
    if (mem.eql(u8, action, "leave")) return parseChannelLeave(allocator, rest);
    if (mem.eql(u8, action, "list")) return parseNoArgs(allocator, rest, .channel_list);

    return ParseError.UnknownSubcommand;
}

fn parseChannelCreate(allocator: Allocator, args: []const []const u8) !Subcommand {
    const params = comptime clap.parseParamsComptime(
        \\    --description <str>  Channel description.
        \\-h, --help               Display help and exit.
        \\<str>
        \\
    );
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    const name = res.positionals[0] orelse return ParseError.MissingArgument;
    return .{ .ipc = .{
        .action = .channel_create,
        .args = .{ .channel_create = .{ .name = name, .description = res.args.description } },
    } };
}

fn parseChannelInvite(allocator: Allocator, args: []const []const u8) !Subcommand {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display help and exit.
        \\<str>
        \\<str>
        \\
    );
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    const channel = res.positionals[0] orelse return ParseError.MissingArgument;
    const agent_id = res.positionals[1] orelse return ParseError.MissingArgument;
    return .{ .ipc = .{
        .action = .channel_invite,
        .args = .{ .channel_invite = .{ .channel = channel, .agent_id = agent_id } },
    } };
}

fn parseChannelLeave(allocator: Allocator, args: []const []const u8) !Subcommand {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display help and exit.
        \\<str>
        \\
    );
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    const channel = res.positionals[0] orelse return ParseError.MissingArgument;
    return .{ .ipc = .{
        .action = .channel_leave,
        .args = .{ .channel_leave = .{ .channel = channel } },
    } };
}

fn parseHookEvent(allocator: Allocator, args: []const []const u8) !Subcommand {
    _ = allocator;
    if (wantsHelp(args)) return ParseError.HelpRequested;
    if (args.len == 0) return ParseError.MissingArgument;
    if (args.len > 1) return ParseError.TooManyArguments;
    return .{ .hook_event = .{ .tool = args[0] } };
}

/// `synapty tools exec --tool <name> [--args <json>]` — the WORKBENCH-side
/// executor for credential-bound task tools ([[ADR-0008]] decision 6).
/// Deliberately not folded into `synapty task`: `task` talks to the hub as
/// a client, this runs the tool here and now with the local credential, and
/// conflating the two is how a hub ends up loading a PAT again.
fn parseTools(allocator: Allocator, args: []const []const u8) !Subcommand {
    _ = allocator;
    if (args.len == 0) return ParseError.MissingSubcommand;
    if (wantsHelp(args)) return ParseError.HelpRequested;
    if (!mem.eql(u8, args[0], "exec")) return ParseError.UnknownSubcommand;

    var out = types.ToolsExecArgs{ .tool = "" };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (mem.eql(u8, a, "--help") or mem.eql(u8, a, "-h")) return ParseError.HelpRequested;
        if (mem.eql(u8, a, "--tool")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            out.tool = args[i];
        } else if (mem.eql(u8, a, "--args")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            out.args_json = args[i];
        } else return ParseError.UnknownSubcommand;
    }
    if (out.tool.len == 0) return ParseError.MissingArgument;
    return .{ .tools_exec = out };
}

/// ASKED FOR HELP ANYWHERE IN A COMMAND, not only as its first word.
///
/// The hand-written parsers below each checked `args[0]` and then treated
/// a later `--help` as an unrecognised flag, so `synapty expose 8080
/// --help` — someone half-way through a command, checking what else it
/// takes — was told the command was unknown. The clap-driven parsers
/// never had the hole, because clap is handed the whole slice.
fn wantsHelp(args: []const []const u8) bool {
    for (args) |a| {
        if (mem.eql(u8, a, "--help") or mem.eql(u8, a, "-h")) return true;
    }
    return false;
}

/// WHICH MISTAKE CLAP FOUND, IN THIS PARSER'S OWN WORDS.
///
/// A word this command does not have and a word it has with no value after
/// it are different mistakes, and an agent told "unknown subcommand" about
/// `--to` goes looking for the wrong problem. clap distinguishes them —
/// `InvalidArgument` against `MissingValue` — so this asks rather than
/// guesses.
///
/// TWO EARLIER FORMS GUESSED. The first read whether the last word began
/// with `--`, which put `--recursive` at the end of a line in the same
/// bucket as a dangling `--to`. The second carried a list of which flags
/// take values, beside the params string that already says so — a second
/// copy of one fact, wrong the first time either moved.
fn usageError(err: anyerror) ParseError {
    return switch (err) {
        error.MissingValue => ParseError.MissingArgument,
        else => ParseError.UnknownSubcommand,
    };
}

/// `synapty put <path> --to <host> [--into <dir>]`
/// `synapty fetch <path> --from <host> [--into <dir>]`
///
/// The direction word differs because the sentence should read correctly
/// in both — `--to` for a push and `--from` for a pull name the same
/// field, and a single `--host` would make one of the two read wrong.
fn parseFile(allocator: Allocator, args: []const []const u8,
             verb: types.FileArgs.Verb) !Subcommand {
    const params = comptime clap.parseParamsComptime(
        \\    --to <str>    The other end — a host label the workbench knows.
        \\    --from <str>  The same field, spelled for a fetch.
        \\    --into <str>  Destination directory. Absent means the far end's home.
        \\-h, --help        Display help and exit.
        \\<str>
        \\
    );
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    const path = res.positionals[0] orelse return ParseError.MissingArgument;
    // A TRANSFER WITH NO OTHER END IS A USAGE ERROR, not a transfer to
    // nowhere. clap knows each flag is optional and cannot know that one
    // of these two is required, so the rule is stated here rather than
    // lost in the move.
    const host = res.args.to orelse res.args.from orelse
        return ParseError.MissingArgument;
    return .{ .file = .{
        .verb = verb,
        .path = path,
        .host = host,
        .into = res.args.into,
    } };
}

fn parseExposed(args: []const []const u8) !Subcommand {
    // --help anywhere, not only first: `exposed 8080 --help` printed the
    // status instead of the help ([[WI-2026-09-02-021]]).
    if (wantsHelp(args)) return ParseError.HelpRequested;
    if (args.len > 1) return ParseError.TooManyArguments;
    var out = types.ExposedArgs{};
    if (args.len > 0) {
        out.port = std.fmt.parseInt(u16, args[0], 10) catch return ParseError.MissingArgument;
    }
    return .{ .exposed = out };
}

/// `synapty expose <port> [--title <text>] [--at <path>]`
/// `synapty unexpose <port>`
fn parseView(allocator: Allocator, args: []const []const u8,
             verb: types.ViewArgs.Verb) !Subcommand {
    const params = comptime clap.parseParamsComptime(
        \\    --title <str>  What to call it — the agent's own words.
        \\    --at <str>     A path on the service, so the human lands where the work is.
        \\-h, --help         Display help and exit.
        \\<str>
        \\
    );
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    const text = res.positionals[0] orelse return ParseError.MissingArgument;
    // A PORT IS A NUMBER AND NEVER ZERO. clap's `<str>` takes the word;
    // what it means is this command's business, and "0" reaching a
    // forward would be a port nobody can serve.
    const port = std.fmt.parseInt(u16, text, 10) catch return ParseError.MissingArgument;
    if (port == 0) return ParseError.MissingArgument;

    return .{ .view = .{ .verb = verb, .port = port, .title = res.args.title, .at = res.args.at } };
}

fn parsePresent(allocator: Allocator, args: []const []const u8) !Subcommand {
    const params = comptime clap.parseParamsComptime(
        \\    --title <str>  What to call it — the agent's own words.
        \\-h, --help         Display help and exit.
        \\<str>
        \\
    );
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch |err| return usageError(err);
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    const path = res.positionals[0] orelse return ParseError.MissingArgument;
    // A PRESENTED ARTIFACT HAS NO PORT; the field is shared with expose.
    return .{ .view = .{ .verb = .present, .port = 0, .path = path, .title = res.args.title } };
}

/// `synapty ask "<question>" [--option A --option B] [--timeout <secs>]`
/// NOT MOVED ONTO CLAP, AND THAT IS THE DECISION RATHER THAN AN OMISSION.
///
/// `put`, `expose` and `present` moved because each was hand-walking its
/// arguments and each had to get `--help` right on its own — seven sites
/// did not. This one repeats a flag, which clap answers with an allocated
/// slice, and that would put `OutOfMemory` in the error set of a parser
/// whose own note says it stays free of it: the option count is bounded by
/// what a badge can present, so an inline buffer is not an optimisation
/// here but the reason the failure mode does not exist.
///
/// Finishing the migration for symmetry would trade a property this code
/// states for a consistency nothing asked for.
fn parseAsk(args: []const []const u8) !Subcommand {
    if (args.len == 0) return ParseError.MissingArgument;
    if (wantsHelp(args)) return ParseError.HelpRequested;

    // NO ALLOCATION: the option set is bounded by what a badge can present,
    // so it fits an inline buffer and the parser keeps its error set free
    // of OutOfMemory.
    var out = types.AskArgs{ .question = args[0] };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--option")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            if (out.option_count >= types.AskArgs.max_options) return ParseError.TooManyArguments;
            out.options_buf[out.option_count] = args[i];
            out.option_count += 1;
        } else if (mem.eql(u8, args[i], "--timeout")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingArgument;
            out.timeout_secs = std.fmt.parseInt(u32, args[i], 10) catch return ParseError.MissingArgument;
        } else {
            return ParseError.UnknownSubcommand;
        }
    }
    return .{ .ask = out };
}

fn parseExec(allocator: Allocator, args: []const []const u8) !Subcommand {
    _ = allocator;
    if (args.len == 0) return ParseError.MissingSubcommand;
    if (wantsHelp(args)) return ParseError.HelpRequested;

    const verb: types.ExecArgs.Verb = if (mem.eql(u8, args[0], "open"))
        .open
    else if (mem.eql(u8, args[0], "run"))
        .run
    else if (mem.eql(u8, args[0], "wait-output"))
        .wait_output
    else if (mem.eql(u8, args[0], "read"))
        .read
    else if (mem.eql(u8, args[0], "close"))
        .close
    else
        return ParseError.UnknownSubcommand;

    var out = types.ExecArgs{ .verb = verb };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const eat = struct {
            fn next(idx: *usize, arr: []const []const u8) ![]const u8 {
                idx.* += 1;
                if (idx.* >= arr.len) return ParseError.MissingArgument;
                return arr[idx.*];
            }
        }.next;
        if (mem.eql(u8, a, "--pane")) {
            out.pane = try eat(&i, args);
        } else if (mem.eql(u8, a, "--cmd")) {
            out.command = try eat(&i, args);
        } else if (mem.eql(u8, a, "--follow-up")) {
            out.follow_up = true;
        } else if (mem.eql(u8, a, "--cwd")) {
            out.cwd = try eat(&i, args);
        } else if (mem.eql(u8, a, "--pattern")) {
            out.pattern = try eat(&i, args);
        } else if (mem.eql(u8, a, "--timeout")) {
            out.timeout_secs = std.fmt.parseInt(u32, try eat(&i, args), 10) catch return ParseError.MissingArgument;
        } else if (mem.eql(u8, a, "--rows")) {
            out.rows = std.fmt.parseInt(u32, try eat(&i, args), 10) catch return ParseError.MissingArgument;
        } else {
            return ParseError.UnknownSubcommand;
        }
    }
    return .{ .exec = out };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "put and fetch name the same field with the word that reads correctly" {
    const a = testing.allocator;
    const push = try parseArgs(a, &.{ "put", "out.tar", "--to", "builder" });
    try testing.expectEqual(types.FileArgs.Verb.put, push.file.verb);
    try testing.expectEqualStrings("out.tar", push.file.path);
    try testing.expectEqualStrings("builder", push.file.host);
    try testing.expect(push.file.into == null);

    const pull = try parseArgs(a, &.{ "fetch", "logs/latest", "--from", "builder", "--into", "/tmp" });
    try testing.expectEqual(types.FileArgs.Verb.fetch, pull.file.verb);
    try testing.expectEqualStrings("builder", pull.file.host);
    try testing.expectEqualStrings("/tmp", pull.file.into.?);
}

test "a transfer with no other end is a usage error, not a transfer to nowhere" {
    const a = testing.allocator;
    try testing.expectError(ParseError.MissingArgument, parseArgs(a, &.{ "put", "out.tar" }));
    try testing.expectError(ParseError.MissingArgument, parseArgs(a, &.{"put"}));
    // A flag that eats the next token must not silently take the end of argv.
    try testing.expectError(ParseError.MissingArgument, parseArgs(a, &.{ "put", "out.tar", "--to" }));
}

test "an unknown flag is refused rather than ignored" {
    const a = testing.allocator;
    try testing.expectError(ParseError.UnknownSubcommand,
        parseArgs(a, &.{ "put", "out.tar", "--to", "builder", "--recursive" }));
}

test "one option too many is one option too many, not an unknown subcommand" {
    const a = testing.allocator;
    // Eight is the bound and eight is fine.
    const eight = parseArgs(a, &.{
        "ask",       "Deploy?", "--option", "a", "--option", "b", "--option", "c",
        "--option",  "d",       "--option", "e", "--option", "f", "--option", "g",
        "--option",  "h",
    });
    try testing.expect(eight != error.TooManyArguments);

    // THE NINTH IS THE CALLER'S MISTAKE, and the message they read has to
    // be about the mistake they made. `ask` is a real subcommand and
    // saying it is unknown sends an agent looking in the wrong place.
    try testing.expectError(ParseError.TooManyArguments, parseArgs(a, &.{
        "ask",      "Deploy?", "--option", "a", "--option", "b", "--option", "c",
        "--option", "d",       "--option", "e", "--option", "f", "--option", "g",
        "--option", "h",       "--option", "i",
    }));
}

test "every subcommand the bar names is one the parser accepts" {
    // An arena, because a bare verb that parses successfully may allocate
    // and the point here is the verb, not its cleanup.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for (types.subcommands) |sc| {
        const result = parseArgs(a, &.{sc.name});
        if (result) |_| {
            // Recognised and complete on its own.
        } else |err| {
            // MissingArgument is recognition too: the verb was understood
            // and found wanting. UnknownSubcommand is the failure — a name
            // the front door offers and the parser refuses.
            try testing.expect(err != ParseError.UnknownSubcommand);
        }
    }
}

test "every subcommand says what it is for, and says it once" {
    // The front door named nine of twenty-nine, and every verb the agent
    // skills teach — ask, put, send, recv, exec, wait — was missing. A
    // name with no summary would be back in that state for one row.
    for (types.subcommands) |sc| {
        try testing.expect(sc.summary.len > 0);
        // Lower case and no full stop: it is a list entry, not a sentence,
        // and one row shouting would be the row nobody trusts.
        try testing.expect(sc.summary[0] >= 'a' and sc.summary[0] <= 'z');
        try testing.expect(sc.summary[sc.summary.len - 1] != '.');
    }
}

test "a subcommand's flags are described where they are parsed" {
    // The descriptions existed and nothing printed them: seventeen parse
    // functions carried zig-clap parameter text that `clap.help` never
    // saw. They are now one string, parsed from and printed from, so a
    // flag cannot be documented differently from how it parses.
    for (types.subcommands) |sc| {
        if (sc.params.len == 0) continue;
        // Every named flag carries a description — the whole point of
        // keeping the text rather than the parsed shape.
        try testing.expect(mem.indexOf(u8, sc.params, "--help") != null);
    }
}

// EVERY SUBCOMMAND ANSWERS `--help`, INCLUDING THE ONES WITH NO FLAGS OF
// THEIR OWN.
//
// The check above skips a subcommand with no `params`, which is exactly
// the shape that dispatches its own sub-actions — and `channel` answered
// "unknown subcommand" to `--help` for that reason, the one command the
// guard existed for being the one it stepped over. And answered wherever
// it appears, not only as the first word — `wantsHelp` says why.
test "help is help wherever it appears in a command" {
    const allocator = testing.allocator;
    const cases = [_][]const []const u8{
        &.{ "expose", "8080", "--help" },
        &.{ "unexpose", "8080", "--help" },
        &.{ "present", "8080", "--help" },
        &.{ "put", "x", "--help" },
        &.{ "fetch", "x", "--help" },
        &.{ "exec", "open", "--help" },
        &.{ "channel", "create", "--help" },
    };
    for (cases) |argv| {
        try testing.expectError(ParseError.HelpRequested, parseArgs(allocator, argv));
    }
}

test "asking any subcommand for help is answered as help" {
    const allocator = testing.allocator;
    inline for (types.subcommands) |sc| {
        const argv = [_][]const u8{ sc.name, "--help" };
        const err = parseArgs(allocator, &argv);
        try testing.expectError(ParseError.HelpRequested, err);
    }
}

test "the words the help offers are the words the parser takes" {
    // ONE FACT, TWO READERS. The usage line is rendered from the action
    // enum ([[types.actionList]]) and the parser resolves against the same
    // enum ([[types.actionFrom]]), so the help cannot name a word the
    // parser refuses. It did: `synapty hooks --help` told an agent to run
    // `hooks show`, which parseHooks answers with UnknownSubcommand
    // ([[WI-2026-08-30-005]]).
    const alloc = std.testing.allocator;

    inline for (@typeInfo(types.HooksArgs.Action).@"enum".fields) |f| {
        const word = comptime types.actionName(f.name);
        try std.testing.expect(std.mem.indexOf(u8, comptime types.usageFor("hooks"), word) != null);
        const parsed = try parseHooks(alloc, &.{ word, "claude" });
        try std.testing.expectEqual(@field(types.HooksArgs.Action, f.name), parsed.hooks.action);
    }

    inline for (@typeInfo(types.GithubArgs.Action).@"enum".fields) |f| {
        const word = comptime types.actionName(f.name);
        try std.testing.expect(std.mem.indexOf(u8, comptime types.usageFor("github"), word) != null);
    }

    // A word neither names is refused rather than guessed at.
    try std.testing.expectError(ParseError.UnknownSubcommand, parseHooks(alloc, &.{ "show", "claude" }));
}

test "a flag no subcommand has is refused rather than silently ignored" {
    // `skills install --harness codex` was accepted and the flag dropped,
    // so a caller believed it had installed to one harness when it had
    // installed to every one detected. The flag never existed; the usage
    // string invented it ([[WI-2026-08-30-005]]).
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        ParseError.UnknownSubcommand,
        parseSkills(alloc, &.{ "install", "--harness", "codex" }),
    );
    const ok = try parseSkills(alloc, &.{"install"});
    try std.testing.expectEqual(types.SkillsArgs.Action.install, ok.skills.action);
    try std.testing.expect(std.mem.indexOf(u8, comptime types.usageFor("skills"), "harness") == null);
}

// WHAT THE FILE, VIEW, PRESENT AND ASK GRAMMARS ACCEPT, PINNED. These
// were hand-written and have since moved onto clap; the tests are what
// made each move a refactor rather than a rewrite — they say what the
// grammars take, positional order and repeated flags included, so a
// change to any of it fails here instead of in somebody's terminal.

test "put and fetch: a path, the other end, and where it lands" {
    const a = testing.allocator;

    const push = try parseArgs(a, &.{ "put", "./out.tar", "--to", "prod-1" });
    try testing.expectEqual(types.FileArgs.Verb.put, push.file.verb);
    try testing.expectEqualStrings("./out.tar", push.file.path);
    try testing.expectEqualStrings("prod-1", push.file.host);
    try testing.expect(push.file.into == null);

    // `--to` and `--from` are the SAME field: which one reads naturally
    // depends on the direction, and the parser takes either for either.
    const pull = try parseArgs(a, &.{ "fetch", "/var/log/app.log", "--from", "prod-1", "--into", "/tmp" });
    try testing.expectEqual(types.FileArgs.Verb.fetch, pull.file.verb);
    try testing.expectEqualStrings("/var/log/app.log", pull.file.path);
    try testing.expectEqualStrings("prod-1", pull.file.host);
    try testing.expectEqualStrings("/tmp", pull.file.into.?);
}

test "put: the path is positional and must come first" {
    const a = testing.allocator;
    try testing.expectError(ParseError.MissingArgument, parseArgs(a, &.{"put"}));
    // A FLAG WHERE THE PATH BELONGS IS REFUSED. Which error it is called
    // moved when the parser did — clap reports the missing positional
    // rather than an unknown subcommand, which is the truer of the two —
    // and what the test pins is that it is still refused.
    try testing.expectError(ParseError.MissingArgument,
        parseArgs(a, &.{ "put", "--to", "prod-1" }));
}

test "put: an unknown flag is refused rather than ignored" {
    const a = testing.allocator;
    // An unknown word and a dangling flag are told apart (`usageError`).
    try testing.expectError(ParseError.UnknownSubcommand,
        parseArgs(a, &.{ "put", "x", "--nowhere", "y" }));
    try testing.expectError(ParseError.MissingArgument,
        parseArgs(a, &.{ "put", "x", "--to" }));
}

test "expose and unexpose: a port, and what to call it" {
    const a = testing.allocator;

    const on = try parseArgs(a, &.{ "expose", "8080", "--title", "dev server" });
    try testing.expectEqual(types.ViewArgs.Verb.expose, on.view.verb);
    try testing.expectEqual(@as(u16, 8080), on.view.port);
    try testing.expectEqualStrings("dev server", on.view.title.?);

    const deep = try parseArgs(a, &.{ "expose", "8888", "--at", "/lab?token=abc" });
    try testing.expectEqualStrings("/lab?token=abc", deep.view.at.?);

    const off = try parseArgs(a, &.{ "unexpose", "8080" });
    try testing.expectEqual(types.ViewArgs.Verb.withdraw, off.view.verb);
    try testing.expectEqual(@as(u16, 8080), off.view.port);
}

test "expose: a port is a number, and never zero" {
    const a = testing.allocator;
    try testing.expectError(ParseError.MissingArgument, parseArgs(a, &.{ "expose", "http" }));
    try testing.expectError(ParseError.MissingArgument, parseArgs(a, &.{ "expose", "0" }));
    try testing.expectError(ParseError.MissingArgument, parseArgs(a, &.{ "expose", "70000" }));
}

test "present: a path, and the agent's own words for it" {
    const a = testing.allocator;

    const bare = try parseArgs(a, &.{ "present", "./out/diagram.png" });
    try testing.expectEqual(types.ViewArgs.Verb.present, bare.view.verb);
    try testing.expectEqualStrings("./out/diagram.png", bare.view.path.?);
    try testing.expect(bare.view.title == null);
    try testing.expectEqual(@as(u16, 0), bare.view.port);

    const titled = try parseArgs(a, &.{ "present", "./report.html", "--title", "coverage" });
    try testing.expectEqualStrings("coverage", titled.view.title.?);
}

test "ask: a question, its options in order, and how long to wait" {
    const a = testing.allocator;

    const q = try parseArgs(a, &.{ "ask", "ship it?", "--option", "yes", "--option", "no" });
    try testing.expectEqualStrings("ship it?", q.ask.question);
    try testing.expectEqual(@as(usize, 2), q.ask.option_count);
    // THE ORDER IS THE AGENT'S. A human reads them as offered, so a parser
    // that sorted or deduplicated them would be answering a different
    // question from the one asked.
    try testing.expectEqualStrings("yes", q.ask.options_buf[0]);
    try testing.expectEqualStrings("no", q.ask.options_buf[1]);

    const timed = try parseArgs(a, &.{ "ask", "now?", "--timeout", "30" });
    try testing.expectEqual(@as(u32, 30), timed.ask.timeout_secs);
}

test "ask: a question with no options is still a question" {
    const a = testing.allocator;
    const q = try parseArgs(a, &.{ "ask", "anything?" });
    try testing.expectEqualStrings("anything?", q.ask.question);
    try testing.expectEqual(@as(usize, 0), q.ask.option_count);
    // AND CARRIES THE DEFAULT PATIENCE rather than none, because "wait
    // forever" is not a thing this primitive offers.
    try testing.expectEqual(@as(u32, 300), q.ask.timeout_secs);
}

// TRAILING WORDS ARE REFUSED, NOT IGNORED, and --help is help before any
// argument is read ([[WI-2026-09-02-021]]). Each of these once passed:
// `identify junk` identified, `task update 5 open junk` updated, and
// `task update --help` reported a missing argument because parseInt ran
// before anyone looked for the word.
test "the hand-written parsers refuse trailing junk and answer --help first" {
    const allocator = testing.allocator;
    const junk = [_][]const []const u8{
        &.{ "identify", "junk" },
        &.{ "activity", "junk" },
        &.{ "hook-event", "claude", "junk" },
        &.{ "exposed", "8080", "junk" },
        &.{ "github", "logout", "junk" },
        &.{ "task", "claim", "5", "junk" },
        &.{ "task", "update", "5", "open", "junk" },
        &.{ "task", "comment", "5", "body", "junk" },
    };
    for (junk) |argv| {
        try testing.expectError(ParseError.TooManyArguments, parseArgs(allocator, argv));
    }
    const help = [_][]const []const u8{
        &.{ "exposed", "8080", "--help" },
        &.{ "task", "update", "--help" },
        &.{ "task", "comment", "--help" },
        &.{ "task", "claim", "--help" },
    };
    for (help) |argv| {
        try testing.expectError(ParseError.HelpRequested, parseArgs(allocator, argv));
    }
}

// A KNOWN FLAG WITH NO VALUE IS A MISSING ARGUMENT; A WORD THE COMMAND
// DOES NOT HAVE IS NOT. clap tells them apart and now every clap-backed
// parser asks, not only file and view.
test "every clap-backed parser distinguishes a dangling flag from an unknown one" {
    const allocator = testing.allocator;
    try testing.expectError(ParseError.MissingArgument, parseArgs(allocator, &.{ "notify", "--state" }));
    try testing.expectError(ParseError.MissingArgument, parseArgs(allocator, &.{ "register", "--tool" }));
    try testing.expectError(ParseError.UnknownSubcommand, parseArgs(allocator, &.{ "send", "--bogus", "x" }));
    try testing.expectError(ParseError.MissingArgument, parseArgs(allocator, &.{ "attach", "--client" }));
    try testing.expectError(ParseError.UnknownSubcommand, parseArgs(allocator, &.{ "sessions", "--bogus" }));
}
