const std = @import("std");
const sys = @import("sys");
const io_mod = @import("io");
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
    const sock_env = sys.getenv("SYNAPTY_SOCK") orelse return false;
    var client = try ipc.IpcClient.connect(sock_env);
    defer client.deinit();
    const req = try protocol.serializeIpcRequest(allocator, request);
    defer allocator.free(req);
    try client.send(req);
    var buf: [64 * 1024]u8 = undefined;
    if (try client.recv(&buf)) |response| {
        try io_mod.stdoutWriteAll(response);
        try io_mod.stdoutWriteAll("\n");
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
        try io_mod.stderrWriteAll("error: not in a synapty session (SYNAPTY_SOCK not set)\n");
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
        try io_mod.stderrWriteAll("error: not in a synapty session (SYNAPTY_SOCK not set)\n");
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
    const now_ms = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds();
    const source_id = try std.fmt.allocPrint(allocator, "{s}{d}", .{ transport.temp_agent_prefix, now_ms });
    defer allocator.free(source_id);

    const fd = try transport.connectAndRegister(allocator, source_id);
    defer sys.close(fd);

    // Build the DM envelope per [[RFC-0002:C-DM]].
    var payload_obj = json.ObjectMap.empty;
    try payload_obj.put(allocator, "text", .{ .string = args.text });
    const envelope = protocol.Envelope{
        .@"type" = "dm",
        .id = "send-0",
        .source = source_id,
        .target = args.target,
        .payload = .{ .object = payload_obj },
    };
    const raw = try protocol.serializeEnvelope(allocator, envelope);
    defer allocator.free(raw);

    try sys.writeAll(fd, raw);

    const msg = try std.fmt.allocPrint(allocator, "sent to {s}: {s}\n", .{ args.target, args.text });
    defer allocator.free(msg);
    try io_mod.stdoutWriteAll(msg);
}

pub fn runRecv(allocator: Allocator, args: RecvArgs) !void {
    if (try ipcRoundtrip(allocator, .{ .action = .recv })) return;

    // Fallback: direct Hub TCP connection.
    // Build a temporary source ID for this one-shot recv.
    const now_ms = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds();
    const source_id = try std.fmt.allocPrint(allocator, "{s}recv-{d}", .{ transport.temp_agent_prefix, now_ms });
    defer allocator.free(source_id);

    const fd = try transport.connectAndRegister(allocator, source_id);
    defer sys.close(fd);

    var buf: [64 * 1024]u8 = undefined;

    if (args.wait) {
        // Block until a message arrives, then print it.
        const n = try sys.read(fd, &buf);
        if (n > 0) {
            try io_mod.stdoutWriteAll(buf[0..n]);
            try io_mod.stdoutWriteAll("\n");
        }
    } else {
        // Poll once with a non-blocking read via POSIX O_NONBLOCK.
        try sys.setNonblocking(fd);

        const n = sys.read(fd, &buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (n > 0) {
            try io_mod.stdoutWriteAll(buf[0..n]);
            try io_mod.stdoutWriteAll("\n");
        } else {
            try io_mod.stdoutWriteAll("no messages\n");
        }
    }
}

pub fn runAgents(allocator: Allocator) !void {
    if (try ipcRoundtrip(allocator, .{ .action = .agents })) return;

    // Fallback: direct Hub TCP connection.
    const now_ms = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds();
    const source_id = try std.fmt.allocPrint(allocator, "{s}agents-{d}", .{ transport.temp_agent_prefix, now_ms });
    defer allocator.free(source_id);

    const fd = try transport.connectAndRegister(allocator, source_id);
    defer sys.close(fd);

    // Send a list_agents request envelope.
    const envelope = protocol.Envelope{
        .@"type" = "list_agents",
        .id = "agents-0",
        .source = source_id,
        .target = "hub",
    };
    const raw = try protocol.serializeEnvelope(allocator, envelope);
    defer allocator.free(raw);

    try sys.writeAll(fd, raw);
    try sys.writeAll(fd, "\n");

    // Read the response (best-effort, no timeout in V1).
    var buf: [64 * 1024]u8 = undefined;
    const n = sys.read(fd, &buf) catch 0;
    if (n > 0) {
        try io_mod.stdoutWriteAll(buf[0..n]);
        try io_mod.stdoutWriteAll("\n");
    } else {
        try io_mod.stdoutWriteAll("(no response from hub)\n");
    }
}
