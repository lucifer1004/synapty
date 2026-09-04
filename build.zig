const std = @import("std");

/// All shared modules for a given target/optimize combination.
const ModuleSet = struct {
    /// Scoped loggers + the severity policy every call site follows.
    diag: *std.Build.Module,
    protocol: *std.Build.Module,
    ipc: *std.Build.Module,
    run: *std.Build.Module,
    /// The pty holder ([[RFC-0014]]).
    holder: *std.Build.Module,
    mcp: *std.Build.Module,
    /// Process-wide Io instance (Zig 0.16).
    io: *std.Build.Module,
    /// POSIX socket/fd bindings (replaces removed std.net).
    sys: *std.Build.Module,
    /// GitHub REST bridge (RFC-0003).
    github: *std.Build.Module,
    /// Task-tool execution — holds the credential, so it runs at the
    /// WORKBENCH, never in the hub ([[ADR-0008]] decision 6).
    tools: *std.Build.Module,
    /// Shared newline-framed socket reader (WI-2026-08-08-035).
    framing: *std.Build.Module,
    /// Config paths classified by lifetime (WI-2026-08-13-003).
    paths: *std.Build.Module,
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
    // The terminal emulator the workbench renders with, as a library on
    // the far side ([[ADR-0012]]). SIMD OFF FOR RISC-V: the vendored
    // vector library's RVV intrinsics do not compile for that target, and
    // it is the only one of the five where they do not.
    const vt_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .simd = target.result.cpu.arch != .riscv64,
    });
    const vt_lib = vt_dep.artifact("ghostty-vt-static");
    const io = b.createModule(.{
        .root_source_file = b.path("src/io.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Zero dependencies on purpose: every other module imports it, so a
    // dependency here would be a cycle waiting to happen.
    const diag = b.createModule(.{
        .root_source_file = b.path("src/diag.zig"),
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
    const framing = b.createModule(.{
        .root_source_file = b.path("src/framing.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "io", .module = io },
            .{ .name = "sys", .module = sys },
            .{ .name = "diag", .module = diag },
        },
    });
    const paths = b.createModule(.{
        .root_source_file = b.path("src/paths.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "io", .module = io },
            .{ .name = "sys", .module = sys },
            .{ .name = "diag", .module = diag },
        },
    });
    const github = b.createModule(.{
        .root_source_file = b.path("src/github.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "io", .module = io },
            .{ .name = "paths", .module = paths },
            .{ .name = "sys", .module = sys },
            .{ .name = "diag", .module = diag },
        },
    });
    const tools = b.createModule(.{
        .root_source_file = b.path("src/tools.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "github", .module = github },
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
            .{ .name = "diag", .module = diag },
            .{ .name = "framing", .module = framing },
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
            .{ .name = "diag", .module = diag },
            .{ .name = "framing", .module = framing },
        },
    });
    const holder = b.createModule(.{
        .root_source_file = b.path("src/holder.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sys", .module = sys },
            .{ .name = "io", .module = io },
            .{ .name = "diag", .module = diag },
            // A session's record lives with this machine's other state
            // rather than in /tmp ([[Record]]).
            .{ .name = "paths", .module = paths },
        },
    });
    holder.linkLibrary(vt_lib);
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
            .{ .name = "diag", .module = diag },
            .{ .name = "framing", .module = framing },
        },
    });
    return .{ .diag = diag, .protocol = protocol, .ipc = ipc, .run = run, .holder = holder, .mcp = mcp, .io = io, .sys = sys, .github = github, .tools = tools, .framing = framing, .paths = paths };
}

