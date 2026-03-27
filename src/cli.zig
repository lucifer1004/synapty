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
// Constants
// ---------------------------------------------------------------------------

const hub_addr = "127.0.0.1";
const hub_port: u16 = 9000;
const temp_agent_prefix = "cli-tmp-";

// ---------------------------------------------------------------------------
// Subcommand types
// ---------------------------------------------------------------------------

pub const Subcommand = union(enum) {
    register: RegisterArgs,
    send: SendArgs,
    recv: RecvArgs,
    agents,
    run: RunArgs,
    mcp_serve,
};

pub const RegisterArgs = struct {
    agent_id: []const u8,
};

pub const SendArgs = struct {
    target: []const u8,
    payload: []const u8,
};

pub const RecvArgs = struct {
    wait: bool,
};

pub const RunArgs = struct {
    agent_id: []const u8,
    child_argv: []const []const u8,
};

// ---------------------------------------------------------------------------
// Arg parsing
// ---------------------------------------------------------------------------

pub const ParseError = error{
    MissingSubcommand,
    UnknownSubcommand,
    MissingArgument,
};

/// Parse process args (excluding argv[0]) into a Subcommand.
/// `args` is a slice of argument strings, not including the program name.
pub fn parseArgs(args: []const []const u8) ParseError!Subcommand {
    if (args.len == 0) return ParseError.MissingSubcommand;

    const sub = args[0];

    if (mem.eql(u8, sub, "register")) {
        if (args.len < 2) return ParseError.MissingArgument;
        return .{ .register = .{ .agent_id = args[1] } };
    }

    if (mem.eql(u8, sub, "send")) {
        if (args.len < 3) return ParseError.MissingArgument;
        return .{ .send = .{ .target = args[1], .payload = args[2] } };
    }

    if (mem.eql(u8, sub, "recv")) {
        var wait = false;
        for (args[1..]) |arg| {
            if (mem.eql(u8, arg, "--wait")) wait = true;
        }
        return .{ .recv = .{ .wait = wait } };
    }

    if (mem.eql(u8, sub, "agents")) {
        return .agents;
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

    if (mem.eql(u8, sub, "mcp-serve")) {
        return .mcp_serve;
    }

    return ParseError.UnknownSubcommand;
}

// ---------------------------------------------------------------------------
// Hub connection helpers
// ---------------------------------------------------------------------------

/// Connect to the Hub and send an initial register envelope.
/// Returns the open stream; caller must close it.
fn connectAndRegister(allocator: Allocator, agent_id: []const u8) !net.Stream {
    const address = net.Address.parseIp4(hub_addr, hub_port) catch unreachable;
    const stream = try net.tcpConnectToAddress(address);
    errdefer stream.close();

    const reg = protocol.makeRegisterEnvelope(agent_id, &.{});
    const payload = try protocol.serializeEnvelope(allocator, reg);
    defer allocator.free(payload);

    _ = try stream.write(payload);
    _ = try stream.write("\n");
    return stream;
}

// ---------------------------------------------------------------------------
// Subcommand handlers
// ---------------------------------------------------------------------------

fn runRegister(allocator: Allocator, args: RegisterArgs) !void {
    const stdout = std.fs.File.stdout();

    const stream = try connectAndRegister(allocator, args.agent_id);
    defer stream.close();

    const msg = try std.fmt.allocPrint(allocator, "registered: {s}\n", .{args.agent_id});
    defer allocator.free(msg);
    try stdout.writeAll(msg);
}

fn runSend(allocator: Allocator, args: SendArgs) !void {
    const stdout = std.fs.File.stdout();

    if (std.posix.getenv("SYNAPTY_SOCK")) |sock_env| {
        const sock_path: []const u8 = sock_env;
        var client = try ipc.IpcClient.connect(sock_path);
        defer client.deinit();
        const req = try protocol.serializeIpcRequest(allocator, .{
            .action = .send,
            .target = args.target,
            .payload = args.payload,
        });
        defer allocator.free(req);
        try client.send(req);
        var buf: [4096]u8 = undefined;
        if (try client.recv(&buf)) |response| {
            try stdout.writeAll(response);
            try stdout.writeAll("\n");
        }
        return;
    }

    // Fallback: direct Hub TCP connection.
    // Build a temporary source ID for this one-shot send.
    const source_id = try std.fmt.allocPrint(allocator, "{s}{d}", .{ temp_agent_prefix, std.time.milliTimestamp() });
    defer allocator.free(source_id);

    const stream = try connectAndRegister(allocator, source_id);
    defer stream.close();

    // Build the A2A request envelope.
    const envelope = protocol.Envelope{
        .@"type" = "a2a_request",
        .id = "send-0",
        .source = source_id,
        .target = args.target,
        .payload = json.Value{ .string = args.payload },
    };
    const raw = try protocol.serializeEnvelope(allocator, envelope);
    defer allocator.free(raw);

    _ = try stream.write(raw);

    const msg = try std.fmt.allocPrint(allocator, "sent to {s}: {s}\n", .{ args.target, args.payload });
    defer allocator.free(msg);
    try stdout.writeAll(msg);
}

fn runRecv(allocator: Allocator, args: RecvArgs) !void {
    const stdout = std.fs.File.stdout();

    if (std.posix.getenv("SYNAPTY_SOCK")) |sock_env| {
        const sock_path: []const u8 = sock_env;
        var client = try ipc.IpcClient.connect(sock_path);
        defer client.deinit();
        const req = try protocol.serializeIpcRequest(allocator, .{
            .action = .recv,
        });
        defer allocator.free(req);
        try client.send(req);
        var buf: [4096]u8 = undefined;
        if (try client.recv(&buf)) |response| {
            try stdout.writeAll(response);
            try stdout.writeAll("\n");
        }
        return;
    }

    // Fallback: direct Hub TCP connection.
    // Build a temporary source ID for this one-shot recv.
    const source_id = try std.fmt.allocPrint(allocator, "{s}recv-{d}", .{ temp_agent_prefix, std.time.milliTimestamp() });
    defer allocator.free(source_id);

    const stream = try connectAndRegister(allocator, source_id);
    defer stream.close();

    var buf: [64 * 1024]u8 = undefined;

    if (args.wait) {
        // Block until a message arrives, then print it.
        const n = try stream.read(&buf);
        if (n > 0) {
            try stdout.writeAll(buf[0..n]);
            try stdout.writeAll("\n");
        }
    } else {
        // Poll once with a non-blocking read via POSIX O_NONBLOCK.
        // For V1 simplicity we attempt a single read with a short timeout
        // by setting the socket to non-blocking mode.
        const fd = stream.handle;
        var flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        flags |= 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags);

        const n = stream.read(&buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (n > 0) {
            try stdout.writeAll(buf[0..n]);
            try stdout.writeAll("\n");
        } else {
            try stdout.writeAll("no messages\n");
        }
    }
}

fn runAgents(allocator: Allocator) !void {
    const stdout = std.fs.File.stdout();

    if (std.posix.getenv("SYNAPTY_SOCK")) |sock_env| {
        const sock_path: []const u8 = sock_env;
        var client = try ipc.IpcClient.connect(sock_path);
        defer client.deinit();
        const req = try protocol.serializeIpcRequest(allocator, .{
            .action = .agents,
        });
        defer allocator.free(req);
        try client.send(req);
        var buf: [4096]u8 = undefined;
        if (try client.recv(&buf)) |response| {
            try stdout.writeAll(response);
            try stdout.writeAll("\n");
        }
        return;
    }

    // Fallback: direct Hub TCP connection.
    const source_id = try std.fmt.allocPrint(allocator, "{s}agents-{d}", .{ temp_agent_prefix, std.time.milliTimestamp() });
    defer allocator.free(source_id);

    const stream = try connectAndRegister(allocator, source_id);
    defer stream.close();

    // Send a list_agents request envelope.
    const envelope = protocol.Envelope{
        .@"type" = "list_agents",
        .id = "agents-0",
        .source = source_id,
        .target = "hub",
    };
    const raw = try protocol.serializeEnvelope(allocator, envelope);
    defer allocator.free(raw);

    _ = try stream.write(raw);
    _ = try stream.write("\n");

    // Read the response (best-effort, no timeout in V1).
    var buf: [64 * 1024]u8 = undefined;
    const n = stream.read(&buf) catch 0;
    if (n > 0) {
        try stdout.writeAll(buf[0..n]);
        try stdout.writeAll("\n");
    } else {
        try stdout.writeAll("(no response from hub)\n");
    }
}

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
                try stderr.writeAll("usage: synapty <register|send|recv|agents|run|mcp-serve> [args]\n");
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
        .register => |a| try runRegister(allocator, a),
        .send => |a| try runSend(allocator, a),
        .recv => |a| try runRecv(allocator, a),
        .agents => try runAgents(allocator),
        .run => |a| {
            var server = try run.RunServer.init(allocator, a.agent_id, hub_addr, hub_port);
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
    const result = try parseArgs(&.{ "register", "my-agent" });
    try std.testing.expectEqualStrings("my-agent", result.register.agent_id);
}

test "parseArgs: register missing agent-id returns error" {
    const result = parseArgs(&.{"register"});
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: send subcommand" {
    const result = try parseArgs(&.{ "send", "agent-b", "hello world" });
    try std.testing.expectEqualStrings("agent-b", result.send.target);
    try std.testing.expectEqualStrings("hello world", result.send.payload);
}

test "parseArgs: send missing payload returns error" {
    const result = parseArgs(&.{ "send", "agent-b" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: recv without --wait" {
    const result = try parseArgs(&.{"recv"});
    try std.testing.expect(!result.recv.wait);
}

test "parseArgs: recv with --wait" {
    const result = try parseArgs(&.{ "recv", "--wait" });
    try std.testing.expect(result.recv.wait);
}

test "parseArgs: agents subcommand" {
    const result = try parseArgs(&.{"agents"});
    try std.testing.expectEqual(Subcommand.agents, result);
}

test "register envelope has correct fields for agent-id" {
    const env = protocol.makeRegisterEnvelope("test-agent", &.{});
    try std.testing.expectEqualStrings("register", env.@"type");
    try std.testing.expectEqualStrings("test-agent", env.source);
    try std.testing.expectEqualStrings("", env.target);
}

test "send envelope has correct source/target/payload fields" {
    const envelope = protocol.Envelope{
        .@"type" = "a2a_request",
        .id = "send-0",
        .source = "cli-src",
        .target = "agent-b",
        .payload = json.Value{ .string = "hello" },
    };
    try std.testing.expectEqualStrings("a2a_request", envelope.@"type");
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
    try std.testing.expectEqual(Subcommand.mcp_serve, result);
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
