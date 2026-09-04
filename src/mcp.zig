const std = @import("std");
const sys = @import("sys");
const io_mod = @import("io");
const mem = std.mem;
const json = std.json;
const builtin = @import("builtin");
const Allocator = mem.Allocator;
const ipc = @import("ipc");
const framing = @import("framing");
const protocol = @import("protocol");

const log = @import("diag").scoped(.mcp);

// ---------------------------------------------------------------------------
// McpServer
// ---------------------------------------------------------------------------

pub const McpServer = struct {
    allocator: Allocator,
    socket_path: ?[]const u8,

    /// Initialize the MCP server. Discovery order:
    /// 1. SYNAPTY_SOCK env var (set by `synapty run`)
    /// 2. Process-tree walk: check /tmp/synapty-<ancestor-pid>.sock
    pub fn init(allocator: Allocator) McpServer {
        const sock = sys.getenv("SYNAPTY_SOCK") orelse discoverSocket(allocator);
        if (sock) |s| {
            log.info("using IPC socket: {s}", .{s});
        } else {
            log.warn("no IPC socket found — tools/call will be unavailable", .{});
        }
        return .{
            .allocator = allocator,
            .socket_path = sock,
        };
    }

    /// Main I/O loop: read stdin line by line, dispatch, write stdout.
    pub fn run(self: *McpServer) !void {
        const stdout = std.Io.File.stdout();
        const io = io_mod.get();

        // THE SHARED READER, not a copy of its loop. The copy that lived
        // here read into a full buffer, got zero bytes back and took that
        // for EOF: one request over 64 KiB ended the server with no
        // message. An oversized line is now dropped and named, and the
        // next request is served ([[WI-2026-09-02-025]]).
        var buf: [64 * 1024]u8 = undefined;
        var lines = framing.LineBuffer.init(&buf);
        const stdin: sys.fd_t = 0;

        while (true) {
            const maybe_line = lines.readLine(stdin) catch |err| switch (err) {
                error.StreamTooLong => {
                    log.err("request line exceeds {d} bytes; dropped", .{buf.len});
                    lines.dropOversizedLine(stdin);
                    continue;
                },
                else => return err,
            };
            const line = maybe_line orelse break; // EOF
            if (line.len == 0) continue;

            const resp = handleRequest(self.allocator, self.socket_path, line) catch |err| blk: {
                log.err("handleRequest failed: {any}", .{err});
                break :blk null;
            };
            if (resp) |r| {
                defer self.allocator.free(r);
                try stdout.writeStreamingAll(io, r);
                try stdout.writeStreamingAll(io, "\n");
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Request dispatcher (pure — no direct I/O, testable)
// ---------------------------------------------------------------------------

/// Parse one JSON-RPC 2.0 line and return the response JSON string (allocated),
/// or null if no response should be sent (notifications).
/// Caller owns the returned slice.
pub fn handleRequest(allocator: Allocator, socket_path: ?[]const u8, line: []const u8) !?[]const u8 {
    const parsed = try json.parseFromSlice(json.Value, allocator, line, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const obj = if (parsed.value == .object) parsed.value.object else {
        // Non-object JSON — return JSON-RPC invalid request with null id.
        return @as(?[]const u8, try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":null,"error":{{"code":-32600,"message":"Invalid Request"}}}}
        , .{}));
    };

    // Extract id early so we can return error responses for malformed requests.
    const id_val = obj.get("id");

    const method_val = obj.get("method") orelse {
        if (id_val) |id| return @as(?[]const u8, try buildErrorResponse(allocator, id, -32600, "Missing method"));
        return null;
    };
    const method = if (method_val == .string) method_val.string else {
        if (id_val) |id| return @as(?[]const u8, try buildErrorResponse(allocator, id, -32600, "Invalid method type"));
        return null;
    };

    // Notifications have no "id" — do not respond.
    if (id_val == null) {
        return null;
    }

    if (mem.eql(u8, method, "initialize")) {
        return @as(?[]const u8, try handleInitialize(allocator, id_val.?));
    } else if (mem.eql(u8, method, "tools/list")) {
        return @as(?[]const u8, try handleToolsList(allocator, id_val.?));
    } else if (mem.eql(u8, method, "tools/call")) {
        const params = obj.get("params");
        return @as(?[]const u8, try handleToolsCall(allocator, socket_path, id_val.?, params));
    } else {
            return @as(?[]const u8, try buildErrorResponse(allocator, id_val.?, -32601, "Method not found"));
    }
}

// ---------------------------------------------------------------------------
// Tool metadata table
// ---------------------------------------------------------------------------

const ToolMeta = struct {
    description: []const u8,
    /// JSON schema string for inputSchema.
    schema: []const u8,
};

/// WHAT EACH ACTION LOOKS LIKE TO AN MCP CLIENT.
///
/// A SWITCH AND NOT A LIST, so the set cannot fall behind the actions that
/// exist. `handleToolsCall` already resolves an incoming name over every
/// field of [[protocol.IpcAction]], so every action is callable; the list
/// `tools/list` was built from was written out by hand beside it and had
/// fallen one short — `notify` was callable and invisible, leaving an
/// agent driving this workbench over MCP with no discoverable way to say
/// it is working, waiting or done. A switch with no `else` cannot fall
/// short: a tenth action fails to compile until it says what it is.
fn toolMeta(action: protocol.IpcAction) ToolMeta {
    return switch (action) {
        .notify => .{
            .description = "Report what you are doing: working, waiting or done",
            .schema =
            \\{"type":"object","properties":{"state":{"type":"string","description":"working, waiting or done"}},"required":["state"]}
            ,
        },
        .send => .{
            .description = "Send a DM or channel message",
            .schema =
            \\{"type":"object","properties":{"target":{"type":"string","description":"Agent ID for DM, or channel:<name> for group"},"text":{"type":"string","description":"Message text"}},"required":["target","text"]}
            ,
        },
        .recv => .{
            .description = "Receive pending messages",
            .schema =
            \\{"type":"object","properties":{}}
            ,
        },
        .agents => .{
            .description = "List registered agents with metadata",
            .schema =
            \\{"type":"object","properties":{}}
            ,
        },
        .register => .{
            .description = "Register agent identity with metadata",
            .schema =
            \\{"type":"object","properties":{"tool":{"type":"string","description":"Agent platform: claude, codex, gemini, human"},"project":{"type":"string","description":"Project path"},"session":{"type":"string","description":"Session summary"}},"required":["tool"]}
            ,
        },
        .channel_create => .{
            .description = "Create a group chat channel",
            .schema =
            \\{"type":"object","properties":{"name":{"type":"string","description":"Channel name"},"description":{"type":"string","description":"Channel description"}},"required":["name"]}
            ,
        },
        .channel_invite => .{
            .description = "Invite an agent to a channel",
            .schema =
            \\{"type":"object","properties":{"channel":{"type":"string","description":"Channel name"},"agent_id":{"type":"string","description":"Agent to invite"}},"required":["channel","agent_id"]}
            ,
        },
        .channel_leave => .{
            .description = "Leave a channel",
            .schema =
            \\{"type":"object","properties":{"channel":{"type":"string","description":"Channel name"}},"required":["channel"]}
            ,
        },
        .channel_list => .{
            .description = "List channels you are a member of",
            .schema =
            \\{"type":"object","properties":{}}
            ,
        },
    };
}

fn handleInitialize(allocator: Allocator, id: json.Value) ![]const u8 {
    const id_str = try jsonValueToString(allocator, id);
    defer allocator.free(id_str);

    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{s},"result":{{"protocolVersion":"2025-03-26","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"synapty","version":"0.1.0"}}}}}}
    , .{id_str});
}

fn handleToolsList(allocator: Allocator, id: json.Value) ![]const u8 {
    const id_str = try jsonValueToString(allocator, id);
    defer allocator.free(id_str);

    // MCP tools per [[RFC-0003:C-CLI-TOOLS]] (daemon socket), one per action.
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try out.appendSlice(allocator, id_str);
    try out.appendSlice(allocator, ",\"result\":{\"tools\":[");

    inline for (@typeInfo(protocol.IpcAction).@"enum".fields, 0..) |field, i| {
        const tool = toolMeta(@field(protocol.IpcAction, field.name));
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"name\":\"synapty_");
        try out.appendSlice(allocator, field.name);
        try out.appendSlice(allocator, "\",\"description\":\"");
        try out.appendSlice(allocator, tool.description);
        try out.appendSlice(allocator, "\",\"inputSchema\":");
        try out.appendSlice(allocator, tool.schema);
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "]}}");
    return out.toOwnedSlice(allocator);
}

fn handleToolsCall(allocator: Allocator, socket_path: ?[]const u8, id: json.Value, params: ?json.Value) ![]const u8 {
    const sock = socket_path orelse return buildErrorResponse(allocator, id, -32603, "SYNAPTY_SOCK not set — run inside a synapty session");
    const id_str = try jsonValueToString(allocator, id);
    defer allocator.free(id_str);

    const p = params orelse return buildErrorResponse(allocator, id, -32602, "Missing params");
    const p_obj = if (p == .object) p.object else return buildErrorResponse(allocator, id, -32602, "Invalid params type");

    const name_val = p_obj.get("name") orelse return buildErrorResponse(allocator, id, -32602, "Missing params.name");
    const tool_name = if (name_val == .string) name_val.string else return buildErrorResponse(allocator, id, -32602, "Invalid params.name type");

    const args_val = p_obj.get("arguments");

    // Resolve IPC action from tool name using protocol.IpcAction as SSOT.
    // Tool names follow the pattern "synapty_" ++ @tagName(action).
    const action: protocol.IpcAction = blk: {
        const prefix = "synapty_";
        if (mem.startsWith(u8, tool_name, prefix)) {
            const suffix = tool_name[prefix.len..];
            inline for (@typeInfo(protocol.IpcAction).@"enum".fields) |f| {
                if (mem.eql(u8, suffix, f.name)) break :blk @enumFromInt(f.value);
            }
        }
        return buildErrorResponse(allocator, id, -32602, "Unknown tool");
    };

    // Build IPC request with action-specific argument extraction.
    const ipc_req: protocol.IpcRequest = blk: {
        switch (action) {
            .send => {
                const args_obj = if (args_val) |av| (if (av == .object) av.object else return buildErrorResponse(allocator, id, -32602, "Invalid arguments type")) else return buildErrorResponse(allocator, id, -32602, "Missing arguments");
                const target_val = args_obj.get("target") orelse return buildErrorResponse(allocator, id, -32602, "Missing target");
                const text_val = args_obj.get("text") orelse return buildErrorResponse(allocator, id, -32602, "Missing text");
                break :blk .{
                    .action = .send,
                    .target = if (target_val == .string) target_val.string else return buildErrorResponse(allocator, id, -32602, "Invalid target type"),
                    .text = if (text_val == .string) text_val.string else return buildErrorResponse(allocator, id, -32602, "Invalid text type"),
                };
            },
            .recv => break :blk .{ .action = .recv },
            .agents => break :blk .{ .action = .agents },
            .notify => {
                // agent_status via MCP (WI-2026-08-09-022) — same contract
                // as `synapty notify --state`.
                const args_obj = if (args_val) |av| (if (av == .object) av.object else return buildErrorResponse(allocator, id, -32602, "Invalid arguments type")) else return buildErrorResponse(allocator, id, -32602, "Missing arguments");
                const state_val = args_obj.get("state") orelse return buildErrorResponse(allocator, id, -32602, "Missing state");
                const state_str = if (state_val == .string) state_val.string else return buildErrorResponse(allocator, id, -32602, "Invalid state type");
                break :blk .{ .action = .notify, .state = state_str };
            },
            .register => {
                const args_obj = if (args_val) |av| (if (av == .object) av.object else return buildErrorResponse(allocator, id, -32602, "Invalid arguments type")) else return buildErrorResponse(allocator, id, -32602, "Missing arguments");
                const tool_val = args_obj.get("tool") orelse return buildErrorResponse(allocator, id, -32602, "Missing tool");
                const tool_str = if (tool_val == .string) tool_val.string else return buildErrorResponse(allocator, id, -32602, "Invalid tool type");
                const proj = if (args_obj.get("project")) |v| (if (v == .string) v.string else null) else null;
                const sess = if (args_obj.get("session")) |v| (if (v == .string) v.string else null) else null;
                break :blk .{ .action = .register, .tool = tool_str, .project = proj, .session = sess };
            },
            .channel_create => {
                const args_obj = if (args_val) |av| (if (av == .object) av.object else return buildErrorResponse(allocator, id, -32602, "Invalid arguments type")) else return buildErrorResponse(allocator, id, -32602, "Missing arguments");
                const name_v = args_obj.get("name") orelse return buildErrorResponse(allocator, id, -32602, "Missing name");
                const name_str = if (name_v == .string) name_v.string else return buildErrorResponse(allocator, id, -32602, "Invalid name type");
                const desc = if (args_obj.get("description")) |v| (if (v == .string) v.string else null) else null;
                break :blk .{ .action = .channel_create, .channel = name_str, .description = desc };
            },
            .channel_invite => {
                const args_obj = if (args_val) |av| (if (av == .object) av.object else return buildErrorResponse(allocator, id, -32602, "Invalid arguments type")) else return buildErrorResponse(allocator, id, -32602, "Missing arguments");
                const ch = args_obj.get("channel") orelse return buildErrorResponse(allocator, id, -32602, "Missing channel");
                const aid = args_obj.get("agent_id") orelse return buildErrorResponse(allocator, id, -32602, "Missing agent_id");
                break :blk .{ .action = .channel_invite, .channel = if (ch == .string) ch.string else return buildErrorResponse(allocator, id, -32602, "Invalid channel type"), .agent_id = if (aid == .string) aid.string else return buildErrorResponse(allocator, id, -32602, "Invalid agent_id type") };
            },
            .channel_leave => {
                const args_obj = if (args_val) |av| (if (av == .object) av.object else return buildErrorResponse(allocator, id, -32602, "Invalid arguments type")) else return buildErrorResponse(allocator, id, -32602, "Missing arguments");
                const ch = args_obj.get("channel") orelse return buildErrorResponse(allocator, id, -32602, "Missing channel");
                break :blk .{ .action = .channel_leave, .channel = if (ch == .string) ch.string else return buildErrorResponse(allocator, id, -32602, "Invalid channel type") };
            },
            .channel_list => break :blk .{ .action = .channel_list },
        }
    };

    // Serialize and send IPC request, read response.
    const ipc_req_json = try protocol.serializeIpcRequest(allocator, ipc_req);
    defer allocator.free(ipc_req_json);

    var client = try ipc.IpcClient.connect(sock);
    defer client.deinit();

    try client.send(ipc_req_json);

    var resp_buf: [64 * 1024]u8 = undefined;
    const resp_line = try client.recv(&resp_buf) orelse return buildErrorResponse(allocator, id, -32603, "No IPC response");

    // Wrap IPC response as MCP content.
    // Escape the response for JSON string embedding.
    const escaped = try jsonEscapeString(allocator, resp_line);
    defer allocator.free(escaped);

    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{s},"result":{{"content":[{{"type":"text","text":"{s}"}}]}}}}
    , .{ id_str, escaped });
}

fn buildErrorResponse(allocator: Allocator, id: json.Value, code: i32, message: []const u8) ![]const u8 {
    const id_str = try jsonValueToString(allocator, id);
    defer allocator.free(id_str);

    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{s},"error":{{"code":{d},"message":"{s}"}}}}
    , .{ id_str, code, message });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Render a json.Value as a compact JSON string suitable for inline insertion.
