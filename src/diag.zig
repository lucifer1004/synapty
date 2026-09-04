const std = @import("std");
const testing = std.testing;

// ---------------------------------------------------------------------------
// Diagnostics policy
//
// Twelve files log and none of them agreed on what a level MEANS. `warn`
// outnumbered `err` 34 to 24, which is backwards for a system whose stated
// position is that silent failure is the enemy: the messages saying a
// promise had been broken were sitting at the same level as the ones
// saying a retry was about to happen.
//
// The rule is about WHAT THE READER MUST DO, not about how bad the event
// feels. Severity that tracks feeling drifts; severity that tracks
// required action does not.
//
//   err   — a PROMISE WAS BROKEN, or a feature silently did not happen.
//           Something the system already told someone it had done is now
//           untrue, or a capability is gone and nothing else will say so.
//           A human must know, and usually must act. Dropping queued mail
//           belongs here; so does failing to persist the machine's own
//           identity, and so does a background loop that never started.
//
//   warn  — the system DEGRADED AND HANDLED IT, but what the user can
//           expect has changed. A retry is scheduled, a peer refused a
//           link, one connection lost a property the others keep. Nothing
//           was silently lost; the caller was told, or the loop will come
//           back. If nobody is told and nothing comes back, it is `err`.
//
//   info  — a STATE TRANSITION worth having in a timeline when someone
//           later asks "what was this machine doing at 03:00". Link up,
//           link down, hub bound, spool flushed. Not per-message.
//
//   debug — flow detail. Off in any shipped build.
//
// THE TEST FOR err VS warn, when it is unclear: assume nobody reads this
// line. If the system still ends up correct — because a retry fires, or
// because the caller got an error response — it is `warn`. If the only
// consequence is that someone is confused later by behaviour nothing
// explains, it is `err`.
//
// WHERE THESE LINES GO. For a workbench-spawned hub, into the pipe
// HubManager reads and shows in the hub popover. For a hub started by
// `hub --ensure` — a remote machine's, or one that self-healed after a
// reboot — into `machine/hub.log` (paths.hub_log). That second path used
// to be /dev/null, which meant the machines nobody can watch were also
// the only ones keeping no record. See service.spawnDetached.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Two channels, two questions — and they MUST NOT carry the same text
//
// A failure has two audiences asking different things.
//
//   THE LOG answers WHY. Cause and identifiers: the error itself, the
//   path, the peer id, the port, the code. Its reader is whoever is
//   debugging — a human in Console.app, an operator reading
//   machine/hub.log on a server, or an AGENT on that box running
//   `log show`, which is a channel this product has and most do not.
//   That reader may arrive hours later, on a machine with no GUI, and
//   after the process that failed is gone. The log is the only channel
//   that still exists then, because a UI cannot report its own absence.
//
//   THE UI answers WHAT. Consequence and next step, shown on the object
//   it happened to, to the person using the app right now.
//
// THE SAME FAILURE SHOULD PRODUCE BOTH, AND THE TWO STRINGS MUST DIFFER.
// Writing one and using it in both places produces the two familiar bad
// outcomes: a dialog reading `NSCocoaErrorDomain Code=513`, or a log line
// reading "something went wrong". Each is the other audience's answer
// delivered to the wrong reader.
//
// A HUB HAS NO UI, so its half of the obligation is different and worth
// stating: log the WHY here, and make the WHAT derivable by putting the
// consequence on a carrier the workbench already reads. That is not a new
// idea — [[RFC-0010]] C-DIAGNOSABILITY already requires exactly this for
// capabilities, down to naming the carrier rather than leaving two
// conforming implementations both undiagnosable. Anything that silently
// changes what an agent can expect owes the same treatment.
//
// WHICH FAILURES EARN A UI: the `err` set above, unchanged. A broken
// promise or a feature that silently did not happen is precisely what a
// human needs to see. Same rule, different rendering.
// ---------------------------------------------------------------------------

/// Scoped logger. Go through here rather than calling std.log.scoped
/// directly, so the policy above is one import away from every call site
/// instead of living in a document nobody opens while writing a log line.
pub fn scoped(comptime tag: @TypeOf(.enum_literal)) type {
    return std.log.scoped(tag);
}

