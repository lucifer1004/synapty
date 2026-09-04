const std = @import("std");
const sys = @import("sys");
const framing = @import("framing");
const mem = std.mem;
const log = @import("diag").scoped(.hub);
const protocol = @import("protocol");

const Connection = @import("connection.zig").Connection;
const writerThread = @import("connection.zig").writerThread;
const registry = @import("registry.zig");
const HubState = registry.HubState;
const handlers = @import("handlers.zig");

pub const recv_buf_size = handlers.recv_buf_size;

/// Reader thread args.
pub const ReaderArgs = struct {
    state: *HubState,
    conn: *Connection,
};

/// Handle a single client connection: read JSON envelopes and dispatch them.
/// Uses a per-connection ArenaAllocator so parsed data is freed on disconnect,
/// and a line buffer so partial TCP frames are carried across reads.
pub fn readerThread(args: ReaderArgs) void {
    const state = args.state;
    const conn = args.conn;
    const fd = conn.fd;
    // Release the reader's reference when done. If no cross-agent enqueue is
    // in flight, this frees the Connection. Otherwise the last release() frees.
    defer conn.release();

    // Per-connection arena for data that lives the whole connection (agent_id).
    var conn_arena = std.heap.ArenaAllocator.init(state.allocator);
    defer conn_arena.deinit();
    const conn_alloc = conn_arena.allocator();

    // Per-message arena — reset after each envelope dispatch so memory is bounded.
    var msg_arena = std.heap.ArenaAllocator.init(state.allocator);
    defer msg_arena.deinit();

    // Line buffer for TCP framing — shared framing.LineBuffer carries
    // partial lines across reads (WI-2026-08-08-035).
    var line_buf: [recv_buf_size]u8 = undefined;
    var lb = framing.LineBuffer.init(&line_buf);

    // Read until we have at least one complete line.
    // A CONNECTION THAT NEVER SPEAKS keeps a thread, an fd and this 64 KiB
    // buffer for as long as it likes; the workbench's probe closes at
    // once and every real client sends its first frame immediately, so a
    // bound here costs nobody anything ([[WI-2026-09-02-015]]). Lifted
    // once the first frame is in: a subscriber legitimately stays quiet.
    sys.setRecvTimeout(fd, first_frame_ms) catch {};
    const parsed_init = blk: {
        while (true) {
            const first_line = mem.trimEnd(u8, (lb.readLine(fd) catch |err| {
                log.err("read error on initial message: {any}", .{err});
                return;
            }) orelse return, "\r ");
            if (first_line.len == 0) return;

            // Parse with conn_arena so agent_id survives the connection.
            const parsed = protocol.parseEnvelope(conn_alloc, first_line) catch |err| {
                log.err("failed to parse initial envelope: {any}", .{err});
                return;
            };
            break :blk parsed;
        }
    };
    // First frame in: the deadline comes off.
    sys.setRecvTimeout(fd, 0) catch {};

    // `subscribe` is in the same vocabulary but gets its own connection
    // shape below, so it is excluded HERE rather than left out of the
    // vocabulary — the set is one list ([[RFC-0009]] C-BOUNDARIES).
    if (handlers.isObserverFrame(parsed_init.value.type) and
        !mem.eql(u8, parsed_init.value.type, "subscribe"))
    {
        return serveOneShot(state, conn, fd, &lb, &msg_arena, parsed_init);
    }

    if (mem.eql(u8, parsed_init.value.type, "subscribe"))
        return serveSubscriber(state, conn, fd, &lb, &msg_arena, parsed_init);

    if (mem.eql(u8, parsed_init.value.type, "relay_hello"))
        return serveRelay(state, conn, fd, &lb, conn_alloc, &msg_arena, parsed_init);

    if (!mem.eql(u8, parsed_init.value.type, "register")) {
        log.err("expected register, subscribe, relay_hello, or tool_request, got: {s}", .{parsed_init.value.type});
        return;
    }
    const agent_id = parsed_init.value.source;

    // Connection was pre-created by the accept loop and registered in
    // HubState.all_connections, ensuring deinit can shutdown its stream.
    // Tracked registration (RFC-0004): assigns or carries forward the
    // registration generation and appends the agent_registered event.
    _ = state.registerAgentTracked(agent_id, conn) catch |err| {
        log.err("failed to register {s}: {any}", .{ agent_id, err });
        return;
    };
    // RFC-0008: record the wire-registered id as this connection's
    // fallback identity (bound == fallback until an identity upgrade).
    // THROUGH THE SAME DOOR AS THE ORDINARY TEARDOWN. These two recovery
    // paths took the routing entry out directly, which skips everything
    // `teardownAgent` does after it: the `agent_unregistered` event, the
    // generation, the metadata, the wake candidate, the mailbox disposal
    // — and the directory `remove` the peers are owed, since
    // `registerAgentTracked` has already told them about this identity by
    // the time either of these runs ([[RFC-0009]] C-DIRECTORY: an update
    // when an identity is bound or ENDS locally). A subscriber saw
    // `agent_registered` and never the matching end, and every peer held
    // an entry for a registration that never worked.
    conn.setIdentity(agent_id) catch |err| {
        log.err("failed to set identity for {s}: {any}", .{ agent_id, err });
        _ = state.teardownAgent(agent_id, conn, conn_alloc);
        return;
    };

    // Spawn the writer thread before entering the read loop.
    const writer = std.Thread.spawn(.{}, writerThread, .{conn}) catch |err| {
        log.err("failed to spawn writer thread for {s}: {any}", .{ agent_id, err });
        _ = state.teardownAgent(agent_id, conn, conn_alloc);
        return;
    };

    defer {
        // Tear down routing + derived state ATOMICALLY while it still
        // belongs to this connection (WI-2026-08-08-029): the routing lock
        // serializes this against a re-register of the same id, so the old
        // connection can never delete the new connection's metadata.
        // Tear down whatever identity the connection holds NOW — after
        // an identity upgrade that is the durable id, not the wire id
        // (RFC-0008: the pane id was already unregistered at upgrade).
        const teardown_id = (conn.boundIdDupe(conn_alloc) catch null) orelse agent_id;
        _ = state.teardownAgent(teardown_id, conn, conn_alloc);
        // Signal writer to drain and stop, then wait for it.
        conn.shutdown();
        writer.join();
        // conn is released by the outer `defer conn.release()`; at refcount
        // zero HubState.releaseConnection drops it from all_connections,
        // closes the stream and frees it.
    }

    // Process any additional complete lines from the initial read(s) —
    // buffered only, no socket reads (WI-2026-08-08-035).
    while (lb.countBufferedLines() > 0) {
        const line = lb.readLine(fd) catch break orelse break;
        const raw = mem.trimEnd(u8, line, "\r ");
        if (raw.len == 0) continue;
        _ = msg_arena.reset(.retain_capacity);
        const parsed = protocol.parseEnvelope(msg_arena.allocator(), raw) catch continue;
        handlers.dispatchEnvelope(state, msg_arena.allocator(), conn, agent_id, parsed.value);
    }

    // Main receive loop with line buffering (WI-2026-08-08-035).
    while (true) {
        const line = lb.readLine(fd) catch |err| switch (err) {
            error.ConnectionResetByPeer => null,
            error.StreamTooLong => {
                log.err("message from {s} exceeds buffer — dropping oversized line", .{agent_id});
                lb.dropOversizedLine(fd);
                continue;
            },
            else => blk: {
                log.warn("read error from {s}: {any}", .{ agent_id, err });
                break :blk null;
            },
        } orelse break;
        const raw = mem.trimEnd(u8, line, "\r ");
        if (raw.len == 0) continue;

        // Reset per-message arena so each envelope parse is bounded.
        _ = msg_arena.reset(.retain_capacity);
        const parsed = protocol.parseEnvelope(msg_arena.allocator(), raw) catch |err| {
            log.err("bad envelope from {s}: {any}", .{ agent_id, err });
            continue;
        };
        handlers.dispatchEnvelope(state, msg_arena.allocator(), conn, agent_id, parsed.value);
    }
}