/// Caller owns the returned slice.
fn jsonValueToString(allocator: Allocator, value: json.Value) ![]const u8 {
    return json.Stringify.valueAlloc(allocator, value, .{});
}

/// Escape a plain string so it can be safely embedded inside a JSON string literal.
/// Escapes backslashes, double-quotes, and control characters.
/// Caller owns the returned slice.
fn jsonEscapeString(allocator: Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Socket discovery via process-tree walking
// ---------------------------------------------------------------------------

/// Walk up the process tree from the current PID, checking at each ancestor
/// whether /tmp/synapty-<pid>.sock exists. Returns an allocated path if found.
fn discoverSocket(allocator: Allocator) ?[]const u8 {
    const pid: i32 = switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        else => std.c.getpid(),
    };
    return discoverSocketFrom(allocator, pid, "/tmp/synapty-");
}

/// The walk itself, with its two ambient facts handed in.
///
/// A TEST OF THIS CANNOT ASK THE MACHINE IT RUNS ON. The version that
/// took neither argument asserted "no daemon is running" while walking
/// the REAL ancestry — and this suite is run from inside a Synapty pane
/// as a matter of course, where an ancestor genuinely does answer. The
/// test then failed for being right about the world. Both the starting
/// pid and the path prefix are parameters so a test can walk a tree that
/// cannot have a socket in it.
fn discoverSocketFrom(allocator: Allocator, start_pid: i32, prefix: []const u8) ?[]const u8 {
    var pid = start_pid;
    var depth: usize = 0;
    while (pid > 1 and depth < 16) : (depth += 1) {
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}{d}.sock", .{ prefix, pid }) catch return null;

        // Try connecting to verify the socket is live (not just a stale file).
        var client = ipc.IpcClient.connect(path) catch {
            pid = getParentPid(pid) orelse return null;
            continue;
        };
        client.deinit();

        log.info("discovered daemon socket at PID {d}: {s}", .{ pid, path });
        return allocator.dupe(u8, path) catch null;
    }
    return null;
}

