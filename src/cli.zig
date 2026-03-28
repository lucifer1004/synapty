const std = @import("std");
const net = std.net;
const mem = std.mem;
const json = std.json;
const protocol = @import("protocol");
const ipc = @import("ipc");
const run = @import("run");
const mcp = @import("mcp");
const Allocator = mem.Allocator;
const log = std.log.scoped(.cli);

// ---------------------------------------------------------------------------
// Sub-module re-exports
// ---------------------------------------------------------------------------

const commands = @import("cli/commands.zig");
const transport = @import("cli/transport.zig");

// ---------------------------------------------------------------------------
// Shared types — defined in cli/types.zig, re-exported here for callers
// ---------------------------------------------------------------------------

pub const types = @import("cli/types.zig");
pub const IpcSubcommand = types.IpcSubcommand;
pub const IpcArgs = types.IpcArgs;
pub const Subcommand = types.Subcommand;
pub const RegisterArgs = types.RegisterArgs;
pub const SendArgs = types.SendArgs;
pub const RecvArgs = types.RecvArgs;
pub const RunArgs = types.RunArgs;
pub const ChannelCreateArgs = types.ChannelCreateArgs;
pub const ChannelInviteArgs = types.ChannelInviteArgs;
pub const ChannelLeaveArgs = types.ChannelLeaveArgs;
pub const ParseError = types.ParseError;

// ---------------------------------------------------------------------------
// Arg parsing
// ---------------------------------------------------------------------------

