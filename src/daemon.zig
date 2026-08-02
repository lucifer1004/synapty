const std = @import("std");
const io_mod = @import("io");
const mem = std.mem;
const run = @import("run");
const Allocator = mem.Allocator;
const log = std.log.scoped(.daemon);

// ---------------------------------------------------------------------------
// Arg types
// ---------------------------------------------------------------------------

pub const DaemonArgs = struct {
    agent_id: []const u8,
    hub_addr: []const u8,
    hub_port: u16,
    child_argv: []const []const u8,
};

// ---------------------------------------------------------------------------
// Arg parsing errors
// ---------------------------------------------------------------------------

pub const ParseError = error{
    MissingId,
    MissingHub,
    InvalidHubFormat,
    MissingChildCommand,
};

// ---------------------------------------------------------------------------
// Arg parsing
// ---------------------------------------------------------------------------

/// Parse daemon args (excluding argv[0]).
/// Expected syntax: --id <agent-id> --hub <host:port> -- <command> [args...]
pub fn parseArgs(args: []const []const u8) ParseError!DaemonArgs {
    var agent_id: ?[]const u8 = null;
    var hub_str: ?[]const u8 = null;
    var dash_dash_idx: ?usize = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.eql(u8, arg, "--")) {
            dash_dash_idx = i;
            break;
        } else if (mem.eql(u8, arg, "--id")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingId;
            agent_id = args[i];
        } else if (mem.eql(u8, arg, "--hub")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingHub;
            hub_str = args[i];
        }
    }

    if (agent_id == null) return ParseError.MissingId;
    if (hub_str == null) return ParseError.MissingHub;

    // Parse "host:port" from hub_str.
    const hub = hub_str.?;
    const colon_idx = mem.lastIndexOfScalar(u8, hub, ':') orelse return ParseError.InvalidHubFormat;
    const host = hub[0..colon_idx];
    const port_str = hub[colon_idx + 1 ..];
    if (host.len == 0 or port_str.len == 0) return ParseError.InvalidHubFormat;
    const port = std.fmt.parseInt(u16, port_str, 10) catch return ParseError.InvalidHubFormat;

    const sep = dash_dash_idx orelse return ParseError.MissingChildCommand;
    if (sep + 1 >= args.len) return ParseError.MissingChildCommand;

    return DaemonArgs{
        .agent_id = agent_id.?,
        .hub_addr = host,
        .hub_port = port,
        .child_argv = args[sep + 1 ..],
    };
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    io_mod.install(init.io);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var arg_list = std.ArrayList([]const u8).empty;
    defer arg_list.deinit(allocator);
    const argv = try init.minimal.args.toSlice(allocator);
    for (argv[1..]) |arg| {
        try arg_list.append(allocator, arg);
    }

    const daemon_args = parseArgs(arg_list.items) catch |err| {
        switch (err) {
            ParseError.MissingId => {
                try io_mod.stderrWriteAll("error: missing --id <agent-id>\n");
            },
            ParseError.MissingHub => {
                try io_mod.stderrWriteAll("error: missing --hub <host:port>\n");
            },
            ParseError.InvalidHubFormat => {
                try io_mod.stderrWriteAll("error: --hub must be in <host:port> format\n");
            },
            ParseError.MissingChildCommand => {
                try io_mod.stderrWriteAll("error: missing -- <command> after arguments\n");
            },
        }
        std.process.exit(1);
    };

    var server = try run.RunServer.init(
        allocator,
        daemon_args.agent_id,
        daemon_args.hub_addr,
        daemon_args.hub_port,
    );
    defer server.deinit();

    try server.run(daemon_args.child_argv);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseArgs: valid args parse correctly" {
    const argv = [_][]const u8{ "--id", "foo", "--hub", "10.0.0.1:9000", "--", "bash", "-l" };
    const result = try parseArgs(&argv);
    try std.testing.expectEqualStrings("foo", result.agent_id);
    try std.testing.expectEqualStrings("10.0.0.1", result.hub_addr);
    try std.testing.expectEqual(@as(u16, 9000), result.hub_port);
    try std.testing.expectEqual(@as(usize, 2), result.child_argv.len);
    try std.testing.expectEqualStrings("bash", result.child_argv[0]);
    try std.testing.expectEqualStrings("-l", result.child_argv[1]);
}

test "parseArgs: missing --id returns error" {
    const argv = [_][]const u8{ "--hub", "10.0.0.1:9000", "--", "bash" };
    try std.testing.expectError(ParseError.MissingId, parseArgs(&argv));
}

test "parseArgs: missing --hub returns error" {
    const argv = [_][]const u8{ "--id", "foo", "--", "bash" };
    try std.testing.expectError(ParseError.MissingHub, parseArgs(&argv));
}

test "parseArgs: invalid hub format (no port) returns error" {
    const argv = [_][]const u8{ "--id", "foo", "--hub", "10.0.0.1", "--", "bash" };
    try std.testing.expectError(ParseError.InvalidHubFormat, parseArgs(&argv));
}

test "parseArgs: invalid hub format (empty host) returns error" {
    const argv = [_][]const u8{ "--id", "foo", "--hub", ":9000", "--", "bash" };
    try std.testing.expectError(ParseError.InvalidHubFormat, parseArgs(&argv));
}

test "parseArgs: missing -- separator returns error" {
    const argv = [_][]const u8{ "--id", "foo", "--hub", "10.0.0.1:9000" };
    try std.testing.expectError(ParseError.MissingChildCommand, parseArgs(&argv));
}

test "parseArgs: -- present but no child command returns error" {
    const argv = [_][]const u8{ "--id", "foo", "--hub", "10.0.0.1:9000", "--" };
    try std.testing.expectError(ParseError.MissingChildCommand, parseArgs(&argv));
}
