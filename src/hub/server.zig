const std = @import("std");
const sys = @import("sys");
const io_mod = @import("io");
const mem = std.mem;
const posix = std.posix;
const protocol = @import("protocol");
const Allocator = mem.Allocator;
const log = @import("diag").scoped(.hub);

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
// Server
// ---------------------------------------------------------------------------

pub const HubServer = struct {
    listener_fd: sys.fd_t,
    bound_port: u16,
    state: HubState,
    /// Reader threads, one per accepted connection — reaped on every
    /// accept and joined in deinit ([[sys.ThreadReaper]]).
    readers: sys.ThreadReaper,
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
        const sigpipe: posix.SIG = @enumFromInt(sys.SIGPIPE);
        posix.sigaction(sigpipe, &.{
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = 0,
        }, null);

        const fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
        errdefer sys.close(fd);
        try sys.setReuseAddress(fd);
        const addr4 = std.Io.net.Ip4Address.parse(addr, port) catch {
            sys.close(fd);
            return error.InvalidListenAddress;
        };
        const sa = sys.sockaddr_in.init(@bitCast(addr4.bytes), port);
        try sys.bind(fd, &sa, @sizeOf(sys.sockaddr_in));
        try sys.listen(fd, 128);

        const bound_port = try sys.boundPort(fd);
        log.info("Synapty Hub listening on {s}:{d}", .{ addr, bound_port });

        return .{
            .listener_fd = fd,
            .bound_port = bound_port,
            .state = HubState.init(std.heap.page_allocator),
            .readers = sys.ThreadReaper.init(std.heap.page_allocator),
            .accept_thread = null,
        };
    }

    pub fn deinit(self: *HubServer) void {
        const io = io_mod.get();
        // 1. Close listener to unblock accept() in the accept loop.
        sys.close(self.listener_fd);
        // 2. Join accept thread — guarantees no more readers.spawn() calls.
        if (self.accept_thread) |t| t.join();
        // 3. Shutdown all client fds to unblock readers blocked in read().
        //    Without this, idle clients prevent deinit from completing.
        self.state.all_connections_mutex.lock(io) catch unreachable;
        for (self.state.all_connections.items) |conn| {
            // Use raw C shutdown to avoid Zig's unreachable on EBADF —
            // the reader thread may have already closed this fd.
            sys.shutdown(conn.fd, sys.SHUT.RDWR);
        }
        self.state.all_connections_mutex.unlock(io);
        // 4. Join all reader threads (now unblocked by fd shutdown), and
        //    the dial threads, whose peer connections were shut above too.
        self.readers.deinit();
        self.state.dial_threads.joinAll();
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
            const fd = sys.accept(self.listener_fd) catch |err| switch (err) {
                // Fatal: the listener is gone (normal shutdown — deinit
                // closed the fd). Propagate so the accept loop terminates.
                error.ConnectionAborted, error.Unexpected, error.SocketUnconnected => return err,
                // Transient errors (fd exhaustion, client resets,
                // backpressure): one bad accept must not kill the hub and
                // every connected agent — back off briefly and continue
                // (WI-2026-08-08-016).
                else => {
                    log.err("accept failed: {s} — continuing after backoff", .{@errorName(err)});
                    io_mod.get().sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
                    continue;
                },
            };
            // Note: no log here on purpose. The GUI HubManager health check
            // opens a probe connection (connect + close) every few seconds;
            // logging every accept would spam the log with empty
            // connections. Real connections log on register/tool_request
            // in the reader thread.

            // Create Connection on heap and register in all_connections BEFORE
            // spawning the reader thread, so deinit can always shutdown the
            // fd even if the thread hasn't started yet.
            // A SUBSCRIBER THAT STOPS READING must not pin the writer and
            // grow the queue forever: the holder side has this bound
            // (RFC-0014 C-STALLED-CLIENT), the hub side did not
            // ([[WI-2026-09-02-015]]). A write that waits this long fails,
            // and the writer thread closes the connection.
            sys.setSendTimeout(fd, stalled_client_ms) catch {};
            // Reaping happens where the work already is: whatever finished
            // since the last accept is joined now, so the list holds only
            // live connections.
            _ = self.readers.reap();

            const conn = self.state.allocator.create(Connection) catch {
                sys.close(fd);
                continue;
            };
            conn.* = Connection.init(
                self.state.allocator,
                fd,
                @ptrCast(&self.state),
                &HubState.releaseConnection,
            );
            {
                self.state.all_connections_mutex.lock(io_mod.get()) catch unreachable;
                defer self.state.all_connections_mutex.unlock(io_mod.get());
                self.state.all_connections.append(self.state.allocator, conn) catch {
                    conn.deinit();
                    self.state.allocator.destroy(conn);
                    continue;
                };
            }

            self.readers.spawn(readerThread, .{ReaderArgs{
                .state = &self.state,
                .conn = conn,
            }}) catch |err| {
                // Spawned-but-untrackable threads were already joined by
                // the reaper; either way the connection is ours to end.
                log.err("failed to spawn handler thread: {any}", .{err});
                conn.shutdown();
                sys.shutdown(conn.fd, sys.SHUT.RDWR);
                conn.release(); // refcount -> 0 -> releaseConnection
                continue;
            };
        }
    }

    /// How many reader threads are alive right now, after joining the ones
    /// that finished. For the soak test that pins the leak closed.
    pub fn liveReaderThreads(self: *HubServer) usize {
        _ = self.readers.reap();
        return self.readers.live();
    }

    /// Thirty seconds without the peer draining a write is a stalled
    /// client, not a slow one.
    pub const stalled_client_ms: u64 = 30_000;

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

test "accept loop returns when the listener is closed (WI-2026-08-08-034)" {
    // The accept-loop error handling: a closed listener (normal shutdown)
    // must terminate the loop with a fatal error — and the TRANSIENT
    // branch (backoff + continue) is what keeps EMFILE-class errors from
    // killing the hub. This test pins the fatal classification so the
    // loop cannot regress into spinning or hanging.
    var server = try HubServer.initWithAddress("127.0.0.1", 0);
    // Close the listener out from under the loop (what deinit does).
    sys.close(server.listener_fd);
    // EBADF now maps to ConnectionAborted (normal shutdown) instead of
    // falling into posix.unexpectedErrno, which ABORTED test builds
    // (WI-2026-08-09-022 drive-by fix).
    try std.testing.expectError(error.ConnectionAborted, server.run());
}
