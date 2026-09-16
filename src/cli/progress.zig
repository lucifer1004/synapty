//! What a connection is doing, told to the workbench rather than written
//! onto the session's screen ([[WI-2026-08-17-016]]).
//!
//! THE PANE IS THE SESSION'S SCREEN ([[ADR-0012]]: the holder draws
//! nothing, the pane is the session). Narration printed there is displaced
//! by the session's own screen the moment it arrives — erased by the
//! repaint, or pushed out of view by it, but gone either way — so the
//! human sees words flash past and cannot read them. They are not written
//! there any more. They are appended here, and the workbench shows them
//! for as long as they are the only thing there is to show.
//!
//! A LINE IS A FACT WITH A TIME ON IT: milliseconds since the epoch, a
//! kind, and the rest of the line. That is enough for the workbench to
//! render steps, to notice that nothing has happened for a while, and to
//! say which step a slow connection spent its time in — which until now
//! was guessed at rather than measured.
//!
//! DIAGNOSTICS NEVER FAIL LOUDLY. A channel that cannot be opened is a
//! channel that is off; a connection is not worth failing because the
//! account of it could not be written.

const std = @import("std");
const sys = @import("sys");
const io_mod = @import("io");

/// Where the workbench asks for the account to be written. Absent means
/// nobody is listening, which is the ordinary case for a CLI a human ran
/// themselves.
pub const env_var = "SYNAPTY_CONNECT_LOG";

/// The kinds a reader can rely on. Anything else is free text and is
/// shown as such — a transport's own complaints are not ours to
/// classify.
pub const Kind = enum {
    /// The connection began. Text: the transport being run.
    start,
    /// Something the transport or the far side said, verbatim.
    note,
    /// The client is dialling the session.
    attach,
    /// The session's screen has been painted. THE MOMENT THE PANE HAS
    /// SOMETHING TRUE TO SHOW, and so the moment the workbench stops
    /// showing progress in front of it.
    paint,
    /// The client returned to a session it still had a position in, so
    /// there is no screen to paint — what follows is live output, which
    /// is equally something to show.
    live,
    /// The transport died and another attempt follows.
    lost,
    /// The client has STOPPED dialling and is waiting to be told to try
    /// again. Text: how long it had been trying.
    ///
    /// NOT AN `end`. The process is alive and so is its pty, which is the
    /// point: the screen and the scrollback the human was reading are
    /// still there, and a resumed attach repaints over them rather than
    /// starting a pane from nothing ([[WI-2026-09-07-004]]).
    paused,
    /// It was told, and is dialling again.
    resumed,
    /// Nothing further will happen. Text: why.
    end,
    /// THERE IS A GAP IN WHAT THIS PANE CAN SHOW, and the session goes
    /// on. Text: which gap ([[Hole]]).
    ///
    /// NOT A `note`, WHICH IS WHERE THESE USED TO GO AND IS WHY NOBODY
    /// SAW THEM. `note` is progress narration — including the
    /// transport's own stderr, relayed line by line — and the workbench
    /// shows it in front of a pane that has not painted yet. A gap
    /// arrives on a pane that HAS painted, where that surface is gone,
    /// so it was recorded and shown to nobody ([[WI-2026-09-16-002]]).
    /// A kind of its own is what lets the workbench owe it a surface
    /// without owing one to every line ssh prints.
    hole,

    pub fn text(self: Kind) []const u8 {
        return @tagName(self);
    }
};

