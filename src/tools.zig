const std = @import("std");
const json = std.json;
const mem = std.mem;
const github = @import("github");
const Allocator = mem.Allocator;

// ---------------------------------------------------------------------------
// Task-tool execution — [[RFC-0003]] C-EVENTS, as amended by [[RFC-0009]]
//
// THIS CODE HOLDS THE CREDENTIAL, and that is why it lives here and not
// in the hub. A hub that loaded the GitHub PAT from the macOS Keychain
// and called the API itself would be non-relocatable regardless of any
// process boundary — move it to a Linux server and there is no Keychain,
// no `security` CLI and no token. [[ADR-0008]] decision 6: a hub routes,
// and anything requiring the human's credentials executes at the
// workbench. This module is what the workbench runs.
//
// Nothing here knows about connections, hubs, or agents. It takes tool
// arguments and returns a result — which is what makes it callable from the
// CLI (`synapty tools exec`) with no hub in the picture at all.
// ---------------------------------------------------------------------------

pub const Result = struct {
    ok: bool,
    data: ?json.Value = null,
    err: ?[]const u8 = null,

    pub fn failure(msg: []const u8) Result {
        return .{ .ok = false, .err = msg };
    }
};

/// Tools that MUST run at the workbench, because that is where the human's
/// credentials are. `activity.list` is DELIBERATELY ABSENT: it reads the
/// hub's own activity stream, needs no credential, and stays hub-side.
/// Splitting on "does this need the human's secret" is the whole point.
///
/// WHERE THEY RUN AT THE WORKBENCH DIFFERS, and this predicate deliberately
/// does not care. The task verbs are executed by `exec` below, in a CLI
/// subprocess the workbench spawns. The FILE verbs are not: a transfer
/// belongs to the workbench's own resident transfer service, which owns the
/// queue, the concurrency limit and the record ([[ADR-0010]]) — spawning a
/// subprocess for one would put the queue somewhere it cannot be seen or
/// cancelled. The workbench routes them; the hub only needs to know they
/// go there.
pub fn isCredentialTool(tool: []const u8) bool {
    return mem.eql(u8, tool, "task.list") or
        mem.eql(u8, tool, "task.show") or
        mem.eql(u8, tool, "task.claim") or
        mem.eql(u8, tool, "task.update") or
        mem.eql(u8, tool, "task.comment") or
        mem.eql(u8, tool, "task.create") or
        isFileTool(tool) or
        isViewTool(tool);
}

/// Transfers between machines ([[RFC-0013]] C-BROKER). Served in the
/// workbench's own process, never by `exec`.
pub fn isFileTool(tool: []const u8) bool {
    return mem.eql(u8, tool, "file.put") or mem.eql(u8, tool, "file.fetch");
}

/// Agent-requested views ([[RFC-0013]] C-PRIMITIVES). Served in the
/// workbench's own process: a port forward belongs to the connection the
/// workbench holds, and the view belongs to its window.
pub fn isViewTool(tool: []const u8) bool {
    return mem.eql(u8, tool, "view.expose") or
        mem.eql(u8, tool, "view.withdraw") or
        mem.eql(u8, tool, "view.present") or
        mem.eql(u8, tool, "view.ask") or
        mem.eql(u8, tool, "view.answer") or
        // NOT A FIFTH PRIMITIVE, and the bound in [[RFC-0013]]
        // C-PRIMITIVES holds. `view.status` presents nothing: it is the
        // other half of `expose`, which put a page in front of a human and
        // left the agent that put it there unable to learn whether it
        // loaded. `agent.identify` presents nothing either — it tells a
        // caller which machine and session it is already in.
        mem.eql(u8, tool, "view.status") or
        mem.eql(u8, tool, "agent.identify");
}

pub fn exec(arena: Allocator, tool: []const u8, args: json.ObjectMap) Result {
    if (mem.eql(u8, tool, "task.list")) return taskList(arena, args);
    if (mem.eql(u8, tool, "task.show")) return taskShow(arena, args);
    if (mem.eql(u8, tool, "task.claim")) return taskClaim(arena, args);
    if (mem.eql(u8, tool, "task.update")) return taskUpdate(arena, args);
    if (mem.eql(u8, tool, "task.comment")) return taskComment(arena, args);
    if (mem.eql(u8, tool, "task.create")) return taskCreate(arena, args);
    // A file verb reaching here means the workbench routed it to a
    // subprocess instead of to its transfer service. Say which mistake it
    // is rather than "unknown tool", which would send the reader looking
    // for a missing implementation.
    if (isFileTool(tool)) return Result.failure("file transfers are served by the workbench, not by exec");
    if (isViewTool(tool)) return Result.failure("views are served by the workbench, not by exec");
    return Result.failure("unknown tool");
}

