//! `synapty hooks` — the hooks column of the harness adapter pack
//! (WI-2026-08-11-007). Cooperative harnesses report presence through
//! their OWN lifecycle hooks as deterministic explicit signals
//! (RFC-0004 dual-source: hooks are the cooperative path, passive
//! screen detection stays the fallback).
//!
//! Every generated command is gated on SYNAPTY_SOCK (injected into pane
//! environments by the run wrapper, src/run.zig) so hooks NO-OP for
//! harness sessions outside Synapty panes, and ends `; true` so a hook
//! failure can never block the harness. hook-event prints nothing, because
//! Claude Code injects SessionStart/UserPromptSubmit hook stdout into the
//! prompt.

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

/// Claude Code lifecycle events we hook (WI-2026-08-11-009). Every
/// event runs the SAME command; the CLI reads the hook's stdin JSON and
/// dispatches internally (planClaudeHookEvent) — SessionStart supplies
/// the real harness session identity to registration.
pub const claude_hook_events = [_][]const u8{
    "SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd",
};

/// The single hook command. No stdout redirect needed: hook-event is
/// silent by contract (SessionStart/UserPromptSubmit stdout would be
/// injected into the model's context) and always exits 0.
pub const claude_command = "[ -n \"$SYNAPTY_SOCK\" ] && synapty hook-event claude; true";

/// Substring identifying OUR hook commands — uninstall removes exactly
/// the entries containing a marker and never touches user hooks.
pub const marker = "synapty hook-event";
/// WI-2026-08-11-007 shipped per-state notify one-liners; install
/// migrates them, uninstall strips them too.
pub const legacy_marker = "synapty notify --state";

fn isOurs(cmd: []const u8) bool {
    return std.mem.indexOf(u8, cmd, marker) != null or isLegacy(cmd);
}

// ---------------------------------------------------------------------------
// hook-event dispatch (pure; IPC happens in commands.zig)
// ---------------------------------------------------------------------------

/// Planned reaction to one hook-input JSON payload.
pub const HookPlan = union(enum) {
    register: struct { project: []const u8, resume_ref: []const u8 },
    /// class null = explicit (the default the hub assumes).
    notify: struct { state: []const u8, class: ?[]const u8 = null },
    /// One event carrying both (codex agent-turn-complete: thread-id +
    /// the done edge) — the dispatcher issues register THEN notify.
    register_notify: struct { project: []const u8, resume_ref: []const u8, state: []const u8 },
    none,
};

