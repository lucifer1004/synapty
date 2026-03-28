const std = @import("std");
const mem = std.mem;
const types = @import("types.zig");
const Subcommand = types.Subcommand;
const ParseError = types.ParseError;

/// Parse process args (excluding argv[0]) into a Subcommand.
/// `args` is a slice of argument strings, not including the program name.
pub fn parseArgs(args: []const []const u8) ParseError!Subcommand {
    if (args.len == 0) return ParseError.MissingSubcommand;

    const sub = args[0];

    if (mem.eql(u8, sub, "register")) {
        // register --tool <t> [--project <p>] [--session <s>]
        var tool: ?[]const u8 = null;
        var project: ?[]const u8 = null;
        var session_val: ?[]const u8 = null;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (mem.eql(u8, args[i], "--tool")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingArgument;
                tool = args[i];
            } else if (mem.eql(u8, args[i], "--project")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingArgument;
                project = args[i];
            } else if (mem.eql(u8, args[i], "--session")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingArgument;
                session_val = args[i];
            }
        }
        if (tool == null) return ParseError.MissingArgument;
        return .{ .ipc = .{
            .action = .register,
            .args = .{ .register = .{ .tool = tool.?, .project = project, .session = session_val } },
        } };
    }

    if (mem.eql(u8, sub, "send")) {
        if (args.len < 3) return ParseError.MissingArgument;
        return .{ .ipc = .{
            .action = .send,
            .args = .{ .send = .{ .target = args[1], .text = args[2] } },
        } };
    }

    if (mem.eql(u8, sub, "recv")) {
        var wait = false;
        for (args[1..]) |arg| {
            if (mem.eql(u8, arg, "--wait")) wait = true;
        }
        return .{ .ipc = .{
            .action = .recv,
            .args = .{ .recv = .{ .wait = wait } },
        } };
    }

    if (mem.eql(u8, sub, "agents")) {
        return .{ .ipc = .{
            .action = .agents,
            .args = .agents,
        } };
    }

    if (mem.eql(u8, sub, "run")) {
        // Syntax: run --id <agent-id> -- <command> [args...]
        var agent_id: ?[]const u8 = null;
        var dash_dash_idx: ?usize = null;

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (mem.eql(u8, args[i], "--")) {
                dash_dash_idx = i;
                break;
            } else if (mem.eql(u8, args[i], "--id")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingArgument;
                agent_id = args[i];
            }
        }

        if (agent_id == null) return ParseError.MissingArgument;
        if (dash_dash_idx == null) return ParseError.MissingArgument;

        const sep = dash_dash_idx.?;
        if (sep + 1 >= args.len) return ParseError.MissingArgument;

        return .{ .run = .{
            .agent_id = agent_id.?,
            .child_argv = args[sep + 1 ..],
        } };
    }

    if (mem.eql(u8, sub, "channel")) {
        if (args.len < 2) return ParseError.MissingArgument;
        const channel_sub = args[1];
        if (mem.eql(u8, channel_sub, "create")) {
            if (args.len < 3) return ParseError.MissingArgument;
            var desc: ?[]const u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (mem.eql(u8, args[i], "--description")) {
                    i += 1;
                    if (i >= args.len) return ParseError.MissingArgument;
                    desc = args[i];
                }
            }
            return .{ .ipc = .{
                .action = .channel_create,
                .args = .{ .channel_create = .{ .name = args[2], .description = desc } },
            } };
        } else if (mem.eql(u8, channel_sub, "invite")) {
            if (args.len < 4) return ParseError.MissingArgument;
            return .{ .ipc = .{
                .action = .channel_invite,
                .args = .{ .channel_invite = .{ .channel = args[2], .agent_id = args[3] } },
            } };
        } else if (mem.eql(u8, channel_sub, "leave")) {
            if (args.len < 3) return ParseError.MissingArgument;
            return .{ .ipc = .{
                .action = .channel_leave,
                .args = .{ .channel_leave = .{ .channel = args[2] } },
            } };
        } else if (mem.eql(u8, channel_sub, "list")) {
            return .{ .ipc = .{
                .action = .channel_list,
                .args = .channel_list,
            } };
        }
        return ParseError.UnknownSubcommand;
    }

    if (mem.eql(u8, sub, "mcp-serve")) {
        return .mcp_serve;
    }

    return ParseError.UnknownSubcommand;
}
