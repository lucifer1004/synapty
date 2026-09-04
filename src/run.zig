const std = @import("std");
const sys = @import("sys");
const framing = @import("framing");
const io_mod = @import("io");
const mem = std.mem;
const json = std.json;
const posix = std.posix;
const protocol = @import("protocol");
const ipc = @import("ipc");
const Allocator = mem.Allocator;
const log = @import("diag").scoped(.run);

// ---------------------------------------------------------------------------
// MessageQueue — thread-safe FIFO for incoming Hub messages
// ---------------------------------------------------------------------------

pub const MessageQueue = struct {
    mutex: std.Io.Mutex,
    /// Wakes blocked `recv --wait` connection threads (WI-2026-08-10-001).
    cond: std.Io.Condition,
    /// Set on daemon shutdown so blocked waiters exit instead of hanging.
    closed: bool,
    messages: std.ArrayList([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) MessageQueue {
        return .{
            .mutex = .init,
            .cond = .init,
            .closed = false,
            .messages = std.ArrayList([]const u8).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MessageQueue) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg);
        }
        self.messages.deinit(self.allocator);
    }

    /// Push a copy of msg onto the queue.
    pub fn push(self: *MessageQueue, msg: []const u8) !void {
        const copy = try self.allocator.dupe(u8, msg);
        errdefer self.allocator.free(copy);
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        try self.messages.append(self.allocator, copy);
        self.cond.signal(io_mod.get());
    }

    /// Block until the queue is non-empty or the queue is closed
    /// (daemon shutdown). Returns true when a message is available —
    /// the pane IPC leg of `recv --wait` (WI-2026-08-10-001, found live
    /// by agents local-2c69/local-4194 on hub issue #2).
    pub fn waitNonEmpty(self: *MessageQueue) bool {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        while (self.messages.items.len == 0 and !self.closed) {
            self.cond.wait(io_mod.get(), &self.mutex) catch unreachable;
        }
        return self.messages.items.len > 0;
    }

    /// Wake every blocked waiter and refuse future blocking — called at
    /// daemon shutdown BEFORE joining connection threads.
    pub fn close(self: *MessageQueue) void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        self.closed = true;
        self.cond.broadcast(io_mod.get());
    }

    /// Drain up to `max` messages into a newly allocated slice.
    /// Caller owns both the outer slice and each inner string — free each with
    /// allocator.free(item) then allocator.free(slice). The cap bounds the
    /// serialized response so the 64KiB IPC line cannot truncate or hang the
    /// client (WI-2026-08-08-028).
    pub fn drain(self: *MessageQueue, allocator: Allocator, max: usize) ![][]const u8 {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());

        const count = @min(self.messages.items.len, max);
        if (count == 0) {
            return try allocator.alloc([]const u8, 0);
        }

        const result = try allocator.alloc([]const u8, count);
        for (self.messages.items[0..count], 0..) |item, i| {
            result[i] = item;
        }
        // Remove without freeing — ownership transferred to caller.
        for (0..count) |_| _ = self.messages.orderedRemove(0);
        return result;
    }
};

// ---------------------------------------------------------------------------
// RunServer
// ---------------------------------------------------------------------------

