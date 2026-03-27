const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---------------------------------------------------------------------------
    // Shared modules (defined first so all executables can reference them)
    // ---------------------------------------------------------------------------

    // Shared protocol module
    const protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shared IPC transport module (no imports — transport only)
    const ipc_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shared run module (depends on protocol + ipc)
    const run_mod = b.createModule(.{
        .root_source_file = b.path("src/run.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
            .{ .name = "ipc", .module = ipc_mod },
        },
    });

    // MCP stdio server module
    const mcp_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
            .{ .name = "ipc", .module = ipc_mod },
        },
    });

    // ---------------------------------------------------------------------------
    // synapty-hub executable
    // ---------------------------------------------------------------------------

    const hub_mod = b.createModule(.{
        .root_source_file = b.path("src/hub.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
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
            .{ .name = "protocol", .module = protocol_mod },
            .{ .name = "ipc", .module = ipc_mod },
            .{ .name = "run", .module = run_mod },
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
            .{ .name = "protocol", .module = protocol_mod },
            .{ .name = "ipc", .module = ipc_mod },
            .{ .name = "run", .module = run_mod },
            .{ .name = "mcp", .module = mcp_mod },
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
    // Cross-compilation: CLI for Linux aarch64 (musl) — deploy target
    // ---------------------------------------------------------------------------

    const linux_aarch64_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .musl,
    });

    const deploy_linux_aarch64_protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol.zig"),
        .target = linux_aarch64_target,
        .optimize = .ReleaseSmall,
    });
    const deploy_linux_aarch64_ipc_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc.zig"),
        .target = linux_aarch64_target,
        .optimize = .ReleaseSmall,
    });
    const deploy_linux_aarch64_run_mod = b.createModule(.{
        .root_source_file = b.path("src/run.zig"),
        .target = linux_aarch64_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "protocol", .module = deploy_linux_aarch64_protocol_mod },
            .{ .name = "ipc", .module = deploy_linux_aarch64_ipc_mod },
        },
    });
    const deploy_linux_aarch64_mcp_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp.zig"),
        .target = linux_aarch64_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "protocol", .module = deploy_linux_aarch64_protocol_mod },
            .{ .name = "ipc", .module = deploy_linux_aarch64_ipc_mod },
        },
    });
    const cli_linux_aarch64_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = linux_aarch64_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "protocol", .module = deploy_linux_aarch64_protocol_mod },
            .{ .name = "ipc", .module = deploy_linux_aarch64_ipc_mod },
            .{ .name = "run", .module = deploy_linux_aarch64_run_mod },
            .{ .name = "mcp", .module = deploy_linux_aarch64_mcp_mod },
        },
    });
    const cli_linux_aarch64_exe = b.addExecutable(.{
        .name = "synapty",
        .root_module = cli_linux_aarch64_mod,
    });

    const linux_deploy_step = b.step("deploy-linux-aarch64", "Cross-compile CLI for Linux aarch64");
    linux_deploy_step.dependOn(&b.addInstallArtifact(cli_linux_aarch64_exe, .{
        .dest_dir = .{ .override = .{ .custom = "linux-aarch64" } },
    }).step);

    // ---------------------------------------------------------------------------
    // Cross-compilation: CLI for Linux x86_64 (musl) — deploy target
    // ---------------------------------------------------------------------------

    const linux_x86_64_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });

    const deploy_linux_x86_64_protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol.zig"),
        .target = linux_x86_64_target,
        .optimize = .ReleaseSmall,
    });
    const deploy_linux_x86_64_ipc_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc.zig"),
        .target = linux_x86_64_target,
        .optimize = .ReleaseSmall,
    });
    const deploy_linux_x86_64_run_mod = b.createModule(.{
        .root_source_file = b.path("src/run.zig"),
        .target = linux_x86_64_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "protocol", .module = deploy_linux_x86_64_protocol_mod },
            .{ .name = "ipc", .module = deploy_linux_x86_64_ipc_mod },
        },
    });
    const deploy_linux_x86_64_mcp_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp.zig"),
        .target = linux_x86_64_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "protocol", .module = deploy_linux_x86_64_protocol_mod },
            .{ .name = "ipc", .module = deploy_linux_x86_64_ipc_mod },
        },
    });
    const cli_linux_x86_64_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = linux_x86_64_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "protocol", .module = deploy_linux_x86_64_protocol_mod },
            .{ .name = "ipc", .module = deploy_linux_x86_64_ipc_mod },
            .{ .name = "run", .module = deploy_linux_x86_64_run_mod },
            .{ .name = "mcp", .module = deploy_linux_x86_64_mcp_mod },
        },
    });
    const cli_linux_x86_64_exe = b.addExecutable(.{
        .name = "synapty",
        .root_module = cli_linux_x86_64_mod,
    });

    const linux_deploy_x86_step = b.step("deploy-linux-x86_64", "Cross-compile CLI for Linux x86_64");
    linux_deploy_x86_step.dependOn(&b.addInstallArtifact(cli_linux_x86_64_exe, .{
        .dest_dir = .{ .override = .{ .custom = "linux-x86_64" } },
    }).step);

    // ---------------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------------

    const protocol_test_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const protocol_tests = b.addTest(.{
        .root_module = protocol_test_mod,
    });

    const hub_test_mod = b.createModule(.{
        .root_source_file = b.path("src/hub.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
        },
    });
    const hub_tests = b.addTest(.{
        .root_module = hub_test_mod,
    });

    const daemon_test_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
            .{ .name = "ipc", .module = ipc_mod },
            .{ .name = "run", .module = run_mod },
        },
    });
    const daemon_tests = b.addTest(.{
        .root_module = daemon_test_mod,
    });

    const cli_test_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
            .{ .name = "ipc", .module = ipc_mod },
            .{ .name = "run", .module = run_mod },
            .{ .name = "mcp", .module = mcp_mod },
        },
    });
    const cli_tests = b.addTest(.{
        .root_module = cli_test_mod,
    });

    const ipc_test_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ipc_tests = b.addTest(.{
        .root_module = ipc_test_mod,
    });

    const run_test_mod = b.createModule(.{
        .root_source_file = b.path("src/run.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
            .{ .name = "ipc", .module = ipc_mod },
        },
    });
    const run_tests = b.addTest(.{
        .root_module = run_test_mod,
    });

    const mcp_test_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
            .{ .name = "ipc", .module = ipc_mod },
        },
    });
    const mcp_tests = b.addTest(.{
        .root_module = mcp_test_mod,
    });

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&b.addRunArtifact(protocol_tests).step);
    test_step.dependOn(&b.addRunArtifact(hub_tests).step);
    test_step.dependOn(&b.addRunArtifact(daemon_tests).step);
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);
    test_step.dependOn(&b.addRunArtifact(ipc_tests).step);
    test_step.dependOn(&b.addRunArtifact(run_tests).step);
    test_step.dependOn(&b.addRunArtifact(mcp_tests).step);
}
