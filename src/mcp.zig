const std = @import("std");
const mem = std.mem;
const json = std.json;
const builtin = @import("builtin");
const Allocator = mem.Allocator;
const ipc = @import("ipc");
const protocol = @import("protocol");

const log = std.log.scoped(.mcp);

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
        const sock = std.posix.getenv("SYNAPTY_SOCK") orelse discoverSocket(allocator);
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
        const stdin = std.fs.File.stdin();
        const stdout = std.fs.File.stdout();

        var buf: [64 * 1024]u8 = undefined;
        var filled: usize = 0;

        while (true) {
            // Read more bytes into the buffer.
            const n = try stdin.read(buf[filled..]);
            if (n == 0) break; // EOF
            filled += n;

            // Process all complete lines (terminated by '\n').
            var start: usize = 0;
            while (mem.indexOfScalar(u8, buf[start..filled], '\n')) |rel| {
                const end = start + rel;
                const line = buf[start..end];
                start = end + 1;

                if (line.len == 0) continue;

                const resp = handleRequest(self.allocator, self.socket_path, line) catch |err| blk: {
                    log.err("handleRequest failed: {any}", .{err});
                    break :blk null;
                };
                if (resp) |r| {
                    defer self.allocator.free(r);
                    try stdout.writeAll(r);
                    try stdout.writeAll("\n");
                }
            }

            // Shift unconsumed bytes to the front.
            const remaining = filled - start;
            if (remaining > 0) {
                mem.copyForwards(u8, buf[0..remaining], buf[start..filled]);
            }
            filled = remaining;
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
        // Unknown method — return JSON-RPC error response.
        return @as(?[]const u8, try buildErrorResponse(allocator, id_val.?, -32601, "Method not found"));
    }
}

// ---------------------------------------------------------------------------
// Method handlers
// ---------------------------------------------------------------------------

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

    // MCP tools per [[RFC-0002:C-CLI-MCP]].
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{s},"result":{{"tools":[
        \\{{"name":"synapty_send","description":"Send a DM or channel message","inputSchema":{{"type":"object","properties":{{"target":{{"type":"string","description":"Agent ID for DM, or channel:<name> for group"}},"text":{{"type":"string","description":"Message text"}}}},"required":["target","text"]}}}},
        \\{{"name":"synapty_recv","description":"Receive pending messages","inputSchema":{{"type":"object","properties":{{}}}}}},
        \\{{"name":"synapty_agents","description":"List registered agents with metadata","inputSchema":{{"type":"object","properties":{{}}}}}},
        \\{{"name":"synapty_register","description":"Register agent identity with metadata","inputSchema":{{"type":"object","properties":{{"tool":{{"type":"string","description":"Agent platform: claude, codex, gemini, human"}},"project":{{"type":"string","description":"Project path"}},"session":{{"type":"string","description":"Session summary"}}}},"required":["tool"]}}}},
        \\{{"name":"synapty_channel_create","description":"Create a group chat channel","inputSchema":{{"type":"object","properties":{{"name":{{"type":"string","description":"Channel name"}},"description":{{"type":"string","description":"Channel description"}}}},"required":["name"]}}}},
        \\{{"name":"synapty_channel_invite","description":"Invite an agent to a channel","inputSchema":{{"type":"object","properties":{{"channel":{{"type":"string","description":"Channel name"}},"agent_id":{{"type":"string","description":"Agent to invite"}}}},"required":["channel","agent_id"]}}}},
        \\{{"name":"synapty_channel_leave","description":"Leave a channel","inputSchema":{{"type":"object","properties":{{"channel":{{"type":"string","description":"Channel name"}}}},"required":["channel"]}}}},
        \\{{"name":"synapty_channel_list","description":"List channels you are a member of","inputSchema":{{"type":"object","properties":{{}}}}}}
        \\]}}}}
    , .{id_str});
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

    // Build IPC request based on tool name.
    const ipc_req: protocol.IpcRequest = blk: {
        if (mem.eql(u8, tool_name, "synapty_send")) {
            const args_obj = if (args_val) |av| (if (av == .object) av.object else return buildErrorResponse(allocator, id, -32602, "Invalid arguments type")) else return buildErrorResponse(allocator, id, -32602, "Missing arguments");
            const target_val = args_obj.get("target") orelse return buildErrorResponse(allocator, id, -32602, "Missing target");
            const text_val = args_obj.get("text") orelse return buildErrorResponse(allocator, id, -32602, "Missing text");
            break :blk .{
                .action = .send,
                .target = if (target_val == .string) target_val.string else return buildErrorResponse(allocator, id, -32602, "Invalid target type"),
                .text = if (text_val == .string) text_val.string else return buildErrorResponse(allocator, id, -32602, "Invalid text type"),
            };
        } else if (mem.eql(u8, tool_name, "synapty_recv")) {
            break :blk .{ .action = .recv };
        } else if (mem.eql(u8, tool_name, "synapty_agents")) {
            break :blk .{ .action = .agents };
        } else if (mem.eql(u8, tool_name, "synapty_register")) {
            const args_obj = if (args_val) |av| (if (av == .object) av.object else return buildErrorResponse(allocator, id, -32602, "Invalid arguments type")) else return buildErrorResponse(allocator, id, -32602, "Missing arguments");
            const tool_val = args_obj.get("tool") orelse return buildErrorResponse(allocator, id, -32602, "Missing tool");
            const tool_str = if (tool_val == .string) tool_val.string else return buildErrorResponse(allocator, id, -32602, "Invalid tool type");
            const proj = if (args_obj.get("project")) |v| (if (v == .string) v.string else null) else null;
            const sess = if (args_obj.get("session")) |v| (if (v == .string) v.string else null) else null;
            break :blk .{ .action = .register, .tool = tool_str, .project = proj, .session = sess };
        } else if (mem.eql(u8, tool_name, "synapty_channel_create")) {
            const args_obj = if (args_val) |av| (if (av == .object) av.object else return buildErrorResponse(allocator, id, -32602, "Invalid arguments type")) else return buildErrorResponse(allocator, id, -32602, "Missing arguments");
            const name_v = args_obj.get("name") orelse return buildErrorResponse(allocator, id, -32602, "Missing name");
            const name_str = if (name_v == .string) name_v.string else return buildErrorResponse(allocator, id, -32602, "Invalid name type");
            const desc = if (args_obj.get("description")) |v| (if (v == .string) v.string else null) else null;
            break :blk .{ .action = .channel_create, .channel = name_str, .description = desc };
        } else if (mem.eql(u8, tool_name, "synapty_channel_invite")) {
            const args_obj = if (args_val) |av| (if (av == .object) av.object else return buildErrorResponse(allocator, id, -32602, "Invalid arguments type")) else return buildErrorResponse(allocator, id, -32602, "Missing arguments");
            const ch = args_obj.get("channel") orelse return buildErrorResponse(allocator, id, -32602, "Missing channel");
            const aid = args_obj.get("agent_id") orelse return buildErrorResponse(allocator, id, -32602, "Missing agent_id");
            break :blk .{ .action = .channel_invite, .channel = if (ch == .string) ch.string else return buildErrorResponse(allocator, id, -32602, "Invalid channel type"), .agent_id = if (aid == .string) aid.string else return buildErrorResponse(allocator, id, -32602, "Invalid agent_id type") };
        } else if (mem.eql(u8, tool_name, "synapty_channel_leave")) {
            const args_obj = if (args_val) |av| (if (av == .object) av.object else return buildErrorResponse(allocator, id, -32602, "Invalid arguments type")) else return buildErrorResponse(allocator, id, -32602, "Missing arguments");
            const ch = args_obj.get("channel") orelse return buildErrorResponse(allocator, id, -32602, "Missing channel");
            break :blk .{ .action = .channel_leave, .channel = if (ch == .string) ch.string else return buildErrorResponse(allocator, id, -32602, "Invalid channel type") };
        } else if (mem.eql(u8, tool_name, "synapty_channel_list")) {
            break :blk .{ .action = .channel_list };
        } else {
            return buildErrorResponse(allocator, id, -32602, "Unknown tool");
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
    var pid: i32 = switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        else => std.c.getpid(),
    };

    var depth: usize = 0;
    while (pid > 1 and depth < 16) : (depth += 1) {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/tmp/synapty-{d}.sock", .{pid}) catch return null;

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

const darwin = if (builtin.os.tag == .macos) @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/proc_info.h");
}) else struct {};