/// A HOLE IN WHAT THE PANE CAN SHOW, AND THE CHANNEL IT IS SAID ON.
///
/// TWO SITUATIONS, ONE RULE. A position the holder could not honour
/// leaves a repaint in place of a continuation; a catch-up the child
/// outran leaves the scrollback with a gap in it. Both are the far side
/// telling the client something about what it can and cannot show.
///
/// NEITHER IS `lost`, WHICH MEANS SOMETHING ELSE ON BOTH SIDES: "the
/// transport died and another attempt follows" here, and
/// [[ConnectProgress]]`.lostSince` there — a value only `paint` and
/// `live` clear. After a gap neither ever comes, so a pane whose output
/// was streaming in front of the human wore "Link lost — reconnecting"
/// for the rest of its attach and took the sidebar mark at sixty seconds
/// ([[WI-2026-09-11-020]]).
///
/// AND IT IS NOT A PLAIN `note` EITHER, which is where these went next
/// and is why nobody saw them: the workbench shows notes in front of a
/// pane that has not painted, and a hole arrives on one that has
/// ([[WI-2026-09-16-002]]).
///
/// A VALUE WITH A TEST RATHER THAN A CHOICE AT TWO CALL SITES. The rule
/// was pinned by a shell case that had to roll a 1 MiB retention window
/// by volume — which takes as long as the machine takes, so it passed
/// here and failed on CI twice, at twelve seconds and then at a hundred
/// and eighty ([[WI-2026-09-15-003]]). What it was really asserting is
/// this mapping, and a mapping can be asked directly.
pub const Hole = enum {
    /// The holder could not continue from the position this client held.
    position_refused,
    /// The child outran the catch-up; the scrollback has a gap.
    catch_up_outrun,

    pub fn kind(_: Hole) Kind {
        return .hole;
    }

    pub fn text(self: Hole) []const u8 {
        return switch (self) {
            .position_refused => "too much happened to continue; showing the screen as it is now",
            .catch_up_outrun => "output was lost while this client was away",
        };
    }
};

pub const Progress = struct {
    fd: ?sys.fd_t = null,

    /// Open the channel the workbench named, if it named one.
    pub fn open(path: ?[]const u8) Progress {
        const p = path orelse return .{};
        if (p.len == 0) return .{};
        return .{ .fd = sys.openAppend(p) catch null };
    }

    /// Open the channel this process's environment names.
    pub fn fromEnv() Progress {
        return open(sys.getenv(env_var));
    }

    /// WHETHER ANYONE IS LISTENING.
    ///
    /// A workbench names a channel; a human running this in a terminal of
    /// their own does not, and then this is off. What that decides is
    /// WHERE a notice may be said: to the workbench if it is listening,
    /// and otherwise to the terminal — which in that case is not a
    /// session's screen the workbench is drawing but the one the human is
    /// looking at, and the only place left ([[WI-2026-08-29-004]]).
    pub fn listening(self: *const Progress) bool {
        return self.fd != null;
    }

    pub fn close(self: *Progress) void {
        if (self.fd) |fd| sys.close(fd);
        self.fd = null;
    }

    pub fn on(self: *const Progress) bool {
        return self.fd != null;
    }

    /// One line, in one write.
    ///
    /// WHOLE LINES, APPENDED. More than one process writes here — the
    /// launch script before it hands over, and this client after — so a
    /// line assembled from several writes could be split down the middle
    /// by another writer's.
    pub fn say(self: *const Progress, kind: Kind, text: []const u8) void {
        const fd = self.fd orelse return;
        var buf: [1024]u8 = undefined;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        // A line break inside the text would be read as a second fact.
        var clean: [512]u8 = undefined;
        const n = @min(trimmed.len, clean.len);
        for (trimmed[0..n], 0..) |c, i| clean[i] = if (c == '\n' or c == '\r') ' ' else c;
        const line = std.fmt.bufPrint(&buf, "{d} {s} {s}\n", .{
            sys.nowMillis(),
            kind.text(),
            clean[0..n],
        }) catch return;
        sys.writeAll(fd, line) catch {};
    }
};