fn getString(v: json.Value, key: []const u8) ?[]const u8 {
    const field = v.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

/// claude: map hook stdin JSON to a plan. NEVER errors — a hook must
/// never disturb the harness, so anything unparseable is .none.
/// Returned slices point into `arena`-owned memory.
pub fn planClaudeHookEvent(arena: Allocator, input: []const u8) HookPlan {
    const parsed = json.parseFromSliceLeaky(json.Value, arena, input, .{}) catch return .none;
    if (parsed != .object) return .none;
    const ev = getString(parsed, "hook_event_name") orelse return .none;
    if (std.mem.eql(u8, ev, "SessionStart")) {
        // session_id feeds resume_ref (RFC-0008 identity + RFC-0006
        // resume), NOT the free-text session description.
        const session_id = getString(parsed, "session_id") orelse "";
        const cwd = getString(parsed, "cwd") orelse "";
        return .{ .register = .{
            .project = std.fs.path.basename(cwd),
            .resume_ref = session_id,
        } };
    }
    if (std.mem.eql(u8, ev, "UserPromptSubmit")) return .{ .notify = .{ .state = "working" } };
    if (std.mem.eql(u8, ev, "Notification")) return .{ .notify = .{ .state = "waiting" } };
    if (std.mem.eql(u8, ev, "Stop")) return .{ .notify = .{ .state = "done" } };
    // WI-2026-08-11-016: the harness died/cleared — a STATUS-ONLY
    // lifecycle signal (state unknown), deliberately NOT an unregister:
    // resume plans and the durable identity must survive (the standing
    // SessionEnd decision objected to unregistering, not to honesty).
    // /clear round-trips cleanly — the next SessionStart re-registers.
    if (std.mem.eql(u8, ev, "SessionEnd")) return .{ .notify = .{ .state = "unknown", .class = "lifecycle" } };
    return .none;
}

/// codex: map the notify payload (WI-2026-08-11-011). codex fires notify
/// only at turn completion; the payload's thread-id IS the session
/// identity (UUID — verified against codex notify docs 2026-08-11), so
/// one event yields BOTH the identity claim and the done edge.
pub fn planCodexHookEvent(arena: Allocator, input: []const u8) HookPlan {
    const parsed = json.parseFromSliceLeaky(json.Value, arena, input, .{}) catch return .none;
    if (parsed != .object) return .none;
    const ev = getString(parsed, "type") orelse return .none;
    if (std.mem.eql(u8, ev, "agent-turn-complete")) {
        const thread_id = getString(parsed, "thread-id") orelse "";
        const cwd = getString(parsed, "cwd") orelse "";
        return .{ .register_notify = .{
            .project = std.fs.path.basename(cwd),
            .resume_ref = thread_id,
            .state = "done",
        } };
    }
    return .none;
}

/// codex adapter script (instructed-manual install: we write the script
/// under our own config dir; the user adds one `notify` line to
/// ~/.codex/config.toml themselves — we do not edit another tool's TOML).
pub const codex_script =
    \\#!/bin/sh
    \\# synapty codex notify adapter (WI-2026-08-11-007, upgraded by
    \\# WI-2026-08-11-011): route the payload through hook-event codex —
    \\# the JSON arrives as $1, hook-event reads stdin. thread-id feeds
    \\# the durable identity (RFC-0008) and the resume plan (RFC-0006).
    \\[ -n "$SYNAPTY_SOCK" ] || exit 0
    \\printf '%s' "$1" | synapty hook-event codex >/dev/null 2>&1
    \\exit 0
    \\
;

pub const HooksError = error{MalformedSettings};

/// Does this event's matcher-group array already contain a CURRENT
/// (non-legacy) entry of ours?
fn eventHasMarker(groups: *const json.Value) bool {
    if (groups.* != .array) return false;
    for (groups.array.items) |group| {
        if (group != .object) continue;
        const hooks_val = group.object.get("hooks") orelse continue;
        if (hooks_val != .array) continue;
        for (hooks_val.array.items) |entry| {
            if (entry != .object) continue;
            const cmd = entry.object.get("command") orelse continue;
            if (cmd == .string and std.mem.indexOf(u8, cmd.string, marker) != null)
                return true;
        }
    }
    return false;
}

/// Strip entries matching `predicate` from one event's group array,
/// in place (arena-allocated rebuild). Returns true if anything was
/// removed. Groups left empty are dropped.
fn stripEntries(
    a: Allocator,
    hooks_obj: *json.Value,
    event: []const u8,
    comptime predicate: fn ([]const u8) bool,
) !bool {
    const groups_val = hooks_obj.object.get(event) orelse return false;
    if (groups_val != .array) return false;
    var changed = false;
    var kept_groups = json.Array.init(a);
    for (groups_val.array.items) |group| {
        if (group != .object) {
            try kept_groups.append(group);
            continue;
        }
        const inner_val = group.object.get("hooks");
        if (inner_val == null or inner_val.? != .array) {
            try kept_groups.append(group);
            continue;
        }
        var kept_entries = json.Array.init(a);
        for (inner_val.?.array.items) |entry| {
            const matches = entry == .object and blk: {
                const cmd = entry.object.get("command") orelse break :blk false;
                break :blk cmd == .string and predicate(cmd.string);
            };
            if (matches) {
                changed = true;
            } else {
                try kept_entries.append(entry);
            }
        }
        if (kept_entries.items.len > 0) {
            var new_group = group;
            try new_group.object.put(a, "hooks", .{ .array = kept_entries });
            try kept_groups.append(.{ .object = new_group.object });
        }
    }
    if (kept_groups.items.len > 0) {
        try hooks_obj.object.put(a, event, .{ .array = kept_groups });
    } else {
        _ = hooks_obj.object.orderedRemove(event);
    }
    return changed;
}

fn isLegacy(cmd: []const u8) bool {
    return std.mem.indexOf(u8, cmd, legacy_marker) != null;
}

/// Merge our entries — one per event in `claude_hook_events` — into claude
/// settings JSON text. Returns the
/// new pretty-printed JSON, or null when nothing changed (already
/// installed). `settings_json` == null means the file does not exist.
/// The result is allocated with `allocator`; parsing scratch lives in
/// an internal arena.
pub fn mergeClaudeHooks(allocator: Allocator, settings_json: ?[]const u8) !?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const text = settings_json orelse "{}";
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const effective = if (trimmed.len == 0) "{}" else text;
    const parsed = json.parseFromSliceLeaky(json.Value, a, effective, .{}) catch
        return HooksError.MalformedSettings;
    if (parsed != .object) return HooksError.MalformedSettings;
    var root = parsed;

    // Ensure .hooks object.
    var hooks_val = root.object.get("hooks") orelse json.Value{ .object = json.ObjectMap.empty };
    if (hooks_val != .object) return HooksError.MalformedSettings;

    var changed = false;
    for (claude_hook_events) |event| {
        // Migration: strip WI-007-era per-state notify entries first.
        if (try stripEntries(a, &hooks_val, event, isLegacy)) changed = true;

        var groups = hooks_val.object.get(event) orelse json.Value{ .array = json.Array.init(a) };
        if (groups != .array) return HooksError.MalformedSettings;
        if (eventHasMarker(&groups)) {
            try hooks_val.object.put(a, event, groups);
            continue;
        }
        // {"hooks":[{"type":"command","command":<claude_command>}]}
        var entry = json.ObjectMap.empty;
        try entry.put(a, "type", .{ .string = "command" });
        try entry.put(a, "command", .{ .string = claude_command });
        var inner = json.Array.init(a);
        try inner.append(.{ .object = entry });
        var group = json.ObjectMap.empty;
        try group.put(a, "hooks", .{ .array = inner });
        try groups.array.append(.{ .object = group });
        try hooks_val.object.put(a, event, groups);
        changed = true;
    }
    if (!changed) return null;
    try root.object.put(a, "hooks", hooks_val);
    return try json.Stringify.valueAlloc(allocator, root, .{ .whitespace = .indent_2 });
}

