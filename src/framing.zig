//! Newline-framed socket reader shared by the hub, the daemon, the IPC
//! server and the CLI ([[WI-2026-08-08-035]]). ONE implementation because
//! a chunked read with carry-remainder has more failure modes than it
//! looks: one-byte reads, bytes discarded past a newline, permanent death
//! on an oversized line. Each hand-rolled copy gets its own.
const std = @import("std");
const sys = @import("sys");
const io_mod = @import("io");
const mem = std.mem;

/// Newline-framed reader over a caller-provided buffer. `readLine` hands
/// out complete lines without the trailing '\n'; bytes past a newline are
/// carried to the next call, so pipelined frames are never lost. The
/// buffer is borrowed — callers keep ownership.
///
/// A returned line slice is valid only until the NEXT call on the same
/// LineBuffer (the buffer is reused); callers must consume lines before
/// reading again.
pub const LineBuffer = struct {
    buf: []u8,
    filled: usize = 0,
    /// Offset of the next unconsumed line. Bytes before `start` have been
    /// handed out; compaction (shifting the tail to the front) is DEFERRED
    /// to the next call so a returned line is never clobbered by its own
    /// carry — the classic overlap bug a naive copy-on-return hits
    /// (WI-2026-08-08-035).
    start: usize = 0,

    pub fn init(buf: []u8) LineBuffer {
        return .{ .buf = buf };
    }

    /// Read the next complete newline-terminated line (without the '\n').
    /// Returns null on EOF. `error.StreamTooLong` when a line exceeds the
    /// buffer (callers may then `dropOversizedLine` to resync and keep
    /// serving instead of dying).
    pub fn readLine(self: *LineBuffer, fd: sys.fd_t) !?[]const u8 {
        while (true) {
            if (mem.indexOfScalar(u8, self.buf[self.start..self.filled], '\n')) |rel| {
                const nl = self.start + rel;
                const line = self.buf[self.start..nl];
                self.start = nl + 1;
                return line;
            }
            if (self.start > 0) {
                // Compact consumed bytes so reads have room again.
                const remaining = self.filled - self.start;
                mem.copyForwards(u8, self.buf[0..remaining], self.buf[self.start..self.filled]);
                self.filled = remaining;
                self.start = 0;
            }
            if (self.filled >= self.buf.len) {
                return error.StreamTooLong;
            }
            const n = try sys.read(fd, self.buf[self.filled..]);
            if (n == 0) {
                if (self.filled == self.start) return null;
                const line = self.buf[self.start..self.filled];
                self.filled = 0;
                self.start = 0;
                return line; // EOF after a partial line
            }
            self.filled += n;
        }
    }

    /// Drop bytes through the next newline (or EOF), re-reading over the
    /// buffer as needed. Lets a reader survive an oversized line instead
    /// of wedging every later request.
    pub fn dropOversizedLine(self: *LineBuffer, fd: sys.fd_t) void {
        while (true) {
            if (self.start > 0) {
                const remaining = self.filled - self.start;
                mem.copyForwards(u8, self.buf[0..remaining], self.buf[self.start..self.filled]);
                self.filled = remaining;
                self.start = 0;
            }
            if (mem.indexOfScalar(u8, self.buf[0..self.filled], '\n')) |nl| {
                self.start = nl + 1;
                return;
            }
            const n = sys.read(fd, self.buf[0..]) catch {
                self.filled = 0;
                self.start = 0;
                return;
            };
            if (n == 0) {
                self.filled = 0;
                self.start = 0;
                return;
            }
            self.filled = n;
        }
    }

    /// Number of complete lines currently buffered (never reads). Used by
    /// single-shot paths that must process a buffered remainder without
    /// blocking on the socket.
    pub fn countBufferedLines(self: *const LineBuffer) usize {
        var count: usize = 0;
        for (self.buf[self.start..self.filled]) |b| {
            if (b == '\n') count += 1;
        }
        return count;
    }

    /// Reset to empty (for reuse on a fresh connection).
    pub fn reset(self: *LineBuffer) void {
        self.filled = 0;
        self.start = 0;
    }
};

// ---------------------------------------------------------------------------
// Tests ([[WI-2026-09-02-025]]): the failure modes the header names, each
// exercised over a real socketpair.
// ---------------------------------------------------------------------------

const testing = std.testing;

const Pair = struct {
    reader: sys.fd_t,
    writer: sys.fd_t,

    fn open() !Pair {
        var fds: [2]c_int = undefined;
        if (std.c.socketpair(sys.AF.UNIX, sys.SOCK.STREAM, 0, &fds) != 0) return error.Unexpected;
        return .{ .reader = fds[0], .writer = fds[1] };
    }

    fn write(self: Pair, bytes: []const u8) !void {
        try sys.writeAll(self.writer, bytes);
    }

    fn closeWriter(self: Pair) void {
        sys.close(self.writer);
    }

    fn deinit(self: Pair) void {
        sys.close(self.reader);
    }
};

test "two lines in one read are both delivered, in order" {
    const pair = try Pair.open();
    defer pair.deinit();
    var buf: [64]u8 = undefined;
    var lines = LineBuffer.init(&buf);

    try pair.write("first\nsecond\n");
    try testing.expectEqualStrings("first", (try lines.readLine(pair.reader)).?);
    try testing.expectEqualStrings("second", (try lines.readLine(pair.reader)).?);
    try testing.expectEqual(@as(usize, 0), lines.countBufferedLines());
}

test "a returned line survives until the next call, even when a carry is pending" {
    // The deferred-compaction case: with copy-on-return the carried "fg"
    // would be moved over the front of the buffer while "abcde" is still
    // the caller's.
    const pair = try Pair.open();
    defer pair.deinit();
    var buf: [8]u8 = undefined;
    var lines = LineBuffer.init(&buf);

    try pair.write("abcde\nfg");
    const first = (try lines.readLine(pair.reader)).?;
    try testing.expectEqualStrings("abcde", first);
    try pair.write("\n");
    try testing.expectEqualStrings("fg", (try lines.readLine(pair.reader)).?);
}

test "an oversized line is StreamTooLong, and after dropping it the next line is served" {
    const pair = try Pair.open();
    defer pair.deinit();
    var buf: [8]u8 = undefined;
    var lines = LineBuffer.init(&buf);

    try pair.write("0123456789abcdef\nok\n");
    try testing.expectError(error.StreamTooLong, lines.readLine(pair.reader));
    lines.dropOversizedLine(pair.reader);
    try testing.expectEqualStrings("ok", (try lines.readLine(pair.reader)).?);
}

test "EOF after a partial line yields the partial, then null" {
    const pair = try Pair.open();
    defer pair.deinit();
    var buf: [64]u8 = undefined;
    var lines = LineBuffer.init(&buf);

    try pair.write("whole\ntail");
    pair.closeWriter();
    try testing.expectEqualStrings("whole", (try lines.readLine(pair.reader)).?);
    try testing.expectEqualStrings("tail", (try lines.readLine(pair.reader)).?);
    try testing.expectEqual(@as(?[]const u8, null), try lines.readLine(pair.reader));
}

test "EOF with nothing pending is null at once" {
    const pair = try Pair.open();
    defer pair.deinit();
    var buf: [16]u8 = undefined;
    var lines = LineBuffer.init(&buf);
    pair.closeWriter();
    try testing.expectEqual(@as(?[]const u8, null), try lines.readLine(pair.reader));
}