/// Read a transport's complaints into the account instead of onto the
/// pane.
///
/// SAID, NOT SWALLOWED and not shown as it arrives: an ssh that cannot
/// resolve a host has something to say, and before this it said it to the
/// terminal the session was about to repaint. Every line becomes a fact
/// with a time on it, which is also what makes the slow step in a slow
/// connection identifiable.
pub fn pumpLines(progress: *const Progress, fd: sys.fd_t, stop: *std.atomic.Value(bool)) void {
    var buf: [4096]u8 = undefined;
    var held: usize = 0;
    while (true) {
        // WAITED FOR WITH A DEADLINE, so the caller can end this.
        //
        // A PIPE REACHES END-OF-STREAM ONLY WHEN EVERY HOLDER OF ITS WRITE
        // END HAS CLOSED IT. The transport's stderr is inherited by
        // anything it spawns, so a transport that backgrounds something —
        // ssh autostarting a ControlMaster, `ssh -f`, a remote command
        // that daemonizes — leaves a grandchild holding the pipe open
        // after the transport itself is dead and reaped. A blocking read
        // then waits for the GRANDCHILD, and the attempt that joins this
        // thread waits with it: measured at 20011ms for a transport
        // leaving a `sleep 20` behind, against 16ms without one, with no
        // retry and no detach key because the input thread is not spawned
        // until after the handshake ([[WI-2026-09-09-002]]).
        //
        // THE SAME ARGUMENT [[sys.waitReadable]] IS WRITTEN FOR, and the
        // same remedy: a thread parked in read() holds no lock and checks
        // no flag until a byte arrives.
        const ready = sys.waitReadable(fd, 100) catch break;
        if (!ready) {
            // NOTHING PENDING AND NOTHING MORE WANTED. Checked only when
            // the pipe is quiet, so a transport's last words are still
            // drained before this returns.
            if (stop.load(.acquire)) break;
            continue;
        }
        const n = sys.read(fd, buf[held..]) catch break;
        if (n == 0) break;
        var end = held + n;
        var start: usize = 0;
        while (std.mem.indexOfScalar(u8, buf[start..end], '\n')) |rel| {
            const line = buf[start .. start + rel];
            if (std.mem.trim(u8, line, " \t\r").len > 0) progress.say(.note, line);
            start += rel + 1;
        }
        // A line that has not ended yet waits for the rest of itself,
        // unless it is longer than anything a transport says, in which
        // case it is said as it stands rather than growing forever.
        if (start == 0 and end == buf.len) {
            progress.say(.note, buf[0..end]);
            end = 0;
        } else if (start > 0) {
            std.mem.copyForwards(u8, buf[0 .. end - start], buf[start..end]);
            end -= start;
        }
        held = end;
    }
    if (held > 0 and std.mem.trim(u8, buf[0..held], " \t\r").len > 0) {
        progress.say(.note, buf[0..held]);
    }
}