/// Get the parent PID of an arbitrary process. Platform-specific.
fn getParentPid(pid: i32) ?i32 {
    return switch (builtin.os.tag) {
        .macos => getParentPidDarwin(pid),
        .linux => getParentPidLinux(pid),
        else => null,
    };
}

// -- macOS: use proc_pidinfo(PROC_PIDTBSDINFO) from libproc ----------------
// Direct extern bindings (no @cImport) — zig 0.16's translate-c cannot
// instantiate the mach_msg_* types pulled in by libproc.h.

const darwin = if (builtin.os.tag == .macos) struct {
    pub const PROC_PIDTBSDINFO: c_int = 3;

    /// struct proc_bsdinfo from <sys/proc_info.h>.
    pub const proc_bsdinfo = extern struct {
        pbi_flags: u32,
        pbi_status: u32,
        pbi_xstatus: u32,
        pbi_pid: u32,
        pbi_ppid: u32,
        pbi_uid: u32,
        pbi_gid: u32,
        pbi_ruid: u32,
        pbi_rgid: u32,
        pbi_svuid: u32,
        pbi_svgid: u32,
        rfu_1: u32,
        pbi_comm: [16]u8, // MAXCOMLEN
        pbi_name: [32]u8, // 2 * MAXCOMLEN
        pbi_nfiles: u32,
        pbi_pgid: u32,
        pbi_pjobc: u32,
        e_tdev: u32,
        e_tpgid: u32,
        pbi_nice: i32,
        pbi_start_tvsec: u64,
        pbi_start_tvusec: u64,
    };

    pub extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, buffersize: c_int) c_int;
} else struct {};

