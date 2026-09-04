const std = @import("std");
const io_mod = @import("io");
const mem = std.mem;
const json = std.json;
const protocol = @import("protocol");
const ipc = @import("ipc");
const run = @import("run");
const mcp = @import("mcp");
const Allocator = mem.Allocator;
const log = @import("diag").scoped(.cli);

// ---------------------------------------------------------------------------
// Sub-module re-exports
// ---------------------------------------------------------------------------

const commands = @import("cli/commands.zig");
const transport = @import("cli/transport.zig");
const sys = @import("sys");
const hub = @import("hub");
const federation = hub.federation;

// ---------------------------------------------------------------------------
// Shared types — defined in cli/types.zig, re-exported here for callers
// ---------------------------------------------------------------------------

pub const types = @import("cli/types.zig");
const help = @import("cli/help.zig");
pub const IpcSubcommand = types.IpcSubcommand;
pub const IpcArgs = types.IpcArgs;
pub const Subcommand = types.Subcommand;
pub const RegisterArgs = types.RegisterArgs;
pub const SendArgs = types.SendArgs;
pub const RecvArgs = types.RecvArgs;
pub const RunArgs = types.RunArgs;
pub const HubArgs = types.HubArgs;
pub const ChannelCreateArgs = types.ChannelCreateArgs;
pub const ChannelInviteArgs = types.ChannelInviteArgs;
pub const ChannelLeaveArgs = types.ChannelLeaveArgs;
pub const ParseError = types.ParseError;

// ---------------------------------------------------------------------------
// Arg parsing
// ---------------------------------------------------------------------------

pub const parseArgs = @import("cli/parse.zig").parseArgs;

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Installed here, at the root, so it intercepts EVERY std.log call
/// rather than only the ones routed through diag.scoped — including
/// std's own. log_level is left wide open at comptime because the real
/// filter is diag's RUNTIME one ([[RFC-0012]] C-LEVEL-CONTROL): a
/// comptime cap would make a level change impossible without a rebuild,
/// which is worse than the restart it exists to avoid.
pub const std_options: std.Options = .{
    .logFn = @import("diag").logFn,
    .log_level = .debug,
};

pub fn main(init: std.process.Init) !void {
    io_mod.install(init.io);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Collect args, skipping argv[0] (program name).
    var arg_list = std.ArrayList([]const u8).empty;
    defer arg_list.deinit(allocator);
    const argv = try init.minimal.args.toSlice(allocator);
    for (argv[1..]) |arg| {
        try arg_list.append(allocator, arg);
    }

    // Classify-by-lifetime migration (WI-2026-08-13-003). Idempotent and
    // cheap; runs before anything can read a config path so a first launch
    // after the upgrade finds its files where the new layout expects them.
    @import("paths").migrate();

    const sub = parseArgs(allocator, arg_list.items) catch |err| {
        switch (err) {
            ParseError.HelpRequested => {
                // WHICH SUBCOMMAND ASKED. The error cannot carry it, and
                // does not have to: the name is the first argument.
                if (arg_list.items.len > 0 and types.isSubcommand(arg_list.items[0])) {
                    try help.printSubcommand(arg_list.items[0]);
                } else {
                    try help.printOverview(true);
                }
                std.process.exit(0);
            },
            ParseError.MissingSubcommand => {
                try help.printOverview(true);
            },
            ParseError.UnknownSubcommand => try usageLine(arg_list.items,
                "unknown subcommand or flag"),
            ParseError.MissingArgument => try usageLine(arg_list.items,
                "a required argument is missing, or a flag was given no value"),
            ParseError.TooManyArguments => try usageLine(arg_list.items, "too many arguments"),
        }
        // ONE CODE FOR A USAGE ERROR ([[WI-2026-09-02-021]]): 2 — what
        // `wait` already promised (RFC-0004 C-WAIT: 0/3/4 are outcomes, 1
        // is transport) and what the in-command usage errors (a missing
        // --cmd, the attach chooser without a tty) exit. Parse-time errors
        // exited 1, so one mistake had two codes depending on which layer
        // caught it.
        std.process.exit(2);
    };

    switch (sub) {
        .ipc => |ipc_sub| switch (ipc_sub.action) {
            .register => try commands.runRegister(allocator, ipc_sub.args.register),
            .notify => try commands.runNotify(allocator, ipc_sub.args.notify),
            .send => try commands.runSend(allocator, ipc_sub.args.send),
            .recv => try commands.runRecv(allocator, ipc_sub.args.recv),
            .agents => try commands.runAgents(allocator),
            .channel_create, .channel_invite, .channel_leave, .channel_list => try commands.runChannel(allocator, ipc_sub.action, ipc_sub.args),
        },
        .run => |a| {
            // A REFUSED START LEAVES NOTHING BEHIND ([[RFC-0014]]
            // C-START). The name has to be judged before the hub is
            // touched: a start that registers and then discovers it is a
            // duplicate has already put two connections on one agent id,
            // and the second one's exit tears down the first one's
            // registration.
            if (a.hold and commands.holdRefused(a.agent_id)) {
                try io_mod.stderrWriteAll("synapty run --hold: session already held: ");
                try io_mod.stderrWriteAll(a.agent_id);
                try io_mod.stderrWriteAll("\n");
                std.process.exit(3);
            }
            // BEFORE ANYTHING IS OPENED, and this is where "before" has
            // to be. The wrapper's hub connection and pane socket are
            // built by the init below; forking after them gives the
            // grandchild copies of descriptors the returning parent then
            // tears down in its own deinit — the socket unlinked, the hub
            // connection shut, and a holder left joining threads that
            // will never finish.
            if (a.hold and a.detach) {
                switch (sys.daemonize()) {
                    .in_daemon => {},
                    .launched => {
                        if (commands.waitUntilHeld(a.agent_id, 5000)) return;
                        try io_mod.stderrWriteAll("synapty run --hold --detach: the session did not come up\n");
                        std.process.exit(1);
                    },
                    .failed => {
                        try io_mod.stderrWriteAll("synapty run --hold --detach: could not fork the background process\n");
                        std.process.exit(1);
                    },
                }
            }
            var server = run.RunServer.init(allocator, a.agent_id, a.hub_addr, a.hub_port) catch |err| {
                try io_mod.stderrWriteAll("synapty run: init failed: ");
                try io_mod.stderrWriteAll(@errorName(err));
                var diag_buf: [128]u8 = undefined;
                const diag = std.fmt.bufPrint(&diag_buf, " (hub {s}:{d})\n", .{ a.hub_addr, a.hub_port }) catch "\n";
                try io_mod.stderrWriteAll(diag);
                std.process.exit(1);
            };
            defer server.deinit();
            server.parent_pid = a.parent_pid;
            if (a.hold) {
                commands.runHold(allocator, &server, a) catch |err| {
                    try io_mod.stderrWriteAll("synapty run --hold: failed: ");
                    try io_mod.stderrWriteAll(@errorName(err));
                    try io_mod.stderrWriteAll("\n");
                    std.process.exit(1);
                };
                return;
            }
            server.run(a.child_argv) catch |err| {
                try io_mod.stderrWriteAll("synapty run: failed: ");
                try io_mod.stderrWriteAll(@errorName(err));
                try io_mod.stderrWriteAll("\n");
                std.process.exit(1);
            };
        },
        .attach => |a| try commands.runAttach(allocator, a),
        .attach_choose => try commands.runAttachChooser(allocator),
        .sessions => |a| if (a.agent_id) |id|
            try commands.runSessionOne(id)
        else
            try commands.runSessions(allocator),
        .end => |a| try commands.runEnd(allocator, a),
        .name => |a| try commands.runName(a),
        .hub => |h| {
            // Set BEFORE anything can mint: a scratch hub that writes the
            // real identity file renames the machine, and peers key their
            // directory entries and spooled mail on that name.
            if (h.identity_path) |ip| hub.identity_store.path_override = ip;
            if (h.log) return try hubLog(h);
            if (h.remint) return try hubRemint(h);
            if (h.ensure) return try hubEnsure(h);
            try hubServe(h);
        },
        .version => {
            // The build id ALONE on stdout — the workbench reads this
            // directly, and anything else would have to be parsed off.
            try io_mod.stdoutWriteAll(hub.handlers.build_id);
            try io_mod.stdoutWriteAll("\n");
        },
        .mcp_serve => {
            try mcp.runMcp(allocator);
        },
        .github => |g| switch (g.action) {
            .login => try commands.runGithubLogin(allocator, g),
            .logout => try commands.runGithubLogout(allocator),
            .status => try commands.runGithubStatus(allocator),
        },
        .skills => |sk| switch (sk.action) {
            .install => try commands.runSkillsInstall(allocator),
        },
        .activity => {
            try commands.runActivity(allocator);
        },
        .wait => |a| try commands.runWait(allocator, a),
        .hooks => |a| try commands.runHooks(allocator, a),
        .hook_event => |a| try commands.runHookEvent(allocator, a),
        .exec => |a| try commands.runExec(allocator, a),
        .file => |a| try commands.runFile(allocator, a),
        .view => |a| try commands.runView(allocator, a),
        .ask => |a| try commands.runAsk(allocator, a),
        .identify => try commands.runIdentify(allocator),
        .exposed => |a| try commands.runExposed(allocator, a),
        .tools_exec => |a| try commands.runToolsExec(allocator, a),
        .task => |t| switch (t) {
            .list => |a| try commands.runTaskList(allocator, a),
            .show => |a| try commands.runTaskShow(allocator, a),
            .claim => |a| try commands.runTaskClaim(allocator, a),
            .update => |a| try commands.runTaskUpdate(allocator, a),
            .comment => |a| try commands.runTaskComment(allocator, a),
            .create => |a| try commands.runTaskCreate(allocator, a),
        },
    }
}