pub const RunServer = struct {
    allocator: Allocator,
    agent_id: []const u8,
    hub_fd: sys.fd_t,
    ipc_server: ipc.IpcServer,
    socket_path: []const u8,
    message_queue: MessageQueue,
    running: bool,
    /// Serializes writes to hub_stream (hubReaderThread is the sole reader).
    hub_write_mutex: std.Io.Mutex,
    /// Protects pending_responses — the response mailbox between hubReaderThread
    /// and IPC handlers that need a Hub response.
    response_mutex: std.Io.Mutex,
    pending_responses: std.ArrayList([]const u8),
    /// Monotonic counter for unique envelope IDs (prevents stale-response misrouting).
    next_request_id: u32,
    /// Per-connection IPC threads (WI-2026-08-10-001): a blocked
    /// `recv --wait` parks on its own thread so it never starves
    /// concurrent IPC requests. Reaped on every accept
    /// ([[sys.ThreadReaper]]) and joined at shutdown after
    /// message_queue.close() wakes the waiters.
    ipc_threads: sys.ThreadReaper,
    /// Reconnect target (WI-2026-08-11-017): the ORIGINAL --hub address.
    /// The embedded hub restarts in-place on the same preferred port, so
    /// the address stays valid across a hub restart.
    hub_sa: sys.sockaddr_in,
    /// Last agent_update envelope forwarded for this pane (raw,
    /// smp-owned) — replayed after a reconnect so the durable identity
    /// is re-claimed via its resume_ref (RFC-0008; fresh generation per
    /// RFC-0004). Guarded by replay_mutex.
    last_agent_update: ?[]const u8,
    replay_mutex: std.Io.Mutex,
    /// [[ADR-0008]] applied to a pane: the workbench that spawned this
    /// wrapper. Absent for a hand-launched wrapper, which no window owns
    /// and which must therefore not hang itself up.
    parent_pid: ?i32 = null,

    /// Create socket path, connect to Hub, send register, create IPC server.
    pub fn init(
        allocator: Allocator,
        agent_id: []const u8,
        hub_addr: []const u8,
        hub_port: u16,
    ) !RunServer {
        const builtin = @import("builtin");
        const pid: i32 = switch (builtin.os.tag) {
            .linux => std.os.linux.getpid(),
            else => std.c.getpid(),
        };
        const socket_path = try std.fmt.allocPrint(allocator, "/tmp/synapty-{d}.sock", .{pid});
        errdefer allocator.free(socket_path);

        // Remove any stale socket at OUR pid, and sweep the ones every
        // previous pane left behind.
        sys.unlink(socket_path);
        sweepStaleSockets();

        // Connect to Hub. The GUI starts its hub subprocess and spawns
        // panes CONCURRENTLY, so at app launch this wrapper regularly
        // races the hub's bind — a bounded ConnectionRefused retry absorbs
        // the race (WI-2026-08-09-025 root cause: with no pre-existing hub
        // on the port, every first pane degraded to a bare shell).
        // Anything beyond the window is a real failure and propagates.
        const addr4 = std.Io.net.Ip4Address.parse(hub_addr, hub_port) catch {
            return error.InvalidHubAddress;
        };
        const sa = sys.sockaddr_in.init(@bitCast(addr4.bytes), hub_port);
        const retry_step_ms = 250;
        const max_wait_ms = 8_000;
        var waited_ms: u64 = 0;
        const hub_fd = blk: while (true) {
            const fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
            if (sys.connect(fd, &sa, @sizeOf(sys.sockaddr_in))) |_| {
                break :blk fd;
            } else |err| {
                sys.close(fd);
                if (err != error.ConnectionRefused or waited_ms >= max_wait_ms) return err;
                io_mod.get().sleep(std.Io.Duration.fromMilliseconds(retry_step_ms), .awake) catch {};
                waited_ms += retry_step_ms;
            }
        };
        errdefer sys.close(hub_fd);

        // Send register envelope (newline-terminated for Hub's line framing).
        const reg = try protocol.makeRegisterEnvelope(allocator, agent_id, &.{});
        const reg_raw = try protocol.serializeEnvelope(allocator, reg);
        defer allocator.free(reg_raw);
        try sys.writeAll(hub_fd, reg_raw);
        try sys.writeAll(hub_fd, "\n");

        // Bind IPC unix socket.
        const ipc_server = try ipc.IpcServer.init(socket_path);
        errdefer {
            var s = ipc_server;
            s.deinit();
        }

        return RunServer{
            .allocator = allocator,
            .agent_id = agent_id,
            .hub_fd = hub_fd,
            .ipc_server = ipc_server,
            .socket_path = socket_path,
            // Message queue + pending responses use the thread-safe smp
            // allocator: dupes must be FREABLE (the caller's arena free is
            // a no-op — items would live for the daemon's lifetime) and
            // freeable from the IPC thread while the reader thread appends
            // (WI-2026-08-08-017).
            .message_queue = MessageQueue.init(std.heap.smp_allocator),
            .running = false,
            .hub_write_mutex = .init,
            .response_mutex = .init,
            .pending_responses = std.ArrayList([]const u8).empty,
            .next_request_id = 0,
            .ipc_threads = sys.ThreadReaper.init(std.heap.smp_allocator),
            .hub_sa = sa,
            .last_agent_update = null,
            .replay_mutex = .init,
        };
    }

    pub fn deinit(self: *RunServer) void {
        self.ipc_threads.deinit();
        for (self.pending_responses.items) |r| std.heap.smp_allocator.free(r);
        self.pending_responses.deinit(std.heap.smp_allocator);
        if (self.last_agent_update) |u| std.heap.smp_allocator.free(u);
        sys.close(self.hub_fd);
        self.ipc_server.deinit();
        self.message_queue.deinit();
        // The graceful half of WI-2026-08-13-001. It is the MINORITY case
        // — a pane's wrapper is usually killed — so the startup sweep is
        // what actually reclaims these. Both, because a file that lives
        // only until the next pane launches is still one a human can trip
        // over in between.
        var zbuf: [128]u8 = undefined;
        if (std.fmt.bufPrintZ(&zbuf, "{s}", .{self.socket_path})) |zpath| {
            sys.unlink(zpath);
        } else |_| {}
        self.allocator.free(self.socket_path);
    }

    /// Spawn the child with its standard streams INHERITED, run background
    /// threads, wait for it.
    ///
    /// Inherited, NOT a pseudoterminal proxy — the distinction matters
    /// outside this file. It means the wrapper never sees screen content or
    /// keystrokes, so it cannot serve as an evidence channel for
    /// RFC-0004 passive detection or RFC-0005's human-recency backoff. A
    /// draft of RFC-0011 reasoned about headless evidence partly from the
    /// old "PTY passthrough" wording here and got it wrong in both
    /// directions. What the wrapper DOES carry is the pane socket every
    /// hook is gated on, and the agent's own lifecycle.
    /// Hang up this pane when the workbench that owns it exits
    /// ([[WI-2026-08-14-004]]).
    ///
    /// An unsupervised wrapper is reparented to init, keeps its pty, and
    /// RECONNECTS to whatever hub next binds the port — so the next
    /// workbench inherits agents no window can reach. Ending it loses
    /// nothing: resume does not reattach to a surviving process, it
    /// re-runs the incantation in a fresh pane (RFC-0006
    /// C-RESUME-RESTORE).
    ///
    /// SIGHUP to our OWN PROCESS GROUP, which is what a hangup is: the
    /// child and every job it started go down together, and there is no
    /// child pid to track across the moment it is reaped — so no window
    /// in which a reused pid could be killed instead.
    fn watchWorkbench(parent_pid: i32) void {
        if (!sys.waitForPidExit(parent_pid)) {
            // Watchdog unavailable — poll. A watch that could not be
            // established must never read as "the workbench is immortal".
            while (sys.pidAlive(parent_pid)) {
                io_mod.get().sleep(std.Io.Duration.fromMilliseconds(1000), .awake) catch {};
            }
        }
        log.info("workbench {d} exited — hanging up this pane", .{parent_pid});
        posix.kill(0, posix.SIG.HUP) catch |err| {
            log.err("could not hang up the pane group: {s} — this pane will outlive its window", .{@errorName(err)});
        };
        std.process.exit(0);
    }

    pub fn run(self: *RunServer, child_argv: []const []const u8) !void {
        self.running = true;

        // Build env map inheriting current env then adding our vars.
        var env_map = try buildEnvMap(self.allocator);
        defer env_map.deinit();
        try env_map.put("SYNAPTY_AGENT_ID", self.agent_id);
        try env_map.put("SYNAPTY_SOCK", self.socket_path);

        // Prepend the directory of the current executable to PATH so child
        // processes (e.g. MCP servers) can find `synapty`.
        // Works for all deployments: dev (zig-out/bin/), bundled (.app/Resources/),
        // and remote (~/.synapty/bin/).
        var self_exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const self_exe_n = std.process.executablePath(io_mod.get(), &self_exe_buf) catch 0;
        if (self_exe_n > 0) {
            const self_exe = self_exe_buf[0..self_exe_n];
            if (std.fs.path.dirnamePosix(self_exe)) |exe_dir| {
                if (env_map.get("PATH")) |existing_path| {
                    const new_path = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ exe_dir, existing_path });
                    defer self.allocator.free(new_path);
                    try env_map.put("PATH", new_path);
                } else {
                    try env_map.put("PATH", exe_dir);
                }
            }
        }

        var child = try std.process.spawn(io_mod.get(), .{
            .argv = child_argv,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
            .environ_map = &env_map,
        });

        // Hang up when the workbench dies. Spawned AFTER the child so
        // there is something to hang up, and detached: it never returns
        // while the pane should live.
        if (self.parent_pid) |ppid| {
            _ = std.Thread.spawn(.{}, watchWorkbench, .{ppid}) catch |err| {
                // Refuse to run: a pane that cannot hang itself up is the
                // zombie this exists to prevent, and nothing downstream
                // would notice its absence.
                @atomicStore(bool, &self.running, false, .release);
                std.process.Child.kill(&child, io_mod.get());
                _ = std.process.Child.wait(&child, io_mod.get()) catch {};
                return err;
            };
        }

        // Spawn hub reader thread. On failure: kill and reap the child,
        // mark stopped, rethrow — an orphaned child would keep running
        // with nobody to manage it (WI-2026-08-08-017).
        const hub_thread = std.Thread.spawn(.{}, hubReaderThread, .{self}) catch |err| {
            @atomicStore(bool, &self.running, false, .release);
            std.process.Child.kill(&child, io_mod.get());
            _ = std.process.Child.wait(&child, io_mod.get()) catch {};
            return err;
        };

        // Spawn IPC server thread. On failure: stop the reader thread, join
        // it (it must not run against a deinitializing RunServer), then
        // kill/reap the child.
        const ipc_thread = std.Thread.spawn(.{}, ipcServerThread, .{self}) catch |err| {
            @atomicStore(bool, &self.running, false, .release);
            self.shutdownHubFd();
            hub_thread.join();
            std.process.Child.kill(&child, io_mod.get());
            _ = std.process.Child.wait(&child, io_mod.get()) catch {};
            return err;
        };

            _ = try std.process.Child.wait(&child, io_mod.get());

        // Signal threads to stop.
        @atomicStore(bool, &self.running, false, .release);

        // Unblock hubReaderThread: shutdown causes read() to return 0/error.
        self.shutdownHubFd();

        // Unblock ipcServerThread: dummy connection causes accept() to return.
        if (connectUnixDummy(self.socket_path)) |fd| {
            sys.close(fd);
        }

        hub_thread.join();
        ipc_thread.join();
        // After the accept loop is down (no new connections), wake any
        // parked `recv --wait` waiters and join their threads
        // (WI-2026-08-10-001).
        joinIpcConnThreads(self);
    }

    /// Shut down the CURRENT hub fd under the write mutex — the
    /// reconnect swap holds the same mutex, so teardown can never
    /// shutdown a stale fd while the reader re-blocks on a fresh one
    /// (which would hang the join; WI-2026-08-11-017). `running` is
    /// always set false BEFORE this, so a reconnect that races past the
    /// shutdown exits at its next running check instead of re-blocking.
    fn shutdownHubFd(self: *RunServer) void {
        self.hub_write_mutex.lock(io_mod.get()) catch unreachable;
        defer self.hub_write_mutex.unlock(io_mod.get());
        sys.shutdown(self.hub_fd, sys.SHUT.RDWR);
    }

    /// Start hub reader and IPC server threads without spawning a child process.
    /// Caller must call stopThreads() to shut down.
    pub const ThreadHandles = struct { hub: std.Thread, ipc: std.Thread };

    pub fn startThreads(self: *RunServer) !ThreadHandles {
        self.running = true;
        const hub_thread = try std.Thread.spawn(.{}, hubReaderThread, .{self});
        const ipc_thread = std.Thread.spawn(.{}, ipcServerThread, .{self}) catch |err| {
            // Partial failure: stop and join the already-spawned thread so
            // it never runs against a deinitializing RunServer
            // (WI-2026-08-08-017).
            @atomicStore(bool, &self.running, false, .release);
            self.shutdownHubFd();
            hub_thread.join();
            return err;
        };
        return .{ .hub = hub_thread, .ipc = ipc_thread };
    }

    /// Signal threads to stop and join them.
    pub fn stopThreads(self: *RunServer, threads: ThreadHandles) void {
        @atomicStore(bool, &self.running, false, .release);
        self.shutdownHubFd();
        if (connectUnixDummy(self.socket_path)) |fd| {
            sys.close(fd);
        }
        threads.hub.join();
        threads.ipc.join();
        // Wake + join parked `recv --wait` connection threads
        // (WI-2026-08-10-001).
        joinIpcConnThreads(self);
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Connect a dummy unix-socket client to unblock the IPC accept loop.
/// Returns the fd, or null on failure.
fn connectUnixDummy(socket_path: []const u8) ?sys.fd_t {
    const fd = sys.socket(sys.AF.UNIX, sys.SOCK.STREAM, 0) catch return null;
    const addr = sys.sockaddr_un.init(socket_path) orelse {
        sys.close(fd);
        return null;
    };
    sys.connect(fd, &addr, addr.len()) catch {
        sys.close(fd);
        return null;
    };
    return fd;
}

/// Build an env map inheriting the current process environment (libc environ).
fn buildEnvMap(allocator: Allocator) !std.process.Environ.Map {
    var env_map = std.process.Environ.Map.init(allocator);
    // Count entries up to the null sentinel.
    var count: usize = 0;
    while (std.c.environ[count]) |_| : (count += 1) {}
    const block: std.process.Environ.PosixBlock = .{
        .slice = @ptrCast(std.c.environ[0..count :null]),
    };
    try env_map.putPosixBlock(block.view());
    return env_map;
}

// ---------------------------------------------------------------------------
// Thread functions
// ---------------------------------------------------------------------------

/// Sole reader of hub_stream. Buffers partial TCP frames across reads,
/// routes "response" envelopes to the response slot and everything else
/// to the message queue.
fn hubReaderThread(srv: *RunServer) void {
    var line_buf: [64 * 1024]u8 = undefined;
    // Shared framing (WI-2026-08-08-035): carry-remainder chunked reader,
    // oversized-line resync built in.
    var lb = framing.LineBuffer.init(&line_buf);

    // Per-line arena for parsing envelope type — reset after each line.
    var parse_arena = std.heap.ArenaAllocator.init(srv.allocator);
    defer parse_arena.deinit();

    while (@atomicLoad(bool, &srv.running, .acquire)) {
        const line = lb.readLine(srv.hub_fd) catch |err| switch (err) {
            // An oversized line (e.g. a huge list_agents response) must
            // not kill the reader permanently — every later IPC request
            // would hang then time out. Drop through the next newline and
            // keep serving (WI-2026-08-08-029).
            error.StreamTooLong => {
                log.err("hub message exceeds buffer — dropping oversized line", .{});
                lb.dropOversizedLine(srv.hub_fd);
                continue;
            },
            // Mid-life connection loss (the embedded hub restarting):
            // reconnect with backoff instead of dying — the pane
            // outlives the hub now (WI-2026-08-11-017).
            else => {
                if (!reconnectHub(srv)) break;
                lb = framing.LineBuffer.init(&line_buf);
                continue;
            },
        } orelse {
            if (!reconnectHub(srv)) break;
            lb = framing.LineBuffer.init(&line_buf);
            continue;
        };
        const trimmed = mem.trimEnd(u8, line, "\r ");
        if (trimmed.len == 0) continue;

        // Parse the envelope to check the type field reliably.
        _ = parse_arena.reset(.retain_capacity);
        const is_response = blk: {
            const parsed = json.parseFromSlice(json.Value, parse_arena.allocator(), trimmed, .{ .allocate = .alloc_always }) catch break :blk false;
            const obj = if (parsed.value == .object) parsed.value.object else break :blk false;
            const type_val = obj.get("type") orelse break :blk false;
            break :blk if (type_val == .string) mem.eql(u8, type_val.string, "response") else false;
        };

        if (is_response) {
            const copy = std.heap.smp_allocator.dupe(u8, trimmed) catch continue;
            srv.response_mutex.lock(io_mod.get()) catch unreachable;
            srv.pending_responses.append(std.heap.smp_allocator, copy) catch {
                std.heap.smp_allocator.free(copy);
            };
            srv.response_mutex.unlock(io_mod.get());
        } else {
            srv.message_queue.push(trimmed) catch |err| {
                log.err("message_queue.push failed: {any}", .{err});
            };
        }
    }
}

/// Parse an envelope line and return true when its `id` field equals
/// `expected_id` EXACTLY. Substring matching collided ('req-5' matched
/// 'req-50'; WI-2026-08-08-028). Takes the caller's arena — the response
/// wait loop reuses ONE arena across its attempts instead of allocating
/// per call (WI-2026-08-08-042).
fn responseIdMatches(arena: Allocator, line: []const u8, expected_id: []const u8) bool {
    const parsed = json.parseFromSlice(json.Value, arena, line, .{ .allocate = .alloc_always }) catch return false;
    if (parsed.value != .object) return false;
    const id_val = parsed.value.object.get("id") orelse return false;
    return if (id_val == .string) mem.eql(u8, id_val.string, expected_id) else false;
}

/// Cap on unclaimed hub responses. Generous on purpose: it only has to
/// exceed the number of IPC requests genuinely in flight in one pane at
/// once, and anything above it belongs to a waiter that already gave up.
const max_pending_responses = 64;

/// Wait up to ~1 second for a hub response whose envelope ID matches
/// `expected_id`. Responses belonging to OTHER in-flight waiters are left
/// where they are; the queue is bounded by age instead.
/// Caller owns the returned slice and must free it with std.heap.smp_allocator.
fn waitForHubResponse(srv: *RunServer, expected_id: []const u8) ?[]const u8 {
    // One parse arena for the whole wait loop — no per-attempt allocation
    // (WI-2026-08-08-042).
    var parse_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer parse_arena.deinit();
    const arena = parse_arena.allocator();

    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        srv.response_mutex.lock(io_mod.get()) catch unreachable;
        // Take ONLY what is ours, and leave the rest alone.
        //
        // Discarding every non-matching response from the head would
        // treat it as stale from a request that already timed out. That
        // holds only while ONE request is in flight, and
        // [[WI-2026-08-10-001]] gave every IPC connection its own thread — its own
        // comment names the pair: a parked `recv --wait` alongside the
        // harness's `notify` at turn end. From then on the rule was
        // destroying live answers, and the waiter whose response was eaten
        // spun out its full timeout and reported "hub timeout" for a
        // request the hub had answered correctly.
        var found: ?[]const u8 = null;
        var i: usize = 0;
        while (i < srv.pending_responses.items.len) : (i += 1) {
            if (responseIdMatches(arena, srv.pending_responses.items[i], expected_id)) {
                found = srv.pending_responses.orderedRemove(i);
                break;
            }
        }
        // A response nobody ever claims (its waiter really did time out)
        // must still not accumulate, so the queue is bounded here instead
        // — by age-in-the-queue rather than by "not mine".
        while (srv.pending_responses.items.len > max_pending_responses) {
            std.heap.smp_allocator.free(srv.pending_responses.orderedRemove(0));
        }
        srv.response_mutex.unlock(io_mod.get());
        if (found) |f| return f;
        io_mod.get().sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    return null;
}

/// Write a newline-terminated message to the hub under mutex.
fn writeToHub(srv: *RunServer, data: []const u8) !void {
    srv.hub_write_mutex.lock(io_mod.get()) catch unreachable;
    defer srv.hub_write_mutex.unlock(io_mod.get());
    try sys.writeAll(srv.hub_fd, data);
    try sys.writeAll(srv.hub_fd, "\n");
}

/// Remember the pane's identity claim for post-reconnect replay
/// (WI-2026-08-11-017). Serialization failure just skips the cache —
/// the live request path still runs.
fn cacheAgentUpdate(srv: *RunServer, envelope: protocol.Envelope) void {
    const raw = protocol.serializeEnvelope(std.heap.smp_allocator, envelope) catch return;
    srv.replay_mutex.lock(io_mod.get()) catch unreachable;
    defer srv.replay_mutex.unlock(io_mod.get());
    if (srv.last_agent_update) |old| std.heap.smp_allocator.free(old);
    srv.last_agent_update = raw;
}

/// Steady-state hub reconnect (WI-2026-08-11-017): the embedded hub can
/// restart in-app; the pane must survive it. Retries the ORIGINAL --hub
/// address with capped backoff for as long as the daemon runs, then
/// re-registers the pane id and replays the cached identity claim so the
/// durable identity is re-claimed via its resume_ref (RFC-0008; the
/// fresh generation is normal RFC-0004 reconnect semantics). Returns
/// false only when the daemon is shutting down. Runs on the reader
/// thread — the sole reader of hub_fd; the swap is fenced by
/// hub_write_mutex so IPC writers never hit a closed fd.
fn reconnectHub(srv: *RunServer) bool {
    var backoff_ms: i64 = 250;
    while (@atomicLoad(bool, &srv.running, .acquire)) {
        io_mod.get().sleep(std.Io.Duration.fromMilliseconds(backoff_ms), .awake) catch {};
        backoff_ms = @min(backoff_ms * 2, 2_000);
        if (!@atomicLoad(bool, &srv.running, .acquire)) return false;

        const fd = sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0) catch continue;
        if (sys.connect(fd, &srv.hub_sa, @sizeOf(sys.sockaddr_in))) |_| {
            {
                srv.hub_write_mutex.lock(io_mod.get()) catch unreachable;
                defer srv.hub_write_mutex.unlock(io_mod.get());
                sys.close(srv.hub_fd);
                srv.hub_fd = fd;
            }
            // Re-register the pane identity (wire register), then replay
            // the identity claim if one was ever made.
            var arena = std.heap.ArenaAllocator.init(srv.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            // A reconnect that cannot RE-REGISTER has not reconnected.
            //
            // These three must NOT fail alike. A failed WRITE breaks the
            // socket, so the reader loop comes straight back here; a
            // failed envelope build does not — the socket is perfectly
            // healthy, so nothing brings us back and the pane sits
            // connected to
            // the hub and unregistered for the rest of its life. Invisible
            // to the agent, to `synapty agents`, and to the human. So the
            // first two retry instead of claiming success; the third keeps
            // the old behaviour because its own failure IS the retrigger.
            const reg = protocol.makeRegisterEnvelope(a, srv.agent_id, &.{}) catch {
                log.warn("hub reconnect: could not build the register envelope — retrying", .{});
                continue;
            };
            const reg_raw = protocol.serializeEnvelope(a, reg) catch {
                log.warn("hub reconnect: could not serialize the register envelope — retrying", .{});
                continue;
            };
            writeToHub(srv, reg_raw) catch return true; // the broken socket re-enters this loop
            {
                srv.replay_mutex.lock(io_mod.get()) catch unreachable;
                defer srv.replay_mutex.unlock(io_mod.get());
                if (srv.last_agent_update) |claim| {
                    writeToHub(srv, claim) catch {};
                }
            }
            log.info("hub reconnected, identity re-claimed", .{});
            return true;
        } else |_| {
            sys.close(fd);
        }
    }
    return false;
}

/// Write an envelope to the hub, wait for its response, and send the
/// daemon's IPC response to the client — one place for the
/// write→wait→respond sequence the send, register and channel branches
/// all need ([[WI-2026-08-08-038]]).
fn hubRoundtripAndRespond(srv: *RunServer, alloc: Allocator, client_fd: sys.fd_t, envelope: protocol.Envelope) !void {
    const raw = try protocol.serializeEnvelope(alloc, envelope);
    defer alloc.free(raw);
    try writeToHub(srv, raw);
    // Wait for hub acknowledgment, matched by request ID.
    const hub_resp = waitForHubResponse(srv, envelope.id);
    defer if (hub_resp) |r| std.heap.smp_allocator.free(r);
    const success = if (hub_resp) |r| parseHubOk(r) else false;
    const resp = protocol.IpcResponse{
        .success = success,
        .data = hub_resp,
        .error_msg = if (!success and hub_resp == null) "hub timeout" else null,
    };
    const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
    try ipc.IpcServer.writeLine(client_fd, resp_raw);
}

/// Parse a hub mailbox_recv response ({payload:{ok,data:{messages:[..]}}})
/// into an alloc-owned slice of alloc-owned strings (WI-2026-08-11-012).
fn parseMailboxMessages(alloc: Allocator, hub_resp: []const u8) ![]const []const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const parsed = try json.parseFromSliceLeaky(json.Value, arena.allocator(), hub_resp, .{});
    if (parsed != .object) return &.{};
    const payload = parsed.object.get("payload") orelse return &.{};
    if (payload != .object) return &.{};
    const data = payload.object.get("data") orelse return &.{};
    if (data != .object) return &.{};
    const msgs = data.object.get("messages") orelse return &.{};
    if (msgs != .array or msgs.array.items.len == 0) return &.{};
    const out = try alloc.alloc([]const u8, msgs.array.items.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |m| alloc.free(m);
        alloc.free(out);
    }
    for (msgs.array.items) |m| {
        // Entries are always strings (our own hub built them); a foreign
        // shape dupes empty so filled == out.len and the slice frees whole.
        out[filled] = try alloc.dupe(u8, if (m == .string) m.string else "");
        filled += 1;
    }
    return out;
}

