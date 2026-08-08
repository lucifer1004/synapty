//! Newline-framed socket reader shared by the hub, the daemon, the IPC
//! server and the CLI (WI-2026-08-08-035). Every one of those used to
//! hand-roll the same chunked read with carry-remainder — and each copy
//! had its own bug (one-byte reads, discarded bytes past a newline,
//! permanent death on oversized lines).
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
