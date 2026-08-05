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

    if (mem.eql(u8, sub, "register")) return parseRegister(allocator, rest);
    if (mem.eql(u8, sub, "send")) return parseSend(allocator, rest);
    if (mem.eql(u8, sub, "recv")) return parseRecv(allocator, rest);
    if (mem.eql(u8, sub, "agents")) return parseNoArgs(allocator, rest, .agents);
    if (mem.eql(u8, sub, "run")) return parseRun(allocator, rest);
    if (mem.eql(u8, sub, "hub")) return parseHub(allocator, rest);
    if (mem.eql(u8, sub, "channel")) return parseChannel(allocator, rest);
    if (mem.eql(u8, sub, "mcp-serve")) return parseMcpServe(allocator, rest);
    if (mem.eql(u8, sub, "github")) return parseGithub(allocator, rest);
    if (mem.eql(u8, sub, "task")) return parseTask(allocator, rest);
    if (mem.eql(u8, sub, "skills")) return parseSkills(allocator, rest);

    return ParseError.UnknownSubcommand;
}

// ---------------------------------------------------------------------------
// skills subcommand (RFC-0003 C-SKILLS)
// ---------------------------------------------------------------------------

fn parseSkills(allocator: Allocator, args: []const []const u8) !Subcommand {
    _ = allocator;
    if (args.len == 0) return ParseError.MissingSubcommand;
    if (mem.eql(u8, args[0], "--help") or mem.eql(u8, args[0], "-h")) return ParseError.HelpRequested;
    if (!mem.eql(u8, args[0], "install")) return ParseError.UnknownSubcommand;
    if (args.len > 1 and (mem.eql(u8, args[1], "--help") or mem.eql(u8, args[1], "-h"))) {
        return ParseError.HelpRequested;
    }
    return .{ .skills = .{ .install = true } };
}

// ---------------------------------------------------------------------------
// github subcommand (RFC-0003 C-AUTH)
// ---------------------------------------------------------------------------

fn parseGithub(allocator: Allocator, args: []const []const u8) !Subcommand {
    if (args.len == 0) return ParseError.MissingSubcommand;
    if (mem.eql(u8, args[0], "--help") or mem.eql(u8, args[0], "-h")) return ParseError.HelpRequested;
    if (!mem.eql(u8, args[0], "login")) return ParseError.UnknownSubcommand;
    const rest = args[1..];

    const params = comptime clap.parseParamsComptime(
        \\    --owner <str>  Hub repo owner (optional; prompts if omitted).
        \\    --repo <str>   Hub repo name (optional; prompts if omitted).
        \\    --token <str>  Fine-grained PAT (optional; prompts if omitted).
        \\-h, --help        Display help and exit.
        \\
    );
    var iter = clap.args.SliceIterator{ .args = rest };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch return ParseError.MissingArgument;
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    return .{ .github = .{
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
        }) catch return ParseError.MissingArgument;
        defer res.deinit();
        if (res.args.help != 0) return ParseError.HelpRequested;
        return .{ .task = .{ .list = .{ .project = res.args.project, .state = res.args.state } } };
    }
    if (mem.eql(u8, action, "claim")) {
        if (rest.len < 1) return ParseError.MissingArgument;
        if (mem.eql(u8, rest[0], "--help") or mem.eql(u8, rest[0], "-h")) return ParseError.HelpRequested;
        const number = std.fmt.parseInt(u32, rest[0], 10) catch return ParseError.MissingArgument;
        return .{ .task = .{ .claim = .{ .number = number } } };
    }
    if (mem.eql(u8, action, "update")) {
        if (rest.len < 2) return ParseError.MissingArgument;
        const number = std.fmt.parseInt(u32, rest[0], 10) catch return ParseError.MissingArgument;
        return .{ .task = .{ .update = .{ .number = number, .status = rest[1] } } };
    }
    if (mem.eql(u8, action, "comment")) {
        if (rest.len < 2) return ParseError.MissingArgument;
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
        }) catch return ParseError.MissingArgument;
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