/// HOW LONG TO WAIT BEFORE DIALLING AGAIN, AND HOW LONG TO GO ON.
///
/// A VALUE, SO THE POLICY CAN BE ASKED SOMETHING. It was a literal second
/// inside the loop, which is a policy nothing can test and nothing can
/// read ([[WI-2026-09-07-004]]).
///
/// WHY IT BACKS OFF. The old fixed second spent an outage dialling: 3600
/// attempts an hour, on a machine that may be on battery, none of which
/// could succeed any sooner than the network allowed. The first few
/// attempts are the ones worth making quickly — most drops are a Wi-Fi
/// handover or a sleep, and are over in seconds — so the ramp is fast at
/// the start and flat after.
///
/// WHY IT STOPS AT ALL, given that RFC-0014's whole premise is a session
/// outliving its client. It does not stop being ABLE to reconnect; it
/// stops SPENDING. Pausing costs nothing and is undone by one act, and a
/// laptop closed for a weekend should not wake having dialled a dead host
/// two hundred thousand times.
pub const Retry = struct {
    pub const first_ms: u64 = 1000;
    pub const cap_ms: u64 = 15_000;
    /// Thirty minutes of trying. Long enough for a reboot, a VPN
    /// reconnect or a train tunnel; short enough that a host which is
    /// gone for the day is not dialled all day.
    pub const default_budget_ms: u64 = 30 * 60 * 1000;

    /// A TEST SEAM, NAMED AS ONE, on the model of `SYNAPTY_CONFIG_ROOT`.
    ///
    /// THIRTY MINUTES IS UNREACHABLE FROM A SCRIPT, so the pause, the
    /// resume, the retry marker and every word they write had no test at
    /// all — and the busy-spin that made the pause burn a core was found
    /// by READING, in exactly the function an end-to-end test would have
    /// driven ([[WI-2026-09-08-001]]). A function nothing calls in anger
    /// is a function whose first real caller finds the bug.
    ///
    /// A VALUE THAT IS NOT A NUMBER FALLS BACK TO THE DEFAULT, and says
    /// nothing. That is the right shape for a TEST SEAM and would be the
    /// wrong one for an operator's knob — a knob that silently ignores
    /// what it was given is one nobody can tell is working, and this one
    /// decides how long a human's session goes on being dialled for. If it
    /// ever becomes something a human sets, the fallback has to become
    /// audible ([[WI-2026-09-08-015]]).
    ///
    /// A budget of ZERO is honoured rather than treated as unset: it means
    /// the first loss pauses immediately, which is a thing a test wants to
    /// ask for.
    pub const budget_env = "SYNAPTY_RETRY_BUDGET_MS";

    pub fn budgetMs() u64 {
        return budgetFrom(sys.getenv(budget_env));
    }

    /// THE READING, WITHOUT THE ENVIRONMENT. Split out so the two ways
    /// this goes wrong silently can be asked about: nothing in this tree
    /// calls `setenv` at runtime, and adding one so a test could would
    /// give up the thread-safety that buys.
    pub fn budgetFrom(raw: ?[]const u8) u64 {
        const text = raw orelse return default_budget_ms;
        if (text.len == 0) return default_budget_ms;
        return std.fmt.parseInt(u64, text, 10) catch default_budget_ms;
    }

    /// The wait after the nth consecutive loss, counting the first as 1.
    ///
    /// Doubling from a second, held at the cap. `attempt` of 0 is not a
    /// thing that happens — a wait is only ever asked for after a loss —
    /// and it answers as the first would rather than dividing by nothing.
    pub fn delayMs(attempt: usize) u64 {
        if (attempt <= 1) return first_ms;
        const shift: u6 = @intCast(@min(attempt - 1, 16));
        const scaled = first_ms *| (@as(u64, 1) <<| shift);
        return @min(scaled, cap_ms);
    }

    /// Whether to dial again, given how long the link has been down.
    ///
    /// MEASURED FROM THE LOSS, NOT COUNTED IN ATTEMPTS. A budget in
    /// attempts means the backoff silently changes how long the client
    /// tries for — the same twenty attempts is twenty seconds at the
    /// start of the ramp and five minutes at the end.
    pub fn keepTrying(down_for_ms: u64) bool {
        return down_for_ms < budgetMs();
    }
};

/// A ONE-SHOT INSTRUCTION FROM THE WORKBENCH: dial again now.
///
/// A FILE BESIDE THE ACCOUNT, and not a keystroke into the pane. The
/// workbench can type into a pane and that was the obvious way to wake a
/// paused client — but what a keystroke means depends on what receives it
/// ([[RFC-0006]] C-RESUME-RESTORE makes exactly that argument), and a
/// button pressed at the moment the link came back on its own would put a
/// stray byte into the human's shell. A file has no such race: the paused
/// client is the only reader, and it is paused precisely because nothing
/// else is happening.
///
/// DERIVED FROM THE CHANNEL THE WORKBENCH ALREADY NAMED, so there is no
/// second path to agree about. No channel means no workbench, and then
/// there is nobody to press anything.
pub const RetrySignal = struct {
    pub fn path(buf: []u8) ?[]const u8 {
        const channel = sys.getenv(env_var) orelse return null;
        if (channel.len == 0) return null;
        return std.fmt.bufPrint(buf, "{s}.retry", .{channel}) catch null;
    }

    /// TAKEN, NOT READ. The marker is consumed so one press is one
    /// attempt; left in place it would resume every pause forever after.
    pub fn take() bool {
        var buf: [512]u8 = undefined;
        const p = path(&buf) orelse return false;
        std.Io.Dir.cwd().deleteFile(io_mod.get(), p) catch return false;
        return true;
    }
};