// ---------------------------------------------------------------------------
// Credential + API plumbing
// ---------------------------------------------------------------------------

const Bridge = struct {
    api: github.Api,
    /// GitHub username for claim assignee; may be null.
    username: ?[]const u8,
};

fn loadBridge(arena: Allocator, err_msg: *?[]const u8) ?Bridge {
    const config = github.Config.load(arena) catch {
        err_msg.* = "github not configured: run `synapty github login` on the login device";
        return null;
    } orelse {
        err_msg.* = "github not configured: run `synapty github login` on the login device";
        return null;
    };
    const account = std.fmt.allocPrint(arena, "{s}/{s}", .{ config.owner, config.repo }) catch {
        err_msg.* = "out of memory";
        return null;
    };
    const token = github.loadToken(arena, account) catch {
        err_msg.* = "github token unavailable in Keychain";
        return null;
    } orelse {
        err_msg.* = "github token not found: run `synapty github login`";
        return null;
    };
    return .{
        .api = .{ .allocator = arena, .owner = config.owner, .repo = config.repo, .token = token },
        .username = config.username,
    };
}

pub fn objGetString(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Validate a wire-supplied issue number (WI-2026-08-08-003).
/// Returns null for out-of-range or non-integral values. The magnitude is
/// bounded BEFORE any float->int conversion so the safety-checked
/// @intFromFloat / @intCast can never panic.
pub fn parseIssueNumber(number_val: json.Value) ?u32 {
    return switch (number_val) {
        .integer => |i| std.math.cast(u32, i),
        .float => |f| blk: {
            if (std.math.isNan(f) or std.math.isInf(f)) break :blk null;
            if (f < 0 or f >= 4294967296.0) break :blk null; // outside u32 range
            const i: i64 = @intFromFloat(f); // safe: |f| < 2^32
            if (@as(f64, @floatFromInt(i)) != f) break :blk null; // must be integral
            break :blk @intCast(i);
        },
        else => null,
    };
}

/// Shrink a GitHub issue JSON into the compact task shape.
pub fn compactIssue(arena: Allocator, issue: json.Value) !json.Value {
    var out = json.ObjectMap.empty;
    if (issue != .object) return .{ .object = out };
    const obj = issue.object;
    if (obj.get("number")) |n| try out.put(arena, "number", n);
    if (objGetString(obj, "title")) |t| try out.put(arena, "title", .{ .string = t });
    if (objGetString(obj, "state")) |st| try out.put(arena, "state", .{ .string = st });
    if (objGetString(obj, "html_url")) |u| try out.put(arena, "url", .{ .string = u });

    if (obj.get("labels")) |labels| {
        var arr = json.Array.init(arena);
        switch (labels) {
            .array => |arr_val| for (arr_val.items) |item| {
                switch (item) {
                    .object => |lo| if (objGetString(lo, "name")) |name|
                        try arr.append(.{ .string = name }),
                    else => {},
                }
            },
            else => {},
        }
        try out.put(arena, "labels", .{ .array = arr });
    }

    if (obj.get("assignee")) |a| {
        switch (a) {
            .object => |ao| if (objGetString(ao, "login")) |login|
                try out.put(arena, "assignee", .{ .string = login }),
            else => {},
        }
    }
    return .{ .object = out };
}

/// Replace state labels (s:*) on an issue with the given one.
fn updateStateLabels(arena: Allocator, api: *const github.Api, number: u32, new_state_label: []const u8, close: bool) ![]const u8 {
    const path = try std.fmt.allocPrint(arena, "/repos/{s}/{s}/issues/{d}", .{ api.owner, api.repo, number });
    defer arena.free(path);
    const body = try api.request(.GET, path, null);
    const parsed = try json.parseFromSlice(json.Value, arena, body, .{ .allocate = .alloc_always });
    var kept = std.ArrayList([]const u8).empty;
    if (parsed.value == .object) {
        if (parsed.value.object.get("labels")) |labels| {
            if (labels == .array) {
                for (labels.array.items) |item| {
                    if (item != .object) continue;
                    const name = objGetString(item.object, "name") orelse continue;
                    if (mem.startsWith(u8, name, "s:")) continue;
                    try kept.append(arena, name);
                }
            }
        }
    }
    try kept.append(arena, new_state_label);
    return api.updateIssue(number, if (close) "closed" else "open", kept.items, null);
}

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

fn taskList(arena: Allocator, args: json.ObjectMap) Result {
    const labels = objGetString(args, "labels");
    // Default to "all" so done issues (closed + s:done) are visible; the
    // caller filters by state. "open" would hide every completed task.
    const state = objGetString(args, "state") orelse "all";
    var err_msg: ?[]const u8 = null;
    const bridge = loadBridge(arena, &err_msg) orelse return Result.failure(err_msg orelse "github unavailable");
    const body = bridge.api.listIssues(labels, state) catch return Result.failure("github api error");
    const parsed = json.parseFromSlice(json.Value, arena, body, .{ .allocate = .alloc_always }) catch
        return Result.failure("github returned unparseable json");
    var out = json.Array.init(arena);
    switch (parsed.value) {
        .array => |arr_val| for (arr_val.items) |item| {
            out.append(compactIssue(arena, item) catch continue) catch {};
        },
        else => {},
    }
    return .{ .ok = true, .data = .{ .array = out } };
}

/// ONE ISSUE, WITH WHAT HAS BEEN SAID ABOUT IT
/// ([[RFC-0003:C-CLI-TOOLS]]).
///
/// The body AND the comments, because an agent handed an issue number
/// wants to know what the issue says, and one round trip here answers
/// that where two would. `task list` carries neither: it compacts every
/// issue down to a title, which is what a listing should do and is why an
/// agent working the queue was working from titles.
///
/// A COMMENT-LESS ISSUE IS AN EMPTY LIST AND SUCCESS. A question nobody
/// has answered yet is the ordinary case, not a failure to read.
fn taskShow(arena: Allocator, args: json.ObjectMap) Result {
    const number_val = args.get("number") orelse return Result.failure("missing number");
    const number: u32 = parseIssueNumber(number_val) orelse
        return Result.failure("number must be an integer in range");
    var err_msg: ?[]const u8 = null;
    const bridge = loadBridge(arena, &err_msg) orelse return Result.failure(err_msg orelse "github unavailable");

    const issue_body = bridge.api.getIssue(number) catch return Result.failure("github api error (show)");
    const issue_parsed = json.parseFromSlice(json.Value, arena, issue_body, .{ .allocate = .alloc_always }) catch
        return Result.failure("github returned unparseable json");
    const compact = compactIssue(arena, issue_parsed.value) catch return Result.failure("out of memory");
    var out = compact.object;
    // The one field a listing drops and a reader came for.
    if (issue_parsed.value == .object) {
        if (objGetString(issue_parsed.value.object, "body")) |b|
            out.put(arena, "body", .{ .string = b }) catch return Result.failure("out of memory");
    }

    const comments_body = bridge.api.listComments(number) catch return Result.failure("github api error (comments)");
    const comments_parsed = json.parseFromSlice(json.Value, arena, comments_body, .{ .allocate = .alloc_always }) catch
        return Result.failure("github returned unparseable json");
    var comments = json.Array.init(arena);
    switch (comments_parsed.value) {
        // IN THE ORDER THE FORGE GAVE THEM. GitHub returns a discussion
        // oldest-first, and a second ordering here would be a second
        // answer to a settled question.
        .array => |arr| for (arr.items) |item| {
            comments.append(compactComment(arena, item) catch continue) catch {};
        },
        else => {},
    }
    out.put(arena, "comments", .{ .array = comments }) catch return Result.failure("out of memory");
    return .{ .ok = true, .data = .{ .object = out } };
}

/// Who said it and what they said. The rest of a GitHub comment object is
/// forge bookkeeping an agent has no use for.
pub fn compactComment(arena: Allocator, comment: json.Value) !json.Value {
    var out = json.ObjectMap.empty;
    if (comment != .object) return .{ .object = out };
    const obj = comment.object;
    if (obj.get("user")) |u| switch (u) {
        .object => |uo| if (objGetString(uo, "login")) |login|
            try out.put(arena, "author", .{ .string = login }),
        else => {},
    };
    if (objGetString(obj, "body")) |b| try out.put(arena, "body", .{ .string = b });
    if (objGetString(obj, "created_at")) |c| try out.put(arena, "created_at", .{ .string = c });
    return .{ .object = out };
}

fn taskClaim(arena: Allocator, args: json.ObjectMap) Result {
    const number_val = args.get("number") orelse return Result.failure("missing number");
    const number: u32 = parseIssueNumber(number_val) orelse
        return Result.failure("number must be an integer in range");
    var err_msg: ?[]const u8 = null;
    const bridge = loadBridge(arena, &err_msg) orelse return Result.failure(err_msg orelse "github unavailable");
    // Labels are replaced wholesale by the API, so preserve non-state ones.
    const body = updateStateLabels(arena, &bridge.api, number, "s:doing", false) catch
        return Result.failure("github api error (claim)");
    // updateStateLabels does not touch assignees — set it now.
    if (bridge.username) |u| {
        _ = bridge.api.updateIssue(number, null, null, u) catch
            return Result.failure("github api error (claim assignee)");
    }
    const parsed = json.parseFromSlice(json.Value, arena, body, .{ .allocate = .alloc_always }) catch
        return Result.failure("github returned unparseable json");
    return .{ .ok = true, .data = compactIssue(arena, parsed.value) catch return Result.failure("out of memory") };
}

fn taskUpdate(arena: Allocator, args: json.ObjectMap) Result {
    const number_val = args.get("number") orelse return Result.failure("missing number");
    const number: u32 = parseIssueNumber(number_val) orelse
        return Result.failure("number must be an integer in range");
    const status = objGetString(args, "status") orelse
        return Result.failure("missing status (todo|doing|done)");
    // REFUSED, NOT COERCED. A status outside the three used to become
    // todo — an agent that misspelt "done" reopened its own task and was
    // told ok — and it was discovered only after the credential had been
    // loaded to act on it ([[WI-2026-09-02-024]]).
    const label = if (mem.eql(u8, status, "todo"))
        "s:todo"
    else if (mem.eql(u8, status, "doing"))
        "s:doing"
    else if (mem.eql(u8, status, "done"))
        "s:done"
    else
        return Result.failure("status must be one of todo|doing|done");
    var err_msg: ?[]const u8 = null;
    const bridge = loadBridge(arena, &err_msg) orelse return Result.failure(err_msg orelse "github unavailable");
    const close = mem.eql(u8, status, "done");
    const body = updateStateLabels(arena, &bridge.api, number, label, close) catch
        return Result.failure("github api error (update)");
    const parsed = json.parseFromSlice(json.Value, arena, body, .{ .allocate = .alloc_always }) catch
        return Result.failure("github returned unparseable json");
    return .{ .ok = true, .data = compactIssue(arena, parsed.value) catch return Result.failure("out of memory") };
}

fn taskComment(arena: Allocator, args: json.ObjectMap) Result {
    const number_val = args.get("number") orelse return Result.failure("missing number");
    const number: u32 = parseIssueNumber(number_val) orelse
        return Result.failure("number must be an integer in range");
    // NOTE the body arrives ALREADY ATTRIBUTED. RFC-0003 1.1.0 stamps the
    // requesting connection's bound identity HUB-side, because only the hub
    // knows which identity a connection holds — an agent-composed signature
    // would be forgeable prose. Moving execution here must not move the
    // stamp here; it would become a claim the executor cannot verify.
    const body_text = objGetString(args, "body") orelse return Result.failure("missing body");
    var err_msg: ?[]const u8 = null;
    const bridge = loadBridge(arena, &err_msg) orelse return Result.failure(err_msg orelse "github unavailable");
    const resp_body = bridge.api.addComment(number, body_text) catch
        return Result.failure("github api error (comment)");
    const parsed = json.parseFromSlice(json.Value, arena, resp_body, .{ .allocate = .alloc_always }) catch
        return Result.failure("github returned unparseable json");
    const id: ?json.Value = if (parsed.value == .object) parsed.value.object.get("id") else null;
    return .{ .ok = true, .data = id };
}

fn taskCreate(arena: Allocator, args: json.ObjectMap) Result {
    const title = objGetString(args, "title") orelse return Result.failure("missing title");
    // Already attributed hub-side — see taskComment.
    const body_text = objGetString(args, "body");
    const project = objGetString(args, "project") orelse return Result.failure("missing project (p:<name>)");
    var err_msg: ?[]const u8 = null;
    const bridge = loadBridge(arena, &err_msg) orelse return Result.failure(err_msg orelse "github unavailable");
    const labels: []const []const u8 = &.{ project, "s:todo" };
    const body = bridge.api.createIssue(title, body_text, labels) catch
        return Result.failure("github api error (create)");
    const parsed = json.parseFromSlice(json.Value, arena, body, .{ .allocate = .alloc_always }) catch
        return Result.failure("github returned unparseable json");
    return .{ .ok = true, .data = compactIssue(arena, parsed.value) catch return Result.failure("out of memory") };
}

// ---------------------------------------------------------------------------
// Serialization — the wire shape `synapty tools exec` prints
// ---------------------------------------------------------------------------

pub fn resultToJson(arena: Allocator, r: Result) !json.Value {
    var obj = json.ObjectMap.empty;
    try obj.put(arena, "ok", .{ .bool = r.ok });
    if (r.data) |d| try obj.put(arena, "data", d);
    if (r.err) |e| try obj.put(arena, "error", .{ .string = e });
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "isCredentialTool splits on the human's secret, not on the name prefix" {
    try testing.expect(isCredentialTool("task.list"));
    try testing.expect(isCredentialTool("task.create"));
    // Reads the hub's OWN activity stream — no credential, so it stays
    // hub-side and must not be routed to a workbench.
    try testing.expect(!isCredentialTool("activity.list"));
    try testing.expect(!isCredentialTool("task.nonsense"));
}

test "parseIssueNumber rejects out-of-range and non-integral values (WI-2026-08-08-003)" {
    try testing.expectEqual(@as(?u32, 0), parseIssueNumber(.{ .integer = 0 }));
    try testing.expectEqual(@as(?u32, 1), parseIssueNumber(.{ .integer = 1 }));
    try testing.expectEqual(@as(?u32, 4294967295), parseIssueNumber(.{ .integer = 4294967295 }));
    try testing.expectEqual(@as(?u32, 12), parseIssueNumber(.{ .float = 12.0 }));
    try testing.expectEqual(@as(?u32, 0), parseIssueNumber(.{ .float = 0.0 }));
    // Out of u32 range, negative, non-integral, NaN/Inf, wrong type.
    try testing.expectEqual(@as(?u32, null), parseIssueNumber(.{ .integer = 4294967296 }));
    try testing.expectEqual(@as(?u32, null), parseIssueNumber(.{ .integer = -1 }));
    try testing.expectEqual(@as(?u32, null), parseIssueNumber(.{ .float = 12.5 }));
    try testing.expectEqual(@as(?u32, null), parseIssueNumber(.{ .float = -1.0 }));
    try testing.expectEqual(@as(?u32, null), parseIssueNumber(.{ .float = 5e9 }));
    try testing.expectEqual(@as(?u32, null), parseIssueNumber(.{ .float = std.math.nan(f64) }));
    try testing.expectEqual(@as(?u32, null), parseIssueNumber(.{ .float = std.math.inf(f64) }));
    try testing.expectEqual(@as(?u32, null), parseIssueNumber(.{ .integer = -4294967296 }));
    try testing.expectEqual(@as(?u32, null), parseIssueNumber(.{ .float = 1e30 }));
    try testing.expectEqual(@as(?u32, null), parseIssueNumber(.{ .float = 3.5 }));
    try testing.expectEqual(@as(?u32, null), parseIssueNumber(.{ .float = 4294967296.0 }));
    try testing.expectEqual(@as(?u32, null), parseIssueNumber(.{ .string = "12" }));
    try testing.expectEqual(@as(?u32, null), parseIssueNumber(.null));
}

test "arg validation fails before any credential load" {
    // These must NOT reach the Keychain: a missing argument is the
    // caller's error, and touching the credential to discover that would
    // prompt the human for nothing.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const empty = json.ObjectMap.empty;
    try testing.expectEqualStrings("missing number", exec(a, "task.show", empty).err.?);
    try testing.expectEqualStrings("missing number", exec(a, "task.claim", empty).err.?);
    try testing.expectEqualStrings("missing number", exec(a, "task.update", empty).err.?);
    try testing.expectEqualStrings("missing number", exec(a, "task.comment", empty).err.?);
    try testing.expectEqualStrings("missing title", exec(a, "task.create", empty).err.?);
    try testing.expectEqualStrings("unknown tool", exec(a, "task.nope", empty).err.?);

    var bad_number = json.ObjectMap.empty;
    try bad_number.put(a, "number", .{ .string = "12" });
    try testing.expectEqualStrings(
        "number must be an integer in range",
        exec(a, "task.claim", bad_number).err.?,
    );

    // A status outside the three is the caller's error too, and it is
    // caught before the credential is loaded — this test has none.
    var bad_status = json.ObjectMap.empty;
    try bad_status.put(a, "number", .{ .integer = 12 });
    try bad_status.put(a, "status", .{ .string = "finished" });
    try testing.expectEqualStrings(
        "status must be one of todo|doing|done",
        exec(a, "task.update", bad_status).err.?,
    );
}

test "compactIssue keeps the task shape and drops the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw =
        \\{"number":7,"title":"fix it","state":"open","html_url":"https://x/7",
        \\ "labels":[{"name":"p:synapty"},{"name":"s:doing"}],
        \\ "assignee":{"login":"octocat"},"body":"long body","user":{"login":"other"}}
    ;
    const parsed = try json.parseFromSliceLeaky(json.Value, a, raw, .{});
    const compact = try compactIssue(a, parsed);
    const obj = compact.object;
    try testing.expectEqual(@as(i64, 7), obj.get("number").?.integer);
    try testing.expectEqualStrings("fix it", obj.get("title").?.string);
    try testing.expectEqualStrings("https://x/7", obj.get("url").?.string);
    try testing.expectEqualStrings("octocat", obj.get("assignee").?.string);
    try testing.expectEqual(@as(usize, 2), obj.get("labels").?.array.items.len);
    // Not part of the task shape — dropped rather than passed through.
    try testing.expect(obj.get("body") == null);
    try testing.expect(obj.get("user") == null);
}

test "resultToJson carries ok/data/error and omits what is absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const failed = try resultToJson(a, Result.failure("github token not found"));
    try testing.expect(!failed.object.get("ok").?.bool);
    try testing.expectEqualStrings("github token not found", failed.object.get("error").?.string);
    try testing.expect(failed.object.get("data") == null);

    const ok = try resultToJson(a, .{ .ok = true, .data = .{ .integer = 42 } });
    try testing.expect(ok.object.get("ok").?.bool);
    try testing.expectEqual(@as(i64, 42), ok.object.get("data").?.integer);
    try testing.expect(ok.object.get("error") == null);
}