fn parseRegister(allocator: Allocator, args: []const []const u8) !Subcommand {
    const params = comptime clap.parseParamsComptime(
        \\    --tool <str>     Tool name (required).
        \\    --project <str>  Project path.
        \\    --session <str>  Session identifier.
        \\-h, --help           Display help and exit.
        \\
    );
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch return ParseError.MissingArgument;
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    const tool = res.args.tool orelse return ParseError.MissingArgument;
    return .{ .ipc = .{
        .action = .register,
        .args = .{ .register = .{ .tool = tool, .project = res.args.project, .session = res.args.session } },
    } };
}

fn parseSend(allocator: Allocator, args: []const []const u8) !Subcommand {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display help and exit.
        \\<str>
        \\<str>
        \\
    );
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch return ParseError.MissingArgument;
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
    const params = comptime clap.parseParamsComptime(
        \\    --wait  Wait for incoming messages.
        \\-h, --help  Display help and exit.
        \\
    );
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch return ParseError.MissingArgument;
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    return .{ .ipc = .{
        .action = .recv,
        .args = .{ .recv = .{ .wait = res.args.wait != 0 } },
    } };
}

fn parseRun(allocator: Allocator, args: []const []const u8) !Subcommand {
    // Check for --help before scanning for -- (so `run --help` works without --).
    for (args) |arg| {
        if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) return ParseError.HelpRequested;
        if (mem.eql(u8, arg, "--")) break;
    }

    // Require explicit -- separator between flags and child command.
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

    const params = comptime clap.parseParamsComptime(
        \\    --id <str>   Agent identifier (required).
        \\    --hub <str>  Hub address as host:port (default: 127.0.0.1:9000).
        \\-h, --help       Display help and exit.
        \\
    );
    var iter = clap.args.SliceIterator{ .args = flag_args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch return ParseError.MissingArgument;
    defer res.deinit();

    const agent_id = res.args.id orelse return ParseError.MissingArgument;

    // Parse optional --hub host:port, default to 127.0.0.1:9000.
    var hub_addr: []const u8 = "127.0.0.1";
    var hub_port: u16 = 9000;
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
    } };
}

/// Standalone Hub for development/testing [[ADR-0004]].
fn parseHub(allocator: Allocator, args: []const []const u8) !Subcommand {
    const params = comptime clap.parseParamsComptime(
        \\    --port <u16>  Listen port (default: 9000).
        \\-h, --help        Display help and exit.
        \\
    );
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch return ParseError.MissingArgument;
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    return .{ .hub = .{ .port = res.args.port orelse 9000 } };
}

/// Parser for subcommands with no arguments (agents, channel list).
/// Only checks for --help.
fn parseNoArgs(allocator: Allocator, args: []const []const u8, action: @import("protocol").IpcAction) !Subcommand {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display help and exit.
        \\
    );
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch return ParseError.MissingArgument;
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;

    return switch (action) {
        .agents => .{ .ipc = .{ .action = .agents, .args = .agents } },
        .channel_list => .{ .ipc = .{ .action = .channel_list, .args = .channel_list } },
        else => ParseError.UnknownSubcommand,
    };
}

fn parseMcpServe(allocator: Allocator, args: []const []const u8) !Subcommand {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display help and exit.
        \\
    );
    var iter = clap.args.SliceIterator{ .args = args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch return ParseError.MissingArgument;
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    return .mcp_serve;
}

fn parseChannel(allocator: Allocator, args: []const []const u8) !Subcommand {
    if (args.len == 0) return ParseError.MissingArgument;
    const action = args[0];
    const rest = args[1..];

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
    }) catch return ParseError.MissingArgument;
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
    }) catch return ParseError.MissingArgument;
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
    }) catch return ParseError.MissingArgument;
    defer res.deinit();

    if (res.args.help != 0) return ParseError.HelpRequested;
    const channel = res.positionals[0] orelse return ParseError.MissingArgument;
    return .{ .ipc = .{
        .action = .channel_leave,
        .args = .{ .channel_leave = .{ .channel = channel } },
    } };
}
