const std = @import("std");
const sys = @import("sys");
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
pub fn connectAndRegister(allocator: Allocator, agent_id: []const u8) !sys.fd_t {
    const fd = try connectToHub(hub_addr, hub_port);
    errdefer sys.close(fd);

    const reg = protocol.makeRegisterEnvelope(agent_id, &.{});
    const payload = try protocol.serializeEnvelope(allocator, reg);
    defer allocator.free(payload);

    try sys.writeAll(fd, payload);
    try sys.writeAll(fd, "\n");
    return fd;
}

/// Open a TCP connection to the Hub at addr:port.
pub fn connectToHub(addr: []const u8, port: u16) !sys.fd_t {
    const fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    errdefer sys.close(fd);
    const addr4 = std.Io.net.Ip4Address.parse(addr, port) catch {
        sys.close(fd);
        return error.InvalidHubAddress;
    };
    const sa = sys.sockaddr_in.init(@bitCast(addr4.bytes), port);
    try sys.connect(fd, &sa, @sizeOf(sys.sockaddr_in));
    return fd;
}
