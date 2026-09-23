const std = @import("std");
const sys = @import("sys");
const framing = @import("framing");
const io_mod = @import("io");
const mem = std.mem;
const json = std.json;
const protocol = @import("protocol");
const log = @import("diag").scoped(.hub);

const Connection = @import("connection.zig").Connection;
const writerThread = @import("connection.zig").writerThread;
const HubState = @import("registry.zig").HubState;
const handlers = @import("handlers.zig");
const federation = @import("federation.zig");

// ---------------------------------------------------------------------------
// Outbound relay link — [[RFC-0009]] C-BOUNDARIES
//
// The DIALING half. The accepting half lives in session.zig, reached by the
// mandatory relay_hello first frame; this file is what sends it.
//
// There is no credential scheme here on purpose. C-BOUNDARIES: the link runs
// inside an already-authenticated channel — the SSH machinery the workbench
// already manages for hosts — and a hub MUST NOT invent its own while an SSH
// path exists. In practice `port` is the local end of a tunnel the human
// established, which is why this dials loopback and nothing else.
// ---------------------------------------------------------------------------

pub const DialArgs = struct {
    state: *HubState,
    /// Local end of the tunnel to the peer.
    port: u16,
};

fn connectLoopback(port: u16) !sys.fd_t {
    const fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    errdefer sys.close(fd);
    const addr4 = std.Io.net.Ip4Address.loopback(port);
    const sa = sys.sockaddr_in.init(@bitCast(addr4.bytes), port);
    try sys.connect(fd, &sa, @sizeOf(sys.sockaddr_in));
    return fd;
}

