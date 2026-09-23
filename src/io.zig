//! Process-wide `std.Io` instance.
//!
//! Zig 0.16 requires an `Io` value for most I/O, locking, and time APIs.
//! Synapty uses a single shared instance: the application entry point calls
//! `install()` with the `io` from `std.process.Init`; test code falls back
//! to `std.testing.io` automatically.

const std = @import("std");
const builtin = @import("builtin");

var io: std.Io = undefined;

/// ATOMIC, AND THE TEST FALLBACK STORES NOTHING.
///
/// This was a plain `bool` beside a plain two-word `std.Io`, and the test
/// fallback wrote `io` and then set the flag. Every `mutex.lock`,
/// `cond.wait`, `Timestamp.now` and `io.sleep` in this codebase goes
/// through here, and the test suite starts threads everywhere — so two
/// threads racing the initialiser could have the second observe the flag
/// before the store to `io`, on an architecture where the two plain
/// stores are freely reorderable, and call through an undefined vtable.
///
/// Production was never exposed: `install()` runs at the entry point
/// before any `spawn`, and thread creation establishes the happens-before
/// on its own. In practice the tests were usually saved by `HubState.init`
/// calling this on the main thread first — an accident of call order, not
/// a guarantee ([[WI-2026-09-12-001]]).
///
/// The fallback now RETURNS the testing instance instead of installing
/// it, so there is no second writer to order against at all.
var installed = std.atomic.Value(bool).init(false);

/// Install the process-wide Io instance. Call once at startup, before any
/// thread is spawned.
pub fn install(i: std.Io) void {
    io = i;
    installed.store(true, .release);
}

/// Return the shared Io instance. In tests (no install call) this is
/// `std.testing.io`; in production the entry point must call `install()`.
pub fn get() std.Io {
    if (installed.load(.acquire)) return io;
    if (builtin.is_test) return std.testing.io;
    @panic("io not installed: call io.install() before any I/O");
}

/// Write to process stdout (0.16 has no `std.fs.File.stdout().writeAll`).
pub fn stdoutWriteAll(bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(get(), bytes);
}

/// Write to process stderr.
pub fn stderrWriteAll(bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(get(), bytes);
}