fn getParentPidDarwin(pid: i32) ?i32 {
    var info: darwin.struct_proc_bsdinfo = undefined;
    const size: c_int = @intCast(@sizeOf(darwin.struct_proc_bsdinfo));
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

    var file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    var stat_buf: [512]u8 = undefined;
    const n = file.read(&stat_buf) catch return null;
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
    std.posix.unlink(sock_path) catch {};

    var server = try ipc.IpcServer.init(sock_path);
    defer server.deinit();

    // Spawn a thread to act as the daemon: accept, read IPC request, verify fields, respond.
    const Thread = std.Thread;
    const thread = try Thread.spawn(.{}, struct {
        fn serve(srv: *ipc.IpcServer, alloc: Allocator) !void {
            const conn = try srv.accept();
            defer conn.close();
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
    std.posix.unlink(sock_path) catch {};

    var server = try ipc.IpcServer.init(sock_path);
    defer server.deinit();

    const Thread = std.Thread;
    const thread = try Thread.spawn(.{}, struct {
        fn serve(srv: *ipc.IpcServer, alloc: Allocator) !void {
            const conn = try srv.accept();
            defer conn.close();
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
    std.posix.unlink(sock_path) catch {};

    var server = try ipc.IpcServer.init(sock_path);
    defer server.deinit();

    const Thread = std.Thread;
    const thread = try Thread.spawn(.{}, struct {
        fn serve(srv: *ipc.IpcServer, alloc: Allocator) !void {
            const conn = try srv.accept();
            defer conn.close();
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

test "discoverSocket returns null when no daemon is running" {
    const result = discoverSocket(std.testing.allocator);
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

test "handleRequest: synapty_send with non-string target returns error response" {
    const allocator = std.testing.allocator;
    const line =
        \\{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"synapty_send","arguments":{"target":999,"text":"hi"}}}
    ;
    const resp = try handleRequest(allocator, null, line);
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(resp != null);
    // Should get SYNAPTY_SOCK error (null socket) or argument type error.
    try std.testing.expect(mem.indexOf(u8, resp.?, "\"error\"") != null);
}
