//! THE MACHINES THIS PROJECT BUILDS A BINARY FOR.
//!
//! ONE LIST, BECAUSE THERE WERE NINE. The same five platforms were
//! written out independently in `build.zig`'s cross-compile loop, two
//! shell loops (`justfile`, `project.yml`), `justfile`'s deploy-all step,
//! `host.zig`'s uname table, `host.zig`'s "Supported:" prose,
//! `HostBinary.swift`'s uname map, and two tests that each asserted a
//! fixed five and so could not notice a sixth.
//!
//! THE QUIET DIRECTION IS THE DANGEROUS ONE. Add a target everywhere but
//! `HostBinary.swift` and `synapty host-setup` deploys to that machine
//! from the terminal while the workbench offers it nothing at all —
//! `WorkspaceManager` takes the nil branch, `ok` stays false, and nothing
//! anywhere says why ([[WI-2026-09-11-003]]).
//!
//! `build.zig` reads this to create the steps; `cli/host.zig` reads it to
//! map what a host says it is; the build writes the names to
//! `zig-out/deploy-targets.txt` so the packaging shells iterate it rather
//! than repeat it; and the Swift side is held to it through the artifact —
//! a bundle carrying a target its map does not know fails a test.

const std = @import("std");

pub const Target = struct {
    /// The directory the binary lands in, in `zig-out` and in the bundle.
    name: []const u8,
    /// Exactly what `uname -sm` says on such a machine.
    uname: []const u8,
    arch: std.Target.Cpu.Arch,
    os: std.Target.Os.Tag,
    abi: std.Target.Abi,
};

pub const all = [_]Target{
    .{ .name = "linux-aarch64", .uname = "Linux aarch64", .arch = .aarch64, .os = .linux, .abi = .musl },
    .{ .name = "linux-x86_64", .uname = "Linux x86_64", .arch = .x86_64, .os = .linux, .abi = .musl },
    .{ .name = "linux-riscv64", .uname = "Linux riscv64", .arch = .riscv64, .os = .linux, .abi = .musl },
    .{ .name = "macos-aarch64", .uname = "Darwin arm64", .arch = .aarch64, .os = .macos, .abi = .none },
    .{ .name = "macos-x86_64", .uname = "Darwin x86_64", .arch = .x86_64, .os = .macos, .abi = .none },
};

/// The directory a machine's binary lives in, or null when this project
/// builds nothing for it. REFUSED RATHER THAN GUESSED: a host with no
/// binary is told so by name, because the alternative is uploading
/// something that cannot run and finding out at the far end.
pub fn dirFor(uname_sm: []const u8) ?[]const u8 {
    for (all) |t| {
        if (std.mem.eql(u8, t.uname, uname_sm)) return t.name;
    }
    return null;
}

/// The `uname -sm` answers this build knows, joined for a human — derived
/// rather than written out, so the sentence cannot name a different set
/// from the table that decides.
pub fn unamesJoined(buf: []u8) []const u8 {
    var w: usize = 0;
    for (all, 0..) |t, i| {
        const sep = if (i == 0) "" else ", ";
        const part = std.fmt.bufPrint(buf[w..], "{s}{s}", .{ sep, t.uname }) catch return buf[0..w];
        w += part.len;
    }
    return buf[0..w];
}