// ---------------------------------------------------------------------------
// The connection shapes, one function each
//
// Held inline in readerThread, the cost is not length for its own sake:
// the branches share NOTHING but the first envelope that selects them, so
// reading one means scrolling past the others, and each branch's `defer`
// teardown sits far from the thread spawn it pairs with — the distance
// that lets a handshake failure leak a peer
// link (WI-2026-08-13-006). [[RFC-0009]] C-BOUNDARIES makes the separation
// a real invariant rather than a stylistic one: a connection is under
// exactly one rule set, decided by its first frame and never revisited.
// ---------------------------------------------------------------------------

/// Anonymous one-shot request (RFC-0003 C-CLI-TOOLS): no registration and
/// no routing-table churn.
fn serveOneShot(
    state: *HubState,
    conn: *Connection,
    fd: sys.fd_t,
    lb: *framing.LineBuffer,
    msg_arena: *std.heap.ArenaAllocator,
    parsed_init: anytype,
) void {
    // Dispatch the first line
    // (already consumed from line_buf), then any buffered remainder,
    // respond, and close. Fixes WI-2026-03-31-004 (cli-tmp churn).
    // agent_status joined the anonymous set for RFC-0004 C-OWNERSHIP:
    // the workbench (not an agent) emits the done→idle gaze transition
    // as a one-shot {state, class, agent} signal; the acceptance rules
    // (C-PRECEDENCE rule 1) bound what such a signal can do.
    // wake_report joined for RFC-0005 C-WAKE-ACK: injection receipts
    // are the workbench's one-shot too (same authority geometry).
    // hub_info joined for ADR-0008: a workbench MUST be able to ask
    // "who are you and which build" BEFORE adopting a listener, so
    // the query cannot itself require registering.
    // tool_receipt joined for [[ADR-0008]] decision 6: task tools now
    // execute at the workbench, which answers on the same one-shot
    // shape exec already uses.
    const writer = std.Thread.spawn(.{}, writerThread, .{conn}) catch return;
    defer {
        conn.shutdown();
        writer.join();
    }
    handlers.dispatchEnvelope(state, msg_arena.allocator(), conn, parsed_init.value.source, parsed_init.value);
    // Dispatch any lines already buffered after the first — WITHOUT
    // reading (the connection closes right after).
    while (lb.countBufferedLines() > 0) {
        const line = lb.readLine(fd) catch break orelse break;
        const raw = mem.trimEnd(u8, line, "\r ");
        if (raw.len == 0) continue;
        _ = msg_arena.reset(.retain_capacity);
        const parsed = protocol.parseEnvelope(msg_arena.allocator(), raw) catch continue;
        handlers.dispatchObserverEnvelope(state, msg_arena.allocator(), conn, parsed_init.value.source, parsed.value) catch |err| {
            log.warn("observer follow-on dispatch failed: {any}", .{err});
        };
    }
    // Hold the connection open until the CLIENT closes. A tool_request
    // is no longer answered synchronously — the hub forwards it to the
    // workbench and the tool_response arrives on another thread, after
    // this dispatch has returned ([[ADR-0008]] decision 6). Closing
    // here would drop that answer on the floor and leave the agent
    // waiting for a reply the hub had already discarded. Every client
    // on this path reads its response and then closes, which is what
    // ends this loop.
    // BOUNDED BY THE PARK: the only thing this loop waits for is an
    // asynchronous tool_response, and the park that produces it expires
    // after pending_tool_ttl_ms. A client that keeps the socket open past
    // that is not waiting for anything ([[WI-2026-09-02-015]]).
    sys.setRecvTimeout(fd, @intCast(HubState.pending_tool_ttl_ms + 5_000)) catch {};
    while (true) {
        _ = lb.readLine(fd) catch break orelse break;
    }
    return;
}

