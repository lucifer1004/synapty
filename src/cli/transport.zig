const std = @import("std");
const net = std.net;
const mem = std.mem;
const protocol = @import("protocol");
const Allocator = mem.Allocator;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const hub_addr = "127.0.0.1";
pub const hub_port: u16 = 9000;
pub const temp_agent_prefix = "cli-tmp-";

// ---------------------------------------------------------------------------
// Hub connection helpers
// ---------------------------------------------------------------------------

/// Connect to the Hub and send an initial register envelope.
/// Returns the open stream; caller must close it.
pub fn connectAndRegister(allocator: Allocator, agent_id: []const u8) !net.Stream {
    const address = net.Address.parseIp4(hub_addr, hub_port) catch unreachable;
    const stream = try net.tcpConnectToAddress(address);
    errdefer stream.close();

    const reg = protocol.makeRegisterEnvelope(agent_id, &.{});
    const payload = try protocol.serializeEnvelope(allocator, reg);
    defer allocator.free(payload);

    _ = try stream.write(payload);
    _ = try stream.write("\n");
    return stream;
}