fn getParentPidDarwin(pid: i32) ?i32 {
    var info: darwin.proc_bsdinfo = undefined;
    const size: c_int = @intCast(@sizeOf(darwin.proc_bsdinfo));
    const ret = darwin.proc_pidinfo(pid, darwin.PROC_PIDTBSDINFO, 0, &info, size);
    if (ret < size) return null;

    const ppid: i32 = @intCast(info.pbi_ppid);
    if (ppid <= 0) return null;
    return ppid;
}

// -- Linux: read /proc/<pid>/stat ------------------------------------------

fn getParentPidLinux(pid: i32) ?i32 {
    // /proc/<pid>/stat format: pid (comm) state ppid ...
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return null;

    const file = std.Io.Dir.cwd().openFile(io_mod.get(), path, .{}) catch return null;
    defer file.close(io_mod.get());

    var stat_buf: [512]u8 = undefined;
    const n = sys.read(file.handle, &stat_buf) catch return null;
    if (n == 0) return null;

    const data = stat_buf[0..n];
    // Find last ')' to skip comm field (may contain spaces/parens).
    const close_paren = mem.lastIndexOfScalar(u8, data, ')') orelse return null;
    if (close_paren + 4 >= n) return null;

    // After ") " comes: state ppid ...
    const rest = data[close_paren + 2 ..];
    var iter = mem.splitScalar(u8, rest, ' ');
    _ = iter.next(); // state character
    const ppid_str = iter.next() orelse return null;
    return std.fmt.parseInt(i32, ppid_str, 10) catch null;
}