/// WHICH FILES MAKE UP THE SKILLS, read from the directory that holds
/// them rather than listed a second time beside it.
///
/// `commands.zig` carried a hand-written array of five `@embedFile`s. A
/// file added to `src/skills/` and not to that array is simply not
/// installed — and a `SKILL.md` that links it sends the reader to a page
/// that was never written out ([[WI-2026-08-30-006]]). Walking the
/// directory here makes the tree the only declaration.
///
/// SORTED, so the generated source depends on what the tree contains and
/// not on the order the filesystem happened to hand it back.
fn skillManifestModule(b: *std.Build) *std.Build.Module {
    const io = b.graph.io;
    var subpaths: std.ArrayList([]const u8) = .empty;
    var dir = b.build_root.handle.openDir(io, "src/skills", .{ .iterate = true }) catch
        @panic("src/skills is missing");
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("cannot walk src/skills");
    defer walker.deinit();
    while (walker.next(io) catch @panic("cannot walk src/skills")) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.basename, ".")) continue;
        subpaths.append(b.allocator, b.dupe(entry.path)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, subpaths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.lessThan);

    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(b.allocator, "pub const subpaths = [_][]const u8{\n") catch @panic("OOM");
    for (subpaths.items) |sp| {
        const line = std.fmt.allocPrint(b.allocator, "    \"{s}\",\n", .{sp}) catch @panic("OOM");
        src.appendSlice(b.allocator, line) catch @panic("OOM");
    }
    src.appendSlice(b.allocator, "};\n") catch @panic("OOM");

    const written = b.addWriteFiles().add("skill_manifest.zig", src.items);
    return b.createModule(.{ .root_source_file = written });
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
    // Hub module. ADR-0008: the GUI is always a hub CLIENT, never an
    // embedder — the static library and its C ABI are gone. build-id
    // survives because the hub publishes it in the adoption handshake,
    // which is what makes silent version skew impossible.
    // ---------------------------------------------------------------------------

    const build_id = b.option(
        []const u8,
        "build-id",
        "Build identifier reported by the hub handshake and discovery file (default: a hash of src/**.zig)",
    ) orelse sourceBuildId(b);
    const hub_opts = b.addOptions();
    hub_opts.addOption([]const u8, "build_id", build_id);

    const hub_mod = b.createModule(.{
        .root_source_file = b.path("src/hub.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "protocol", .module = mods.protocol },
            .{ .name = "io", .module = mods.io },
            .{ .name = "sys", .module = mods.sys },
            .{ .name = "diag", .module = mods.diag },
            .{ .name = "paths", .module = mods.paths },
            // NO DIRECT `github` HERE ([[ADR-0008]] decision 6): an
            // `@import("github")` in any hub file is a build error, which
            // is what a test reading the source for that string used to
            // stand in for. THE GUARANTEE THAT HOLDS IS THAT ONE — no hub
            // file calls the Keychain — and not the stronger "the hub
            // binary contains no Keychain code": `tools` carries the
            // credential-tool predicate table the hub needs and imports
            // github for its own credential paths, so the module reaches
            // the hub transitively. Saying more than that here, and
            // re-adding `github` to the deploy and test hubs, is what the
            // audit found ([[WI-2026-09-02-017]]).
            .{ .name = "tools", .module = mods.tools },
            .{ .name = "framing", .module = mods.framing },
            .{ .name = "build_options", .module = hub_opts.createModule() },
        },
    });

    // ---------------------------------------------------------------------------
    // synapty CLI — single unified binary [[ADR-0004]]
    // ---------------------------------------------------------------------------

    const clap_dep = b.dependency("clap", .{});
    const clap_mod = clap_dep.module("clap");

    const skill_manifest = skillManifestModule(b);
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "protocol", .module = mods.protocol },
            .{ .name = "ipc", .module = mods.ipc },
            .{ .name = "run", .module = mods.run },
            .{ .name = "holder", .module = mods.holder },
            .{ .name = "mcp", .module = mods.mcp },
            .{ .name = "skill_manifest", .module = skill_manifest },
            .{ .name = "hub", .module = hub_mod },
            .{ .name = "clap", .module = clap_mod },
            .{ .name = "io", .module = mods.io },
            .{ .name = "sys", .module = mods.sys },
            .{ .name = "diag", .module = mods.diag },
            .{ .name = "paths", .module = mods.paths },
            .{ .name = "github", .module = mods.github },
            .{ .name = "tools", .module = mods.tools },
            .{ .name = "framing", .module = mods.framing },
        },
    });
    const cli_exe = b.addExecutable(.{
        .name = "synapty",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);


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
                .{ .name = "diag", .module = deploy_mods.diag },
                .{ .name = "paths", .module = deploy_mods.paths },
                // Same import set as the native hub: no direct github.
                .{ .name = "tools", .module = deploy_mods.tools },
                .{ .name = "framing", .module = deploy_mods.framing },
                .{ .name = "build_options", .module = hub_opts.createModule() },
            },
        });
        const deploy_cli_mod = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = deploy_target,
            .optimize = deploy_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "protocol", .module = deploy_mods.protocol },
                .{ .name = "ipc", .module = deploy_mods.ipc },
                .{ .name = "run", .module = deploy_mods.run },
                .{ .name = "holder", .module = deploy_mods.holder },
                .{ .name = "mcp", .module = deploy_mods.mcp },
                .{ .name = "skill_manifest", .module = skill_manifest },
                .{ .name = "hub", .module = deploy_hub_mod },
                .{ .name = "clap", .module = clap_mod },
                .{ .name = "framing", .module = deploy_mods.framing },
                .{ .name = "io", .module = deploy_mods.io },
                .{ .name = "sys", .module = deploy_mods.sys },
                .{ .name = "diag", .module = deploy_mods.diag },
                .{ .name = "paths", .module = deploy_mods.paths },
                .{ .name = "github", .module = deploy_mods.github },
                .{ .name = "tools", .module = deploy_mods.tools },
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

    // THE TEST STEP MUST BUILD THE BINARY IT CLAIMS TO BE TESTING.
    //
    // addTestModule compiles each module on its own, so a compile error
    // reachable only through the EXE's import graph passed `zig build
    // test` cleanly while `zig build` failed. That is the worst shape a
    // verification gap can take: the command everyone runs before
    // committing reports success for a binary that does not exist. Found
    // when a std.c call that does not exist in Zig 0.16 sailed through a
    // green test run.
    test_step.dependOn(&cli_exe.step);

    // protocol: no imports
    addTestModule(b, test_step, "src/protocol.zig", &.{}, target, optimize);
    // sys: no imports of its own.
    addTestModule(b, test_step, "src/sys.zig", &.{}, target, optimize);
    {
        // The holder's tests link the terminal library, like the holder
        // itself: a screen model that only the product has is a screen
        // model nothing checks.
        const holder_test_mod = b.createModule(.{
            .root_source_file = b.path("src/holder.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "sys", .module = mods.sys },
                .{ .name = "io", .module = mods.io },
                .{ .name = "diag", .module = mods.diag },
                .{ .name = "paths", .module = mods.paths },
            },
        });
        const vt_dep = b.dependency("ghostty", .{
            .target = target,
            .optimize = optimize,
            .simd = target.result.cpu.arch != .riscv64,
        });
        holder_test_mod.linkLibrary(vt_dep.artifact("ghostty-vt-static"));
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = holder_test_mod })).step);
    }

    // paths: io + sys + diag
    addTestModule(b, test_step, "src/paths.zig", &.{
        .{ .name = "io", .module = mods.io },
        .{ .name = "sys", .module = mods.sys },
        .{ .name = "diag", .module = mods.diag },
    }, target, optimize);
    // tools: github
    addTestModule(b, test_step, "src/tools.zig", &.{
        .{ .name = "github", .module = mods.github },
    }, target, optimize);
    // github: io + sys + diag + paths
    addTestModule(b, test_step, "src/github.zig", &.{
        .{ .name = "io", .module = mods.io },
        .{ .name = "sys", .module = mods.sys },
        .{ .name = "diag", .module = mods.diag },
        .{ .name = "paths", .module = mods.paths },
    }, target, optimize);

    // framing: io + sys — the line reader every socket goes through
    addTestModule(b, test_step, "src/framing.zig", &.{
        .{ .name = "io", .module = mods.io },
        .{ .name = "sys", .module = mods.sys },
    }, target, optimize);

    // ipc: io + sys + framing
    addTestModule(b, test_step, "src/ipc.zig", &.{
        .{ .name = "io", .module = mods.io },
        .{ .name = "sys", .module = mods.sys },
        .{ .name = "diag", .module = mods.diag },
        .{ .name = "paths", .module = mods.paths },
        .{ .name = "framing", .module = mods.framing },
    }, target, optimize);

    // hub: the same imports the shipped hub has — no direct github, so the
    // test build proves the same thing the exe build does (a missing
    // import once broke this module's compile behind the zig cache —
    // WI-2026-08-08-034; handlers.zig deliberately has no github import).
    addTestModule(b, test_step, "src/hub.zig", &.{
        .{ .name = "protocol", .module = mods.protocol },
        .{ .name = "io", .module = mods.io },
        .{ .name = "sys", .module = mods.sys },
        .{ .name = "diag", .module = mods.diag },
        .{ .name = "paths", .module = mods.paths },
        .{ .name = "tools", .module = mods.tools },
        .{ .name = "framing", .module = mods.framing },
        .{ .name = "build_options", .module = hub_opts.createModule() },
    }, target, optimize);

    // run and mcp: protocol + ipc + io + sys + framing (run.zig reads the
    // hub stream through framing.LineBuffer)
    inline for (.{ "run", "mcp" }) |name| {
        addTestModule(b, test_step, "src/" ++ name ++ ".zig", &.{
            .{ .name = "protocol", .module = mods.protocol },
            .{ .name = "ipc", .module = mods.ipc },
            .{ .name = "io", .module = mods.io },
            .{ .name = "sys", .module = mods.sys },
            .{ .name = "diag", .module = mods.diag },
            .{ .name = "paths", .module = mods.paths },
            .{ .name = "framing", .module = mods.framing },
        }, target, optimize);
    }

    // e2e: protocol + ipc + run + THE hub module the binary ships, not a
    // second copy of it with an extra import ([[WI-2026-09-02-034]]).
    addTestModule(b, test_step, "src/e2e_test.zig", &.{
        .{ .name = "protocol", .module = mods.protocol },
        .{ .name = "ipc", .module = mods.ipc },
        .{ .name = "run", .module = mods.run },
        .{ .name = "hub", .module = hub_mod },
        .{ .name = "io", .module = mods.io },
        .{ .name = "sys", .module = mods.sys },
        .{ .name = "diag", .module = mods.diag },
        .{ .name = "paths", .module = mods.paths },
        .{ .name = "framing", .module = mods.framing },
    }, target, optimize);

    // cli: protocol + ipc + run + mcp + hub + clap
    addTestModule(b, test_step, "src/cli.zig", &.{
        .{ .name = "protocol", .module = mods.protocol },
        .{ .name = "ipc", .module = mods.ipc },
        .{ .name = "run", .module = mods.run },
        // The chooser's row tests reach holder's label bound
        // ([[WI-2026-09-02-013]]); the exe always had this import.
        .{ .name = "holder", .module = mods.holder },
        .{ .name = "mcp", .module = mods.mcp },
        .{ .name = "hub", .module = hub_mod },
        .{ .name = "clap", .module = clap_mod },
        .{ .name = "io", .module = mods.io },
        .{ .name = "sys", .module = mods.sys },
        .{ .name = "diag", .module = mods.diag },
        .{ .name = "paths", .module = mods.paths },
        .{ .name = "github", .module = mods.github },
        .{ .name = "tools", .module = mods.tools },
        .{ .name = "framing", .module = mods.framing },
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

/// Default build identity: a hash of the Zig sources this binary is
/// compiled from ([[WI-2026-08-14-005]]).
///
/// SOURCE CONTENT, NOT A VCS REVISION. Every edit must change the id
/// before it is committed, which a commit hash cannot do. Content also
/// makes the id deterministic and TARGET-INDEPENDENT, so a cross-compiled
/// deploy binary and the local one agree — which is what lets a workbench
/// compare a remote hub against the binary in its own bundle.
///
/// A read failure yields "unknown": refusing to build over an unreadable
/// source directory would be out of proportion, and the comparison this
/// feeds treats an unreadable side as skew rather than as a match.
fn sourceBuildId(b: *std.Build) []const u8 {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, "src", .{ .iterate = true }) catch return "unknown";
    defer dir.close(io);

    // Sorted: the id must depend on the tree's content, not on the order
    // the filesystem hands entries back.
    var paths: std.ArrayList([]const u8) = .empty;
    var walker = dir.walk(b.allocator) catch return "unknown";
    defer walker.deinit();
    while (walker.next(io) catch return "unknown") |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        paths.append(b.allocator, b.dupe(entry.path)) catch return "unknown";
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.lessThan);

    var hasher = std.crypto.hash.Blake3.init(.{});
    for (paths.items) |p| {
        const contents = dir.readFileAlloc(io, p, b.allocator, .limited(8 * 1024 * 1024)) catch return "unknown";
        // Path as well as body: a rename with no edit is a different
        // tree, and hashing bodies alone would call the two equal.
        hasher.update(p);
        hasher.update(contents);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return b.dupe(&std.fmt.bytesToHex(digest[0..6], .lower));
}