// ---------------------------------------------------------------------------
// `synapty hub` — four distinct jobs, separated because they have nothing
// in common past the flag that selects them: --log prints this machine's
// hub log, --remint writes an identity file and exits, --ensure guarantees
// a hub exists somewhere and reports where, and the fourth actually
// becomes one. Together they read past the other three.
// ---------------------------------------------------------------------------

/// `--log`: print this machine's hub log ([[RFC-0012]] C-DESTINATIONS).
///
/// The way a REMOTE hub's log is read is by running this over the SSH the
/// operator already has. A file on another machine is what SSH is for,
/// and carrying log lines over the A2A protocol would give that protocol
/// a reader it should not have — and would blur RFC-0009's rule that
/// event logs are per-machine and peer events are never replayed.
fn hubLog(h: anytype) !void {
    const io = io_mod.get();
    var pbuf: [1024]u8 = undefined;
    const path = @import("paths").hub_log.path(&pbuf) orelse {
        try io_mod.stderrWriteAll("synapty hub --log: cannot resolve the log path\n");
        std.process.exit(1);
    };

    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
        // Not an error: a hub that has only ever run under a workbench
        // writes to the pipe the workbench reads, not to this file. Say
        // which case this is rather than printing nothing.
        var buf: [1200]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            "no hub log at {s}\nA hub started BY the workbench logs to the workbench, and on macOS every hub also logs to the system log:\n  log show --last 10m --info --predicate 'process == \"synapty\"'\n",
            .{path}) catch return;
        try io_mod.stderrWriteAll(msg);
        std.process.exit(1);
    };
    defer f.close(io);

    var offset: u64 = 0;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = f.readPositionalAll(io, &buf, offset) catch 0;
        if (n > 0) {
            try io_mod.stdoutWriteAll(buf[0..n]);
            offset += n;
        }
        if (!h.follow) break;
        if (n == 0) io.sleep(std.Io.Duration.fromMilliseconds(500), .awake) catch break;
    }
}

/// `--remint`: mint a NEW peer id for this machine ([[RFC-0010]]
/// C-COLLISION). An act on the machine that OWNS the name.
fn hubRemint(h: anytype) !void {
    var buf: [128]u8 = undefined;
    const id = hub.identity_store.remint(&buf, h.peer_id) orelse {
        try io_mod.stderrWriteAll("synapty hub --remint: could not persist a new identity\n");
        std.process.exit(1);
    };
    // Serialized, not interpolated: an id is operator-chosen, and one with
    // a quote in it must not be a broken frame ([[WI-2026-09-02-021]]).
    const line = std.json.Stringify.valueAlloc(std.heap.page_allocator, .{ .peer_id = id }, .{}) catch return;
    defer std.heap.page_allocator.free(line);
    try io_mod.stdoutWriteAll(line);
    try io_mod.stdoutWriteAll("\n");
    try io_mod.stderrWriteAll(
        "note: restart this machine's hub for the new id to take effect; peers will drop entries keyed on the old one\n",
    );
    return;
}