// ---------------------------------------------------------------------------
// Destinations — [[RFC-0012]] C-DESTINATIONS
//
// stderr is where std.log goes and where a workbench-spawned hub is read
// from, and it is not enough: a hub started for a remote machine has no
// terminal and no GUI, and the SYSTEM log is the only destination whose
// lines interleave with the SSH, sandbox and network lines they have to
// be read against. So on macOS every line goes to both.
//
// syslog(3) rather than os_log: os_log's entry points are macros with no
// callable symbol, while syslog is a plain variadic C function that macOS
// bridges into the unified log, where `log show` can read it.
// ---------------------------------------------------------------------------

const builtin = @import("builtin");

extern "c" fn syslog(priority: c_int, format: [*:0]const u8, ...) void;

/// syslog(3) priorities. err/warning/info/debug, in that order.
fn syslogPriority(level: std.log.Level) c_int {
    return switch (level) {
        .err => 3,
        .warn => 4,
        .info => 6,
        .debug => 7,
    };
}

/// The level below which nothing is emitted. Runtime rather than comptime
/// because C-LEVEL-CONTROL requires it to change WHILE RUNNING: restarting
/// a hub to raise verbosity severs A2A for every agent working on that
/// machine, so "turn it up and reproduce" would destroy the thing being
/// diagnosed.
///
/// An atomic rather than a mutex, so this module keeps its zero
/// dependencies — a single enum needs no more, and importing the io
/// module here would put a cycle one edit away.
var runtime_level: std.log.Level = .info;

pub fn setLevel(level: std.log.Level) void {
    @atomicStore(std.log.Level, &runtime_level, level, .release);
}

pub fn currentLevel() std.log.Level {
    return @atomicLoad(std.log.Level, &runtime_level, .acquire);
}

pub fn levelFromString(s: []const u8) ?std.log.Level {
    if (std.mem.eql(u8, s, "err") or std.mem.eql(u8, s, "error")) return .err;
    if (std.mem.eql(u8, s, "warn") or std.mem.eql(u8, s, "warning")) return .warn;
    if (std.mem.eql(u8, s, "info")) return .info;
    if (std.mem.eql(u8, s, "debug")) return .debug;
    return null;
}

/// Installed as std.Options.logFn from the root source file, so it
/// intercepts EVERY std.log call rather than only the ones routed through
/// `scoped` — including std's own.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(currentLevel())) return;

    // stderr through std's own path: it is what a workbench-spawned hub
    // is read through, and reimplementing its formatting would be a
    // second copy that drifts.
    std.log.defaultLog(level, scope, format, args);

    if (builtin.os.tag != .macos) return;
    // And the system log — see the destinations note above.
    var buf: [2048]u8 = undefined;
    const line = std.fmt.bufPrintZ(&buf, "[" ++ @tagName(scope) ++ "] " ++ format, args) catch {
        // Too long to format is still worth emitting — the message that
        // overflows is rarely the boring one.
        syslog(syslogPriority(level), "%s", "[" ++ @tagName(scope) ++ "] (message too long to format)");
        return;
    };
    syslog(syslogPriority(level), "%s", line.ptr);
}

test "levels parse from the words the CLI and the wire use" {
    try testing.expectEqual(std.log.Level.err, levelFromString("err").?);
    try testing.expectEqual(std.log.Level.warn, levelFromString("warn").?);
    try testing.expectEqual(std.log.Level.info, levelFromString("info").?);
    try testing.expectEqual(std.log.Level.debug, levelFromString("debug").?);
    try testing.expect(levelFromString("chatty") == null);
}

test "the level filters by severity, and changing it takes effect at once" {
    const before = currentLevel();
    defer setLevel(before);

    setLevel(.err);
    try testing.expectEqual(std.log.Level.err, currentLevel());
    setLevel(.debug);
    try testing.expectEqual(std.log.Level.debug, currentLevel());
}

test "diag.scoped is a drop-in for std.log.scoped" {
    // Cheap, but it pins the shape: if this module ever grows a wrapper
    // that changes the call signature, every logging file fails to
    // compile rather than silently losing its output.
    const l = scoped(.testscope);
    try std.testing.expect(@TypeOf(l.err) == @TypeOf(std.log.scoped(.testscope).err));
}