/// Remove exactly our entries. Returns new JSON text, or null when
/// nothing of ours was present.
pub fn removeClaudeHooks(allocator: Allocator, settings_json: []const u8) !?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = json.parseFromSliceLeaky(json.Value, a, settings_json, .{}) catch
        return HooksError.MalformedSettings;
    if (parsed != .object) return HooksError.MalformedSettings;
    var root = parsed;
    const hooks_val = root.object.get("hooks") orelse return null;
    if (hooks_val != .object) return null;
    var hooks_obj = hooks_val;

    var changed = false;
    for (claude_hook_events) |event| {
        if (try stripEntries(a, &hooks_obj, event, isOurs)) changed = true;
    }
    if (!changed) return null;
    try root.object.put(a, "hooks", hooks_obj);
    return try json.Stringify.valueAlloc(allocator, root, .{ .whitespace = .indent_2 });
}

/// Per-event install status for `hooks status claude`.
pub fn claudeStatus(allocator: Allocator, settings_json: ?[]const u8) ![claude_hook_events.len]bool {
    var out: [claude_hook_events.len]bool = @splat(false);
    const text = settings_json orelse return out;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = json.parseFromSliceLeaky(json.Value, arena.allocator(), text, .{}) catch
        return out;
    if (parsed != .object) return out;
    const hooks_val = parsed.object.get("hooks") orelse return out;
    if (hooks_val != .object) return out;
    for (claude_hook_events, 0..) |event, i| {
        if (hooks_val.object.get(event)) |groups| {
            out[i] = eventHasMarker(&groups);
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests (WI-2026-08-11-007 shape; WI-2026-08-11-009 dispatcher + migration)
// ---------------------------------------------------------------------------

const t = std.testing;

test "merge into missing settings hooks all four events with the single command" {
    const out = (try mergeClaudeHooks(t.allocator, null)).?;
    defer t.allocator.free(out);
    for (claude_hook_events) |event| {
        try t.expect(std.mem.indexOf(u8, out, event) != null);
    }
    try t.expect(std.mem.indexOf(u8, out, "SYNAPTY_SOCK") != null);
    try t.expect(std.mem.indexOf(u8, out, marker) != null);
    const status = try claudeStatus(t.allocator, out);
    for (status) |installed| try t.expect(installed);
}

test "merge is idempotent" {
    const first = (try mergeClaudeHooks(t.allocator, null)).?;
    defer t.allocator.free(first);
    try t.expectEqual(@as(?[]const u8, null), try mergeClaudeHooks(t.allocator, first));
}

test "merge preserves user hooks and unknown fields" {
    const input =
        \\{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"my-own.sh"}]}]}}
    ;
    const out = (try mergeClaudeHooks(t.allocator, input)).?;
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, "my-own.sh") != null);
    try t.expect(std.mem.indexOf(u8, out, "\"model\"") != null);
    try t.expect(std.mem.indexOf(u8, out, marker) != null);
}

test "install migrates WI-007 legacy notify entries in place" {
    const legacy =
        \\{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"[ -n \"$SYNAPTY_SOCK\" ] && synapty notify --state done >/dev/null 2>&1; true"},{"type":"command","command":"my-own.sh"}]}]}}
    ;
    const out = (try mergeClaudeHooks(t.allocator, legacy)).?;
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, legacy_marker) == null);
    try t.expect(std.mem.indexOf(u8, out, marker) != null);
    try t.expect(std.mem.indexOf(u8, out, "my-own.sh") != null);
}