/// Delete IPC sockets whose owning process is gone (WI-2026-08-13-001).
///
/// A pane's wrapper is usually KILLED rather than asked to stop — the app
/// quits, the human closes a tab, a session is torn down — so cleaning up
/// on the graceful path alone would still leak most of the time. 98 files
/// had accumulated on the author's machine across a few days before this
/// existed. The graceful unlink is in deinit as well; this is the one that
/// actually reclaims them.
///
/// A file whose pid no longer exists is unambiguously dead. The reverse
/// error — a dead pane whose pid has been REUSED by an unrelated process —
/// leaves one file behind, which is the harmless direction; deleting a
/// LIVE pane's socket would require its pid to be gone, which means the
/// pane is gone too. Same pid-liveness test the hub applies to its
/// discovery file.
fn sweepStaleSockets() void {
    sweepStaleSocketsIn("/tmp");
}

/// Directory-scoped so tests never touch the real /tmp. The first version
/// of the tests below swept the author's actual socket directory — which
/// deleted 98 genuinely dead files and was therefore "correct", and was
/// still the wrong shape: this codebase has paid for unscoped test writes
/// twice already (a hosts.json clobbered, a machine renamed by a scratch
/// hub), and both times the write was also individually defensible.
fn sweepStaleSocketsIn(dir_path: []const u8) void {
    const io = io_mod.get();
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    var path_buf: [128]u8 = undefined;
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .unix_domain_socket and entry.kind != .file) continue;
        if (!mem.startsWith(u8, entry.name, "synapty-")) continue;
        if (!mem.endsWith(u8, entry.name, ".sock")) continue;
        const digits = entry.name["synapty-".len .. entry.name.len - ".sock".len];
        if (digits.len == 0) continue;
        // Only NUMERIC names are ours to judge: anything else is a
        // differently-shaped file we do not own and must not delete.
        for (digits) |c| {
            if (!std.ascii.isDigit(c)) break;
        } else {
            const pid = std.fmt.parseInt(i32, digits, 10) catch continue;
            if (sys.pidAlive(pid)) continue;
            const full = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            sys.unlink(full);
        }
    }
}