pub const parseArgs = @import("cli/parse.zig").parseArgs;

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stderr = std.fs.File.stderr();

    // Collect args, skipping argv[0] (program name).
    var arg_list = std.ArrayList([]const u8).empty;
    defer arg_list.deinit(allocator);

    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip program name
    while (args_iter.next()) |arg| {
        try arg_list.append(allocator, arg);
    }

    const sub = parseArgs(arg_list.items) catch |err| {
        switch (err) {
            ParseError.MissingSubcommand => {
                try stderr.writeAll("usage: synapty <register|send|recv|agents|channel|run|mcp-serve> [args]\n");
            },
            ParseError.UnknownSubcommand => {
                try stderr.writeAll("error: unknown subcommand\n");
            },
            ParseError.MissingArgument => {
                try stderr.writeAll("error: missing required argument\n");
            },
        }
        std.process.exit(1);
    };

    switch (sub) {
        .ipc => |ipc_sub| switch (ipc_sub.action) {
            .register => try commands.runRegister(allocator, ipc_sub.args.register),
            .send => try commands.runSend(allocator, ipc_sub.args.send),
            .recv => try commands.runRecv(allocator, ipc_sub.args.recv),
            .agents => try commands.runAgents(allocator),
            .channel_create, .channel_invite, .channel_leave, .channel_list => try commands.runChannel(allocator, ipc_sub.action, ipc_sub.args),
        },
        .run => |a| {
            var server = try run.RunServer.init(allocator, a.agent_id, transport.hub_addr, transport.hub_port);
            defer server.deinit();
            try server.run(a.child_argv);
        },
        .mcp_serve => {
            try mcp.runMcp(allocator);
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseArgs: missing subcommand returns error" {
    const result = parseArgs(&.{});
    try std.testing.expectError(ParseError.MissingSubcommand, result);
}

test "parseArgs: unknown subcommand returns error" {
    const result = parseArgs(&.{"bogus"});
    try std.testing.expectError(ParseError.UnknownSubcommand, result);
}

test "parseArgs: register subcommand" {
    const result = try parseArgs(&.{ "register", "--tool", "codex", "--project", "/path" });
    try std.testing.expectEqualStrings("codex", result.ipc.args.register.tool);
    try std.testing.expectEqualStrings("/path", result.ipc.args.register.project.?);
    try std.testing.expectEqual(protocol.IpcAction.register, result.ipc.action);
}

test "parseArgs: register missing --tool returns error" {
    const result = parseArgs(&.{"register"});
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: send subcommand" {
    const result = try parseArgs(&.{ "send", "agent-b", "hello world" });
    try std.testing.expectEqualStrings("agent-b", result.ipc.args.send.target);
    try std.testing.expectEqualStrings("hello world", result.ipc.args.send.text);
    try std.testing.expectEqual(protocol.IpcAction.send, result.ipc.action);
}

test "parseArgs: channel create subcommand" {
    const result = try parseArgs(&.{ "channel", "create", "design-review", "--description", "Auth redesign" });
    try std.testing.expectEqualStrings("design-review", result.ipc.args.channel_create.name);
    try std.testing.expectEqualStrings("Auth redesign", result.ipc.args.channel_create.description.?);
    try std.testing.expectEqual(protocol.IpcAction.channel_create, result.ipc.action);
}

test "parseArgs: channel invite subcommand" {
    const result = try parseArgs(&.{ "channel", "invite", "design-review", "agent-b" });
    try std.testing.expectEqualStrings("design-review", result.ipc.args.channel_invite.channel);
    try std.testing.expectEqualStrings("agent-b", result.ipc.args.channel_invite.agent_id);
    try std.testing.expectEqual(protocol.IpcAction.channel_invite, result.ipc.action);
}

test "parseArgs: channel list subcommand" {
    const result = try parseArgs(&.{ "channel", "list" });
    try std.testing.expectEqual(protocol.IpcAction.channel_list, result.ipc.action);
    try std.testing.expect(result.ipc.args == .channel_list);
}

test "parseArgs: send missing payload returns error" {
    const result = parseArgs(&.{ "send", "agent-b" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: recv without --wait" {
    const result = try parseArgs(&.{"recv"});
    try std.testing.expect(!result.ipc.args.recv.wait);
}

test "parseArgs: recv with --wait" {
    const result = try parseArgs(&.{ "recv", "--wait" });
    try std.testing.expect(result.ipc.args.recv.wait);
}

test "parseArgs: agents subcommand" {
    const result = try parseArgs(&.{"agents"});
    try std.testing.expectEqual(protocol.IpcAction.agents, result.ipc.action);
}

test "register envelope has correct fields for agent-id" {
    const env = protocol.makeRegisterEnvelope("test-agent", &.{});
    try std.testing.expectEqualStrings("register", env.@"type");
    try std.testing.expectEqualStrings("test-agent", env.source);
    try std.testing.expectEqualStrings("", env.target);
}

test "send envelope has correct source/target/payload fields" {
    const envelope = protocol.Envelope{
        .@"type" = "dm",
        .id = "send-0",
        .source = "cli-src",
        .target = "agent-b",
        .payload = json.Value{ .string = "hello" },
    };
    try std.testing.expectEqualStrings("dm", envelope.@"type");
    try std.testing.expectEqualStrings("cli-src", envelope.source);
    try std.testing.expectEqualStrings("agent-b", envelope.target);
    try std.testing.expectEqualStrings("hello", envelope.payload.string);
}

test "parseArgs: run subcommand with --id and -- child" {
    const result = try parseArgs(&.{ "run", "--id", "my-agent", "--", "bash", "-l" });
    try std.testing.expectEqualStrings("my-agent", result.run.agent_id);
    try std.testing.expectEqual(@as(usize, 2), result.run.child_argv.len);
    try std.testing.expectEqualStrings("bash", result.run.child_argv[0]);
    try std.testing.expectEqualStrings("-l", result.run.child_argv[1]);
}

test "parseArgs: mcp-serve subcommand" {
    const result = try parseArgs(&.{"mcp-serve"});
    try std.testing.expect(result == .mcp_serve);
}

test "parseArgs: run without --id returns error" {
    const result = parseArgs(&.{ "run", "--", "bash" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: run with --id but without -- returns error" {
    const result = parseArgs(&.{ "run", "--id", "foo" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: run with --id and -- but no child command returns error" {
    const result = parseArgs(&.{ "run", "--id", "foo", "--" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

// Pull in tests from sub-modules.
comptime {
    _ = @import("cli/commands.zig");
    _ = @import("cli/transport.zig");
}
