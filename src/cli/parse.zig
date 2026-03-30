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

    if (mem.eql(u8, sub, "register")) return parseRegister(allocator, rest);
    if (mem.eql(u8, sub, "send")) return parseSend(allocator, rest);
    if (mem.eql(u8, sub, "recv")) return parseRecv(allocator, rest);
    if (mem.eql(u8, sub, "agents")) return .{ .ipc = .{ .action = .agents, .args = .agents } };
    if (mem.eql(u8, sub, "run")) return parseRun(allocator, rest);
    if (mem.eql(u8, sub, "channel")) return parseChannel(allocator, rest);
    if (mem.eql(u8, sub, "mcp-serve")) return .mcp_serve;

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
        \\    --id <str>  Agent identifier (required).
        \\-h, --help      Display help and exit.
        \\
    );
    var iter = clap.args.SliceIterator{ .args = flag_args };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .allocator = allocator,
    }) catch return ParseError.MissingArgument;
    defer res.deinit();

    const agent_id = res.args.id orelse return ParseError.MissingArgument;
    return .{ .run = .{ .agent_id = agent_id, .child_argv = child_argv } };
}

fn parseChannel(allocator: Allocator, args: []const []const u8) !Subcommand {
    if (args.len == 0) return ParseError.MissingArgument;
    const action = args[0];
    const rest = args[1..];

    if (mem.eql(u8, action, "create")) return parseChannelCreate(allocator, rest);
    if (mem.eql(u8, action, "invite")) return parseChannelInvite(allocator, rest);
    if (mem.eql(u8, action, "leave")) return parseChannelLeave(allocator, rest);
    if (mem.eql(u8, action, "list")) return .{ .ipc = .{ .action = .channel_list, .args = .channel_list } };

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
