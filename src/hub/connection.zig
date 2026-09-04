const std = @import("std");
const sys = @import("sys");
const io_mod = @import("io");
const mem = std.mem;
const protocol = @import("protocol");
const Allocator = mem.Allocator;

// ---------------------------------------------------------------------------
// Connection — owns fd + outbound queue with dedicated writer thread
// ---------------------------------------------------------------------------

pub const Connection = struct {
    fd: sys.fd_t,
    allocator: Allocator,
    /// Opaque context pointer passed to release_fn on final release.
    release_ctx: *anyopaque,
    /// Called on final release (ref_count hits 0) to remove from tracking,
    /// close the fd, and free the Connection. Decouples Connection from
    /// HubState internals — no raw pointer to the connection list.
    release_fn: *const fn (*anyopaque, *Connection) void,
    outbound: std.ArrayListUnmanaged([]const u8),
    mutex: std.Io.Mutex,
    cond: std.Io.Condition,
    closed: bool,
    fd_closed: bool,
    /// Atomic reference count. Starts at 1 (reader thread owns).
    /// Cross-agent lookups retain temporarily; release frees when count hits 0.
    ref_count: std.atomic.Value(u32),
    /// RFC-0008 identity binding (WI-2026-08-11-012). fallback_id is the
    /// wire-registered pane id (set once by the session loop); bound_id
    /// is the currently-bound identity — equal to fallback until an
    /// identity upgrade, reverted to fallback on displacement. Owned
    /// dupes via `allocator`; guarded by `mutex`.
    fallback_id: ?[]const u8 = null,
    bound_id: ?[]const u8 = null,

    pub fn init(
        allocator: Allocator,
        fd: sys.fd_t,
        release_ctx: *anyopaque,
        release_fn: *const fn (*anyopaque, *Connection) void,
    ) Connection {
        return .{
            .fd = fd,
            .allocator = allocator,
            .release_ctx = release_ctx,
            .release_fn = release_fn,
            .outbound = .empty,
            .mutex = .init,
            .cond = .init,
            .closed = false,
            .fd_closed = false,
            .ref_count = std.atomic.Value(u32).init(1),
        };
    }

    pub fn deinit(self: *Connection) void {
        for (self.outbound.items) |item| self.allocator.free(item);
        self.outbound.deinit(self.allocator);
        if (self.fallback_id) |f| self.allocator.free(f);
        if (self.bound_id) |b| self.allocator.free(b);
        if (!self.fd_closed) sys.close(self.fd);
    }

    /// Set the wire-registered fallback identity (once, at session
    /// registration). Also initializes bound_id to the same value.
    pub fn setIdentity(self: *Connection, id: []const u8) !void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        if (self.fallback_id) |f| self.allocator.free(f);
        if (self.bound_id) |b| self.allocator.free(b);
        self.fallback_id = try self.allocator.dupe(u8, id);
        self.bound_id = try self.allocator.dupe(u8, self.fallback_id.?);
    }

    /// Rebind to a new identity (upgrade) or back to fallback
    /// (displacement). Returns the OWNED slice now stored as bound_id —
    /// valid until the next rebind or deinit (routing keys may borrow
    /// it only while a routing entry pins the binding).
    pub fn rebindTo(self: *Connection, id: []const u8) ![]const u8 {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        const fresh = try self.allocator.dupe(u8, id);
        if (self.bound_id) |b| self.allocator.free(b);
        self.bound_id = fresh;
        return fresh;
    }

    /// Copy the current bound id into `alloc` (nil before registration).
    pub fn boundIdDupe(self: *Connection, alloc: Allocator) !?[]const u8 {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        const b = self.bound_id orelse return null;
        return try alloc.dupe(u8, b);
    }

    /// Copy the fallback id into `alloc`.
    pub fn fallbackIdDupe(self: *Connection, alloc: Allocator) !?[]const u8 {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        const f = self.fallback_id orelse return null;
        return try alloc.dupe(u8, f);
    }

    /// Close the fd (e.g. on spawn failure). Prevents double-close in deinit.
    pub fn closeStream(self: *Connection) void {
        if (!self.fd_closed) {
            sys.close(self.fd);
            self.fd_closed = true;
        }
    }

    /// Increment reference count (called under routing table lock).
    pub fn retain(self: *Connection) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    /// Decrement reference count; at zero `release_fn` runs (see the
    /// header for what it owes).
    pub fn release(self: *Connection) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            self.release_fn(self.release_ctx, self);
        }
    }

    /// Enqueue a pre-serialized bytes slice for the writer thread.
    /// Duplicates data into owned storage.
    /// Returns error.ConnectionClosed if the connection is already closing.
    pub fn enqueue(self: *Connection, data: []const u8) error{ ConnectionClosed, OutOfMemory }!void {
        const io = io_mod.get();
        const copy = try self.allocator.dupe(u8, data);
        self.mutex.lock(io) catch unreachable;
        defer self.mutex.unlock(io);
        if (self.closed) {
            self.allocator.free(copy);
            return error.ConnectionClosed;
        }
        self.outbound.append(self.allocator, copy) catch |err| {
            self.allocator.free(copy);
            return err;
        };
        self.cond.signal(io);
    }

    /// Serialize envelope, append newline, and enqueue atomically.
    pub fn enqueueEnvelope(self: *Connection, arena: Allocator, envelope: protocol.Envelope) !void {
        const raw = try protocol.serializeEnvelope(arena, envelope);
        // Build "raw\n" as a single owned buffer for atomic delivery.
        const with_nl = try arena.alloc(u8, raw.len + 1);
        @memcpy(with_nl[0..raw.len], raw);
        with_nl[raw.len] = '\n';
        try self.enqueue(with_nl);
    }

    /// Signal the writer thread to drain and stop.
    pub fn shutdown(self: *Connection) void {
        const io = io_mod.get();
        self.mutex.lock(io) catch unreachable;
        self.closed = true;
        self.cond.signal(io);
        self.mutex.unlock(io);
    }

    /// Unblock a reader blocked in read() WITHOUT closing the fd: shutdown
    /// delivers EOF to the reader while the fd number stays valid, so a
    /// concurrent writer cannot race an fd reuse (WI-2026-08-08-029). The
    /// fd itself is closed later by the reader teardown, after writer.join.
    pub fn interruptStream(self: *Connection) void {
        sys.shutdown(self.fd, sys.SHUT.RDWR);
    }
};