/// `--ensure`: guarantee this machine has a hub and print where it is.
/// Does NOT become one ([[ADR-0008]] stage 3b).
fn hubEnsure(h: anytype) !void {
    if (h.discovery_path) |dp| hub.service.discovery_path_override = dp;
    var exe_buf: [4096]u8 = undefined;
    const exe = sys.selfExePath(&exe_buf) orelse {
        try io_mod.stderrWriteAll("synapty hub --ensure: cannot resolve own path\n");
        std.process.exit(1);
    };
    var exe_z_buf: [4097]u8 = undefined;
    const exe_z = std.fmt.bufPrintZ(&exe_z_buf, "{s}", .{exe}) catch {
        try io_mod.stderrWriteAll("synapty hub --ensure: path too long\n");
        std.process.exit(1);
    };
    // Pass the discovery path through: the spawned hub has to
    // publish where this process is looking, or ensure never
    // sees it and spawns another on the next call.
    var dp_buf: [4097]u8 = undefined;
    var pid_buf: [128]u8 = undefined;
    var id_buf2: [4097]u8 = undefined;
    var extra_buf: [6]?[*:0]const u8 = undefined;
    var extra_len: usize = 0;
    if (h.peer_id) |pid| {
        const pid_z = std.fmt.bufPrintZ(&pid_buf, "{s}", .{pid}) catch {
            try io_mod.stderrWriteAll("synapty hub --ensure: peer id too long\n");
            std.process.exit(1);
        };
        extra_buf[extra_len] = "--peer-id";
        extra_buf[extra_len + 1] = pid_z.ptr;
        extra_len += 2;
    }
    if (h.identity_path) |ip| {
        const ip_z = std.fmt.bufPrintZ(&id_buf2, "{s}", .{ip}) catch {
            try io_mod.stderrWriteAll("synapty hub --ensure: identity path too long\n");
            std.process.exit(1);
        };
        extra_buf[extra_len] = "--identity-path";
        extra_buf[extra_len + 1] = ip_z.ptr;
        extra_len += 2;
    }
    if (h.discovery_path) |dp| {
        const dp_z = std.fmt.bufPrintZ(&dp_buf, "{s}", .{dp}) catch {
            try io_mod.stderrWriteAll("synapty hub --ensure: discovery path too long\n");
            std.process.exit(1);
        };
        extra_buf[extra_len] = "--discovery-path";
        extra_buf[extra_len + 1] = dp_z.ptr;
        extra_len += 2;
    }
    const result = hub.service.ensureRunning(exe_z.ptr, extra_buf[0..extra_len], 5000) orelse {
        try io_mod.stderrWriteAll("synapty hub --ensure: no hub could be started on this machine\n");
        std.process.exit(1);
    };
    // NO RENAME ADVICE. A running hub's id is authoritative and
    // a suggestion does not override it; the previous version
    // told the operator to restart the hub to adopt the
    // supplied name, which severs the link of any OTHER
    // workbench using that hub. Provisioning learns the name
    // here, it does not impose one ([[RFC-0010]]).
    const running_id = result.peer_id_buf[0..result.peer_id_len];
    const line = std.json.Stringify.valueAlloc(std.heap.page_allocator, .{
        .port = result.port,
        .pid = result.pid,
        .started = result.started,
        .peer_id = running_id,
    }, .{}) catch return;
    defer std.heap.page_allocator.free(line);
    try io_mod.stdoutWriteAll(line);
    try io_mod.stdoutWriteAll("\n");
    return;
}

/// Become this machine's hub.
fn hubServe(h: anytype) !void {
    // Loopback only: zero-auth on a reachable interface would
    // allow impersonation and agent kicking (WI-2026-08-08-029).
    // Under [[ADR-0008]] this is also sufficient by design —
    // agents connect to the hub on THEIR OWN machine, and
    // cross-machine traffic rides authenticated peer links, so
    // nothing legitimate needs a non-loopback bind.
    const svc = hub.service;
    const handlers = hub.handlers;

    // SYNAPTY_HUB_PORT is the single manual override, and it is
    // strict: an explicit request must never be silently
    // redirected to another port by the ladder.
    var port = h.port;
    var strict = h.strict_port;
    if (sys.getenv("SYNAPTY_HUB_PORT")) |raw| {
        if (std.fmt.parseInt(u16, raw, 10) catch null) |p| {
            if (p > 0) {
                port = p;
                strict = true;
            }
        }
    }

    var hub_server = try svc.bindWithLadder(.{
        .port = port,
        .strict = strict,
        .parent_pid = h.parent_pid,
        .grace_secs = h.grace_secs,
    });
    defer hub_server.deinit();

    if (h.discovery_path) |dp| svc.discovery_path_override = dp;
    handlers.bound_port = hub_server.bound_port;
    handlers.workbench_spawned = h.parent_pid != null;
    svc.writeDiscovery(hub_server.bound_port, handlers.build_id);
    defer svc.removeDiscovery();

    // Durable state ([[ADR-0008]] stage 2): restore queued mail
    // and durable identities before serving, so an agent that
    // returns after a restart still finds its messages.
    if (h.state_path) |sp| {
        var sbuf: [1024]u8 = undefined;
        const path = if (std.mem.eql(u8, sp, "default"))
            (hub.state_store.statePath(&sbuf) orelse sp)
        else
            sp;
        _ = hub_server.state.restoreFromDisk(path);
    }

    // [[RFC-0009]]: a hub needs a name before any peer can
    // introduce itself to it. A service hub has no human present
    // to supply one, so it adopts its own hostname — the machine
    // is the authority on what it is called, and the alternative
    // (letting the dialing side name it) would let two peers
    // disagree about who is who.
    // The workbench-supplied label wins. It is the only id that
    // can be kept unique across the fleet — the machine's own
    // hostname cannot be, and two cloud VMs called "ubuntu" would
    // otherwise collide and refuse to peer.
    // --peer-id is a SUGGESTION used only at mint time. A machine
    // that already has an identity keeps it, because other
    // machines key directory entries and spooled mail on it
    // ([[RFC-0010]] C-PEER-IDENTITY: provisioning may suggest,
    // never override).
    hub_server.state.adoptMintedPeerId(h.peer_id);

    // Supervised mode: a workbench owns us. Parent death starts a
    // bounded grace window rather than an immediate exit, so a
    // relaunching workbench can reclaim this hub — and if none
    // does, the window is what makes an orphan impossible.
    var supervision = svc.Supervision{};
    hub_server.state.supervision = &supervision;
    if (h.parent_pid) |ppid| {
        _ = std.Thread.spawn(.{}, svc.watchParent, .{ &supervision, ppid, h.grace_secs }) catch |err| {
            // A hub that cannot supervise itself must not run
            // pretending it is supervised.
            try io_mod.stderrWriteAll("synapty hub: cannot start parent watchdog: ");
            try io_mod.stderrWriteAll(@errorName(err));
            try io_mod.stderrWriteAll("\n");
            std.process.exit(1);
        };
    }
    // Federation state expires on a clock ([[RFC-0009]] C-DIRECTORY
    // tombstone retention, C-DELIVERY spool TTL), so something has
    // to hold that clock. Leaving the sweep unwired did not merely
    // leak: tombstones never expired, so one peer drop made
    // `unknown` unreachable as a delivery answer for the rest of
    // this hub's life.
    _ = std.Thread.spawn(.{}, hub.HubState.sweepLoop, .{&hub_server.state}) catch |err| {
        log.err("hub: federation sweep not started: {any} — tombstones will never expire, and delivery permanently loses its `unknown` answer", .{err});
    };
    try hub_server.run();
}

