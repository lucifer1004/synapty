const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared protocol module
    const protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- synapty-hub executable ---
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

    // --- synapty-daemon executable ---
    const daemon_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
        },
    });
    const daemon_exe = b.addExecutable(.{
        .name = "synapty-daemon",
        .root_module = daemon_mod,
    });
    b.installArtifact(daemon_exe);

    const daemon_step = b.step("daemon", "Build the Synapty Daemon (remote companion)");
    daemon_step.dependOn(&daemon_exe.step);

    // --- synapty CLI executable ---
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
        },
    });
    const cli_exe = b.addExecutable(.{
        .name = "synapty",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);

    const cli_step = b.step("cli", "Build the Synapty CLI tool");
    cli_step.dependOn(&cli_exe.step);

    // --- Tests ---
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
        },
    });
    const cli_tests = b.addTest(.{
        .root_module = cli_test_mod,
    });

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&b.addRunArtifact(protocol_tests).step);
    test_step.dependOn(&b.addRunArtifact(hub_tests).step);
    test_step.dependOn(&b.addRunArtifact(daemon_tests).step);
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);
}
