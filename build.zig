const std = @import("std");

/// All shared modules for a given target/optimize combination.
const ModuleSet = struct {
    protocol: *std.Build.Module,
    ipc: *std.Build.Module,
    run: *std.Build.Module,
    mcp: *std.Build.Module,
};

/// Create the full set of shared modules for a given target and optimize level.
fn createModuleSet(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ModuleSet {
    const protocol = b.createModule(.{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ipc = b.createModule(.{
        .root_source_file = b.path("src/ipc.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run = b.createModule(.{
        .root_source_file = b.path("src/run.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol },
            .{ .name = "ipc", .module = ipc },
        },
    });
    const mcp = b.createModule(.{
        .root_source_file = b.path("src/mcp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol },
            .{ .name = "ipc", .module = ipc },
        },
    });
    return .{ .protocol = protocol, .ipc = ipc, .run = run, .mcp = mcp };
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
    // synapty-hub executable
    // ---------------------------------------------------------------------------

    const hub_mod = b.createModule(.{
        .root_source_file = b.path("src/hub.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = mods.protocol },
        },
    });
    const hub_exe = b.addExecutable(.{
        .name = "synapty-hub",
        .root_module = hub_mod,
    });
    b.installArtifact(hub_exe);

    const hub_step = b.step("hub", "Build the Synapty Hub (local router)");
    hub_step.dependOn(&hub_exe.step);

    // ---------------------------------------------------------------------------
    // synapty-daemon executable
    // ---------------------------------------------------------------------------

    const daemon_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = mods.protocol },
            .{ .name = "ipc", .module = mods.ipc },
            .{ .name = "run", .module = mods.run },
        },
    });
    const daemon_exe = b.addExecutable(.{
        .name = "synapty-daemon",
        .root_module = daemon_mod,
    });
    b.installArtifact(daemon_exe);

    const daemon_step = b.step("daemon", "Build the Synapty Daemon (remote companion)");
    daemon_step.dependOn(&daemon_exe.step);

    // ---------------------------------------------------------------------------
    // synapty CLI executable
    // ---------------------------------------------------------------------------

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = mods.protocol },
            .{ .name = "ipc", .module = mods.ipc },
            .{ .name = "run", .module = mods.run },
            .{ .name = "mcp", .module = mods.mcp },
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
        const deploy_cli_mod = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = deploy_target,
            .optimize = deploy_optimize,
            .imports = &.{
                .{ .name = "protocol", .module = deploy_mods.protocol },
                .{ .name = "ipc", .module = deploy_mods.ipc },
                .{ .name = "run", .module = deploy_mods.run },
                .{ .name = "mcp", .module = deploy_mods.mcp },
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

    // Standalone module tests (protocol, ipc)
    inline for (.{ "protocol", "ipc" }) |name| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path("src/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
        });
        const tests = b.addTest(.{ .root_module = test_mod });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // Tests with imports matching their executable modules
    const hub_test_mod = b.createModule(.{
        .root_source_file = b.path("src/hub.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = mods.protocol },
        },
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = hub_test_mod })).step);

    const daemon_test_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = mods.protocol },
            .{ .name = "ipc", .module = mods.ipc },
            .{ .name = "run", .module = mods.run },
        },
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = daemon_test_mod })).step);

    // run and mcp tests share the same import set (protocol + ipc)
    inline for (.{ "run", "mcp" }) |name| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path("src/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protocol", .module = mods.protocol },
                .{ .name = "ipc", .module = mods.ipc },
            },
        });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_mod })).step);
    }

    // e2e integration tests (hub + run + protocol + ipc)
    const hub_module = b.createModule(.{
        .root_source_file = b.path("src/hub.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = mods.protocol },
        },
    });
    const e2e_test_mod = b.createModule(.{
        .root_source_file = b.path("src/e2e_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = mods.protocol },
            .{ .name = "ipc", .module = mods.ipc },
            .{ .name = "run", .module = mods.run },
            .{ .name = "hub", .module = hub_module },
        },
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = e2e_test_mod })).step);

    // cli tests need all four imports
    const cli_test_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = mods.protocol },
            .{ .name = "ipc", .module = mods.ipc },
            .{ .name = "run", .module = mods.run },
            .{ .name = "mcp", .module = mods.mcp },
        },
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cli_test_mod })).step);
}