// ---------------------------------------------------------------------------
// Entry point (used when compiled as part of cli)
// ---------------------------------------------------------------------------

pub fn runMcp(allocator: Allocator) !void {
    var server = McpServer.init(allocator);
    try server.run();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "handleRequest: initialize returns correct protocolVersion and serverInfo" {
    const allocator = std.testing.allocator;
    const line =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    ;
    const resp = try handleRequest(allocator, "/tmp/unused.sock", line);
    defer if (resp) |r| allocator.free(r);

    try std.testing.expect(resp != null);
    const r = resp.?;
    try std.testing.expect(mem.indexOf(u8, r, "\"protocolVersion\":\"2025-03-26\"") != null);
    try std.testing.expect(mem.indexOf(u8, r, "\"name\":\"synapty\"") != null);
    try std.testing.expect(mem.indexOf(u8, r, "\"version\":\"0.1.0\"") != null);
    try std.testing.expect(mem.indexOf(u8, r, "\"tools\":{}") != null);
}

test "handleRequest: tools/list returns 3 tools with correct names" {
    const allocator = std.testing.allocator;
    const line =
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
    ;
    const resp = try handleRequest(allocator, "/tmp/unused.sock", line);
    defer if (resp) |r| allocator.free(r);

    try std.testing.expect(resp != null);
    const r = resp.?;
    try std.testing.expect(mem.indexOf(u8, r, "\"synapty_send\"") != null);
    try std.testing.expect(mem.indexOf(u8, r, "\"synapty_recv\"") != null);
    try std.testing.expect(mem.indexOf(u8, r, "\"synapty_agents\"") != null);
}

test "handleRequest: notification (no id) returns null" {
    const allocator = std.testing.allocator;
    const line =
        \\{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
    ;
    const resp = try handleRequest(allocator, "/tmp/unused.sock", line);
    try std.testing.expect(resp == null);
}

test "handleRequest: unknown method returns JSON-RPC error -32601" {
    const allocator = std.testing.allocator;
    const line =
        \\{"jsonrpc":"2.0","id":3,"method":"bogus/method","params":{}}
    ;
    const resp = try handleRequest(allocator, "/tmp/unused.sock", line);
    defer if (resp) |r| allocator.free(r);

    try std.testing.expect(resp != null);
    const r = resp.?;
    try std.testing.expect(mem.indexOf(u8, r, "-32601") != null);
    try std.testing.expect(mem.indexOf(u8, r, "\"error\"") != null);
}

test "handleRequest: tools/call without SYNAPTY_SOCK returns error" {
    const allocator = std.testing.allocator;
    const line =
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"synapty_send","arguments":{"target":"agent-b","text":"hello"}}}
    ;
    const resp = try handleRequest(allocator, null, line);
    defer if (resp) |r| allocator.free(r);

    try std.testing.expect(resp != null);
    const r = resp.?;
    try std.testing.expect(mem.indexOf(u8, r, "\"error\"") != null);
    try std.testing.expect(mem.indexOf(u8, r, "-32603") != null);
    try std.testing.expect(mem.indexOf(u8, r, "SYNAPTY_SOCK") != null);
}