/// Generate a unique request ID for envelope correlation.
fn nextRequestId(srv: *RunServer, buf: *[32]u8) []const u8 {
    // ATOMIC, because every IPC connection has its own thread
    // (WI-2026-08-10-001) and this counter is shared by all of them. A
    // plain read-modify-write handed two panes the same id, and
    // waitForHubResponse matches on id alone — so one agent received the
    // other's answer, which for `recv` is another pane's mail.
    const id = @atomicRmw(u32, &srv.next_request_id, .Add, 1, .monotonic);
    return std.fmt.bufPrint(buf, "req-{d}", .{id}) catch "req-0";
}

/// Check if a hub response indicates success (payload.ok == true).
/// Parse the envelope payload and return true only when
/// payload.ok == true. Substring matching could false-positive on a
/// nested data payload (WI-2026-08-08-028).
fn parseHubOk(response: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = json.parseFromSlice(json.Value, arena, response, .{ .allocate = .alloc_always }) catch return false;
    if (parsed.value != .object) return false;
    const payload = parsed.value.object.get("payload") orelse return false;
    if (payload != .object) return false;
    const ok = payload.object.get("ok") orelse return false;
    return ok == .bool and ok.bool;
}

/// How long the accept loop will sit before looking up to check that the
/// path it is reachable through is still there. Short enough that a pane
/// heals within a breath of losing its socket, long enough to be two
/// wakeups a second on an idle pane.
const socket_check_ms: i32 = 500;