const testing = std.testing;

fn readAll(path: []const u8, buf: []u8) ![]const u8 {
    const io = io_mod.get();
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    @memset(buf, 0);
    _ = f.readPositionalAll(io, buf, 0) catch {};
    return buf[0..std.mem.indexOfScalar(u8, buf, 0).?];
}

test "a channel nobody asked for is off, and saying things to it is harmless" {
    var p = Progress.open(null);
    defer p.close();
    try testing.expect(!p.on());
    p.say(.start, "nothing to write this to");
}

test "every line carries a time, a kind, and what was said" {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/synapty-progress-{d}.log", .{sys.nowMillis()});
    defer std.Io.Dir.cwd().deleteFile(io_mod.get(), path) catch {};

    var p = Progress.open(path);
    defer p.close();
    try testing.expect(p.on());
    p.say(.start, "ssh -T host");
    p.say(.paint, "");

    var buf: [1024]u8 = undefined;
    const body = try readAll(path, &buf);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, body, "\n"), '\n');

    const first = it.next().?;
    var f1 = std.mem.splitScalar(u8, first, ' ');
    const stamp = try std.fmt.parseInt(i64, f1.next().?, 10);
    // A time, not a counter: the workbench renders elapsed intervals from
    // these, and two writers have only the clock in common.
    try testing.expect(stamp > 1_700_000_000_000);
    try testing.expectEqualStrings("start", f1.next().?);
    try testing.expectEqualStrings("ssh", f1.next().?);

    const second = it.next().?;
    try testing.expect(std.mem.indexOf(u8, second, " paint ") != null);
}

test "a line break inside what was said does not become a second fact" {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/synapty-progress-nl-{d}.log", .{sys.nowMillis()});
    defer std.Io.Dir.cwd().deleteFile(io_mod.get(), path) catch {};

    var p = Progress.open(path);
    defer p.close();
    p.say(.note, "one\nand what looks like another");

    var buf: [1024]u8 = undefined;
    const body = try readAll(path, &buf);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "\n"));
    try testing.expect(std.mem.indexOf(u8, body, "one and what looks like another") != null);
}

test "the wait doubles from a second and holds at the cap" {
    try testing.expectEqual(@as(u64, 1000), Retry.delayMs(1));
    try testing.expectEqual(@as(u64, 2000), Retry.delayMs(2));
    try testing.expectEqual(@as(u64, 4000), Retry.delayMs(3));
    try testing.expectEqual(@as(u64, 8000), Retry.delayMs(4));
    try testing.expectEqual(@as(u64, 15000), Retry.delayMs(5));
    try testing.expectEqual(@as(u64, 15000), Retry.delayMs(6));
}

test "a very long outage never overflows the wait into something short" {
    // THE SHIFT IS THE HAZARD, not the arithmetic. `1 << 64` is undefined
    // and `1 << 200` will not compile into a u6 at all; a wrapping shift
    // would hand back a SMALLER delay the longer the outage ran, which is
    // the opposite of the whole policy.
    try testing.expectEqual(@as(u64, 15000), Retry.delayMs(64));
    try testing.expectEqual(@as(u64, 15000), Retry.delayMs(100_000));
}

test "an attempt count of zero is not a division and answers as the first" {
    try testing.expectEqual(@as(u64, 1000), Retry.delayMs(0));
}

test "the budget is measured in time down, not in attempts made" {
    try testing.expect(Retry.keepTrying(0));
    try testing.expect(Retry.keepTrying(29 * 60 * 1000));
    try testing.expect(!Retry.keepTrying(30 * 60 * 1000));
    try testing.expect(!Retry.keepTrying(24 * 60 * 60 * 1000));
    // WITH NO OVERRIDE SET, which is every case above and every run that
    // is not a test driving the pause.
    try testing.expectEqual(Retry.default_budget_ms, Retry.budgetMs());
}