test "remove strips both generations, preserving user hooks" {
    const installed = (try mergeClaudeHooks(t.allocator,
        \\{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"my-own.sh"}]},{"hooks":[{"type":"command","command":"x synapty notify --state done y"}]}]}}
    )).?;
    defer t.allocator.free(installed);
    const removed = (try removeClaudeHooks(t.allocator, installed)).?;
    defer t.allocator.free(removed);
    try t.expect(std.mem.indexOf(u8, removed, "my-own.sh") != null);
    try t.expect(std.mem.indexOf(u8, removed, marker) == null);
    try t.expect(std.mem.indexOf(u8, removed, legacy_marker) == null);
    try t.expectEqual(@as(?[]const u8, null), try removeClaudeHooks(t.allocator, removed));
}

test "malformed settings abort unwritten" {
    try t.expectError(HooksError.MalformedSettings, mergeClaudeHooks(t.allocator, "{broken"));
    try t.expectError(HooksError.MalformedSettings, mergeClaudeHooks(t.allocator, "[1,2]"));
    try t.expectError(HooksError.MalformedSettings, removeClaudeHooks(t.allocator, "nope"));
}

test "status reports per-event" {
    var st = try claudeStatus(t.allocator, null);
    for (st) |installed| try t.expect(!installed);
    const out = (try mergeClaudeHooks(t.allocator, null)).?;
    defer t.allocator.free(out);
    st = try claudeStatus(t.allocator, out);
    for (st) |installed| try t.expect(installed);
}

test "hook-event plan: SessionStart registers with session + project basename" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const plan = planClaudeHookEvent(arena.allocator(),
        \\{"hook_event_name":"SessionStart","session_id":"abc-123","cwd":"/Users/x/proj","source":"resume"}
    );
    try t.expectEqualStrings("abc-123", plan.register.resume_ref);
    try t.expectEqualStrings("proj", plan.register.project);
}

test "hook-event plan: state events map to notify" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("working", planClaudeHookEvent(a,
        \\{"hook_event_name":"UserPromptSubmit","session_id":"s"}
    ).notify.state);
    try t.expectEqualStrings("waiting", planClaudeHookEvent(a,
        \\{"hook_event_name":"Notification"}
    ).notify.state);
    try t.expectEqualStrings("done", planClaudeHookEvent(a,
        \\{"hook_event_name":"Stop"}
    ).notify.state);
}

test "hook-event plan: unknown, malformed, and non-object inputs are inert" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(HookPlan.none, planClaudeHookEvent(a,
        \\{"hook_event_name":"PreCompact"}
    ));
    try t.expectEqual(HookPlan.none, planClaudeHookEvent(a, "{broken"));
    try t.expectEqual(HookPlan.none, planClaudeHookEvent(a, "[1]"));
    try t.expectEqual(HookPlan.none, planClaudeHookEvent(a,
        \\{"no_event":"x"}
    ));
}

test "hook-event plan: SessionEnd is a STATUS-ONLY lifecycle unknown (WI-2026-08-11-016)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plan = planClaudeHookEvent(a,
        \\{"hook_event_name":"SessionEnd","session_id":"abc","reason":"exit"}
    );
    try t.expectEqualStrings("unknown", plan.notify.state);
    try t.expectEqualStrings("lifecycle", plan.notify.class.?);
    // The other notify events stay explicit (class null).
    const stop = planClaudeHookEvent(a,
        \\{"hook_event_name":"Stop"}
    );
    try t.expectEqual(@as(?[]const u8, null), stop.notify.class);
}

test "hook-event plan: codex agent-turn-complete carries thread-id identity + done (WI-2026-08-11-011)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plan = planCodexHookEvent(a,
        \\{"type":"agent-turn-complete","thread-id":"b5f6c1c2-1111-2222-3333-444455556666","turn-id":"12345","cwd":"/Users/x/proj","input-messages":["hi"],"last-assistant-message":"done"}
    );
    try t.expectEqualStrings("b5f6c1c2-1111-2222-3333-444455556666", plan.register_notify.resume_ref);
    try t.expectEqualStrings("proj", plan.register_notify.project);
    try t.expectEqualStrings("done", plan.register_notify.state);
    // Unknown types and garbage are inert.
    try t.expectEqual(HookPlan.none, planCodexHookEvent(a,
        \\{"type":"something-else"}
    ));
    try t.expectEqual(HookPlan.none, planCodexHookEvent(a, "not json"));
}