test "parseArgs: missing subcommand returns error" {
    const result = parseArgs(std.testing.allocator, &.{});
    try std.testing.expectError(ParseError.MissingSubcommand, result);
}

test "parseArgs: unknown subcommand returns error" {
    const result = parseArgs(std.testing.allocator, &.{"bogus"});
    try std.testing.expectError(ParseError.UnknownSubcommand, result);
}

test "parseArgs: register subcommand" {
    const result = try parseArgs(std.testing.allocator, &.{ "register", "--tool", "codex", "--project", "/path" });
    try std.testing.expectEqualStrings("codex", result.ipc.args.register.tool);
    try std.testing.expectEqualStrings("/path", result.ipc.args.register.project.?);
    try std.testing.expectEqual(protocol.IpcAction.register, result.ipc.action);
}

test "parseArgs: register missing --tool returns error" {
    const result = parseArgs(std.testing.allocator, &.{"register"});
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: send subcommand" {
    const result = try parseArgs(std.testing.allocator, &.{ "send", "agent-b", "hello world" });
    try std.testing.expectEqualStrings("agent-b", result.ipc.args.send.target);
    try std.testing.expectEqualStrings("hello world", result.ipc.args.send.text);
    try std.testing.expectEqual(protocol.IpcAction.send, result.ipc.action);
}

test "parseArgs: channel create subcommand" {
    const result = try parseArgs(std.testing.allocator, &.{ "channel", "create", "design-review", "--description", "Auth redesign" });
    try std.testing.expectEqualStrings("design-review", result.ipc.args.channel_create.name);
    try std.testing.expectEqualStrings("Auth redesign", result.ipc.args.channel_create.description.?);
    try std.testing.expectEqual(protocol.IpcAction.channel_create, result.ipc.action);
}

test "parseArgs: channel invite subcommand" {
    const result = try parseArgs(std.testing.allocator, &.{ "channel", "invite", "design-review", "agent-b" });
    try std.testing.expectEqualStrings("design-review", result.ipc.args.channel_invite.channel);
    try std.testing.expectEqualStrings("agent-b", result.ipc.args.channel_invite.agent_id);
    try std.testing.expectEqual(protocol.IpcAction.channel_invite, result.ipc.action);
}

test "parseArgs: channel list subcommand" {
    const result = try parseArgs(std.testing.allocator, &.{ "channel", "list" });
    try std.testing.expectEqual(protocol.IpcAction.channel_list, result.ipc.action);
    try std.testing.expect(result.ipc.args == .channel_list);
}

test "parseArgs: send missing payload returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "send", "agent-b" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: recv without --wait" {
    const result = try parseArgs(std.testing.allocator, &.{"recv"});
    try std.testing.expect(!result.ipc.args.recv.wait);
}

test "parseArgs: recv with --wait" {
    const result = try parseArgs(std.testing.allocator, &.{ "recv", "--wait" });
    try std.testing.expect(result.ipc.args.recv.wait);
}

test "parseArgs: agents subcommand" {
    const result = try parseArgs(std.testing.allocator, &.{"agents"});
    try std.testing.expectEqual(protocol.IpcAction.agents, result.ipc.action);
}

test "register envelope has correct fields for agent-id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const env = try protocol.makeRegisterEnvelope(arena, "test-agent", &.{});
    try std.testing.expectEqualStrings("register", env.type);
    try std.testing.expectEqualStrings("test-agent", env.source);
    try std.testing.expectEqualStrings("", env.target);
}


test "parseArgs: run subcommand with --id and -- child" {
    const result = try parseArgs(std.testing.allocator, &.{ "run", "--id", "my-agent", "--", "bash", "-l" });
    try std.testing.expectEqualStrings("my-agent", result.run.agent_id);
    try std.testing.expectEqual(@as(usize, 2), result.run.child_argv.len);
    try std.testing.expectEqualStrings("bash", result.run.child_argv[0]);
    try std.testing.expectEqualStrings("-l", result.run.child_argv[1]);
}

test "parseArgs: mcp-serve subcommand" {
    const result = try parseArgs(std.testing.allocator, &.{"mcp-serve"});
    try std.testing.expect(result == .mcp_serve);
}

test "parseArgs: run without --id returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "run", "--", "bash" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: run with --id but without -- returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "run", "--id", "foo" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: run with --id and -- but no child command returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "run", "--id", "foo", "--" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

// ---------------------------------------------------------------------------
// Strengthened coverage for zig-clap migration [[WI-2026-03-30-001]]
// ---------------------------------------------------------------------------

test "parseArgs: register with --session flag" {
    const result = try parseArgs(std.testing.allocator, &.{ "register", "--tool", "claude", "--session", "s1" });
    try std.testing.expectEqualStrings("claude", result.ipc.args.register.tool);
    try std.testing.expectEqualStrings("s1", result.ipc.args.register.session.?);
    try std.testing.expect(result.ipc.args.register.project == null);
}

