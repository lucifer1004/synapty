const std = @import("std");
const sys = @import("sys");
const framing = @import("framing");
const mem = std.mem;
const log = std.log.scoped(.hub);
const protocol = @import("protocol");

const Connection = @import("connection.zig").Connection;
const writerThread = @import("connection.zig").writerThread;
const registry = @import("registry.zig");
const HubState = registry.HubState;
const handlers = @import("handlers.zig");

/// Per-connection receive buffer size (64 KiB).
pub const recv_buf_size = handlers.recv_buf_size;

/// Reader thread args.
pub const ReaderArgs = struct {
    state: *HubState,
    conn: *Connection,
};

/// Handle a single client connection: read JSON envelopes and dispatch them.
/// Uses a per-connection ArenaAllocator so parsed data is freed on disconnect,
/// and a line buffer so partial TCP frames are carried across reads.
/// Creates a Connection with an outbound queue and spawns a writer thread.
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

    if (mem.eql(u8, parsed_init.value.@"type", "tool_request") or
        mem.eql(u8, parsed_init.value.@"type", "list_agents"))
    {
        // Anonymous request connection (RFC-0003 C-CLI-TOOLS): no
        // registration, no routing-table churn. Dispatch the first line
        // (already consumed from line_buf), then any buffered remainder,
        // respond, and close. Fixes WI-2026-03-31-004 (cli-tmp churn).
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
            handlers.dispatchEnvelope(state, msg_arena.allocator(), conn, parsed_init.value.source, parsed.value);
        }
        return;
    }

    if (!mem.eql(u8, parsed_init.value.@"type", "register")) {
        log.err("expected register or tool_request, got: {s}", .{parsed_init.value.@"type"});
        return;
    }
    const agent_id = parsed_init.value.source;

    // Connection was pre-created by the accept loop and registered in
    // HubState.all_connections, ensuring deinit can shutdown its stream.
    state.routing_table.register(agent_id, conn) catch |err| {
        log.err("failed to register {s}: {any}", .{ agent_id, err });
        return;
    };

    // Spawn the writer thread before entering the read loop.
    const writer = std.Thread.spawn(.{}, writerThread, .{conn}) catch |err| {
        log.err("failed to spawn writer thread for {s}: {any}", .{ agent_id, err });
        _ = state.routing_table.unregisterIfOwned(agent_id, conn);
        return;
    };

    defer {
        // Tear down routing + derived state ATOMICALLY while it still
        // belongs to this connection (WI-2026-08-08-029): the routing lock
        // serializes this against a re-register of the same id, so the old
        // connection can never delete the new connection's metadata.
        _ = state.teardownAgent(agent_id, conn, conn_alloc);
        // Signal writer to drain and stop, then wait for it.
        conn.shutdown();
        writer.join();
        // conn is released by the outer `defer conn.release()`. If refcount hits 0,
        // removeConnection removes from all_connections, closes stream, and frees.
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