fn ipcServerThread(srv: *RunServer) void {
    while (@atomicLoad(bool, &srv.running, .acquire)) {
        // A BOUNDED WAIT, SO THE LOOP CAN LOOK AROUND. A bare `accept`
        // blocks for as long as nobody calls, which on a pane whose socket
        // path was removed is forever — the state a live pane was found in
        // ([[WI-2026-09-03-007]]). Waiting with a deadline is what gives
        // this thread a moment to notice and re-bind. A poll that fails
        // falls through to `accept`, which is what it did before.
        if (!(sys.waitReadable(srv.ipc_server.listener_fd, socket_check_ms) catch true)) {
            if (srv.ipc_server.ensureBound())
                log.warn("pane socket {s} had gone; bound it again", .{srv.socket_path});
            continue;
        }
        const client_fd = srv.ipc_server.accept() catch |err| {
            if (!@atomicLoad(bool, &srv.running, .acquire)) break;
            log.err("ipc accept error: {any}", .{err});
            continue;
        };
        // One thread per connection (WI-2026-08-10-001): a `recv --wait`
        // parked on the message-queue condition must not starve the next
        // IPC request (e.g. the harness's own notify at turn end).
        // Reaped here, where the work already is, so finished connection
        // threads do not pile up for the daemon's life ([[WI-2026-09-02-015]]).
        _ = srv.ipc_threads.reap();
        srv.ipc_threads.spawn(ipcConnThread, .{ srv, client_fd }) catch {
            // Thread exhaustion: degrade to the old inline handling so a
            // plain request still gets served.
            defer sys.close(client_fd);
            handleIpcConnection(srv, client_fd) catch |err| {
                log.err("ipc connection error: {any}", .{err});
            };
            continue;
        };
    }
}

fn ipcConnThread(srv: *RunServer, client_fd: sys.fd_t) void {
    defer sys.close(client_fd);
    handleIpcConnection(srv, client_fd) catch |err| {
        log.err("ipc connection error: {any}", .{err});
    };
}

/// Shutdown leg shared by run() and stopThreads(): wake blocked
/// `recv --wait` connection threads, then join them all.
fn joinIpcConnThreads(srv: *RunServer) void {
    srv.message_queue.close();
    srv.ipc_threads.joinAll();
}

