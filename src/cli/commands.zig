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

// ---------------------------------------------------------------------------
// github subcommand — RFC-0003 C-AUTH (login device only)
// ---------------------------------------------------------------------------

const github = @import("github");

/// Prompt on stdin for a line of input (trimmed).
fn promptLine(allocator: Allocator, prompt: []const u8) !?[]const u8 {
    try io_mod.stdoutWriteAll(prompt);
    try io_mod.stdoutWriteAll(": ");
    var buf: [4096]u8 = undefined;
    const n = sys.read(0, &buf) catch return null;
    if (n == 0) return null;
    const line = std.mem.trim(u8, buf[0..n], "\r\n");
    if (line.len == 0) return null;
    const d = try allocator.dupe(u8, line);
    return @as(?[]const u8, d);
}

/// `synapty github login` — configure hub repo + store PAT in Keychain.
pub fn runGithubLogin(allocator: Allocator, args: types.GithubArgs) !void {
    const owner = args.owner orelse (try promptLine(allocator, "Hub repo owner (GitHub username/org)")) orelse {
        try io_mod.stderrWriteAll("error: owner required\n");
        std.process.exit(1);
    };
    const repo = args.repo orelse (try promptLine(allocator, "Hub repo name")) orelse {
        try io_mod.stderrWriteAll("error: repo required\n");
        std.process.exit(1);
    };
    const token = args.token orelse (try promptLine(allocator, "Fine-grained PAT (Issues read/write on the hub repo)")) orelse {
        try io_mod.stderrWriteAll("error: token required\n");
        std.process.exit(1);
    };

    // Verify credentials against the API before storing anything.
    var config = github.Config{ .owner = owner, .repo = repo };
    const api = github.Api{ .allocator = allocator, .owner = owner, .repo = repo, .token = token };
    const check = api.request(.GET, "/rate_limit", null) catch {
        try io_mod.stderrWriteAll("error: token verification failed — check the token scope and repo name\n");
        std.process.exit(1);
    };
    allocator.free(check);

    // Record the GitHub username (issue assignee identity for task.claim).
    if (api.request(.GET, "/user", null)) |user_body| {
        defer allocator.free(user_body);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = json.parseFromSlice(json.Value, arena.allocator(), user_body, .{ .allocate = .alloc_always }) catch null;
        if (parsed) |p| {
            switch (p.value) {
                .object => |obj| if (obj.get("login")) |login| switch (login) {
                    .string => |l| config.username = try allocator.dupe(u8, l),
                    else => {},
                },
                else => {},
            }
        }
    } else |_| {}

    try config.save(allocator);
    try github.storeToken(allocator, accountOf(allocator, owner, repo), token);
    try io_mod.stdoutWriteAll("Saved. Hub repo: ");
    try io_mod.stdoutWriteAll(owner);
    try io_mod.stdoutWriteAll("/");
    try io_mod.stdoutWriteAll(repo);
    try io_mod.stdoutWriteAll("\n");
}

fn accountOf(allocator: Allocator, owner: []const u8, repo: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ owner, repo }) catch "github";
}

// ---------------------------------------------------------------------------
// task subcommand — RFC-0003 C-CLI-TOOLS
// ---------------------------------------------------------------------------

/// Send a tool_request envelope to the hub and print the tool_response.
fn toolRoundtrip(allocator: Allocator, tool: []const u8, args_obj: json.ObjectMap) !void {
    const now_ms = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds();
    const source_id = try std.fmt.allocPrint(allocator, "{s}task-{d}", .{ transport.temp_agent_prefix, now_ms });
    defer allocator.free(source_id);

    const fd = try transport.connectAndRegister(allocator, source_id);
    defer sys.close(fd);

    var payload_obj = json.ObjectMap.empty;
    try payload_obj.put(allocator, "tool", .{ .string = tool });
    try payload_obj.put(allocator, "args", .{ .object = args_obj });
    const envelope = protocol.Envelope{
        .@"type" = "tool_request",
        .id = "task-0",
        .source = source_id,
        .target = "hub",
        .payload = .{ .object = payload_obj },
    };
    const raw = try protocol.serializeEnvelope(allocator, envelope);
    defer allocator.free(raw);
    try sys.writeAll(fd, raw);
    try sys.writeAll(fd, "\n");

    var buf: [256 * 1024]u8 = undefined;
    const line = (try ipc.IpcServer.readLine(fd, &buf)) orelse {
        try io_mod.stdoutWriteAll("{\"ok\":false,\"error\":\"no response from hub\"}\n");
        return;
    };
    try io_mod.stdoutWriteAll(line);
    try io_mod.stdoutWriteAll("\n");
}

pub fn runTaskList(allocator: Allocator, args: types.TaskListArgs) !void {
    var args_obj = json.ObjectMap.empty;
    if (args.project) |p| try args_obj.put(allocator, "labels", .{ .string = p });
    if (args.state) |st| try args_obj.put(allocator, "state", .{ .string = st });
    try toolRoundtrip(allocator, "task.list", args_obj);
}

pub fn runTaskClaim(allocator: Allocator, args: types.TaskClaimArgs) !void {
    var args_obj = json.ObjectMap.empty;
    try args_obj.put(allocator, "number", .{ .integer = args.number });
    try toolRoundtrip(allocator, "task.claim", args_obj);
}

pub fn runTaskUpdate(allocator: Allocator, args: types.TaskUpdateArgs) !void {
    var args_obj = json.ObjectMap.empty;
    try args_obj.put(allocator, "number", .{ .integer = args.number });
    try args_obj.put(allocator, "status", .{ .string = args.status });
    try toolRoundtrip(allocator, "task.update", args_obj);
}

pub fn runTaskComment(allocator: Allocator, args: types.TaskCommentArgs) !void {
    var args_obj = json.ObjectMap.empty;
    try args_obj.put(allocator, "number", .{ .integer = args.number });
    try args_obj.put(allocator, "body", .{ .string = args.body });
    try toolRoundtrip(allocator, "task.comment", args_obj);
}

pub fn runTaskCreate(allocator: Allocator, args: types.TaskCreateArgs) !void {
    var args_obj = json.ObjectMap.empty;
    try args_obj.put(allocator, "title", .{ .string = args.title });
    if (args.project) |p| try args_obj.put(allocator, "project", .{ .string = p });
    if (args.body) |b| try args_obj.put(allocator, "body", .{ .string = b });
    try toolRoundtrip(allocator, "task.create", args_obj);
}