test "parseArgs: register with all three flags" {
    const result = try parseArgs(std.testing.allocator, &.{ "register", "--tool", "codex", "--project", "/p", "--session", "s2" });
    try std.testing.expectEqualStrings("codex", result.ipc.args.register.tool);
    try std.testing.expectEqualStrings("/p", result.ipc.args.register.project.?);
    try std.testing.expectEqualStrings("s2", result.ipc.args.register.session.?);
}

test "parseArgs: register --tool without value returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "register", "--tool" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: channel leave subcommand" {
    const result = try parseArgs(std.testing.allocator, &.{ "channel", "leave", "design-review" });
    try std.testing.expectEqualStrings("design-review", result.ipc.args.channel_leave.channel);
    try std.testing.expectEqual(protocol.IpcAction.channel_leave, result.ipc.action);
}

test "parseArgs: channel create without --description" {
    const result = try parseArgs(std.testing.allocator, &.{ "channel", "create", "general" });
    try std.testing.expectEqualStrings("general", result.ipc.args.channel_create.name);
    try std.testing.expect(result.ipc.args.channel_create.description == null);
}

test "parseArgs: channel unknown sub-action returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "channel", "bogus" });
    try std.testing.expectError(ParseError.UnknownSubcommand, result);
}

test "parseArgs: channel missing sub-action returns error" {
    const result = parseArgs(std.testing.allocator, &.{"channel"});
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: channel create missing name returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "channel", "create" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: channel invite missing agent returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "channel", "invite", "ch1" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: channel leave missing channel returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "channel", "leave" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: run with multi-word child command" {
    const result = try parseArgs(std.testing.allocator, &.{ "run", "--id", "a1", "--", "python", "-c", "print('hi')" });
    try std.testing.expectEqualStrings("a1", result.run.agent_id);
    try std.testing.expectEqual(@as(usize, 3), result.run.child_argv.len);
    try std.testing.expectEqualStrings("python", result.run.child_argv[0]);
    try std.testing.expectEqualStrings("print('hi')", result.run.child_argv[2]);
}


// ---------------------------------------------------------------------------
// --help tests [[WI-2026-03-30-001]]
// ---------------------------------------------------------------------------

test "parseArgs: register --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "register", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: send --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "send", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: recv --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "recv", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: run --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "run", "--help", "--", "bash" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: channel create --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "channel", "create", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: channel invite --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "channel", "invite", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: channel leave --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "channel", "leave", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: channel list --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "channel", "list", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: agents --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "agents", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: mcp-serve --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "mcp-serve", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: run --help without -- returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "run", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: top-level --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{"--help"});
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: register --project without value returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "register", "--tool", "x", "--project" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: register --session without value returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "register", "--tool", "x", "--session" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

// ---------------------------------------------------------------------------
// hub subcommand + run --hub tests [[ADR-0004]]
// ---------------------------------------------------------------------------

test "parseArgs: hub subcommand defaults" {
    const result = try parseArgs(std.testing.allocator, &.{"hub"});
    try std.testing.expectEqual(@as(u16, 9000), result.hub.port);
}

test "parseArgs: hub --port custom" {
    const result = try parseArgs(std.testing.allocator, &.{ "hub", "--port", "8080" });
    try std.testing.expectEqual(@as(u16, 8080), result.hub.port);
}

test "parseArgs: hub --help returns HelpRequested" {
    const result = parseArgs(std.testing.allocator, &.{ "hub", "--help" });
    try std.testing.expectError(ParseError.HelpRequested, result);
}

test "parseArgs: run with --hub flag" {
    const result = try parseArgs(std.testing.allocator, &.{ "run", "--id", "a1", "--hub", "10.0.0.1:8080", "--", "bash" });
    try std.testing.expectEqualStrings("a1", result.run.agent_id);
    try std.testing.expectEqualStrings("10.0.0.1", result.run.hub_addr);
    try std.testing.expectEqual(@as(u16, 8080), result.run.hub_port);
    try std.testing.expectEqualStrings("bash", result.run.child_argv[0]);
}

test "parseArgs: run without --hub resolves the machine's hub, defaulting to 9000" {
    // A manually launched wrapper SHOULD find this machine's hub through
    // the discovery file ([[ADR-0008]]: agents connect to their own
    // machine). The lookup must therefore be isolated — asserting 9000
    // without isolating it makes the result depend on whether a hub
    // happens to be running.
    transport.discovery_path_override = "/nonexistent/synapty-test-no-hub.json";
    defer transport.discovery_path_override = null;
    const result = try parseArgs(std.testing.allocator, &.{ "run", "--id", "a1", "--", "bash" });
    try std.testing.expectEqualStrings("127.0.0.1", result.run.hub_addr);
    try std.testing.expectEqual(@as(u16, 9000), result.run.hub_port);
}

test "parseArgs: run --hub invalid format returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "run", "--id", "a1", "--hub", "noport", "--", "bash" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

test "parseArgs: run --hub empty host returns error" {
    const result = parseArgs(std.testing.allocator, &.{ "run", "--id", "a1", "--hub", ":9000", "--", "bash" });
    try std.testing.expectError(ParseError.MissingArgument, result);
}

// Pull in tests from sub-modules.
comptime {
    _ = @import("cli/commands.zig");
    _ = @import("cli/transport.zig");
}

test "parseArgs: github logout and status subcommands (WI-2026-08-08-043)" {
    const logout = try parseArgs(std.testing.allocator, &.{ "github", "logout" });
    try std.testing.expectEqual(types.GithubArgs.Action.logout, logout.github.action);
    const status = try parseArgs(std.testing.allocator, &.{ "github", "status" });
    try std.testing.expectEqual(types.GithubArgs.Action.status, status.github.action);
    const login = try parseArgs(std.testing.allocator, &.{ "github", "login", "--owner", "o", "--repo", "r" });
    try std.testing.expectEqual(types.GithubArgs.Action.login, login.github.action);
    try std.testing.expectEqualStrings("o", login.github.owner.?);
    try std.testing.expectEqualStrings("r", login.github.repo.?);
}

// ---------------------------------------------------------------------------
// wait subcommand — RFC-0004 C-WAIT
// ---------------------------------------------------------------------------

const wait_mod = @import("cli/wait.zig");
const sys_test = @import("sys");

