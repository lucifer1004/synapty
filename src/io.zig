//! Process-wide `std.Io` instance.
//!
//! Zig 0.16 requires an `Io` value for most I/O, locking, and time APIs.
//! Synapty uses a single shared instance: the application entry point calls
//! `install()` with the `io` from `std.process.Init`; test code falls back
//! to `std.testing.io` automatically.

const std = @import("std");
const builtin = @import("builtin");

pub var io: std.Io = undefined;
var installed = false;

/// Install the process-wide Io instance. Call once at startup.
pub fn install(i: std.Io) void {
    io = i;
    installed = true;
}

/// Return the shared Io instance. In tests (no install call) this is
/// `std.testing.io`; in production the entry point must call `install()`.
pub fn get() std.Io {
    if (!installed) {
        if (builtin.is_test) {
            io = std.testing.io;
        } else {
            @panic("io not installed: call io.install() before any I/O");
        }
        installed = true;
    }
    return io;
}

/// Write to process stdout (0.16 has no `std.fs.File.stdout().writeAll`).
pub fn stdoutWriteAll(bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(get(), bytes);
}

/// Write to process stderr.
pub fn stderrWriteAll(bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(get(), bytes);
}