/// Event subscriber (RFC-0004 C-SUBSCRIPTION), which under [[ADR-0008]] is
/// also the workbench's supervisor link.
fn serveSubscriber(
    state: *HubState,
    conn: *Connection,
    fd: sys.fd_t,
    lb: *framing.LineBuffer,
    msg_arena: *std.heap.ArenaAllocator,
    parsed_init: anytype,
) void {
    // Snapshot + subscriber-add happen atomically in
    // the handler; the pushed events then flow through this
    // connection's writer until the client disconnects.
    const writer = std.Thread.spawn(.{}, writerThread, .{conn}) catch return;
    // [[ADR-0008]]: a subscriber IS a workbench supervisor link. Its
    // presence cancels a pending grace shutdown (a relaunched
    // workbench reclaims the hub by subscribing, which it does
    // anyway), and its absence is what lets the window expire.
    if (state.supervision) |sup| sup.supervisorAttached();
    defer {
        if (state.supervision) |sup| sup.supervisorDetached();
        state.removeSubscriber(conn);
        conn.shutdown();
        writer.join();
    }
    handlers.handleSubscribe(state, msg_arena.allocator(), conn, parsed_init.value) catch |err| {
        log.warn("subscribe failed for {s}: {any}", .{ parsed_init.value.source, err });
        return;
    };
    // Drain (and ignore) anything the subscriber sends until EOF —
    // the subscription surface is push-only after the snapshot.
    // A SUBSCRIBER STAYS QUIET BY DESIGN: no deadline here. The stream
    // ends when the workbench closes it, and its absence is what lets the
    // hub's grace window expire.
    while (true) {
        _ = lb.readLine(fd) catch break orelse break;
    }
    return;
}