/// Dial a peer, handshake, and serve the link until it drops. Blocking —
/// callers run it on its own thread.
pub fn dialAndServe(args: DialArgs) void {
    const state = args.state;
    // COPY, not borrow. This slice is held for the whole life of the
    // link; setPeerId frees the old one on a rename, and a borrowed
    // reference would dangle from that moment on.
    var id_arena = std.heap.ArenaAllocator.init(state.allocator);
    defer id_arena.deinit();
    const me = (state.peerIdDupe(id_arena.allocator()) catch null) orelse {
        log.warn("relay: refusing to dial without a peer id of our own", .{});
        return;
    };

    const fd = connectLoopback(args.port) catch |err| {
        log.warn("relay: dial 127.0.0.1:{d} failed: {any}", .{ args.port, err });
        return;
    };

    const conn = state.allocator.create(Connection) catch {
        sys.close(fd);
        return;
    };
    conn.* = Connection.init(state.allocator, fd, @ptrCast(state), &HubState.releaseConnection);
    {
        state.all_connections_mutex.lock(io_mod.get()) catch unreachable;
        defer state.all_connections_mutex.unlock(io_mod.get());
        state.all_connections.append(state.allocator, conn) catch {
            conn.deinit();
            state.allocator.destroy(conn);
            return;
        };
    }
    defer conn.release();

    const writer = std.Thread.spawn(.{}, writerThread, .{conn}) catch return;
    // ONE teardown, next to the thing it tears down. Twelve hand-written
    // `conn.shutdown(); writer.join();` pairs on twelve early returns is
    // a leaked thread and a leaked fd for whichever one a later edit
    // forgets. Every `return` below is just a return.
    defer {
        conn.shutdown();
        writer.join();
    }

    var arena = std.heap.ArenaAllocator.init(state.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var hello_payload = json.ObjectMap.empty;
    handlers.putVersioning(a, &hello_payload) catch {};
    conn.enqueueEnvelope(a, .{
        .type = "relay_hello",
        .id = "relay-hello",
        .source = me,
        .target = "",
        .payload = .{ .object = hello_payload },
    }) catch {
        return;
    };

    var line_buf: [handlers.recv_buf_size]u8 = undefined;
    var lb = framing.LineBuffer.init(&line_buf);

    // The peer's own id comes from ITS hello, not from our configuration:
    // the machine is the authority on what it is called, and trusting a
    // local guess here is how two peers end up disagreeing about which
    // directory entries belong to whom.
    var negotiated: handlers.HelloVersioning = .{};
    var agreed_version: u16 = federation.protocol_min;
    const peer_id: []const u8 = handshake(state, fd, &lb, a, &negotiated, &agreed_version) orelse return;
    defer state.allocator.free(peer_id);

    state.peerLinkUp(peer_id, conn, args.port, agreed_version, negotiated.caps) catch |err| {
        log.warn("relay: cannot bring up link to {s}: {any}", .{ peer_id, err });
        return;
    };
    // TOMBSTONE, not discard: delivery still needs to know where to spool
    // and presence still owes an `unknown` for each identity. Registered
    // after the teardown defer, so LIFO runs it FIRST — the link is
    // marked down while the connection is still whole, and peer_id is
    // still alive because its free() was registered earlier still.
    defer state.peerLinkDown(peer_id);

    if (negotiated.unknown_caps > 0) {
        // The peer is NEWER than this build. Worth saying, because
        // "the peer does less than us" and "does more" otherwise look
        // identical from here.
        log.info(
            "relay: peer '{s}' declares {d} capability(ies) this build does not know",
            .{ peer_id, negotiated.unknown_caps },
        );
    }
    if (!negotiated.caps.has(.presence_relay)) {
        log.info(
            "relay: peer '{s}' does not provide presence relay — its agents will report unknown status, and that is its BUILD, not a fault",
            .{peer_id},
        );
    }
    log.info("relay: link up to peer '{s}' at protocol v{d}", .{ peer_id, agreed_version });
    state.advertiseAllTo(conn);
    // Statuses too, or an agent that reached `waiting` before the link
    // came up stays `unknown` on the peer until it moves again.
    state.relayPresenceAllTo(conn, negotiated.caps);
    // C-DELIVERY flush order: spooled traffic precedes new traffic, or a
    // sender's later message can overtake its earlier one.
    const flushed = state.flushSpoolTo(peer_id);
    if (flushed > 0) log.info("relay: flushed {d} spooled message(s) to {s}", .{ flushed, peer_id });

    var msg_arena = std.heap.ArenaAllocator.init(state.allocator);
    defer msg_arena.deinit();
    while (true) {
        const line = lb.readLine(fd) catch break orelse break;
        const raw = mem.trimEnd(u8, line, "\r ");
        if (raw.len == 0) continue;
        _ = msg_arena.reset(.retain_capacity);
        const parsed = protocol.parseEnvelope(msg_arena.allocator(), raw) catch continue;
        handlers.dispatchRelayFrame(state, msg_arena.allocator(), conn, peer_id, parsed.value);
    }
}

/// The peer id in a relay_hello: `payload.data.peer` for the accepting
/// side's response, falling back to the envelope source for a hello sent
/// as an opening frame.
fn extractPeerId(envelope: protocol.Envelope) ?[]const u8 {
    if (envelope.payload == .object) {
        if (envelope.payload.object.get("data")) |d| {
            if (d == .object) {
                if (d.object.get("peer")) |p| {
                    if (p == .string and p.string.len > 0) return p.string;
                }
            }
        }
    }
    if (envelope.source.len > 0 and !mem.eql(u8, envelope.source, "hub")) return envelope.source;
    return null;
}

/// The dialing side's handshake: read the peer's relay_hello, negotiate a
/// protocol version, and learn the name the peer reports for ITSELF.
///
/// Lifted out of dialAndServe because it is a self-contained protocol
/// exchange with eight distinct refusal paths, and inline it buried the
/// serve loop that follows. Returns the peer id (state-allocator owned;
/// caller frees) or null when the link must not come up — every null is
/// already logged with the reason.
///
/// `negotiated` and `agreed_version` are out-parameters rather than part
/// of the return, because the caller needs them for capability decisions
/// that outlive the handshake.
fn handshake(
    state: *HubState,
    fd: sys.fd_t,
    lb: *framing.LineBuffer,
    a: std.mem.Allocator,
    negotiated: *handlers.HelloVersioning,
    agreed_version: *u16,
) ?[]const u8 {
    const raw = (lb.readLine(fd) catch null) orelse {
        log.warn("relay: peer closed before answering the handshake", .{});
        return null;
    };
    const trimmed = mem.trimEnd(u8, raw, "\r ");
    const parsed = protocol.parseEnvelope(a, trimmed) catch {
        return null;
    };
    if (mem.eql(u8, parsed.value.type, "relay_refused")) {
        // [[RFC-0010]] C-COLLISION: a refusal is a STATEMENT, not a
        // transport failure. Previously this arrived as a generic
        // response, was logged as "expected relay_hello" and closed,
        // and a human saw a link that just did not come up.
        var code: []const u8 = "unknown";
        var detail: []const u8 = "";
        if (parsed.value.payload == .object) {
            if (parsed.value.payload.object.get("data")) |d| {
                if (d == .object) {
                    if (d.object.get("reason")) |r| {
                        if (r == .string) code = r.string;
                    }
                }
            }
            if (parsed.value.payload.object.get("error")) |e| {
                if (e == .string) detail = e.string;
            }
        }
        log.err("relay: peer REFUSED the link [{s}] {s}", .{ code, detail });
        return null;
    }
    if (!mem.eql(u8, parsed.value.type, "relay_hello")) {
        // C-BOUNDARIES: the two connection kinds are distinguished by
        // this frame and nothing else. Anything else here means we do
        // not know which rule set we are under, so we refuse.
        log.warn("relay: expected relay_hello, got '{s}' — refusing the link", .{parsed.value.type});
        return null;
    }
    negotiated.* = handlers.parseHelloVersioning(parsed.value) orelse {
        log.err("relay: peer's hello carries no version range or capability list — refusing the link", .{});
        return null;
    };
    agreed_version.* = federation.negotiateVersion(negotiated.min, negotiated.max) orelse {
        log.err(
            "relay: no protocol version in common (peer {d}-{d}, this build {d}-{d}) — one side needs upgrading",
            .{ negotiated.min, negotiated.max, federation.protocol_min, federation.protocol_max },
        );
        return null;
    };
    const id = extractPeerId(parsed.value) orelse {
        log.warn("relay: peer answered without a usable peer id", .{});
        return null;
    };
    if (!federation.validPeerId(id)) {
        log.warn("relay: peer id '{s}' fails the character discipline", .{id});
        return null;
    }
    return state.allocator.dupe(u8, id) catch null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "extractPeerId prefers the response's data.peer over the envelope source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The accepting side answers with source "hub" and the real id in
    // data.peer — reading `source` there would name every peer "hub".
    var data = json.ObjectMap.empty;
    try data.put(a, "peer", .{ .string = "remotehost" });
    var payload = json.ObjectMap.empty;
    try payload.put(a, "data", .{ .object = data });
    const resp = protocol.Envelope{
        .type = "relay_hello",
        .id = "relay-hello",
        .source = "hub",
        .target = "laptop",
        .payload = .{ .object = payload },
    };
    try std.testing.expectEqualStrings("remotehost", extractPeerId(resp).?);

    // An opening hello carries it as the source instead.
    const opener = protocol.Envelope{
        .type = "relay_hello",
        .id = "relay-hello",
        .source = "laptop",
        .target = "",
        .payload = .null,
    };
    try std.testing.expectEqualStrings("laptop", extractPeerId(opener).?);

    // "hub" alone is not a peer id — refusing beats inventing one.
    const anon = protocol.Envelope{
        .type = "relay_hello",
        .id = "x",
        .source = "hub",
        .target = "",
        .payload = .null,
    };
    try std.testing.expect(extractPeerId(anon) == null);
}