test "parseArgs: wait subcommand with and without timeout" {
    const r1 = try parseArgs(std.testing.allocator, &.{ "wait", "--agent", "local-3f2a", "--until", "done" });
    try std.testing.expectEqualStrings("local-3f2a", r1.wait.agent);
    try std.testing.expectEqualStrings("done", r1.wait.until);
    try std.testing.expect(r1.wait.timeout_secs == null);

    const r2 = try parseArgs(std.testing.allocator, &.{ "wait", "--agent", "a", "--until", "waiting", "--timeout", "30" });
    try std.testing.expectEqual(@as(?u32, 30), r2.wait.timeout_secs);
}

test "parseArgs: wait rejects invalid or missing --until (unknown is not waitable)" {
    try std.testing.expectError(ParseError.MissingArgument, parseArgs(std.testing.allocator, &.{ "wait", "--agent", "a", "--until", "unknown" }));
    try std.testing.expectError(ParseError.MissingArgument, parseArgs(std.testing.allocator, &.{ "wait", "--agent", "a", "--until", "blocked" }));
    try std.testing.expectError(ParseError.MissingArgument, parseArgs(std.testing.allocator, &.{ "wait", "--agent", "a" }));
    try std.testing.expectError(ParseError.MissingArgument, parseArgs(std.testing.allocator, &.{ "wait", "--until", "done" }));
}

/// Connect a test client to a hub on 127.0.0.1:<port>.
fn waitTestConnect(port: u16) !sys_test.fd_t {
    const fd = try sys_test.socket(sys_test.AF.INET, sys_test.SOCK.STREAM, 0);
    errdefer sys_test.close(fd);
    const addr4 = try std.Io.net.Ip4Address.parse("127.0.0.1", port);
    const sa = sys_test.sockaddr_in.init(@bitCast(addr4.bytes), port);
    try sys_test.connect(fd, &sa, @sizeOf(sys_test.sockaddr_in));
    return fd;
}

/// Register an agent and drive it to `state`, confirming the hub applied
/// the signal (reads the agent_status response before returning).
fn waitTestAgent(port: u16, id: []const u8, state: []const u8) !sys_test.fd_t {
    const fd = try waitTestConnect(port);
    errdefer sys_test.close(fd);
    var buf: [1024]u8 = undefined;
    var msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"register\",\"id\":\"r1\",\"source\":\"{s}\",\"target\":\"\"}}\n", .{id});
    try sys_test.writeAll(fd, msg);
    msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"agent_status\",\"id\":\"n1\",\"source\":\"{s}\",\"target\":\"\",\"payload\":{{\"state\":\"{s}\"}}}}\n", .{ id, state });
    try sys_test.writeAll(fd, msg);
    // Read the agent_status response line — the hub has now applied it.
    try sys_test.setRecvTimeout(fd, 5000);
    var got: usize = 0;
    var resp: [4096]u8 = undefined;
    while (std.mem.indexOfScalar(u8, resp[0..got], '\n') == null) {
        const n = try sys_test.read(fd, resp[got..]);
        if (n == 0) return error.EndOfStream;
        got += n;
    }
    return fd;
}

test "wait: satisfied at start pins the generation (RFC-0004 C-WAIT)" {
    var server = try hub.HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();
    try server.startBackground();

    const ag_fd = try waitTestAgent(server.bound_port, "agent-ws", "working");
    defer sys_test.close(ag_fd);

    const fd = try waitTestConnect(server.bound_port);
    defer sys_test.close(fd);
    const r = try wait_mod.waitOnHub(std.testing.allocator, fd, "agent-ws", .working, 5000);
    try std.testing.expectEqual(wait_mod.Outcome.satisfied, r.outcome);
    try std.testing.expectEqual(protocol.Status.working, r.status);
    try std.testing.expect(r.generation != 0);
}

test "wait: not registered at start exits the 2 path" {
    var server = try hub.HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();
    try server.startBackground();

    const fd = try waitTestConnect(server.bound_port);
    defer sys_test.close(fd);
    const r = try wait_mod.waitOnHub(std.testing.allocator, fd, "ghost", .done, 2000);
    try std.testing.expectEqual(wait_mod.Outcome.not_registered, r.outcome);
}

fn waitTestNoopRelease(_: *anyopaque, _: *hub.Connection) void {}

test "wait: a target this hub cannot resolve fails at the start, saying which case (C-WAIT)" {
    // The three refusals are the three the presence row distinguishes;
    // the reasoning is on the check itself in wait.zig.
    var server = try hub.HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();
    try server.state.setPeerId("laptop-0001");
    try server.startBackground();

    var dummy: u8 = 0;
    const pfd = try sys_test.socket(sys_test.AF.INET, sys_test.SOCK.STREAM, 0);
    var pconn = hub.Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), waitTestNoopRelease);
    defer pconn.deinit();
    const p2fd = try sys_test.socket(sys_test.AF.INET, sys_test.SOCK.STREAM, 0);
    var p2conn = hub.Connection.init(std.testing.allocator, p2fd, @ptrCast(&dummy), waitTestNoopRelease);
    defer p2conn.deinit();

    // 1. THE HOSTING PEER'S LINK IS DOWN. The entry is tombstoned, not
    //    discarded, so the identity is still listed — and still unwaitable.
    try server.state.peerLinkUp("gone-0001", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    _ = try server.state.directoryAdvertise("gone-0001", "claude-away0001");
    server.state.peerLinkDown("gone-0001");

    // 2. TWO PEERS CLAIM IT, so it is addressed by nobody.
    try server.state.peerLinkUp("twinA-0001", &pconn, 9201, federation.protocol_max, federation.CapabilitySet.local());
    try server.state.peerLinkUp("twinB-0001", &p2conn, 9202, federation.protocol_max, federation.CapabilitySet.local());
    defer server.state.peerLinkDown("twinA-0001");
    defer server.state.peerLinkDown("twinB-0001");
    _ = try server.state.directoryAdvertise("twinA-0001", "claude-both00001");
    _ = try server.state.directoryAdvertise("twinB-0001", "claude-both00001");

    // 3. THE LINK IS UP AND THAT PEER NEVER DECLARED presence_relay, so no
    //    presence event for that identity will ever arrive. A link being
    //    up is not evidence that events will come; the capability is.
    try server.state.peerLinkUp("mute-0001", &p2conn, 9203, federation.protocol_max, .{});
    defer server.state.peerLinkDown("mute-0001");
    _ = try server.state.directoryAdvertise("mute-0001", "claude-mute00001");

    const cases = [_]struct { id: []const u8, cause: protocol.UnknownCause }{
        .{ .id = "claude-away0001", .cause = .peer_unreachable },
        .{ .id = "claude-both00001", .cause = .contested },
        .{ .id = "claude-mute00001", .cause = .peer_lacks_capability },
    };
    for (cases) |c| {
        const fd = try waitTestConnect(server.bound_port);
        defer sys_test.close(fd);
        // A generous timeout: if the qualifier is absent this blocks the
        // whole of it and returns `timeout`, which is the defect.
        const r = try wait_mod.waitOnHub(std.testing.allocator, fd, c.id, .done, 3000);
        try std.testing.expectEqual(wait_mod.Outcome.unresolved, r.outcome);
        try std.testing.expectEqual(c.cause, r.cause.?);
    }
}

