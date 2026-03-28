const std = @import("std");
const net = std.net;
const mem = std.mem;
const json = std.json;
const protocol = @import("protocol");
const ipc = @import("ipc");
const Allocator = mem.Allocator;
const transport = @import("transport.zig");

// Import arg types from the shared types module (no circular import).
const types = @import("types.zig");
const RegisterArgs = types.RegisterArgs;
const SendArgs = types.SendArgs;
const RecvArgs = types.RecvArgs;
const IpcArgs = types.IpcArgs;

// ---------------------------------------------------------------------------
// IPC helper
// ---------------------------------------------------------------------------

/// Send an IPC request to the daemon and print the response.
/// Returns true if SYNAPTY_SOCK was available (IPC path used), false if not.
fn ipcRoundtrip(allocator: Allocator, request: protocol.IpcRequest) !bool {
    const sock_env = std.posix.getenv("SYNAPTY_SOCK") orelse return false;
    var client = try ipc.IpcClient.connect(sock_env);
    defer client.deinit();
    const req = try protocol.serializeIpcRequest(allocator, request);
    defer allocator.free(req);
    try client.send(req);
    var buf: [64 * 1024]u8 = undefined;
    if (try client.recv(&buf)) |response| {
        const stdout = std.fs.File.stdout();
        try stdout.writeAll(response);
        try stdout.writeAll("\n");
    }
    return true;
}

// ---------------------------------------------------------------------------
// Subcommand handlers
// ---------------------------------------------------------------------------

/// Agent registration per [[RFC-0002:C-AGENT-IDENTITY]].
/// Routes through IPC to daemon, which forwards agent_update to Hub.
pub fn runRegister(allocator: Allocator, args: RegisterArgs) !void {
    const used_ipc = try ipcRoundtrip(allocator, .{
        .action = .register,
        .tool = args.tool,
        .project = args.project,
        .session = args.session,
    });
    if (!used_ipc) {
        try std.fs.File.stderr().writeAll("error: not in a synapty session (SYNAPTY_SOCK not set)\n");
        std.process.exit(1);
    }
}

/// Channel subcommand handler per [[RFC-0002:C-GROUP-CHAT]].
pub fn runChannel(allocator: Allocator, action: protocol.IpcAction, args: IpcArgs) !void {
    const used_ipc = try ipcRoundtrip(allocator, switch (action) {
        .channel_create => .{ .action = .channel_create, .channel = args.channel_create.name, .description = args.channel_create.description },
        .channel_invite => .{ .action = .channel_invite, .channel = args.channel_invite.channel, .agent_id = args.channel_invite.agent_id },
        .channel_leave => .{ .action = .channel_leave, .channel = args.channel_leave.channel },
        .channel_list => .{ .action = .channel_list },
        else => unreachable,
    });
    if (!used_ipc) {
        try std.fs.File.stderr().writeAll("error: not in a synapty session (SYNAPTY_SOCK not set)\n");
        std.process.exit(1);
    }
}

pub fn runSend(allocator: Allocator, args: SendArgs) !void {
    if (try ipcRoundtrip(allocator, .{
        .action = .send,
        .target = args.target,
        .text = args.text,
    })) return;

    // Fallback: direct Hub TCP connection.
    // Build a temporary source ID for this one-shot send.
    const source_id = try std.fmt.allocPrint(allocator, "{s}{d}", .{ transport.temp_agent_prefix, std.time.milliTimestamp() });
    defer allocator.free(source_id);

    const stream = try transport.connectAndRegister(allocator, source_id);
    defer stream.close();

    // Build the DM envelope per [[RFC-0002:C-DM]].
    var payload_obj = json.ObjectMap.init(allocator);
    try payload_obj.put("text", .{ .string = args.text });
    const envelope = protocol.Envelope{
        .@"type" = "dm",
        .id = "send-0",
        .source = source_id,
        .target = args.target,
        .payload = .{ .object = payload_obj },
    };
    const raw = try protocol.serializeEnvelope(allocator, envelope);
    defer allocator.free(raw);

    _ = try stream.write(raw);

    const msg = try std.fmt.allocPrint(allocator, "sent to {s}: {s}\n", .{ args.target, args.text });
    defer allocator.free(msg);
    try std.fs.File.stdout().writeAll(msg);
}

pub fn runRecv(allocator: Allocator, args: RecvArgs) !void {
    const stdout = std.fs.File.stdout();

    if (try ipcRoundtrip(allocator, .{ .action = .recv })) return;

    // Fallback: direct Hub TCP connection.
    // Build a temporary source ID for this one-shot recv.
    const source_id = try std.fmt.allocPrint(allocator, "{s}recv-{d}", .{ transport.temp_agent_prefix, std.time.milliTimestamp() });
    defer allocator.free(source_id);

    const stream = try transport.connectAndRegister(allocator, source_id);
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

pub fn runAgents(allocator: Allocator) !void {
    const stdout = std.fs.File.stdout();

    if (try ipcRoundtrip(allocator, .{ .action = .agents })) return;

    // Fallback: direct Hub TCP connection.
    const source_id = try std.fmt.allocPrint(allocator, "{s}agents-{d}", .{ transport.temp_agent_prefix, std.time.milliTimestamp() });
    defer allocator.free(source_id);

    const stream = try transport.connectAndRegister(allocator, source_id);
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
