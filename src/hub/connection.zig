const std = @import("std");
const net = std.net;
const mem = std.mem;
const protocol = @import("protocol");
const Allocator = mem.Allocator;

// ---------------------------------------------------------------------------
// Connection — owns stream + outbound queue with dedicated writer thread
// ---------------------------------------------------------------------------

pub const Connection = struct {
    stream: net.Stream,
    allocator: Allocator,
    /// Pointers into HubState for removeConnection on final release.
    all_connections: *std.ArrayList(*Connection),
    all_connections_mutex: *std.Thread.Mutex,
    outbound: std.ArrayListUnmanaged([]const u8),
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    closed: bool,
    stream_closed: bool,
    /// Atomic reference count. Starts at 1 (reader thread owns).
    /// Cross-agent lookups retain temporarily; release frees when count hits 0.
    ref_count: std.atomic.Value(u32),

    pub fn init(
        allocator: Allocator,
        all_connections: *std.ArrayList(*Connection),
        all_connections_mutex: *std.Thread.Mutex,
        stream: net.Stream,
    ) Connection {
        return .{
            .stream = stream,
            .allocator = allocator,
            .all_connections = all_connections,
            .all_connections_mutex = all_connections_mutex,
            .outbound = .empty,
            .mutex = .{},
            .cond = .{},
            .closed = false,
            .stream_closed = false,
            .ref_count = std.atomic.Value(u32).init(1),
        };
    }

    pub fn deinit(self: *Connection) void {
        for (self.outbound.items) |item| self.allocator.free(item);
        self.outbound.deinit(self.allocator);
        if (!self.stream_closed) self.stream.close();
    }

    /// Close the stream (e.g. on spawn failure). Prevents double-close in deinit.
    pub fn closeStream(self: *Connection) void {
        if (!self.stream_closed) {
            self.stream.close();
            self.stream_closed = true;
        }
    }

    /// Increment reference count (called under routing table lock).
    pub fn retain(self: *Connection) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    /// Decrement reference count. When it hits 0, remove from tracking and free.
    pub fn release(self: *Connection) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            self.removeFromTracking();
        }
    }

    /// Remove this connection from tracking, close its stream, and free it.
    fn removeFromTracking(self: *Connection) void {
        self.all_connections_mutex.lock();
        // Find and swap-remove.
        for (self.all_connections.items, 0..) |c, idx| {
            if (c == self) {
                _ = self.all_connections.swapRemove(idx);
                break;
            }
        }
        self.all_connections_mutex.unlock();
        self.closeStream();
        self.deinit();
        self.allocator.destroy(self);
    }

    /// Enqueue a pre-serialized bytes slice for the writer thread.
    /// Duplicates data into owned storage.
    /// Returns error.ConnectionClosed if the connection is already closing.
    pub fn enqueue(self: *Connection, data: []const u8) error{ ConnectionClosed, OutOfMemory }!void {
        const copy = try self.allocator.dupe(u8, data);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) {
            self.allocator.free(copy);
            return error.ConnectionClosed;
        }
        self.outbound.append(self.allocator, copy) catch |err| {
            self.allocator.free(copy);
            return err;
        };
        self.cond.signal();
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
        self.mutex.lock();
        self.closed = true;
        self.cond.signal();
        self.mutex.unlock();
    }
};

/// Writer thread: drains the outbound queue until closed and empty.
/// Poisons the connection (closed=true) under the mutex at every exit point
/// so enqueue() never accepts a message after the writer has decided to stop.
pub fn writerThread(conn: *Connection) void {
    while (true) {
        var batch: [][]const u8 = &.{};
        {
            conn.mutex.lock();
            defer conn.mutex.unlock();
            while (conn.outbound.items.len == 0 and !conn.closed) {
                conn.cond.wait(&conn.mutex);
            }
            if (conn.closed and conn.outbound.items.len == 0) break;
            batch = conn.outbound.toOwnedSlice(conn.allocator) catch {
                // OOM — poison under lock so no new enqueues are accepted.
                conn.closed = true;
                break;
            };
        }
        var write_failed = false;
        for (batch) |item| {
            if (!write_failed) {
                conn.stream.writeAll(item) catch {
                    write_failed = true;
                };
            }
            conn.allocator.free(item);
        }
        conn.allocator.free(batch);
        if (write_failed) {
            // Poison under lock so no new enqueues are accepted.
            conn.mutex.lock();
            conn.closed = true;
            conn.mutex.unlock();
            break;
        }
    }
}
