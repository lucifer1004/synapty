const std = @import("std");

/// All shared modules for a given target/optimize combination.
const ModuleSet = struct {
    protocol: *std.Build.Module,
    ipc: *std.Build.Module,
    run: *std.Build.Module,
    mcp: *std.Build.Module,
    /// Process-wide Io instance (Zig 0.16).
    io: *std.Build.Module,
    /// POSIX socket/fd bindings (replaces removed std.net).
    sys: *std.Build.Module,
    /// GitHub REST bridge (RFC-0003).
    github: *std.Build.Module,
};

/// Create the full set of shared modules for a given target and optimize level.
/// All modules link libc: macOS requires it for the posix socket layer
/// (std.posix.system = std.c), and Linux/musl deploy targets link zig's
/// bundled libc, keeping the socket API uniform ([[ADR-0004]]).
fn createModuleSet(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ModuleSet {
    const io = b.createModule(.{
        .root_source_file = b.path("src/io.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const sys = b.createModule(.{
        .root_source_file = b.path("src/sys.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const github = b.createModule(.{
        .root_source_file = b.path("src/github.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "io", .module = io },
            .{ .name = "sys", .module = sys },
        },
    });
    const protocol = b.createModule(.{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const ipc = b.createModule(.{
        .root_source_file = b.path("src/ipc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "io", .module = io },
            .{ .name = "sys", .module = sys },
        },
    });
    const run = b.createModule(.{
        .root_source_file = b.path("src/run.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "protocol", .module = protocol },
            .{ .name = "ipc", .module = ipc },
            .{ .name = "io", .module = io },
            .{ .name = "sys", .module = sys },
        },
    });
    const mcp = b.createModule(.{
        .root_source_file = b.path("src/mcp.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "protocol", .module = protocol },
            .{ .name = "ipc", .module = ipc },
            .{ .name = "io", .module = io },
            .{ .name = "sys", .module = sys },
        },
    });
    return .{ .protocol = protocol, .ipc = ipc, .run = run, .mcp = mcp, .io = io, .sys = sys, .github = github };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Deploy builds default to ReleaseSmall; override with -Ddeploy-optimize=ReleaseFast etc.
    const deploy_optimize = b.option(
        std.builtin.OptimizeMode,
        "deploy-optimize",
        "Optimization level for cross-compiled deploy targets (default: ReleaseSmall)",
    ) orelse .ReleaseSmall;

    // ---------------------------------------------------------------------------
    // Native modules (use standard target/optimize from CLI flags)
    // ---------------------------------------------------------------------------

    const mods = createModuleSet(b, target, optimize);

    // ---------------------------------------------------------------------------
    // Hub module (used by CLI 'hub' subcommand and GUI app) [[ADR-0004]]
    // ---------------------------------------------------------------------------

    const hub_mod = b.createModule(.{
        .root_source_file = b.path("src/hub.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "protocol", .module = mods.protocol },
            .{ .name = "io", .module = mods.io },
            .{ .name = "sys", .module = mods.sys },
            .{ .name = "github", .module = mods.github },
        },
    });

    // ---------------------------------------------------------------------------
    // synapty CLI — single unified binary [[ADR-0004]]
    // ---------------------------------------------------------------------------

    const clap_dep = b.dependency("clap", .{});
    const clap_mod = clap_dep.module("clap");

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "protocol", .module = mods.protocol },
            .{ .name = "ipc", .module = mods.ipc },
            .{ .name = "run", .module = mods.run },
            .{ .name = "mcp", .module = mods.mcp },
            .{ .name = "hub", .module = hub_mod },
            .{ .name = "clap", .module = clap_mod },
            .{ .name = "io", .module = mods.io },
            .{ .name = "sys", .module = mods.sys },
            .{ .name = "github", .module = mods.github },
        },
    });
    const cli_exe = b.addExecutable(.{
        .name = "synapty",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);

    const cli_step = b.step("cli", "Build the Synapty CLI tool");
    cli_step.dependOn(&cli_exe.step);

    // ---------------------------------------------------------------------------
    // Cross-compilation deploy targets (use deploy_optimize)
    // ---------------------------------------------------------------------------

    inline for (.{
        .{ .arch = .aarch64, .os = .linux, .abi = .musl, .name = "linux-aarch64" },
        .{ .arch = .x86_64, .os = .linux, .abi = .musl, .name = "linux-x86_64" },
        .{ .arch = .riscv64, .os = .linux, .abi = .musl, .name = "linux-riscv64" },
        .{ .arch = .aarch64, .os = .macos, .abi = .none, .name = "macos-aarch64" },
        .{ .arch = .x86_64, .os = .macos, .abi = .none, .name = "macos-x86_64" },
    }) |deploy| {
        const deploy_target = b.resolveTargetQuery(.{
            .cpu_arch = deploy.arch,
            .os_tag = deploy.os,
            .abi = deploy.abi,
        });
        const deploy_mods = createModuleSet(b, deploy_target, deploy_optimize);
        const deploy_hub_mod = b.createModule(.{
            .root_source_file = b.path("src/hub.zig"),
            .target = deploy_target,
            .optimize = deploy_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "protocol", .module = deploy_mods.protocol },
                .{ .name = "io", .module = deploy_mods.io },
                .{ .name = "sys", .module = deploy_mods.sys },
                .{ .name = "github", .module = deploy_mods.github },
            },
        });
        const deploy_cli_mod = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = deploy_target,
            .optimize = deploy_optimize,
            .imports = &.{
                .{ .name = "protocol", .module = deploy_mods.protocol },
                .{ .name = "ipc", .module = deploy_mods.ipc },
                .{ .name = "run", .module = deploy_mods.run },
                .{ .name = "mcp", .module = deploy_mods.mcp },
                .{ .name = "hub", .module = deploy_hub_mod },
                .{ .name = "clap", .module = clap_mod },
                .{ .name = "io", .module = deploy_mods.io },
                .{ .name = "sys", .module = deploy_mods.sys },
                .{ .name = "github", .module = deploy_mods.github },
            },
        });
        const deploy_exe = b.addExecutable(.{
            .name = "synapty",
            .root_module = deploy_cli_mod,
        });
        const deploy_step = b.step(
            "deploy-" ++ deploy.name,
            "Cross-compile CLI for " ++ deploy.name,
        );
        deploy_step.dependOn(&b.addInstallArtifact(deploy_exe, .{
            .dest_dir = .{ .override = .{ .custom = deploy.name } },
        }).step);
    }

    // ---------------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------------

    const test_step = b.step("test", "Run all unit tests");

    // protocol: no imports
    addTestModule(b, test_step, "src/protocol.zig", &.{}, target, optimize);

    // github: io + sys
    addTestModule(b, test_step, "src/github.zig", &.{
        .{ .name = "io", .module = mods.io },
        .{ .name = "sys", .module = mods.sys },
    }, target, optimize);

    // ipc: io + sys
    addTestModule(b, test_step, "src/ipc.zig", &.{
        .{ .name = "io", .module = mods.io },
        .{ .name = "sys", .module = mods.sys },
    }, target, optimize);

    // hub: protocol + io + sys
    addTestModule(b, test_step, "src/hub.zig", &.{
        .{ .name = "protocol", .module = mods.protocol },
        .{ .name = "io", .module = mods.io },
        .{ .name = "sys", .module = mods.sys },
    }, target, optimize);

    // daemon: io + run
    addTestModule(b, test_step, "src/daemon.zig", &.{
        .{ .name = "io", .module = mods.io },
        .{ .name = "run", .module = mods.run },
    }, target, optimize);

    // run and mcp: protocol + ipc + io + sys
    inline for (.{ "run", "mcp" }) |name| {
        addTestModule(b, test_step, "src/" ++ name ++ ".zig", &.{
            .{ .name = "protocol", .module = mods.protocol },
            .{ .name = "ipc", .module = mods.ipc },
            .{ .name = "io", .module = mods.io },
            .{ .name = "sys", .module = mods.sys },
        }, target, optimize);
    }

    // e2e: protocol + ipc + run + hub
    const hub_module = b.createModule(.{
        .root_source_file = b.path("src/hub.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "protocol", .module = mods.protocol },
            .{ .name = "io", .module = mods.io },
            .{ .name = "sys", .module = mods.sys },
            .{ .name = "github", .module = mods.github },
        },
    });
    addTestModule(b, test_step, "src/e2e_test.zig", &.{
        .{ .name = "protocol", .module = mods.protocol },
        .{ .name = "ipc", .module = mods.ipc },
        .{ .name = "run", .module = mods.run },
        .{ .name = "hub", .module = hub_module },
        .{ .name = "io", .module = mods.io },
        .{ .name = "sys", .module = mods.sys },
    }, target, optimize);

    // cli: protocol + ipc + run + mcp + hub + clap
    addTestModule(b, test_step, "src/cli.zig", &.{
        .{ .name = "protocol", .module = mods.protocol },
        .{ .name = "ipc", .module = mods.ipc },
        .{ .name = "run", .module = mods.run },
        .{ .name = "mcp", .module = mods.mcp },
        .{ .name = "hub", .module = hub_mod },
        .{ .name = "clap", .module = clap_mod },
        .{ .name = "io", .module = mods.io },
        .{ .name = "sys", .module = mods.sys },
        .{ .name = "github", .module = mods.github },
    }, target, optimize);
}

// ---------------------------------------------------------------------------
// Test helper
// ---------------------------------------------------------------------------

/// Create a test module with the given root source file and imports, and
/// wire it into the test step.
fn addTestModule(
    b: *std.Build,
    test_step: *std.Build.Step,
    root: []const u8,
    imports: []const std.Build.Module.Import,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
}
