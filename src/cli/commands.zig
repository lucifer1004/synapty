const std = @import("std");
const sys = @import("sys");
const framing = @import("framing");
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

/// Agent registration per [[RFC-0003]] (agent identity).
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

/// Channel subcommand handler per [[RFC-0003:C-A2A-REDUCTION]] (legacy group-chat surface).
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

    try writeSendEnvelope(allocator, fd, source_id, args.target, args.text);

    const msg = try std.fmt.allocPrint(allocator, "sent to {s}: {s}\n", .{ args.target, args.text });
    defer allocator.free(msg);
    try io_mod.stdoutWriteAll(msg);
}

/// Build and write a DM envelope with its newline terminator to `fd`
/// (WI-2026-08-08-004). The hub only processes newline-terminated lines;
/// an unterminated frame is dropped at EOF while the sender still reports
/// "sent to ...".
fn writeSendEnvelope(allocator: Allocator, fd: sys.fd_t, source_id: []const u8, target: []const u8, text: []const u8) !void {
    // Build the DM envelope per [[RFC-0003]] (direct message envelope, legacy chat surface).
    var payload_obj = json.ObjectMap.empty;
    try payload_obj.put(allocator, "text", .{ .string = text });
    const envelope = protocol.Envelope{
        .@"type" = "dm",
        .id = "send-0",
        .source = source_id,
        .target = target,
        .payload = .{ .object = payload_obj },
    };
    const raw = try protocol.serializeEnvelope(allocator, envelope);
    defer allocator.free(raw);

    try sys.writeAll(fd, raw);
    try sys.writeAll(fd, "\n");
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
        // Block until a message arrives, then print it. Line-buffered so a
        // frame split across TCP segments is not truncated (WI-2026-08-08-028).
        const line = try readLineHub(fd, &buf);
        if (line) |l| {
            try io_mod.stdoutWriteAll(l);
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

/// Read one newline-terminated frame from the hub (chunked; a single read
/// truncated frames split across TCP segments — WI-2026-08-08-028).
/// Delegates to the shared framing.LineBuffer (WI-2026-08-08-035).
fn readLineHub(fd: sys.fd_t, buf: []u8) !?[]const u8 {
    var lb = framing.LineBuffer.init(buf);
    return lb.readLine(fd);
}

pub fn runAgents(allocator: Allocator) !void {
    if (try ipcRoundtrip(allocator, .{ .action = .agents })) return;

    // Fallback: direct Hub TCP connection.
    const now_ms = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds();
    const source_id = try std.fmt.allocPrint(allocator, "{s}agents-{d}", .{ transport.temp_agent_prefix, now_ms });
    defer allocator.free(source_id);

    // Anonymous query connection — no register envelope, so no temporary
    // agent churn in the hub routing table (WI-2026-03-31-004).
    const fd = try transport.connectToHub(transport.hub_addr, transport.hub_port);
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

    // Read the response (best-effort, no timeout in V1). Line-buffered so
    // a frame split across TCP segments is not truncated (WI-2026-08-08-028).
    var buf: [64 * 1024]u8 = undefined;
    const line = readLineHub(fd, &buf) catch null;
    if (line) |l| {
        const n = l.len;
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

/// `synapty github logout` — unbind the bridge: delete the Keychain
/// credential AND the config binding (owner/repo/username). The ONLY
/// removal path for the stored PAT (WI-2026-08-08-043).
pub fn runGithubLogout(allocator: Allocator) !void {
    const config = try github.Config.load(allocator);
    if (config) |c| {
        const account = accountOf(allocator, c.owner, c.repo);
        defer allocator.free(account);
        const deleted = try github.deleteToken(allocator, account);
        if (deleted) {
            try io_mod.stdoutWriteAll("Removed GitHub credential for ");
            try io_mod.stdoutWriteAll(c.owner);
            try io_mod.stdoutWriteAll("/");
            try io_mod.stdoutWriteAll(c.repo);
            try io_mod.stdoutWriteAll("\n");
        } else {
            try io_mod.stdoutWriteAll("No stored credential found — clearing the binding anyway.\n");
        }
        // The config file only carries the github binding — remove it.
        if (try github.Config.configPath(allocator)) |path| {
            defer allocator.free(path);
            sys.unlink(path);
        }
        try io_mod.stdoutWriteAll("GitHub bridge unbound.\n");
    } else {
        try io_mod.stdoutWriteAll("GitHub bridge is not configured.\n");
    }
}

/// `synapty github status` — print the current binding as JSON for the
/// GUI: {configured, owner, repo, username?, hasToken} (WI-2026-08-08-043).
pub fn runGithubStatus(allocator: Allocator) !void {
    var payload = json.ObjectMap.empty;
    const config = try github.Config.load(allocator);
    if (config) |c| {
        const account = accountOf(allocator, c.owner, c.repo);
        defer allocator.free(account);
        const has_token = (try github.loadToken(allocator, account)) != null;
        try payload.put(allocator, "configured", .{ .bool = has_token });
        try payload.put(allocator, "owner", .{ .string = c.owner });
        try payload.put(allocator, "repo", .{ .string = c.repo });
        if (c.username) |u| try payload.put(allocator, "username", .{ .string = u });
        try payload.put(allocator, "hasToken", .{ .bool = has_token });
    } else {
        try payload.put(allocator, "configured", .{ .bool = false });
    }
    const raw = try json.Stringify.valueAlloc(allocator, json.Value{ .object = payload }, .{});
    defer allocator.free(raw);
    try io_mod.stdoutWriteAll(raw);
    try io_mod.stdoutWriteAll("\n");
}

// ---------------------------------------------------------------------------
// task subcommand — RFC-0003 C-CLI-TOOLS
// ---------------------------------------------------------------------------

/// Send a tool_request envelope to the hub and print the tool_response.
/// Uses an anonymous connection — no register envelope, so no temporary
/// agent appears in the hub's routing table (WI-2026-03-31-004).
fn toolRoundtrip(allocator: Allocator, tool: []const u8, args_obj: json.ObjectMap) !void {
    const now_ms = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds();
    const source_id = try std.fmt.allocPrint(allocator, "{s}task-{d}", .{ transport.temp_agent_prefix, now_ms });
    defer allocator.free(source_id);

    const fd = try transport.connectToHub(transport.hub_addr, transport.hub_port);
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

// ---------------------------------------------------------------------------
// skills subcommand — RFC-0003 C-SKILLS
// ---------------------------------------------------------------------------

/// The canonical skill document, embedded at compile time.
const synapty_skill = @embedFile("../skills/synapty-task/SKILL.md");

const skill_install_marker = "<!-- synapty:installed -->";

/// Write the skill doc to `<dir>/SKILL.md` (creating parent dirs).
/// All three platforms use the skill-directory convention now
/// (Claude Code / Codex / Gemini CLI), so this is a plain overwrite —
/// idempotent by construction and always current.
fn installSkillFile(allocator: Allocator, path: []const u8) !void {
    _ = allocator;
    const io = io_mod.get();
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    var out = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer out.close(io);
    try out.writeStreamingAll(io, synapty_skill);
}

/// Remove a previously appended marked section (old AGENTS.md / GEMINI.md
/// distribution) so global instruction files are not polluted.
fn stripSynaptySection(allocator: Allocator, path: []const u8) void {
    const io = io_mod.get();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);
    var existing = std.ArrayList(u8).empty;
    defer existing.deinit(allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{tmp[0..]}) catch break;
        if (n == 0) break;
        existing.appendSlice(allocator, tmp[0..n]) catch break;
    }
    const marker = std.mem.indexOf(u8, existing.items, skill_install_marker) orelse return;
    // Cut everything from the blank line before the marker.
    var cut = marker;
    while (cut > 0 and existing.items[cut - 1] == '\n') cut -= 1;
    // Rewrite without the section.
    var out = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer out.close(io);
    out.writeStreamingAll(io, existing.items[0..cut]) catch {};
}

/// `synapty skills install` — copy the skill to detected platforms.
/// All platforms use the skill-directory convention:
///   Claude Code: ~/.claude/skills/synapty-task/SKILL.md
///   Codex:       ~/.codex/skills/synapty-task/SKILL.md
///   Gemini CLI:  ~/.gemini/skills/synapty-task/SKILL.md
pub fn runSkillsInstall(allocator: Allocator) !void {
    const home = sys.getenv("HOME") orelse {
        try io_mod.stderrWriteAll("error: HOME not set\n");
        std.process.exit(1);
    };

    // Migration: remove the old appended sections from global instruction
    // files (AGENTS.md / GEMINI.md) if present.
    const codex_agents = try std.fmt.allocPrint(allocator, "{s}/.codex/AGENTS.md", .{home});
    defer allocator.free(codex_agents);
    stripSynaptySection(allocator, codex_agents);
    const gemini_md = try std.fmt.allocPrint(allocator, "{s}/.gemini/GEMINI.md", .{home});
    defer allocator.free(gemini_md);
    stripSynaptySection(allocator, gemini_md);

    const platforms = [_]struct { label: []const u8, path: []const u8 }{
        .{ .label = "Claude Code", .path = "{s}/.claude/skills/synapty-task/SKILL.md" },
        .{ .label = "Codex", .path = "{s}/.codex/skills/synapty-task/SKILL.md" },
        .{ .label = "Gemini CLI", .path = "{s}/.gemini/skills/synapty-task/SKILL.md" },
    };
    inline for (platforms) |p| {
        const path = try std.fmt.allocPrint(allocator, p.path, .{home});
        defer allocator.free(path);
        try installSkillFile(allocator, path);
        try io_mod.stdoutWriteAll("installed: ");
        try io_mod.stdoutWriteAll(p.label);
        try io_mod.stdoutWriteAll(" skill -> ");
        try io_mod.stdoutWriteAll(path);
        try io_mod.stdoutWriteAll("\n");
    }
}

// ---------------------------------------------------------------------------
// activity subcommand — recent tool-request stream (RFC-0003 C-HUB-ROLE)
// ---------------------------------------------------------------------------

pub fn runActivity(allocator: Allocator) !void {
    try toolRoundtrip(allocator, "activity.list", json.ObjectMap.empty);
}

test "writeSendEnvelope writes a newline-terminated dm frame (WI-2026-08-08-004)" {
    // Loopback listener mimics the hub's line-framed reader: without the
    // trailing newline the frame would be dropped at EOF (the regression
    // this test guards against).
    // Arena: json.ObjectMap.put allocates its key via the allocator, and
    // the envelope payload lives until the write completes.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const listener = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    defer sys.close(listener);
    const addr4 = std.Io.net.Ip4Address.loopback(0);
    var sa = sys.sockaddr_in.init(@bitCast(addr4.bytes), 0);
    try sys.bind(listener, &sa, @sizeOf(sys.sockaddr_in));
    try sys.listen(listener, 1);
    const port = try sys.boundPort(listener);

    const client = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    defer sys.close(client);
    const ca4 = std.Io.net.Ip4Address.loopback(port);
    const csa = sys.sockaddr_in.init(@bitCast(ca4.bytes), port);
    try sys.connect(client, &csa, @sizeOf(sys.sockaddr_in));

    const server_fd = try sys.accept(listener);
    defer sys.close(server_fd);

    try writeSendEnvelope(allocator, client, "cli-tmp-test", "bob", "hello direct");

    var buf: [4096]u8 = undefined;
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = try sys.read(server_fd, buf[filled..]);
        if (n == 0) break;
        filled += n;
        if (buf[filled - 1] == '\n') break;
    }
    try std.testing.expect(filled > 0);
    try std.testing.expectEqual(@as(u8, '\n'), buf[filled - 1]);

    var parsed = try protocol.parseEnvelope(allocator, buf[0 .. filled - 1]);
    try std.testing.expectEqualStrings("dm", parsed.value.@"type");
    try std.testing.expectEqualStrings("cli-tmp-test", parsed.value.source);
    try std.testing.expectEqualStrings("bob", parsed.value.target);
    try std.testing.expectEqualStrings("hello direct", parsed.value.payload.object.get("text").?.string);
}