fn handleIpcConnection(srv: *RunServer, client_fd: sys.fd_t) !void {
    var buf: [64 * 1024]u8 = undefined;
    const line = try ipc.IpcServer.readLine(client_fd, &buf) orelse return;

    // Per-connection arena over the thread-safe allocator: the IPC thread
    // must NOT allocate from the daemon's shared arena — the hub reader
    // thread bumps it concurrently (data race, WI-2026-08-08-017).
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var req_parsed = protocol.parseIpcRequest(alloc, line) catch {
        const resp = protocol.IpcResponse{ .success = false, .error_msg = "invalid request" };
        const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
        try ipc.IpcServer.writeLine(client_fd, resp_raw);
        return;
    };
    defer req_parsed.deinit();

    const req = req_parsed.value;

    switch (req.action) {
        .send => try ipcSend(srv, alloc, client_fd, req),
        .recv => try ipcRecv(srv, alloc, client_fd, req),
        .agents => {
            var id_buf: [32]u8 = undefined;
            const req_id = nextRequestId(srv, &id_buf);
            const envelope = protocol.Envelope{
                .type = "list_agents",
                .id = req_id,
                .source = srv.agent_id,
                .target = "hub",
                .payload = .null,
            };
            const raw = try protocol.serializeEnvelope(alloc, envelope);
            try writeToHub(srv, raw);
            const hub_resp = waitForHubResponse(srv, req_id);
            defer if (hub_resp) |r| std.heap.smp_allocator.free(r);
            const success = hub_resp != null;
            const resp = protocol.IpcResponse{
                .success = success,
                .data = hub_resp,
                .error_msg = if (!success) "hub timeout" else null,
            };
            const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
            try ipc.IpcServer.writeLine(client_fd, resp_raw);
        },
        .notify => {
            // agent_status per [[WI-2026-08-09-022]]: identity comes from
            // this run wrapper (srv.agent_id) — the CLI never names itself.
            var id_buf: [32]u8 = undefined;
            const req_id = nextRequestId(srv, &id_buf);
            var payload_obj = json.ObjectMap.empty;
            if (req.state) |st| try payload_obj.put(alloc, "state", .{ .string = st });
            if (req.class) |cl| try payload_obj.put(alloc, "class", .{ .string = cl });
            const envelope = protocol.Envelope{
                .type = "agent_status",
                .id = req_id,
                .source = srv.agent_id,
                .target = "hub",
                .payload = .{ .object = payload_obj },
            };
            try hubRoundtripAndRespond(srv, alloc, client_fd, envelope);
        },
        .register => {
            var id_buf: [32]u8 = undefined;
            const req_id = nextRequestId(srv, &id_buf);
            var payload_obj = json.ObjectMap.empty;
            if (req.tool) |t| try payload_obj.put(alloc, "tool", .{ .string = t });
            if (req.project) |p| try payload_obj.put(alloc, "project", .{ .string = p });
            if (req.session) |s| try payload_obj.put(alloc, "session", .{ .string = s });
            if (req.resume_ref) |r| try payload_obj.put(alloc, "resume_ref", .{ .string = r });
            const envelope = protocol.Envelope{
                .type = "agent_update",
                .id = req_id,
                .source = srv.agent_id,
                .target = "hub",
                .payload = .{ .object = payload_obj },
            };
            // Cache the claim for replay after a hub reconnect
            // (WI-2026-08-11-017): the durable identity must be
            // re-claimed via its resume_ref, not lost to the restart.
            cacheAgentUpdate(srv, envelope);
            try hubRoundtripAndRespond(srv, alloc, client_fd, envelope);
        },
        .channel_create, .channel_invite, .channel_leave, .channel_list => {
            var id_buf: [32]u8 = undefined;
            const req_id = nextRequestId(srv, &id_buf);
            const msg_type: []const u8 = switch (req.action) {
                .channel_create => "channel_create",
                .channel_invite => "channel_invite",
                .channel_leave => "channel_leave",
                .channel_list => "list_channels",
                else => unreachable,
            };
            var payload_obj = json.ObjectMap.empty;
            if (req.channel) |ch| try payload_obj.put(alloc, "channel", .{ .string = ch });
            if (req.agent_id) |aid| try payload_obj.put(alloc, "agent_id", .{ .string = aid });
            if (req.description) |d| try payload_obj.put(alloc, "description", .{ .string = d });
            if (req.channel) |name| try payload_obj.put(alloc, "name", .{ .string = name });
            const envelope = protocol.Envelope{
                .type = msg_type,
                .id = req_id,
                .source = srv.agent_id,
                .target = "hub",
                .payload = .{ .object = payload_obj },
            };
            try hubRoundtripAndRespond(srv, alloc, client_fd, envelope);
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// IPC actions
//
// The two that carry real logic, lifted out of handleIpcConnection's
// switch. `recv` alone was seventy lines of blocking-wait, drain, merge
// and serialize — longer than most files here have functions — sitting
// inside a dispatcher whose job is to pick an arm.
// ---------------------------------------------------------------------------

/// `synapty send` — build the envelope, round-trip it through the hub.
fn ipcSend(
    srv: *RunServer,
    alloc: Allocator,
    client_fd: sys.fd_t,
    req: protocol.IpcRequest,
) !void {
    const target = req.target orelse {
        const resp = protocol.IpcResponse{ .success = false, .error_msg = "missing target" };
        const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
        try ipc.IpcServer.writeLine(client_fd, resp_raw);
        return;
    };
    const text_str = req.text orelse "";
    // Detect channel target (legacy group-chat surface, reduced away
    // by [[RFC-0003:C-A2A-REDUCTION]]; kept for the daemon IPC compat).
    const envelope_type: []const u8 = if (mem.startsWith(u8, target, "channel:"))
        "channel_msg"
    else
        "dm";
    var id_buf: [32]u8 = undefined;
    const req_id = nextRequestId(srv, &id_buf);
    var payload_obj = json.ObjectMap.empty;
    try payload_obj.put(alloc, "text", .{ .string = text_str });
    const envelope = protocol.Envelope{
        .type = envelope_type,
        .id = req_id,
        .source = srv.agent_id,
        .target = target,
        .payload = .{ .object = payload_obj },
    };
    try hubRoundtripAndRespond(srv, alloc, client_fd, envelope);
}

/// `synapty recv [--wait]` — drain the pane queue, merging the hub-side
/// mailbox when asked.
fn ipcRecv(
    srv: *RunServer,
    alloc: Allocator,
    client_fd: sys.fd_t,
    req: protocol.IpcRequest,
) !void {
    // RFC-0008 C-MAILBOX (WI-2026-08-11-012): the daemon is a
    // pure RELAY on the hub-side identity-keyed mailbox. The
    // local message_queue is now a SIGNAL channel — mail nudges,
    // displacement notices, shutdown — never a message store.
    // Blocking recv: drain-park-drain loop; a nudge (or any
    // pushed line) wakes the park, shutdown ends it, and a
    // displacement notice terminates with the STABLE error the
    // RFC promises scripts.
    var displaced = false;
    const messages: []const []const u8 = blk: {
        while (true) {
            // Drain the hub-side queue for our bound identity.
            var id_buf: [32]u8 = undefined;
            const req_id = nextRequestId(srv, &id_buf);
            const env = protocol.Envelope{
                .type = "mailbox_recv",
                .id = req_id,
                .source = srv.agent_id,
                .target = "hub",
            };
            const raw = try protocol.serializeEnvelope(alloc, env);
            defer alloc.free(raw);
            writeToHub(srv, raw) catch break :blk &.{};
            const hub_resp = waitForHubResponse(srv, req_id) orelse break :blk &.{};
            defer std.heap.smp_allocator.free(hub_resp);
            const msgs = parseMailboxMessages(alloc, hub_resp) catch break :blk &.{};
            if (msgs.len > 0 or !(req.wait orelse false)) break :blk msgs;
            alloc.free(msgs);

            // Empty and waiting: park until a nudge / notice /
            // shutdown arrives on the signal channel.
            const woke = srv.message_queue.waitNonEmpty();
            const signals = try srv.message_queue.drain(alloc, 50);
            defer {
                for (signals) |sig| std.heap.smp_allocator.free(sig);
                alloc.free(signals);
            }
            for (signals) |sig| {
                if (mem.indexOf(u8, sig, "identity_displaced") != null) displaced = true;
            }
            if (displaced) break :blk &.{};
            if (!woke) break :blk &.{}; // queue closed: daemon shutdown
        }
    };
    defer {
        for (messages) |m| alloc.free(m);
        if (messages.len > 0) alloc.free(messages);
    }
    if (displaced) {
        const resp = protocol.IpcResponse{
            .success = false,
            .error_msg = "identity displaced",
        };
        const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
        try ipc.IpcServer.writeLine(client_fd, resp_raw);
        return;
    }
    // Same client-visible shape as before: JSON array of raw
    // message envelope strings.
    var array = json.Array.init(alloc);
    for (messages) |msg| {
        try array.append(json.Value{ .string = msg });
    }
    const arr_val = json.Value{ .array = array };
    const data_raw = try json.Stringify.valueAlloc(alloc, arr_val, .{});
    const resp = protocol.IpcResponse{ .success = true, .data = data_raw };
    const resp_raw = try protocol.serializeIpcResponse(alloc, resp);
    try ipc.IpcServer.writeLine(client_fd, resp_raw);
}

test "MessageQueue init and deinit" {
    var q = MessageQueue.init(std.testing.allocator);
    defer q.deinit();
    try std.testing.expectEqual(@as(usize, 0), q.messages.items.len);
}

test "MessageQueue push then drain returns messages in order" {
    var q = MessageQueue.init(std.testing.allocator);
    defer q.deinit();

    try q.push("first");
    try q.push("second");
    try q.push("third");

    const msgs = try q.drain(std.testing.allocator, 50);
    defer {
        for (msgs) |m| std.testing.allocator.free(m);
        std.testing.allocator.free(msgs);
    }

    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    try std.testing.expectEqualStrings("first", msgs[0]);
    try std.testing.expectEqualStrings("second", msgs[1]);
    try std.testing.expectEqualStrings("third", msgs[2]);
}

test "MessageQueue drain returns empty slice when no messages" {
    var q = MessageQueue.init(std.testing.allocator);
    defer q.deinit();

    const msgs = try q.drain(std.testing.allocator, 50);
    defer std.testing.allocator.free(msgs);

    try std.testing.expectEqual(@as(usize, 0), msgs.len);
}

test "MessageQueue drain empties the queue" {
    var q = MessageQueue.init(std.testing.allocator);
    defer q.deinit();

    try q.push("msg-a");

    // First drain returns the message.
    const first = try q.drain(std.testing.allocator, 50);
    defer {
        for (first) |m| std.testing.allocator.free(m);
        std.testing.allocator.free(first);
    }
    try std.testing.expectEqual(@as(usize, 1), first.len);

    // Second drain returns empty.
    const second = try q.drain(std.testing.allocator, 50);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqual(@as(usize, 0), second.len);
}

const ThreadPushContext = struct {
    q: *MessageQueue,
    prefix: []const u8,
    count: usize,
};

fn pushWorker(ctx: ThreadPushContext) void {
    var buf: [32]u8 = undefined;
    for (0..ctx.count) |i| {
        const s = std.fmt.bufPrint(&buf, "{s}{d}", .{ ctx.prefix, i }) catch unreachable;
        ctx.q.push(s) catch unreachable;
    }
}

test "MessageQueue is thread-safe: push from two threads drain gets all" {
    var q = MessageQueue.init(std.testing.allocator);
    defer q.deinit();

    const n = 50;
    const ctx_a = ThreadPushContext{ .q = &q, .prefix = "a-", .count = n };
    const ctx_b = ThreadPushContext{ .q = &q, .prefix = "b-", .count = n };

    const t1 = try std.Thread.spawn(.{}, pushWorker, .{ctx_a});
    const t2 = try std.Thread.spawn(.{}, pushWorker, .{ctx_b});
    t1.join();
    t2.join();

    // Cap above the push count so the thread-safety assertion sees all
    // messages (drain caps at `max` by design; WI-2026-08-08-028).
    const msgs = try q.drain(std.testing.allocator, 200);
    defer {
        for (msgs) |m| std.testing.allocator.free(m);
        std.testing.allocator.free(msgs);
    }

    try std.testing.expectEqual(@as(usize, n * 2), msgs.len);
}



test "send to plain agent target produces dm envelope type" {
    const target = "agent-b";
    const envelope_type: []const u8 = if (mem.startsWith(u8, target, "channel:"))
        "channel_msg"
    else
        "dm";
    try std.testing.expectEqualStrings("dm", envelope_type);
}




// -- Follow-up fix tests: response matching, success parsing, register \n ---

test "parseHubOk returns true for ok:true response" {
    try std.testing.expect(parseHubOk("{\"type\":\"response\",\"id\":\"req-0\",\"payload\":{\"ok\":true}}"));
}

test "parseHubOk returns false for ok:false response" {
    try std.testing.expect(!parseHubOk("{\"type\":\"response\",\"id\":\"req-0\",\"payload\":{\"ok\":false,\"error\":\"not found\"}}"));
}

test "parseHubOk returns false for missing ok field" {
    try std.testing.expect(!parseHubOk("{\"type\":\"response\",\"id\":\"req-0\",\"payload\":{}}"));
}

test "register envelope is newline-terminated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reg = try protocol.makeRegisterEnvelope(arena, "test-agent", &.{});
    const raw = try protocol.serializeEnvelope(arena, reg);
    // The hub's handleClient expects newline-terminated frames.
    // RunServer.init() appends "\n" after writing raw — verify raw itself
    // does NOT contain a newline (so the explicit "\n" write is needed).
    try std.testing.expect(mem.indexOfScalar(u8, raw, '\n') == null);
}

test "responseIdMatches compares the envelope id exactly (WI-2026-08-08-034)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The F12 regression: substring matching collided ('req-5' matched
    // 'req-50').
    try std.testing.expect(responseIdMatches(
        arena,
        "{\"type\":\"response\",\"id\":\"req-5\",\"payload\":{\"ok\":true}}",
        "req-5",
    ));
    try std.testing.expect(!responseIdMatches(
        arena,
        "{\"type\":\"response\",\"id\":\"req-50\",\"payload\":{\"ok\":true}}",
        "req-5",
    ));
    try std.testing.expect(responseIdMatches(
        arena,
        "{\"type\":\"response\",\"id\":\"req-50\",\"payload\":{\"ok\":true}}",
        "req-50",
    ));
}

test "responseIdMatches rejects malformed or missing ids (WI-2026-08-08-034)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Missing id field.
    try std.testing.expect(!responseIdMatches(
        arena,
        "{\"type\":\"response\",\"payload\":{\"ok\":true}}",
        "req-5",
    ));
    // Non-string id.
    try std.testing.expect(!responseIdMatches(
        arena,
        "{\"type\":\"response\",\"id\":42,\"payload\":{\"ok\":true}}",
        "42",
    ));
    // Malformed JSON.
    try std.testing.expect(!responseIdMatches(arena, "{broken", "req-5"));
    // Non-object root.
    try std.testing.expect(!responseIdMatches(arena, "[1,2,3]", "req-5"));
    // The id must match fully — a prefix is not enough.
    try std.testing.expect(!responseIdMatches(
        arena,
        "{\"type\":\"response\",\"id\":\"req-5-suffix\",\"payload\":{\"ok\":true}}",
        "req-5",
    ));
}