/// Writer thread: drains the outbound queue until closed and empty.
/// Poisons the connection (closed=true) under the mutex at every exit point
/// so enqueue() never accepts a message after the writer has decided to stop.
pub fn writerThread(conn: *Connection) void {
    const io = io_mod.get();
    while (true) {
        var batch: [][]const u8 = &.{};
        {
            conn.mutex.lock(io) catch unreachable;
            defer conn.mutex.unlock(io);
            while (conn.outbound.items.len == 0 and !conn.closed) {
                conn.cond.wait(io, &conn.mutex) catch unreachable;
            }
            if (conn.closed and conn.outbound.items.len == 0) break;
            batch = conn.outbound.toOwnedSlice(conn.allocator) catch {
                // OOM — poison under lock so no new enqueues are accepted,
                // AND WAKE THE READER: a writer that leaves quietly leaves
                // a reader parked in read() on a connection nobody will
                // ever write to again, and a relay peer's directory stays
                // reachable=true for as long as that read lasts
                // ([[WI-2026-09-02-033]]).
                conn.closed = true;
                conn.interruptStream();
                break;
            };
        }
        var write_failed = false;
        for (batch) |item| {
            if (!write_failed) {
                sys.writeAll(conn.fd, item) catch {
                    write_failed = true;
                };
            }
            conn.allocator.free(item);
        }
        conn.allocator.free(batch);
        if (write_failed) {
            // Poison under lock so no new enqueues are accepted, then wake
            // the reader so the connection is torn down rather than left
            // half-dead ([[WI-2026-09-02-033]]).
            conn.mutex.lock(io) catch unreachable;
            conn.closed = true;
            conn.mutex.unlock(io);
            conn.interruptStream();
            break;
        }
    }
}

test "a writer that fails wakes the reader instead of leaving it parked" {
    // SIGPIPE would end the test process on the failing write; the hub
    // ignores it at startup and this test does the same.
    const sigpipe: std.posix.SIG = @enumFromInt(sys.SIGPIPE);
    std.posix.sigaction(sigpipe, &.{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);
    var fds: [2]c_int = undefined;
    try std.testing.expect(std.c.socketpair(sys.AF.UNIX, sys.SOCK.STREAM, 0, &fds) == 0);
    const Noop = struct {
        fn release(_: *anyopaque, _: *Connection) void {}
    };
    var ctx: u8 = 0;
    var conn = Connection.init(std.testing.allocator, fds[0], @ptrCast(&ctx), Noop.release);
    defer conn.deinit();

    // The peer is gone, so the next write fails.
    sys.close(fds[1]);
    try conn.enqueue("hello\n");
    conn.shutdown();
    writerThread(&conn);

    // A reader on the same connection is woken (HUP/EOF) promptly rather
    // than waiting for bytes that will never come.
    const woke = try sys.waitReadable(conn.fd, 2000);
    try std.testing.expect(woke);
    var buf: [8]u8 = undefined;
    const n = sys.read(conn.fd, &buf) catch 0;
    try std.testing.expectEqual(@as(usize, 0), n);
}