test "an unusable budget is the default, and zero is zero" {
    // THE TWO WAYS THIS COULD GO WRONG SILENTLY. A parse failure landing
    // on 0 would pause every reconnect at its first loss and report
    // "stopped dialling after 0 minutes down", which is what a genuine
    // half-hour outage says; and a deliberate 0 being read as "unset"
    // would make the seam untestable. Neither had a test
    // ([[WI-2026-09-09-001]]).
    const cases = [_]struct { raw: ?[]const u8, want: u64 }{
        .{ .raw = null, .want = Retry.default_budget_ms },
        .{ .raw = "", .want = Retry.default_budget_ms },
        .{ .raw = "not-a-number", .want = Retry.default_budget_ms },
        .{ .raw = "-1", .want = Retry.default_budget_ms },
        .{ .raw = "30 minutes", .want = Retry.default_budget_ms },
        .{ .raw = "0", .want = 0 },
        .{ .raw = "2500", .want = 2500 },
    };
    for (cases) |c| try testing.expectEqual(c.want, Retry.budgetFrom(c.raw));
}

test "a pause and a resume reach the channel as their own kinds" {
    // NOT `expectEqualStrings("paused", Kind.paused.text())`, which was
    // here and is a compiler identity: `text()` IS `@tagName`. A rename
    // breaks the build, not that assertion. What can actually be wrong is
    // whether these reach the channel at all and under which word — the
    // workbench decides whether a pane may still come back from exactly
    // that ([[WI-2026-09-08-003]]).
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/synapty-progress-pause-{d}.log", .{sys.nowMillis()});
    defer std.Io.Dir.cwd().deleteFile(io_mod.get(), path) catch {};

    var p = Progress.open(path);
    defer p.close();
    p.say(.paused, "stopped dialling after 30 minutes down");
    p.say(.resumed, "dialling again");

    var buf: [1024]u8 = undefined;
    const body = try readAll(path, &buf);
    try testing.expect(std.mem.indexOf(u8, body, " paused stopped dialling") != null);
    try testing.expect(std.mem.indexOf(u8, body, " resumed dialling again") != null);
    // AND NEITHER IS AN `end`. The two must never collapse: one leaves a
    // pane that can still come back with a press, the other has nothing to
    // come back to.
    try testing.expect(std.mem.indexOf(u8, body, " end ") == null);
}

test "no channel means no retry marker, because there is nobody to press anything" {
    // `SYNAPTY_CONNECT_LOG` is unset under the test runner, which is the
    // same condition as a human running this in their own terminal.
    var buf: [512]u8 = undefined;
    try testing.expect(RetrySignal.path(&buf) == null);
    try testing.expect(!RetrySignal.take());
}

test "a hole in what the pane can show is never announced as a lost link" {
    // `lost` means the transport died and another attempt follows. For a
    // position the holder refused, the restoration is already on its way;
    // for a catch-up the child outran, the link never went down at all.
    // Saying it on that channel set [[ConnectProgress]]`.lostSince`, which
    // only `paint` and `live` clear — and after a gap neither ever comes.
    //
    // NOR A `note`, WHICH IS THE OTHER WAY TO SAY IT TO NOBODY. The
    // workbench shows notes in front of a pane that has not painted, and
    // both of these arrive on one that has ([[WI-2026-09-16-002]]).
    for ([_]Hole{ .position_refused, .catch_up_outrun }) |hole| {
        try testing.expect(hole.kind() != .lost);
        try testing.expect(hole.kind() != .note);
        try testing.expectEqual(Kind.hole, hole.kind());
        try testing.expect(hole.text().len > 0);
    }
    // AND THE TWO SAY DIFFERENT THINGS, because the human's situation
    // differs: one screen jumped under them, the other has a gap in what
    // it remembers.
    try testing.expect(!std.mem.eql(u8, Hole.position_refused.text(), Hole.catch_up_outrun.text()));
}