test "handleRequest: tools/call synapty_send builds correct IPC request" {
    // This test verifies the IPC request serialization by using a mock unix
    // socket server that echoes back a canned IPC response.
    const allocator = std.testing.allocator;
    const sock_path = "/tmp/synapty-mcp-test-send.sock";
    sys.unlink(sock_path);

    var server = try ipc.IpcServer.init(sock_path);
    defer server.deinit();

    // Spawn a thread to act as the daemon: accept, read IPC request, verify fields, respond.
    const Thread = std.Thread;
    const thread = try Thread.spawn(.{}, struct {
        fn serve(srv: *ipc.IpcServer, alloc: Allocator) !void {
            const conn = try srv.accept();
            defer sys.close(conn);
            var buf: [4096]u8 = undefined;
            const line = (try ipc.IpcServer.readLine(conn, &buf)) orelse return;
            // Verify the IPC request
            var parsed = try protocol.parseIpcRequest(alloc, line);
            defer parsed.deinit();
            try std.testing.expectEqual(protocol.IpcAction.send, parsed.value.action);
            try std.testing.expectEqualStrings("agent-b", parsed.value.target.?);
            try std.testing.expectEqualStrings("hello", parsed.value.text.?);
            // Respond with success
            try ipc.IpcServer.writeLine(conn, "{\"success\":true,\"data\":\"delivered\"}");
        }
    }.serve, .{ &server, allocator });

    const line =
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"synapty_send","arguments":{"target":"agent-b","text":"hello"}}}
    ;
    const resp = try handleRequest(allocator, sock_path, line);
    defer if (resp) |r| allocator.free(r);
    thread.join();

    try std.testing.expect(resp != null);
    const r = resp.?;
    try std.testing.expect(mem.indexOf(u8, r, "\"content\"") != null);
    try std.testing.expect(mem.indexOf(u8, r, "\"type\":\"text\"") != null);
}