test "file verbs route to the workbench but are not executed by exec" {
    // The hub forwards on this predicate, so a file verb missing from it
    // would be answered "unknown tool" instead of reaching the workbench.
    try testing.expect(isCredentialTool("file.put"));
    try testing.expect(isCredentialTool("file.fetch"));
    try testing.expect(!isCredentialTool("file.delete"));

    // And reaching exec means the workbench routed it wrong, which must say
    // so rather than read as a missing implementation.
    var args = json.ObjectMap.empty;
    const r = exec(testing.allocator, "file.put", args);
    args.deinit(testing.allocator);
    try testing.expect(!r.ok);
    try testing.expect(mem.indexOf(u8, r.err.?, "workbench") != null);
}


test "a comment is compacted to who said it and what they said" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const raw =
        \\{"id":42,"user":{"login":"operator","id":7},"body":"answered",
        \\ "created_at":"2026-09-03T10:00:00Z","html_url":"https://x","reactions":{}}
    ;
    var parsed = try json.parseFromSlice(json.Value, a, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const out = (try compactComment(a, parsed.value)).object;

    try testing.expectEqualStrings("operator", out.get("author").?.string);
    try testing.expectEqualStrings("answered", out.get("body").?.string);
    try testing.expectEqualStrings("2026-09-03T10:00:00Z", out.get("created_at").?.string);
    // The forge's bookkeeping is not an agent's business.
    try testing.expect(out.get("reactions") == null);
    try testing.expect(out.get("html_url") == null);
}

test "a comment object that is not one compacts to nothing rather than failing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // GitHub answering with something unexpected must not take the whole
    // listing down with it — taskShow skips what it cannot read.
    const out = (try compactComment(a, .{ .string = "not an object" })).object;
    try testing.expectEqual(@as(usize, 0), out.count());
}

test "reading an issue is a credential tool, served where the token is" {
    // [[RFC-0003:C-CLI-TOOLS]]: the read goes wherever `task.list` goes,
    // and never to a pane ([[WI-2026-09-03-011]]).
    try testing.expect(isCredentialTool("task.show"));
    try testing.expect(!isFileTool("task.show"));
    try testing.expect(!isViewTool("task.show"));
}