test "WI-2026-08-13-001: the sweep reclaims dead sockets and spares live ones" {
    // The case that actually happens: a pane's wrapper is usually KILLED,
    // so a deinit-only cleanup leaks most of the time.
    const io = io_mod.get();
    var dbuf: [128]u8 = undefined;
    const scratch = try std.fmt.bufPrint(&dbuf, "/tmp/synapty-sweeptest-{d}", .{std.c.getpid()});
    try std.Io.Dir.cwd().createDirPath(io, scratch);

    const dead_pid: i32 = 2147483600; // certainly not running
    const live_pid = std.c.getpid();
    var p1: [192]u8 = undefined;
    var p2: [192]u8 = undefined;
    const dead = try std.fmt.bufPrintZ(&p1, "{s}/synapty-{d}.sock", .{ scratch, dead_pid });
    const live = try std.fmt.bufPrintZ(&p2, "{s}/synapty-{d}.sock", .{ scratch, live_pid });
    for ([_][:0]const u8{ dead, live }) |p| {
        var f = try std.Io.Dir.cwd().createFile(io, p, .{});
        f.close(io);
    }
    defer {
        sys.unlink(dead);
        sys.unlink(live);
        var zb: [128]u8 = undefined;
        if (std.fmt.bufPrintZ(&zb, "{s}", .{scratch})) |z| {
            _ = std.c.rmdir(z.ptr);
        } else |_| {}
    }

    sweepStaleSocketsIn(scratch);

    // The dead one is gone...
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, dead, .{}));
    // ...and a LIVE pane's socket is untouched. Deleting one would take
    // down a working pane's IPC, which is far worse than the litter.
    _ = try std.Io.Dir.cwd().statFile(io, live, .{});
}