test "handleRequest: tools/call synapty_recv builds correct IPC request" {
    const allocator = std.testing.allocator;
    const sock_path = "/tmp/synapty-mcp-test-recv.sock";
    sys.unlink(sock_path);

    var server = try ipc.IpcServer.init(sock_path);
    defer server.deinit();

    const Thread = std.Thread;
    const thread = try Thread.spawn(.{}, struct {
        fn serve(srv: *ipc.IpcServer, alloc: Allocator) !void {
            const conn = try srv.accept();
            defer sys.close(conn);
            var buf: [4096]u8 = undefined;
            const line = (try ipc.IpcServer.readLine(conn, &buf)) orelse return;
            var parsed = try protocol.parseIpcRequest(alloc, line);
            defer parsed.deinit();
            try std.testing.expectEqual(protocol.IpcAction.recv, parsed.value.action);
            try ipc.IpcServer.writeLine(conn, "{\"success\":true,\"data\":\"msg-from-agent\"}");
        }
    }.serve, .{ &server, allocator });

    const line =
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"synapty_recv","arguments":{}}}
    ;
    const resp = try handleRequest(allocator, sock_path, line);
    defer if (resp) |r| allocator.free(r);
    thread.join();

    try std.testing.expect(resp != null);
    const r = resp.?;
    try std.testing.expect(mem.indexOf(u8, r, "\"content\"") != null);
}

test "handleRequest: tools/call synapty_agents builds correct IPC request" {
    const allocator = std.testing.allocator;
    const sock_path = "/tmp/synapty-mcp-test-agents.sock";
    sys.unlink(sock_path);

    var server = try ipc.IpcServer.init(sock_path);
    defer server.deinit();

    const Thread = std.Thread;
    const thread = try Thread.spawn(.{}, struct {
        fn serve(srv: *ipc.IpcServer, alloc: Allocator) !void {
            const conn = try srv.accept();
            defer sys.close(conn);
            var buf: [4096]u8 = undefined;
            const line = (try ipc.IpcServer.readLine(conn, &buf)) orelse return;
            var parsed = try protocol.parseIpcRequest(alloc, line);
            defer parsed.deinit();
            try std.testing.expectEqual(protocol.IpcAction.agents, parsed.value.action);
            try ipc.IpcServer.writeLine(conn, "{\"success\":true,\"data\":\"agent-a,agent-b\"}");
        }
    }.serve, .{ &server, allocator });

    const line =
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"synapty_agents","arguments":{}}}
    ;
    const resp = try handleRequest(allocator, sock_path, line);
    defer if (resp) |r| allocator.free(r);
    thread.join();

    try std.testing.expect(resp != null);
    const r = resp.?;
    try std.testing.expect(mem.indexOf(u8, r, "\"content\"") != null);
}

