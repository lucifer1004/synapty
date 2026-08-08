const std = @import("std");
const io_mod = @import("io");
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
const hub = @import("hub");

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
pub const HubArgs = types.HubArgs;
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

pub fn main(init: std.process.Init) !void {
    io_mod.install(init.io);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Collect args, skipping argv[0] (program name).
    var arg_list = std.ArrayList([]const u8).empty;
    defer arg_list.deinit(allocator);
    const argv = try init.minimal.args.toSlice(allocator);
    for (argv[1..]) |arg| {
        try arg_list.append(allocator, arg);
    }

    const sub = parseArgs(allocator, arg_list.items) catch |err| {
        switch (err) {
            ParseError.HelpRequested => {
                try io_mod.stdoutWriteAll("usage: synapty <task|agents|activity|github|skills|run|hub|mcp-serve> [args]\n");
                try io_mod.stdoutWriteAll("try 'synapty <subcommand> --help' for subcommand options\n");
                std.process.exit(0);
            },
            ParseError.MissingSubcommand => {
                try io_mod.stderrWriteAll("usage: synapty <task|agents|activity|github|skills|run|hub|mcp-serve> [args]\n");
            },
            ParseError.UnknownSubcommand => {
                try io_mod.stderrWriteAll("error: unknown subcommand\n");
            },
            ParseError.MissingArgument => {
                try io_mod.stderrWriteAll("error: missing required argument\n");
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
            var server = run.RunServer.init(allocator, a.agent_id, a.hub_addr, a.hub_port) catch |err| {
                try io_mod.stderrWriteAll("synapty run: init failed: ");
                try io_mod.stderrWriteAll(@errorName(err));
                var diag_buf: [128]u8 = undefined;
                const diag = std.fmt.bufPrint(&diag_buf, " (hub {s}:{d})\n", .{ a.hub_addr, a.hub_port }) catch "\n";
                try io_mod.stderrWriteAll(diag);
                std.process.exit(1);
            };
            defer server.deinit();
            server.run(a.child_argv) catch |err| {
                try io_mod.stderrWriteAll("synapty run: failed: ");
                try io_mod.stderrWriteAll(@errorName(err));
                try io_mod.stderrWriteAll("\n");
                std.process.exit(1);
            };
        },
        .hub => |h| {
            var hub_server = try hub.HubServer.initWithAddress("0.0.0.0", h.port);
            defer hub_server.deinit();
            try hub_server.run();
        },
        .mcp_serve => {
            try mcp.runMcp(allocator);
        },
        .github => |g| {
            try commands.runGithubLogin(allocator, g);
        },
        .skills => |sk| {
            if (sk.install) try commands.runSkillsInstall(allocator);
        },
        .activity => {
            try commands.runActivity(allocator);
        },
        .task => |t| switch (t) {
            .list => |a| try commands.runTaskList(allocator, a),
            .claim => |a| try commands.runTaskClaim(allocator, a),
            .update => |a| try commands.runTaskUpdate(allocator, a),
            .comment => |a| try commands.runTaskComment(allocator, a),
            .create => |a| try commands.runTaskCreate(allocator, a),
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseArgs: missing subcommand returns error" {
    const result = parseArgs(std.testing.allocator, &.{});
    try std.testing.expectError(ParseError.MissingSubcommand, result);
}

test "parseArgs: unknown subcommand returns error" {
    const result = parseArgs(std.testing.allocator, &.{"bogus"});
    try std.testing.expectError(ParseError.UnknownSubcommand, result);
}

test "parseArgs: register subcommand" {
    const result = try parseArgs(std.testing.allocator, &.{ "register", "--tool", "codex", "--project", "/path" });
    try std.testing.expectEqualStrings("codex", result.ipc.args.register.tool);
    try std.testing.expectEqualStrings("/path", result.ipc.args.register.project.?);
    try std.testing.expectEqual(protocol.IpcAction.register, result.ipc.action);
}

test "parseArgs: register missing --tool returns error" {
    const result = parseArgs(std.testing.allocator, &.{"register"});
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: send subcommand" {
    const result = try parseArgs(std.testing.allocator, &.{ "send", "agent-b", "hello world" });
    try std.testing.expectEqualStrings("agent-b", result.ipc.args.send.target);
    try std.testing.expectEqualStrings("hello world", result.ipc.args.send.text);
    try std.testing.expectEqual(protocol.IpcAction.send, result.ipc.action);
}

test "parseArgs: channel create subcommand" {
    const result = try parseArgs(std.testing.allocator, &.{ "channel", "create", "design-review", "--description", "Auth redesign" });
    try std.testing.expectEqualStrings("design-review", result.ipc.args.channel_create.name);
    try std.testing.expectEqualStrings("Auth redesign", result.ipc.args.channel_create.description.?);
    try std.testing.expectEqual(protocol.IpcAction.channel_create, result.ipc.action);
}

test "parseArgs: channel invite subcommand" {
    const result = try parseArgs(std.testing.allocator, &.{ "channel", "invite", "design-review", "agent-b" });
    try std.testing.expectEqualStrings("design-review", result.ipc.args.channel_invite.channel);
    try std.testing.expectEqualStrings("agent-b", result.ipc.args.channel_invite.agent_id);
    try std.testing.expectEqual(protocol.IpcAction.channel_invite, result.ipc.action);
}

test "parseArgs: channel list subcommand" {
    const result = try parseArgs(std.testing.allocator, &.{ "channel", "list" });
    try std.testing.expectEqual(protocol.IpcAction.channel_list, result.ipc.action);
    try std.testing.expect(result.ipc.args == .channel_list);
}

test "parseArgs: send missing payload returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "send", "agent-b" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: recv without --wait" {
    const result = try parseArgs(std.testing.allocator, &.{"recv"});
    try std.testing.expect(!result.ipc.args.recv.wait);
}

test "parseArgs: recv with --wait" {
    const result = try parseArgs(std.testing.allocator, &.{ "recv", "--wait" });
    try std.testing.expect(result.ipc.args.recv.wait);
}

test "parseArgs: agents subcommand" {
    const result = try parseArgs(std.testing.allocator, &.{"agents"});
    try std.testing.expectEqual(protocol.IpcAction.agents, result.ipc.action);
}

test "register envelope has correct fields for agent-id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const env = try protocol.makeRegisterEnvelope(arena, "test-agent", &.{});
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
    const result = try parseArgs(std.testing.allocator, &.{ "run", "--id", "my-agent", "--", "bash", "-l" });
    try std.testing.expectEqualStrings("my-agent", result.run.agent_id);
    try std.testing.expectEqual(@as(usize, 2), result.run.child_argv.len);
    try std.testing.expectEqualStrings("bash", result.run.child_argv[0]);
    try std.testing.expectEqualStrings("-l", result.run.child_argv[1]);
}

test "parseArgs: mcp-serve subcommand" {
    const result = try parseArgs(std.testing.allocator, &.{"mcp-serve"});
    try std.testing.expect(result == .mcp_serve);
}

test "parseArgs: run without --id returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "run", "--", "bash" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: run with --id but without -- returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "run", "--id", "foo" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: run with --id and -- but no child command returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "run", "--id", "foo", "--" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

// ---------------------------------------------------------------------------
// Strengthened coverage for zig-clap migration [[WI-2026-03-30-001]]
// ---------------------------------------------------------------------------

test "parseArgs: register with --session flag" {
    const result = try parseArgs(std.testing.allocator, &.{ "register", "--tool", "claude", "--session", "s1" });
    try std.testing.expectEqualStrings("claude", result.ipc.args.register.tool);
    try std.testing.expectEqualStrings("s1", result.ipc.args.register.session.?);
    try std.testing.expect(result.ipc.args.register.project == null);
}

test "parseArgs: register with all three flags" {
    const result = try parseArgs(std.testing.allocator, &.{ "register", "--tool", "codex", "--project", "/p", "--session", "s2" });
    try std.testing.expectEqualStrings("codex", result.ipc.args.register.tool);
    try std.testing.expectEqualStrings("/p", result.ipc.args.register.project.?);
    try std.testing.expectEqualStrings("s2", result.ipc.args.register.session.?);
}

test "parseArgs: register --tool without value returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "register", "--tool" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: channel leave subcommand" {
    const result = try parseArgs(std.testing.allocator, &.{ "channel", "leave", "design-review" });
    try std.testing.expectEqualStrings("design-review", result.ipc.args.channel_leave.channel);
    try std.testing.expectEqual(protocol.IpcAction.channel_leave, result.ipc.action);
}

test "parseArgs: channel create without --description" {
    const result = try parseArgs(std.testing.allocator, &.{ "channel", "create", "general" });
    try std.testing.expectEqualStrings("general", result.ipc.args.channel_create.name);
    try std.testing.expect(result.ipc.args.channel_create.description == null);
}

test "parseArgs: channel unknown sub-action returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "channel", "bogus" });
    try std.testing.expectError(ParseError.UnknownSubcommand, result);
}

test "parseArgs: channel missing sub-action returns error" {
    const result = parseArgs(std.testing.allocator, &.{"channel"});
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: channel create missing name returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "channel", "create" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: channel invite missing agent returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "channel", "invite", "ch1" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: channel leave missing channel returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "channel", "leave" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: run with multi-word child command" {
    const result = try parseArgs(std.testing.allocator, &.{ "run", "--id", "a1", "--", "python", "-c", "print('hi')" });
    try std.testing.expectEqualStrings("a1", result.run.agent_id);
    try std.testing.expectEqual(@as(usize, 3), result.run.child_argv.len);
    try std.testing.expectEqualStrings("python", result.run.child_argv[0]);
    try std.testing.expectEqualStrings("print('hi')", result.run.child_argv[2]);
}

test "parseArgs: send exact boundary (3 args)" {
    const result = try parseArgs(std.testing.allocator, &.{ "send", "tgt", "msg" });
    try std.testing.expectEqualStrings("tgt", result.ipc.args.send.target);
    try std.testing.expectEqualStrings("msg", result.ipc.args.send.text);
}

// ---------------------------------------------------------------------------
// --help tests [[WI-2026-03-30-001]]
// ---------------------------------------------------------------------------

test "parseArgs: register --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "register", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: send --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "send", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: recv --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "recv", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: run --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "run", "--help", "--", "bash" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: channel create --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "channel", "create", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: channel invite --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "channel", "invite", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: channel leave --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "channel", "leave", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: channel list --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "channel", "list", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: agents --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "agents", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: mcp-serve --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "mcp-serve", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: run --help without -- returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "run", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: top-level --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{"--help"});
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: register --project without value returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "register", "--tool", "x", "--project" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: register --session without value returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "register", "--tool", "x", "--session" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

// ---------------------------------------------------------------------------
// hub subcommand + run --hub tests [[ADR-0004]]
// ---------------------------------------------------------------------------

test "parseArgs: hub subcommand defaults" {
    const result = try parseArgs(std.testing.allocator, &.{"hub"});
    try std.testing.expectEqual(@as(u16, 9000), result.hub.port);
}

test "parseArgs: hub --port custom" {
    const result = try parseArgs(std.testing.allocator, &.{ "hub", "--port", "8080" });
    try std.testing.expectEqual(@as(u16, 8080), result.hub.port);
}

test "parseArgs: hub --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "hub", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: run with --hub flag" {
    const result = try parseArgs(std.testing.allocator, &.{ "run", "--id", "a1", "--hub", "10.0.0.1:8080", "--", "bash" });
    try std.testing.expectEqualStrings("a1", result.run.agent_id);
    try std.testing.expectEqualStrings("10.0.0.1", result.run.hub_addr);
    try std.testing.expectEqual(@as(u16, 8080), result.run.hub_port);
    try std.testing.expectEqualStrings("bash", result.run.child_argv[0]);
}

test "parseArgs: run without --hub uses defaults" {
    const result = try parseArgs(std.testing.allocator, &.{ "run", "--id", "a1", "--", "bash" });
    try std.testing.expectEqualStrings("127.0.0.1", result.run.hub_addr);
    try std.testing.expectEqual(@as(u16, 9000), result.run.hub_port);
}

test "parseArgs: run --hub invalid format returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "run", "--id", "a1", "--hub", "noport", "--", "bash" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: run --hub empty host returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "run", "--id", "a1", "--hub", ":9000", "--", "bash" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

// Pull in tests from sub-modules.
comptime {
    _ = @import("cli/commands.zig");
    _ = @import("cli/transport.zig");
}
