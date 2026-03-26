const std = @import("std");
const net = std.net;
const mem = std.mem;
const json = std.json;
const protocol = @import("protocol");
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

    const source_id = try std.fmt.allocPrint(allocator, "{s}agents-{d}", .{ temp_agent_prefix, std.time.milliTimestamp() });
    defer allocator.free(source_id);

    const stream = try connectAndRegister(allocator, source_id);
    defer stream.close();

    // Send a list_agents request envelope.
    const envelope = protocol.Envelope{
        .@"type" = "a2a_request",
        .id = "agents-0",
        .source = source_id,
        .target = "hub",
        .payload = json.Value{ .string = "list_agents" },
    };
    const raw = try protocol.serializeEnvelope(allocator, envelope);
    defer allocator.free(raw);

    _ = try stream.write(raw);

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
                try stderr.writeAll("usage: synapty <register|send|recv|agents> [args]\n");
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
