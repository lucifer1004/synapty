const std = @import("std");
const sys = @import("sys");
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

    // Line buffer for TCP framing — carries partial lines across reads.
    var line_buf: [recv_buf_size]u8 = undefined;
    var filled: usize = 0;

    // Read until we have at least one complete line.
    const parsed_init = blk: {
        while (true) {
            if (filled >= line_buf.len) {
                log.err("initial message exceeds buffer", .{});
                return;
            }
            const n = sys.read(fd, line_buf[filled..]) catch |err| {
                log.err("read error on initial message: {any}", .{err});
                return;
            };
            if (n == 0) return;
            filled += n;

            // Check for a complete first line.
            if (mem.indexOfScalar(u8, line_buf[0..filled], '\n')) |nl| {
                const first_line = mem.trimEnd(u8, line_buf[0..nl], "\r ");
                if (first_line.len == 0) return;

                // Parse with conn_arena so agent_id survives the connection.
                const parsed = protocol.parseEnvelope(conn_alloc, first_line) catch |err| {
                    log.err("failed to parse initial envelope: {any}", .{err});
                    return;
                };
                // Shift consumed bytes out of line_buf.
                const consumed = nl + 1;
                const remaining = filled - consumed;
                if (remaining > 0) {
                    mem.copyForwards(u8, line_buf[0..remaining], line_buf[consumed..filled]);
                }
                filled = remaining;
                break :blk parsed;
            }
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
        handlers.processLines(state, &msg_arena, conn, parsed_init.value.source, &line_buf, &filled);
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
        state.routing_table.unregister(agent_id);
        return;
    };

    defer {
        state.routing_table.unregister(agent_id);
        state.agent_registry.remove(agent_id);
        // Remove from all channels per [[RFC-0002:C-HUB-STATE]].
        _ = state.channel_registry.removeFromAll(agent_id, conn_alloc) catch {};
        // Signal writer to drain and stop, then wait for it.
        conn.shutdown();
        writer.join();
        // conn is released by the outer `defer conn.release()`. If refcount hits 0,
        // removeConnection removes from all_connections, closes stream, and frees.
    }

    // Process any additional complete lines from the initial read(s).
    handlers.processLines(state, &msg_arena, conn, agent_id, &line_buf, &filled);

    // Main receive loop with line buffering.
    while (true) {
        if (filled >= line_buf.len) {
            log.err("message from {s} exceeds buffer", .{agent_id});
            break;
        }
        const n = sys.read(fd, line_buf[filled..]) catch |err| {
            switch (err) {
                error.ConnectionResetByPeer => {},
                else => log.warn("read error from {s}: {any}", .{ agent_id, err }),
            }
            break;
        };
        if (n == 0) break;
        filled += n;

        handlers.processLines(state, &msg_arena, conn, agent_id, &line_buf, &filled);
    }
}