/// Relay link ([[RFC-0009]] C-BOUNDARIES): many identities on one
/// connection, distinguished by the mandatory first frame.
///
/// NOT AUTHENTICATED, and the word was retracted from the clause for the
/// reason it is retracted here: this arrives on the same loopback
/// listener as every submission, an SSH reverse tunnel terminates on
/// loopback too, and the only discriminator is that first frame. A peer
/// id is self-reported on exactly the same footing as an agent id.
fn serveRelay(
    state: *HubState,
    conn: *Connection,
    fd: sys.fd_t,
    lb: *framing.LineBuffer,
    conn_alloc: std.mem.Allocator,
    msg_arena: *std.heap.ArenaAllocator,
    parsed_init: anytype,
) void {
    // [[RFC-0009]] C-BOUNDARIES: a RELAY link, not a submission
    // connection. The distinction is this frame and nothing else —
    // which is exactly why relay_hello must be first: it means a hub
    // never has to guess which set of rules a connection is under,
    // and a connection that starts any other way can never reach the
    // relay vocabulary (many identities on one connection) that would
    // break every connection-scoped invariant in RFC-0004/0007/0008.
    const writer = std.Thread.spawn(.{}, writerThread, .{conn}) catch return;
    const peer = handlers.handleRelayHello(state, conn_alloc, conn, parsed_init.value) catch |err| {
        log.warn("relay handshake failed: {any}", .{err});
        conn.shutdown();
        writer.join();
        return;
    } orelse {
        conn.shutdown();
        writer.join();
        return;
    };
    defer {
        // Link down TOMBSTONES this peer's identities rather than
        // discarding them: delivery still needs to know where to
        // spool, and presence still owes an `unknown` for each.
        state.peerLinkDown(peer);
        conn.shutdown();
        writer.join();
    }
    while (true) {
        const line = lb.readLine(fd) catch break orelse break;
        const raw = mem.trimEnd(u8, line, "\r ");
        if (raw.len == 0) continue;
        _ = msg_arena.reset(.retain_capacity);
        const parsed = protocol.parseEnvelope(msg_arena.allocator(), raw) catch continue;
        handlers.dispatchRelayFrame(state, msg_arena.allocator(), conn, peer, parsed.value);
    }
    return;
}

/// Ten seconds for a first frame is generous by three orders of magnitude.
pub const first_frame_ms: u64 = 10_000;