test "wait: a remote agent reaching the state SATISFIES the wait (C-WAIT)" {
    // A remote identity's state arrives as `peer_presence_relayed`, not
    // as the local pair of events; the loop in wait.zig says why.
    var server = try hub.HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();
    try server.state.setPeerId("laptop-0001");
    try server.startBackground();

    var dummy: u8 = 0;
    const pfd = try sys_test.socket(sys_test.AF.INET, sys_test.SOCK.STREAM, 0);
    var pconn = hub.Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), waitTestNoopRelease);
    defer pconn.deinit();
    try server.state.peerLinkUp("live-0001", &pconn, 9210, federation.protocol_max, federation.CapabilitySet.local());
    defer server.state.peerLinkDown("live-0001");
    _ = try server.state.directoryAdvertise("live-0001", "claude-remote01");

    const fd = try waitTestConnect(server.bound_port);
    defer sys_test.close(fd);

    // The peer relays the conclusion while the wait is in flight.
    const t = try std.Thread.spawn(.{}, struct {
        fn run(st: *hub.HubState) void {
            io_mod.get().sleep(
                std.Io.Duration.fromMilliseconds(120), .awake) catch {};
            st.relayPresence("live-0001", "claude-remote01", .done);
        }
    }.run, .{&server.state});
    defer t.join();

    const r = try wait_mod.waitOnHub(std.testing.allocator, fd, "claude-remote01", .done, 5000);
    try std.testing.expectEqual(wait_mod.Outcome.satisfied, r.outcome);
    try std.testing.expectEqual(protocol.Status.done, r.status);
}

test "wait: a remote identity leaving the directory ends the wait rather than hanging it" {
    // `directory_identity_removed` is the remote form of "it went away
    // while you waited". Ignored, the wait ran to its timeout and exit 3
    // said the agent was slow when it was gone.
    var server = try hub.HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();
    try server.state.setPeerId("laptop-0001");
    try server.startBackground();

    var dummy: u8 = 0;
    const pfd = try sys_test.socket(sys_test.AF.INET, sys_test.SOCK.STREAM, 0);
    var pconn = hub.Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), waitTestNoopRelease);
    defer pconn.deinit();
    try server.state.peerLinkUp("live-0001", &pconn, 9211, federation.protocol_max, federation.CapabilitySet.local());
    defer server.state.peerLinkDown("live-0001");
    _ = try server.state.directoryAdvertise("live-0001", "claude-remote01");

    const fd = try waitTestConnect(server.bound_port);
    defer sys_test.close(fd);

    const t = try std.Thread.spawn(.{}, struct {
        fn run(st: *hub.HubState) void {
            io_mod.get().sleep(
                std.Io.Duration.fromMilliseconds(120), .awake) catch {};
            _ = st.directoryWithdraw("live-0001", "claude-remote01");
        }
    }.run, .{&server.state});
    defer t.join();

    const r = try wait_mod.waitOnHub(std.testing.allocator, fd, "claude-remote01", .done, 5000);
    try std.testing.expectEqual(wait_mod.Outcome.generation_ended, r.outcome);
}

test "wait: a peer that can relay but has not spoken yet is WAITED ON, not refused" {
    // `no_evidence` is not one of the three refusals (wait.zig says why);
    // a qualifier that refused it would pass every test above and break
    // every remote wait.
    var server = try hub.HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();
    try server.state.setPeerId("laptop-0001");
    try server.startBackground();

    var dummy: u8 = 0;
    const pfd = try sys_test.socket(sys_test.AF.INET, sys_test.SOCK.STREAM, 0);
    var pconn = hub.Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), waitTestNoopRelease);
    defer pconn.deinit();
    try server.state.peerLinkUp("live-0001", &pconn, 9204, federation.protocol_max, federation.CapabilitySet.local());
    defer server.state.peerLinkDown("live-0001");
    _ = try server.state.directoryAdvertise("live-0001", "claude-quiet0001");

    const fd = try waitTestConnect(server.bound_port);
    defer sys_test.close(fd);
    const r = try wait_mod.waitOnHub(std.testing.allocator, fd, "claude-quiet0001", .done, 300);
    try std.testing.expectEqual(wait_mod.Outcome.timeout, r.outcome);
}

test "wait: timeout while the agent never reaches the state" {
    var server = try hub.HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();
    try server.startBackground();

    const ag_fd = try waitTestAgent(server.bound_port, "agent-wt", "working");
    defer sys_test.close(ag_fd);

    const fd = try waitTestConnect(server.bound_port);
    defer sys_test.close(fd);
    const r = try wait_mod.waitOnHub(std.testing.allocator, fd, "agent-wt", .done, 300);
    try std.testing.expectEqual(wait_mod.Outcome.timeout, r.outcome);
}

const WaitThreadCtx = struct {
    port: u16,
    result: wait_mod.WaitResult = .{ .outcome = .protocol_error },
    err: bool = false,

    fn waitForDone(self: *WaitThreadCtx, target: []const u8) void {
        const fd = waitTestConnect(self.port) catch {
            self.err = true;
            return;
        };
        defer sys_test.close(fd);
        self.result = wait_mod.waitOnHub(std.heap.page_allocator, fd, target, .done, 5000) catch {
            self.err = true;
            return;
        };
    }
};

/// Block until the hub has `n` attached event subscribers (bounded).
fn waitForSubscribers(server: *hub.HubServer, n: usize) !void {
    var tries: usize = 0;
    while (tries < 2500) : (tries += 1) {
        server.state.presence_mutex.lock(io_mod.get()) catch unreachable;
        const count = server.state.event_log.subscribers.items.len;
        server.state.presence_mutex.unlock(io_mod.get());
        if (count >= n) return;
        io_mod.get().sleep(std.Io.Duration.fromMilliseconds(2), .awake) catch {};
    }
    return error.SubscriberNeverAttached;
}