test "getParentPid returns valid parent for current process" {
    const my_pid = std.c.getpid();
    const ppid = getParentPid(my_pid);
    // Current process must have a parent.
    try std.testing.expect(ppid != null);
    try std.testing.expect(ppid.? > 0);
    // Verify it matches libc getppid().
    try std.testing.expectEqual(std.c.getppid(), ppid.?);
}

test "the walk gives up when no ancestor answers" {
    // A PREFIX NOTHING LISTENS ON, rather than the real one — see
    // discoverSocketFrom.
    const result = discoverSocketFrom(std.testing.allocator, std.c.getpid(), "/tmp/synapty-absent-");
    try std.testing.expect(result == null);
}

// -- Finding 6: malformed input validation tests ----------------------------

test "handleRequest: non-object top-level JSON returns JSON-RPC error with null id" {
    const allocator = std.testing.allocator;
    // A JSON array is not a valid JSON-RPC request object.
    const resp = try handleRequest(allocator, "/tmp/unused.sock", "[1,2,3]");
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(resp != null);
    try std.testing.expect(mem.indexOf(u8, resp.?, "\"error\"") != null);
    try std.testing.expect(mem.indexOf(u8, resp.?, "-32600") != null);
    try std.testing.expect(mem.indexOf(u8, resp.?, "\"id\":null") != null);
}

test "handleRequest: non-string method returns JSON-RPC error response" {
    const allocator = std.testing.allocator;
    const line =
        \\{"jsonrpc":"2.0","id":99,"method":42}
    ;
    const resp = try handleRequest(allocator, "/tmp/unused.sock", line);
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(resp != null);
    try std.testing.expect(mem.indexOf(u8, resp.?, "\"error\"") != null);
    try std.testing.expect(mem.indexOf(u8, resp.?, "-32600") != null);
}

test "handleRequest: tools/call with non-object params returns error response" {
    const allocator = std.testing.allocator;
    const line =
        \\{"jsonrpc":"2.0","id":10,"method":"tools/call","params":"not-an-object"}
    ;
    const resp = try handleRequest(allocator, "/tmp/unused.sock", line);
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(resp != null);
    try std.testing.expect(mem.indexOf(u8, resp.?, "\"error\"") != null);
    try std.testing.expect(mem.indexOf(u8, resp.?, "-32602") != null);
}

test "handleRequest: tools/call with non-string tool name returns error response" {
    const allocator = std.testing.allocator;
    const line =
        \\{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":123}}
    ;
    const resp = try handleRequest(allocator, "/tmp/unused.sock", line);
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(resp != null);
    try std.testing.expect(mem.indexOf(u8, resp.?, "\"error\"") != null);
    try std.testing.expect(mem.indexOf(u8, resp.?, "-32602") != null);
}


test "tools/list offers one tool per action, and never fewer" {
    // THE RULE [[RFC-0003]] C-CLI-TOOLS leaves implicit: an action the
    // server can execute is one a client can discover (toolMeta's doc has
    // the account of the one that was not).
    const allocator = std.testing.allocator;
    const listed = try handleToolsList(allocator, .{ .integer = 1 });
    defer allocator.free(listed);

    inline for (@typeInfo(protocol.IpcAction).@"enum".fields) |field| {
        const needle = "\"synapty_" ++ field.name ++ "\"";
        try std.testing.expect(std.mem.indexOf(u8, listed, needle) != null);
    }
    // And nothing beyond them: one name apiece.
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, listed, i, "\"name\":\"synapty_")) |at| : (i = at + 1) count += 1;
    try std.testing.expectEqual(@typeInfo(protocol.IpcAction).@"enum".fields.len, count);
}
