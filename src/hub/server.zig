const std = @import("std");
const net = std.net;
const mem = std.mem;
const posix = std.posix;
const protocol = @import("protocol");
const Allocator = mem.Allocator;
const log = std.log.scoped(.hub);

const Connection = @import("connection.zig").Connection;
const registry = @import("registry.zig");
const HubState = registry.HubState;
const handlers = @import("handlers.zig");
const session = @import("session.zig");
pub const ReaderArgs = session.ReaderArgs;
pub const readerThread = session.readerThread;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const default_listen_addr = "127.0.0.1";
pub const default_listen_port: u16 = 9000;

/// Per-connection receive buffer size (64 KiB).
pub const recv_buf_size = handlers.recv_buf_size;

// ---------------------------------------------------------------------------
// Connection release callback
// ---------------------------------------------------------------------------

/// Called when a Connection's ref_count hits 0. Removes it from
/// HubState.all_connections, closes the stream, and frees the allocation.
/// The ctx pointer is a *HubState cast to *anyopaque.
fn hubReleaseConnection(ctx: *anyopaque, conn: *Connection) void {
    const state: *HubState = @ptrCast(@alignCast(ctx));
    state.all_connections_mutex.lock();
    for (state.all_connections.items, 0..) |c, idx| {
        if (c == conn) {
            _ = state.all_connections.swapRemove(idx);
            break;
        }
    }
    state.all_connections_mutex.unlock();
    conn.closeStream();
    conn.deinit();
    conn.allocator.destroy(conn);
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

pub const HubServer = struct {
    listener: net.Server,
    state: HubState,
    /// Tracks spawned client handler threads for clean shutdown.
    client_threads: std.ArrayList(std.Thread),
    client_threads_mutex: std.Thread.Mutex,
    /// Accept loop thread, set by startBackground().
    accept_thread: ?std.Thread,

    pub fn init(allocator: Allocator) !HubServer {
        _ = allocator;
        return initWithAddress(default_listen_addr, default_listen_port);
    }

    /// Create a Hub bound to a specific address/port. Use port 0 for an
    /// OS-assigned ephemeral port (useful for tests).
    pub fn initWithAddress(addr: []const u8, port: u16) !HubServer {
        // Ignore SIGPIPE so writes to disconnected clients return
        // error.BrokenPipe instead of killing the process.
        posix.sigaction(posix.SIG.PIPE, &.{
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = 0,
        }, null);

        const address = try net.Address.parseIp4(addr, port);
        const listener = try address.listen(.{
            .reuse_address = true,
        });

        const bound_port = listener.listen_address.getPort();
        log.info("Synapty Hub listening on {s}:{d}", .{ addr, bound_port });

        return .{
            .listener = listener,
            .state = HubState.init(std.heap.page_allocator),
            .client_threads = std.ArrayList(std.Thread).empty,
            .client_threads_mutex = .{},
            .accept_thread = null,
        };
    }

    pub fn deinit(self: *HubServer) void {
        // 1. Close listener to unblock accept() in the accept loop.
        self.listener.deinit();
        // 2. Join accept thread — guarantees no more client_threads.append() calls.
        if (self.accept_thread) |t| t.join();
        // 3. Shutdown all client streams to unblock readers blocked in read().
        //    Without this, idle clients prevent deinit from completing.
        self.state.all_connections_mutex.lock();
        for (self.state.all_connections.items) |conn| {
            // Use raw C shutdown to avoid Zig's unreachable on EBADF —
            // the reader thread may have already closed this fd.
            _ = std.c.shutdown(conn.stream.handle, 2); // SHUT_RDWR
        }
        self.state.all_connections_mutex.unlock();
        // 4. Join all reader threads (now unblocked by stream shutdown).
        self.client_threads_mutex.lock();
        for (self.client_threads.items) |t| t.join();
        self.client_threads.deinit(std.heap.page_allocator);
        self.client_threads_mutex.unlock();
        // 5. Free shared state (including all heap-allocated connections).
        self.state.deinit();
    }

    /// Start the accept loop in a background thread. Call deinit() to stop.
    pub fn startBackground(self: *HubServer) !void {
        self.accept_thread = try std.Thread.spawn(.{}, runBackground, .{self});
    }

    /// Accept connections in a loop, spawning a reader thread per client.
    pub fn run(self: *HubServer) !void {
        while (true) {
            const accepted = try self.listener.accept();
            log.info("accepted connection from {f}", .{accepted.address});

            // Create Connection on heap and register in all_connections BEFORE
            // spawning the reader thread, so deinit can always shutdown the
            // stream even if the thread hasn't started yet.
            const conn = self.state.allocator.create(Connection) catch {
                accepted.stream.close();
                continue;
            };
            conn.* = Connection.init(
                self.state.allocator,
                accepted.stream,
                @ptrCast(&self.state),
                &hubReleaseConnection,
            );
            {
                self.state.all_connections_mutex.lock();
                defer self.state.all_connections_mutex.unlock();
                self.state.all_connections.append(self.state.allocator, conn) catch {
                    conn.deinit();
                    self.state.allocator.destroy(conn);
                    continue;
                };
            }

            const thread = std.Thread.spawn(.{}, readerThread, .{ReaderArgs{
                .state = &self.state,
                .conn = conn,
            }}) catch |err| {
                log.err("failed to spawn handler thread: {any}", .{err});
                conn.shutdown();
                conn.release(); // refcount -> 0 -> removeFromTracking
                continue;
            };
            self.client_threads_mutex.lock();
            const tracked = blk: {
                self.client_threads.append(std.heap.page_allocator, thread) catch break :blk false;
                break :blk true;
            };
            self.client_threads_mutex.unlock();

            if (!tracked) {
                // Can't track the thread — stop it now to prevent an orphaned
                // reader from accessing freed state after deinit.
                // Shutdown stream to unblock reader, then join. The reader's
                // defer will call conn.release() to clean up.
                _ = std.c.shutdown(conn.stream.handle, 2);
                thread.join();
            }
        }
    }

    pub fn startInBackground(allocator: Allocator) !*HubServer {
        const server = try allocator.create(HubServer);
        errdefer allocator.destroy(server);
        server.* = try HubServer.init(allocator);
        errdefer server.deinit();

        try server.startBackground();
        return server;
    }

    /// Return a heap-allocated slice of currently registered agent IDs.
    pub fn registeredAgents(self: *HubServer, allocator: Allocator) ![][]const u8 {
        return self.state.routing_table.agentIds(allocator);
    }
};

/// Thread entry point for background Hub execution. Errors are logged and
/// the thread exits cleanly so the GUI app is not disrupted.
/// `error.ConnectionAborted` is the normal shutdown signal (listener closed),
/// so it is swallowed silently.
pub fn runBackground(server: *HubServer) void {
    server.run() catch |err| switch (err) {
        error.ConnectionAborted => {}, // normal shutdown via deinit()
        else => log.err("Hub background thread exited with error: {}", .{err}),
    };
}
