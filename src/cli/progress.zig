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
    /// Nothing further will happen. Text: why.
    end,

    pub fn text(self: Kind) []const u8 {
        return @tagName(self);
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
pub fn pumpLines(progress: *const Progress, fd: sys.fd_t) void {
    var buf: [4096]u8 = undefined;
    var held: usize = 0;
    while (true) {
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