test "WI-2026-08-13-001: the sweep only judges files it owns" {
    // Numeric-named synapty sockets are ours. Anything else is not, and a
    // sweep that guessed would delete other people's files.
    const io = io_mod.get();
    var dbuf: [128]u8 = undefined;
    const scratch = try std.fmt.bufPrint(&dbuf, "/tmp/synapty-owntest-{d}", .{std.c.getpid()});
    try std.Io.Dir.cwd().createDirPath(io, scratch);

    const names = [_][]const u8{
        "synapty-notapid.sock", "synapty-.sock", "synapty-123.txt", "notsynapty-123.sock",
    };
    var made: [4][192]u8 = undefined;
    for (names, 0..) |n, i| {
        const p = try std.fmt.bufPrintZ(&made[i], "{s}/{s}", .{ scratch, n });
        var f = try std.Io.Dir.cwd().createFile(io, p, .{});
        f.close(io);
    }
    defer {
        for (names, 0..) |n, i| {
            var zb: [192]u8 = undefined;
            if (std.fmt.bufPrintZ(&zb, "{s}/{s}", .{ scratch, n })) |z| sys.unlink(z) else |_| {}
            _ = i;
        }
        var zb2: [128]u8 = undefined;
        if (std.fmt.bufPrintZ(&zb2, "{s}", .{scratch})) |z| {
            _ = std.c.rmdir(z.ptr);
        } else |_| {}
    }

    sweepStaleSocketsIn(scratch);

    for (names) |n| {
        var zb: [192]u8 = undefined;
        const p = try std.fmt.bufPrintZ(&zb, "{s}/{s}", .{ scratch, n });
        _ = std.Io.Dir.cwd().statFile(io, p, .{}) catch {
            std.debug.print("\nsweep deleted a file it does not own: {s}\n", .{n});
            return error.SweptSomebodyElsesFile;
        };
    }
}

test "a waiter must not discard another in-flight request's response" {
    // Two requests in flight — a parked `recv --wait` and the harness's
    // `notify` — and waitForHubResponse's old rule freed whichever answer
    // was not its own; its comment carries the account.
    var srv: RunServer = undefined;
    srv.response_mutex = .init;
    srv.pending_responses = std.ArrayList([]const u8).empty;
    defer {
        for (srv.pending_responses.items) |r| std.heap.smp_allocator.free(r);
        srv.pending_responses.deinit(std.heap.smp_allocator);
    }

    // The hub answered req-2 first; req-1's waiter gets there first.
    const other = try std.heap.smp_allocator.dupe(u8, "{\"type\":\"response\",\"id\":\"req-2\",\"payload\":{\"ok\":true}}");
    try srv.pending_responses.append(std.heap.smp_allocator, other);
    const mine = try std.heap.smp_allocator.dupe(u8, "{\"type\":\"response\",\"id\":\"req-1\",\"payload\":{\"ok\":true}}");
    try srv.pending_responses.append(std.heap.smp_allocator, mine);

    const got = waitForHubResponse(&srv, "req-1");
    try std.testing.expect(got != null);
    std.heap.smp_allocator.free(got.?);

    // The point: req-2 is still there for ITS waiter.
    try std.testing.expectEqual(@as(usize, 1), srv.pending_responses.items.len);
    try std.testing.expect(mem.indexOf(u8, srv.pending_responses.items[0], "req-2") != null);
}

test "request ids are unique under concurrency" {
    // Two panes handed the SAME id is one agent reading another's mail;
    // nextRequestId's comment says why it is atomic.
    var srv: RunServer = undefined;
    srv.next_request_id = 0;

    const N = 64;
    const Ctx = struct {
        srv: *RunServer,
        out: []u32,
        fn run(self: *@This(), slot: usize) void {
            var buf: [32]u8 = undefined;
            const id = nextRequestId(self.srv, &buf);
            self.out[slot] = std.fmt.parseInt(u32, id["req-".len..], 10) catch 0;
        }
    };
    var seen: [N]u32 = undefined;
    var ctx = Ctx{ .srv = &srv, .out = &seen };
    var threads: [N]std.Thread = undefined;
    for (0..N) |i| threads[i] = try std.Thread.spawn(.{}, Ctx.run, .{ &ctx, i });
    for (threads) |t| t.join();

    var uniq = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer uniq.deinit();
    for (seen) |v| try uniq.put(v, {});
    try std.testing.expectEqual(@as(usize, N), uniq.count());
}
