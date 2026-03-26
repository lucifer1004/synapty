const std = @import("std");
const net = std.net;
const mem = std.mem;
const json = std.json;
const protocol = @import("protocol");
const Allocator = mem.Allocator;
const log = std.log.scoped(.daemon);

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const Config = struct {
    hub_addr: []const u8 = "127.0.0.1",
    hub_port: u16 = 9000,
    agent_id: []const u8 = "daemon-agent-01",
    spawn_cmd: []const []const u8 = &.{ "ping", "-c", "5", "localhost" },
};

// ---------------------------------------------------------------------------
// Hub connection (TCP — WebSocket upgrade deferred to V1.1)
// ---------------------------------------------------------------------------

/// Connect to the Hub over raw TCP and send the Register envelope.
/// Returns the connected stream for subsequent A2A messaging.
fn connectToHub(allocator: Allocator, config: Config) !net.Stream {
    const address = net.Address.parseIp4(config.hub_addr, config.hub_port) catch unreachable;
    const stream = try net.tcpConnectToAddress(address);
    errdefer stream.close();

    log.info("connected to Hub at {s}:{d}", .{ config.hub_addr, config.hub_port });

    // Build and send registration envelope
    const reg = protocol.makeRegisterEnvelope(config.agent_id, &.{});
    const payload = try protocol.serializeEnvelope(allocator, reg);
    defer allocator.free(payload);

    _ = try stream.write(payload);
    log.info("sent register for agent {s}", .{config.agent_id});

    return stream;
}

// ---------------------------------------------------------------------------
// Process spawner
// ---------------------------------------------------------------------------

/// Spawn a child process and pipe its stdout to our stdout (the SSH PTY
/// data plane). Returns the Child so the caller can wait on it.
fn spawnAgent(config: Config) !std.process.Child {
    var child = std.process.Child.init(config.spawn_cmd, std.heap.page_allocator);

    // Pipe stdout so we can relay it; inherit stderr directly.
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    log.info("spawned agent process: {s}", .{config.spawn_cmd[0]});

    return child;
}

/// Read from the child's stdout and write to our stdout (data plane).
/// This runs in its own thread so the main thread can handle the
/// control plane (WS messages from the Hub).
fn relayStdout(child_stdout: std.fs.File) void {
    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = child_stdout.read(&buf) catch |err| {
            log.err("child stdout read error: {any}", .{err});
            break;
        };
        if (n == 0) break; // child closed stdout

        // Scan for OSC 99 sequences in the data stream
        const data = buf[0..n];
        if (protocol.parseOsc99(data)) |osc| {
            log.info("OSC 99 intercepted: agent={s} status={s}", .{ osc.agent_id, osc.status });
            // TODO: forward as A2A envelope to Hub for human-in-the-loop routing
        }

        stdout.writeAll(data) catch |err| {
            log.err("stdout write error: {any}", .{err});
            break;
        };
    }
}

/// Read A2A messages from the Hub and process them (control plane).
fn handleHubMessages(stream: net.Stream) void {
    var buf: [64 * 1024]u8 = undefined;

    while (true) {
        const n = stream.read(&buf) catch |err| {
            log.err("hub read error: {any}", .{err});
            break;
        };
        if (n == 0) break;

        log.info("received from Hub: {s}", .{buf[0..n]});
        // TODO: dispatch incoming A2A messages to the agent process via stdin
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = Config{};

    // 1. Connect to the Hub and register
    const hub_stream = connectToHub(allocator, config) catch |err| {
        log.err("failed to connect to Hub: {any}", .{err});
        return err;
    };
    defer hub_stream.close();

    // 2. Spawn the agent process
    var child = spawnAgent(config) catch |err| {
        log.err("failed to spawn agent: {any}", .{err});
        return err;
    };

    // 3. Start stdout relay in a background thread (data plane)
    if (child.stdout) |child_stdout| {
        _ = std.Thread.spawn(.{}, relayStdout, .{child_stdout}) catch |err| {
            log.err("failed to spawn relay thread: {any}", .{err});
        };
    }

    // 4. Handle Hub messages on the main thread (control plane)
    _ = std.Thread.spawn(.{}, handleHubMessages, .{hub_stream}) catch |err| {
        log.err("failed to spawn hub handler thread: {any}", .{err});
    };

    // 5. Wait for the child process to exit
    const term = child.wait();
    log.info("agent process exited: {any}", .{term});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Config defaults" {
    const c = Config{};
    try std.testing.expectEqualStrings("127.0.0.1", c.hub_addr);
    try std.testing.expectEqual(@as(u16, 9000), c.hub_port);
    try std.testing.expectEqualStrings("daemon-agent-01", c.agent_id);
}