test "wait: satisfied by a pushed status event" {
    var server = try hub.HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();
    try server.startBackground();

    const ag_fd = try waitTestAgent(server.bound_port, "agent-we", "working");
    defer sys_test.close(ag_fd);

    var ctx = WaitThreadCtx{ .port = server.bound_port };
    const t = try std.Thread.spawn(.{}, WaitThreadCtx.waitForDone, .{ &ctx, "agent-we" });
    // Ensure the waiter's subscription is attached BEFORE the transition,
    // so this test exercises the pushed-event path (not the snapshot).
    try waitForSubscribers(&server, 1);

    try sys_test.writeAll(ag_fd, "{\"type\":\"agent_status\",\"id\":\"n2\",\"source\":\"agent-we\",\"target\":\"\",\"payload\":{\"state\":\"done\"}}\n");
    t.join();
    try std.testing.expect(!ctx.err);
    try std.testing.expectEqual(wait_mod.Outcome.satisfied, ctx.result.outcome);
    try std.testing.expectEqual(protocol.Status.done, ctx.result.status);
}

test "wait: generation ending fails the wait (pinned identity)" {
    var server = try hub.HubServer.initWithAddress("127.0.0.1", 0);
    defer server.deinit();
    try server.startBackground();

    const ag_fd = try waitTestAgent(server.bound_port, "agent-wg", "working");

    var ctx = WaitThreadCtx{ .port = server.bound_port };
    const t = try std.Thread.spawn(.{}, WaitThreadCtx.waitForDone, .{ &ctx, "agent-wg" });
    try waitForSubscribers(&server, 1);

    // The agent goes away: reader teardown ends the generation and emits
    // agent_unregistered — the wait must FAIL, not hang or be satisfied
    // by a later same-name newcomer.
    sys_test.close(ag_fd);
    t.join();
    try std.testing.expect(!ctx.err);
    try std.testing.expectEqual(wait_mod.Outcome.generation_ended, ctx.result.outcome);
}

test "parseArgs: hooks install with --yes" {
    const sub = try parseArgs(std.testing.allocator, &.{ "hooks", "install", "claude", "--yes" });
    try std.testing.expectEqual(types.HooksArgs.Action.install, sub.hooks.action);
    try std.testing.expectEqualStrings("claude", sub.hooks.tool);
    try std.testing.expect(sub.hooks.yes);
}

test "parseArgs: hooks status without tool is an error" {
    try std.testing.expectError(
        ParseError.MissingArgument,
        parseArgs(std.testing.allocator, &.{ "hooks", "status" }),
    );
}

test {
    // Force test collection for lazily-analyzed submodules (hooks.zig
    // is only reached through commands.zig's runtime path).
    std.testing.refAllDecls(@import("cli/hooks.zig"));
    std.testing.refAllDecls(@import("cli/transport.zig"));
    std.testing.refAllDecls(@import("cli/progress.zig"));
}

test "ADR-0008: `synapty tools exec` parses the workbench-side executor form" {
    // The workbench-side executor, not `synapty task` — parseTools's doc
    // says why the two must stay apart.
    const r = try parseArgs(std.testing.allocator, &.{
        "tools", "exec", "--tool", "task.claim", "--args", "{\"number\":7}",
    });
    try std.testing.expectEqualStrings("task.claim", r.tools_exec.tool);
    try std.testing.expectEqualStrings("{\"number\":7}", r.tools_exec.args_json);

    // args defaults to an empty object rather than being required.
    const bare = try parseArgs(std.testing.allocator, &.{ "tools", "exec", "--tool", "task.list" });
    try std.testing.expectEqualStrings("{}", bare.tools_exec.args_json);

    // --tool is mandatory: executing "some tool" is not a thing.
    try std.testing.expectError(ParseError.MissingArgument, parseArgs(std.testing.allocator, &.{ "tools", "exec" }));
    try std.testing.expectError(ParseError.UnknownSubcommand, parseArgs(std.testing.allocator, &.{ "tools", "nope" }));
}

test "RFC-0010: `hub --remint` parses and --peer-id is a suggestion, not a rename" {
    const r = try parseArgs(std.testing.allocator, &.{ "hub", "--remint" });
    try std.testing.expect(r.hub.remint);
    // A label may accompany a re-mint, but on its own it must NOT imply
    // one: `--peer-id` on a machine that already has an identity is a
    // suggestion that gets ignored, and if it silently re-minted instead
    // it would strand every peer keying state on the old id.
    const s = try parseArgs(std.testing.allocator, &.{ "hub", "--peer-id", "deskmac" });
    try std.testing.expect(!s.hub.remint);
    try std.testing.expectEqualStrings("deskmac", s.hub.peer_id.?);
}

test "RFC-0010: --identity-path isolates a scratch hub from the machine's real name" {
    // Learned by doing the damage: a `--peer-id` experiment on a scratch
    // hub minted into the REAL identity file and relabelled this laptop
    // after a remote host. `--discovery-path` exists for exactly this
    // hazard and identity has it worse — a discovery file is a pointer,
    // a machine name is what every peer keys its directory and spool on.
    const r = try parseArgs(std.testing.allocator, &.{
        "hub", "--identity-path", "/tmp/scratch-id.json", "--peer-id", "probe",
    });
    try std.testing.expectEqualStrings("/tmp/scratch-id.json", r.hub.identity_path.?);
    try std.testing.expectEqualStrings("probe", r.hub.peer_id.?);
}

/// `error: <subcommand>: <what>; try 'synapty <subcommand> --help'` —
/// the mistake named where it was made ([[WI-2026-09-02-021]]). "error:
/// missing required argument" with no subcommand sent an agent looking
/// for the wrong problem.
fn usageLine(argv: []const []const u8, what: []const u8) !void {
    try io_mod.stderrWriteAll("error: ");
    if (argv.len > 0) {
        try io_mod.stderrWriteAll(argv[0]);
        try io_mod.stderrWriteAll(": ");
    }
    try io_mod.stderrWriteAll(what);
    try io_mod.stderrWriteAll("; try 'synapty ");
    if (argv.len > 0) {
        try io_mod.stderrWriteAll(argv[0]);
        try io_mod.stderrWriteAll(" ");
    }
    try io_mod.stderrWriteAll("--help'\n");
}
