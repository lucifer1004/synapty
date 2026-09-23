//! ONE PANE'S CONNECTION TO A HOST, from this side ([[ADR-0020]]).
//!
//! WHAT THIS TOOK OVER AND WHY. `connect.sh` did all of this: assembling
//! ssh's flags, turning the workbench's forwarding rules into `-L`/`-R`,
//! probing for a ControlMaster, choosing whether a durable client goes in
//! front, writing the pool's socket and pid records, and reading what the
//! transport exited with. None of it runs on the far side, and all of it
//! ran in a language chosen for gluing two processes together — with a
//! `perl` call for a millisecond, a `printf` of a format three other
//! writers share, and a test seam that reached its subject by `sed`-ing
//! line ranges out of the file.
//!
//! WHAT STAYED SHELL. The string that runs on the FAR side arrives here as
//! `--remote` and is passed through untouched. It executes before that
//! machine's synapty binary has been located — it is the bootstrap that
//! locates it — so there is nothing else there to run it.
//!
//! TWO MODES, BECAUSE THERE ARE TWO EVENTS. The DIAL happens once: probe
//! the master, say what is happening, and hand over. The TRANSPORT is one
//! ssh, and on a durable host the client in front re-runs it after every
//! drop — which is why the connection it rides must be re-read on each
//! attempt rather than baked into an argv ([[WI-2026-09-02-030]]).

const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys");
const io_mod = @import("io");
const types = @import("types.zig");
const progress_mod = @import("progress.zig");

/// Robustness ([[WI-2026-03-31-003]]): fail fast on unreachable hosts,
/// accept a new host key rather than hanging on a prompt no pane can
/// answer, and notice a silently dropped link so the pane never freezes
/// on a dead one.
///
/// SPLIT BECAUSE THE TWO CALLERS DIFFER BY EXACTLY ONE OPTION, and that
/// was worth checking rather than assuming: the host setup's flags never
/// carried `ExitOnForwardFailure`, and giving it one would turn a
/// forwarding it could not make into a refusal to connect at all.
pub const base_robustness = [_][]const u8{
    "-o", "ConnectTimeout=10",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=3",
};

/// AND ONE MORE WHERE A FORWARDING IS THE POINT. A transport that came up
/// without the port it was asked to carry is a pane that looks connected
/// and is not.
pub const robustness = base_robustness ++ [_][]const u8{
    "-o", "ExitOnForwardFailure=yes",
};

/// A forwarding rule, as the workbench names it: `local:8080:127.0.0.1:80`.
///
/// ONE ARGUMENT RATHER THAN FOUR POSITIONALS. The script took these as a
/// variadic run of quads on the end of its argument list, which is why
/// everything else there had to ride in the environment — there was no
/// room after them for anything else.
pub const Forward = struct {
    flag: []const u8,
    spec: []const u8,

    /// A PORT, NOT MERELY A FIELD THAT WAS FILLED IN. `8080:h:abc` used to
    /// reach ssh, where `ExitOnForwardFailure=yes` turned it into a pane
    /// that would not open and a message about the syntax of a flag the
    /// human never typed. Zero is refused too: `-R 0:` asks ssh to choose,
    /// and nothing here can find out what it chose ([[WI-2026-09-10-002]]).
    fn portNumber(text: []const u8) ?u16 {
        const n = std.fmt.parseInt(u16, text, 10) catch return null;
        return if (n == 0) null else n;
    }

    /// THE SAME BRACKETS SSH ITSELF DOCUMENTS. `host` sits between two
    /// colons in a format whose separator is a colon, so an IPv6 literal
    /// is ambiguous in exactly the way it is ambiguous to ssh -L — and it
    /// is spelled out of that ambiguity the same way, rather than by
    /// inventing a second convention for the same string.
    pub fn parse(buf: []u8, text: []const u8) ?Forward {
        const k_end = std.mem.indexOfScalar(u8, text, ':') orelse return null;
        const flag = if (std.mem.eql(u8, text[0..k_end], "local"))
            "-L"
        else if (std.mem.eql(u8, text[0..k_end], "remote"))
            "-R"
        else
            return null;
        const after_kind = text[k_end + 1 ..];
        const l_end = std.mem.indexOfScalar(u8, after_kind, ':') orelse return null;
        const listen = after_kind[0..l_end];
        const target = after_kind[l_end + 1 ..];

        var host: []const u8 = undefined;
        var port: []const u8 = undefined;
        var bracketed = false;
        if (target.len > 0 and target[0] == '[') {
            const close = std.mem.indexOfScalar(u8, target, ']') orelse return null;
            host = target[1..close];
            if (host.len == 0) return null;
            if (close + 1 >= target.len or target[close + 1] != ':') return null;
            port = target[close + 2 ..];
            bracketed = true;
        } else {
            const h_end = std.mem.indexOfScalar(u8, target, ':') orelse return null;
            host = target[0..h_end];
            port = target[h_end + 1 ..];
            // An unbracketed literal splits in the wrong place rather than
            // not at all, so the leftover colon is what catches it.
            if (std.mem.indexOfScalar(u8, port, ':') != null) return null;
        }
        if (portNumber(listen) == null) return null;
        if (portNumber(port) == null) return null;

        // THE DOCUMENTED DEFAULT, MADE TRUE. `PortForward.targetHost` says
        // "empty = localhost" and its editor is a free TextField, so an
        // empty target is a shape the workbench can and does produce.
        const target_host = if (host.len == 0) "localhost" else host;
        const spec = if (bracketed)
            std.fmt.bufPrint(buf, "{s}:[{s}]:{s}", .{ listen, target_host, port }) catch return null
        else
            std.fmt.bufPrint(buf, "{s}:{s}:{s}", .{ listen, target_host, port }) catch return null;
        return .{ .flag = flag, .spec = spec };
    }

    /// BOTH CALLERS ANSWER A BAD RULE THE SAME WAY. `host-master` exited 2
    /// and said which rule; `connect` did `orelse continue` and dialled a
    /// pane whose forwarding was simply absent — the same input, opposite
    /// outcomes, and the silent one on the path the human watches. The
    /// direct dial already carries `ExitOnForwardFailure=yes`, which is
    /// this project having decided that a forward asked for and not got is
    /// a failed connection rather than a degraded one; a rule that never
    /// reached ssh is that, earlier.
    pub fn parseOrExit(buf: []u8, text: []const u8, who: []const u8) Forward {
        return parse(buf, text) orelse {
            io_mod.stderrWriteAll(who) catch {};
            io_mod.stderrWriteAll(": not a forwarding: ") catch {};
            io_mod.stderrWriteAll(text) catch {};
            io_mod.stderrWriteAll("\n") catch {};
            std.process.exit(2);
        };
    }
};

/// WHICH SSH THIS IS. A master that is already up carries the forwardings
/// already, so a second ssh through it must not re-add them; one that has
/// to open its own connection carries them itself.
pub const Shape = union(enum) {
    master: []const u8,
    direct: []const []const u8,
};

pub const Invocation = struct {
    tty: []const u8,
    shape: Shape,
    port: u16,
    key: []const u8,
    jump: []const u8,
    dest: []const u8,
    remote: []const u8,
};

/// The ssh command line for one attempt.
///
/// IN THE ORDER THE SCRIPT EMITTED IT, so a human comparing the two reads
/// one list rather than two. ssh does not care; a reviewer does.
pub fn sshArgv(alloc: Allocator, inv: Invocation) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, "ssh");
    try out.append(alloc, inv.tty);
    switch (inv.shape) {
        .master => |socket| {
            try out.append(alloc, "-S");
            try out.append(alloc, socket);
        },
        .direct => |specs| {
            for (specs) |text| {
                var buf: [256]u8 = undefined;
                const f = Forward.parseOrExit(&buf, text, "synapty connect");
                try out.append(alloc, f.flag);
                try out.append(alloc, try alloc.dupe(u8, f.spec));
            }
        },
    }
    if (inv.jump.len > 0) {
        try out.append(alloc, "-J");
        try out.append(alloc, inv.jump);
    }
    if (inv.key.len > 0) {
        try out.append(alloc, "-i");
        try out.append(alloc, inv.key);
    }
    try out.append(alloc, "-p");
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{d}", .{inv.port}));
    for (robustness) |f| try out.append(alloc, f);
    try out.append(alloc, inv.dest);
    // ONE ARGUMENT, WHOLE. This is a shell script for the far side; split
    // by anything on this side it arrives as several commands.
    try out.append(alloc, inv.remote);
    return out.toOwnedSlice(alloc);
}

/// POSIX SINGLE-QUOTING, for a value that reaches another shell as data.
///
/// THE ONE QUOTING FUNCTION ON THIS PATH, and having one is half the
/// reason the assembling moved here at all ([[ADR-0020]]). `printf %q` is
/// not an option: it is a bashism that emits `$'\''…'\''` for anything
/// unusual, and the far side may be a plain POSIX sh that takes it
/// literally — which is why the script did this with `sed` too.
pub fn shellQuote(out: *std.ArrayList(u8), alloc: Allocator, text: []const u8) !void {
    try out.append(alloc, '\'');
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '\'')) |at| {
        try out.appendSlice(alloc, rest[0..at]);
        // Close the quote, an escaped one, open again. The only way to
        // put a single quote inside single quotes.
        try out.appendSlice(alloc, "'\\''");
        rest = rest[at + 1 ..];
    }
    try out.appendSlice(alloc, rest);
    try out.append(alloc, '\'');
}

/// IF THE FAR SIDE CANNOT RESOLVE THE TERM ssh FORWARDED, fall back to one
/// every ncurses install has. Without a resolvable entry, shells (zsh with
/// powerlevel10k and friends) mis-encode backspace and delete — the classic
/// "backspace prints a space" bug (ghostty#5818). The ACTUAL `$TERM` is
/// probed rather than a name being assumed.
pub const preamble =
    \\case "$TERM" in "") TERM=xterm-256color ;; *) infocmp -x "$TERM" >/dev/null 2>&1 || export TERM=xterm-256color ;; esac;
;

/// WHERE THE FAR SIDE'S BINARY IS, AND WHAT HUB IT TALKS TO.
///
/// [[ADR-0008]] stage 3b: the agent connects to the hub on ITS OWN host
/// over loopback, not back through a reverse tunnel to the laptop's hub.
/// That is what lets a remote agent keep working — and keep receiving mail
/// from its neighbours on the same box — while the laptop is asleep or
/// gone; cross-machine traffic rides an authenticated peer link between
/// the two hubs instead ([[RFC-0009]]).
///
/// `hub --ensure` is idempotent by probing before it spawns, so running it
/// on every connect is how a server reboot self-heals without anyone
/// ssh-ing in. The port comes from ITS output rather than being assumed,
/// because the ladder may have moved the hub off 9000.
///
/// SAID AS IT HAPPENS, not summarised afterwards, and said on the FAR side
/// so the words travel as the transport's stderr — which the client reads
/// into the connection's account rather than letting it reach the pane
/// ([[WI-2026-08-17-016]]).
pub const ensure =
    \\SYNAPTY_REMOTE_BIN="$PWD/.synapty/bin/synapty"
    \\printf "synapty: ensuring a hub on this host\\n" >&2
    \\SYNAPTY_HUB_JSON="$(.synapty/bin/synapty hub --ensure 2>/dev/null || true)"
    \\SYNAPTY_REMOTE_PORT="$(printf %s "$SYNAPTY_HUB_JSON" | sed -n "s/.*\"port\":\\([0-9][0-9]*\\).*/\\1/p")"
    \\if [ -z "$SYNAPTY_REMOTE_PORT" ]; then
    \\  echo "synapty: no hub could be started on this host — A2A is unavailable for this agent" >&2
    \\  SYNAPTY_REMOTE_PORT=9000
    \\fi
;

/// THE SCRIPT THAT RUNS ON THE FAR SIDE, built here and quoted once.
///
/// EVERY `$` IN IT IS THE OTHER SHELL'S. The hub port is not known on this
/// machine and `$SHELL` is the far side's preference rather than ours, so
/// they are left to be expanded over there. Zig's multiline literals take
/// no escapes at all, which is why this reads as the shell it is — the
/// version in `connect.sh` had to escape every one of them twice, once for
/// the assigning shell and once for the receiving one.
pub fn remoteLaunch(alloc: Allocator, o: struct {
    agent_id: []const u8,
    fresh_id: []const u8,
    cwd: []const u8,
    durable: bool,
}) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(alloc);
    try b.appendSlice(alloc, preamble);
    try b.append(alloc, ' ');
    try b.appendSlice(alloc, ensure);
    try b.append(alloc, '\n');

    // WHERE A DUPLICATED PANE OPENS ([[RFC-0015]] C-LAYOUT). Splitting is
    // copying the pane, and a copy of a shell that is not standing where
    // the original stands is a different pane wearing its name.
    //
    // AFTER THE BINARY IS RESOLVED, NEVER BEFORE. Everything below
    // addresses `.synapty/bin/synapty` relative to the login directory, so
    // a cd that ran first would leave the launch unable to find the thing
    // it launches. `|| true`: a directory that is gone since it was read
    // is a reason to open at home, not a reason to fail to open.
    if (o.cwd.len > 0) {
        try b.appendSlice(alloc, "cd ");
        try shellQuote(&b, alloc, o.cwd);
        try b.appendSlice(alloc, " 2>/dev/null || true\n");
    }

    // NOTHING IS PROBED. Durability used to depend on what the host
    // happened to have installed; it depends on the binary this project
    // already requires, so there is no capability to detect and no
    // degraded path to explain ([[ADR-0012]]).
    if (!o.durable) {
        try b.appendSlice(alloc, "exec \"${SYNAPTY_REMOTE_BIN}\" run --id ");
        try b.appendSlice(alloc, o.agent_id);
        try b.appendSlice(alloc, " --hub 127.0.0.1:${SYNAPTY_REMOTE_PORT} -- ${SHELL:-/bin/sh} -l");
        return b.toOwnedSlice(alloc);
    }

    // START, THEN ATTACH, AS TWO REQUESTS ([[RFC-0014]] C-START). A start
    // against a name already held fails and says so, which is exactly the
    // reattach path: the failure is expected and the attach that follows
    // is what joins the running session.
    //
    // ONE FAILURE IS EXPECTED AND THE REST ARE NOT ([[WI-2026-08-17-015]]).
    // Exit 3 is the held name and only that is a reattach; exit 1 is a
    // session that did not come up, or an init naming a hub it could not
    // reach. Reported as a reattach those produce a pane that says the
    // session is fine, then that there is no such session, then dies —
    // with the one process that knew why having written it to /dev/null.
    // So the start's own words are kept and said.
    //
    // A RECORDED AGENT ID IS A RECORD AND NOT A GRANT ([[RFC-0015]]
    // C-PERSIST): it may return a pane to a child that SURVIVED, and must
    // not be conferred on one newly started — the name routes A2A mail, so
    // a fresh child wearing it receives what was addressed to the one it
    // replaced. Asked BEFORE anything is started, because starting under
    // it and reading the code afterwards is too late: by then the child
    // has the name.
    //
    // TWO NAMES ARE SENT AND THE FAR SIDE PICKS. The workbench cannot ask
    // first — the answer is over there and restore must not block on a
    // connection ([[RFC-0015]] C-UNARCHIVE) — so it hands over the one to
    // RETURN to and the one to START under. It does not need to be told
    // which was used: only one of them can exist, and the registration
    // says which one did.
    try b.appendSlice(alloc, "if \"${SYNAPTY_REMOTE_BIN}\" sessions --id ");
    try b.appendSlice(alloc, o.agent_id);
    try b.appendSlice(alloc,
        \\ >/dev/null 2>&1; then
        \\  SYNAPTY_SESSION_ID=
    );
    try b.appendSlice(alloc, o.agent_id);
    try b.appendSlice(alloc,
        \\
        \\  printf 'synapty: returning to the session already running here\n' >&2
        \\else
        \\  SYNAPTY_SESSION_ID=
    );
    try b.appendSlice(alloc, o.fresh_id);
    try b.appendSlice(alloc,
        \\
        \\  SYNAPTY_START_ERR="$("${SYNAPTY_REMOTE_BIN}" run --hold --detach --id ${SYNAPTY_SESSION_ID} --hub 127.0.0.1:${SYNAPTY_REMOTE_PORT} -- ${SHELL:-/bin/sh} -l 2>&1 >/dev/null)"
        \\  SYNAPTY_START_CODE=$?
        \\  case ${SYNAPTY_START_CODE} in
        \\    0) printf 'synapty: started a session on this host\n' >&2 ;;
        \\    *) printf 'synapty: could not start a session on this host (exit %s): %s\n' "${SYNAPTY_START_CODE}" "${SYNAPTY_START_ERR}" >&2 ;;
        \\  esac
        \\fi
        \\exec "${SYNAPTY_REMOTE_BIN}" attach --relay --id ${SYNAPTY_SESSION_ID}
    );
    return b.toOwnedSlice(alloc);
}

/// Whether this host keeps a session between connections ([[RFC-0014]]
/// C-OPT-OUT). The workbench says so in the environment, as it always did.
fn durable() bool {
    const v = sys.getenv("SYNAPTY_DURABLE") orelse return true;
    return !std.mem.eql(u8, v, "0");
}

/// A word for whoever is listening: the account when the workbench named
/// one, and the human's own terminal when nobody did.
fn say(account: *const progress_mod.Progress, text: []const u8) void {
    if (account.on()) {
        account.say(.note, text);
    } else {
        io_mod.stderrWriteAll("synapty: ") catch {};
        io_mod.stderrWriteAll(text) catch {};
        io_mod.stderrWriteAll("\n") catch {};
    }
}

/// WHICH CONNECTION THIS PANE RIDES ([[RFC-0013]] C-BROKER). A host holds
/// as many as its load has called for, and the workbench has the
/// measurements that say which is quiet; falling back to the first one is
/// right for a host that holds nothing yet.
fn socketPath(buf: []u8, a: types.ConnectArgs) ?[]const u8 {
    if (sys.getenv("SYNAPTY_SOCKET")) |s| {
        if (s.len > 0) return std.fmt.bufPrint(buf, "{s}", .{s}) catch null;
    }
    const home = sys.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.synapty/sockets/{s}@{s}:{d}", .{
        home, a.user, a.host, a.port,
    }) catch null;
}

/// Is a ControlMaster answering on this socket?
/// RUN `argv` TO COMPLETION, SAYING NOTHING, and answer whether it
/// succeeded. For the calls whose output is not news — a probe, a master
/// being opened — where what matters is the status.
///
/// HERE RATHER THAN IN `sys`, which has no `Io` by design and says so.
/// RUN `argv` AND KEEP WHAT IT SAID. Null when it could not be run or did
/// not succeed — the callers here all treat "no answer" and "a bad answer"
/// the same way, because both mean the fact they wanted is not available.
pub fn runCapturing(alloc: Allocator, argv: []const []const u8, stdin_text: []const u8) ?[]u8 {
    var child = std.process.spawn(io_mod.get(), .{
        .argv = argv,
        .stdin = if (stdin_text.len > 0) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    if (stdin_text.len > 0) {
        if (child.stdin) |f| {
            var w = f.writer(io_mod.get(), &.{});
            w.interface.writeAll(stdin_text) catch {};
            w.interface.flush() catch {};
            f.close(io_mod.get());
            child.stdin = null;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    if (child.stdout) |f| {
        var buf: [8192]u8 = undefined;
        var r = f.reader(io_mod.get(), &.{});
        while (true) {
            const n = r.interface.readSliceShort(&buf) catch break;
            if (n == 0) break;
            out.appendSlice(alloc, buf[0..n]) catch break;
        }
    }
    const term = std.process.Child.wait(&child, io_mod.get()) catch {
        out.deinit(alloc);
        return null;
    };
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        out.deinit(alloc);
        return null;
    }
    return out.toOwnedSlice(alloc) catch null;
}

pub fn runQuietly(argv: []const []const u8) bool {
    var child = std.process.spawn(io_mod.get(), .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = std.process.Child.wait(&child, io_mod.get()) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub fn masterIsUp(socket: []const u8, dest: []const u8) bool {
    // ITS COMPLAINT IS NOT NEWS. "No such file or directory" for a socket
    // that was never made is the ordinary case, and printing it onto the
    // pane would make a first connection look like a failure.
    return runQuietly(&.{ "ssh", "-S", socket, "-O", "check", dest });
}

/// `synapty connect` — dial this pane's host.
///
/// THE ORDER HERE IS THE SCRIPT'S ORDER, deliberately: the account is
/// opened, a host that keeps no session says so before anything slow
/// happens, the master is probed, one word is said about which it was, and
/// then the pane is handed over and never comes back.
pub fn run(alloc: Allocator, a: types.ConnectArgs) !void {
    // THE FAR SIDE'S SCRIPT, ON ITS OWN. Printing it is how the shell that
    // used to build it can be compared against this, byte for byte, rather
    // than by reading both and believing they agree.
    if (a.print_remote) {
        const text = try remoteLaunch(alloc, .{
            .agent_id = a.agent_id,
            .fresh_id = if (a.fresh_id.len > 0) a.fresh_id else a.agent_id,
            .cwd = a.cwd,
            .durable = durable(),
        });
        try io_mod.stdoutWriteAll(text);
        try io_mod.stdoutWriteAll("\n");
        return;
    }

    // A DRY RUN LEAVES NOTHING BEHIND. `--print` says what WOULD happen,
    // so it must not write the account the workbench is reading, nor the
    // pool record that says which connection this pane took.
    var account = if (a.print) progress_mod.Progress{} else progress_mod.Progress.fromEnv();
    defer account.close();

    var dest_buf: [512]u8 = undefined;
    const dest = try std.fmt.bufPrint(&dest_buf, "{s}@{s}", .{ a.user, a.host });
    var sock_buf: [1024]u8 = undefined;
    const socket = socketPath(&sock_buf, a) orelse return error.NoSocketPath;

    // AND NOTHING WILL EVER PAINT ON A HOST THAT KEEPS NO SESSION. There
    // is no holder to hand a screen back, so no client says the pane has
    // something on it; without this the workbench would show progress in
    // front of a working terminal until it gave up on the silence
    // ([[WI-2026-08-17-016]]).
    if (!durable()) account.say(.live, "this host keeps no session between connections");

    const up = masterIsUp(socket, dest);
    // AND A DRY RUN SAYS NOTHING AT THE HUMAN EITHER. "opening a
    // connection to this host" is a claim about what just happened, and
    // under `--print` nothing did; which branch was taken is visible in
    // the ssh line below without anybody asserting it.
    if (!a.print) say(&account, if (up)
        "reusing this host's open connection"
    else
        "opening a connection to this host");

    // WHERE THE POOL'S RECORD GOES, when the workbench named one. That one
    // file is the whole record: the pool counts it, the transport re-reads
    // it on every attempt, and a migration is one write to it. Nothing
    // derives a second path to the same fact ([[WI-2026-09-02-030]]).
    const socket_file: ?[]const u8 = if (up) blk: {
        const f = sys.getenv("SYNAPTY_SOCKET_FILE") orelse break :blk null;
        if (f.len == 0) break :blk null;
        if (!a.print) writeSocketRecord(f, socket);
        break :blk f;
    } else null;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    // WHICH COPY OF THIS BINARY THE PANE RUNS. `SYNAPTY_BIN` first,
    // because that is the contract the workbench already has with this
    // path — a bundled application names its own helper rather than
    // trusting a bare name on PATH ([[WI-2026-08-17-009]]) — and the
    // running executable otherwise, which is what a human invoking this by
    // hand means.
    var self_buf: [1024]u8 = undefined;
    const self = blk: {
        if (sys.getenv("SYNAPTY_BIN")) |b| {
            if (b.len > 0) break :blk b;
        }
        break :blk sys.selfExePath(&self_buf) orelse "synapty";
    };

    // THE CLIENT GOES IN FRONT, OR NOTHING DOES. On a durable host the
    // client owns the reconnecting: it spawns the transport, and when the
    // transport dies it spawns it again in the same process and the same
    // pty, which is why a dropped link leaves the pane's scrollback where
    // it was. On a host that keeps no session there is nothing to come
    // back to, so ssh is the pane's child directly and needs the terminal
    // the holder would otherwise have provided.
    if (durable()) {
        try argv.append(alloc, self);
        try argv.append(alloc, "attach");
        try argv.append(alloc, "--id");
        try argv.append(alloc, a.agent_id);
        try argv.append(alloc, "--");
    }
    try argv.append(alloc, self);
    try argv.append(alloc, "connect");
    try argv.append(alloc, "--transport");
    // BUILT HERE UNLESS SOMEBODY HANDED ONE OVER. `--remote` stays
    // because it is the honest way to say "run exactly this over there",
    // which is what makes a strange host debuggable ([[ADR-0020]]).
    const remote = if (a.remote.len > 0) a.remote else try remoteLaunch(alloc, .{
        .agent_id = a.agent_id,
        .fresh_id = if (a.fresh_id.len > 0) a.fresh_id else a.agent_id,
        .cwd = a.cwd,
        .durable = durable(),
    });
    try appendTransportArgs(alloc, &argv, a, dest, socket, socket_file, up, remote);

    if (a.print) {
        printArgv(argv.items);
        // AND THE SSH ITSELF, which is the thing a human is actually
        // trying to see. The line above is who runs it; this is what runs.
        printArgv(try sshArgv(alloc, .{
            .tty = if (durable()) "-T" else "-t",
            .shape = if (up) Shape{ .master = socket } else Shape{ .direct = a.forwards },
            .port = a.port,
            .key = a.key,
            .jump = a.jump,
            .dest = dest,
            .remote = remote,
        }));
        return;
    }
    sys.execInto(alloc, argv.items);
    try io_mod.stderrWriteAll("synapty connect: could not run the transport\n");
    std.process.exit(1);
}

/// The dial's own choices, spelled out for the transport to re-read.
fn appendTransportArgs(
    alloc: Allocator,
    argv: *std.ArrayList([]const u8),
    a: types.ConnectArgs,
    dest: []const u8,
    socket: []const u8,
    socket_file: ?[]const u8,
    up: bool,
    remote: []const u8,
) !void {
    try argv.append(alloc, "--dest");
    try argv.append(alloc, try alloc.dupe(u8, dest));
    try argv.append(alloc, "--remote");
    try argv.append(alloc, remote);
    try argv.append(alloc, "--port");
    try argv.append(alloc, try std.fmt.allocPrint(alloc, "{d}", .{a.port}));
    if (a.key.len > 0) {
        try argv.append(alloc, "--key");
        try argv.append(alloc, a.key);
    }
    if (a.jump.len > 0) {
        try argv.append(alloc, "--jump");
        try argv.append(alloc, a.jump);
    }
    if (up) {
        if (socket_file) |f| {
            // RE-READ, NOT BAKED IN. A socket in the argv is a connection
            // this pane can never leave, and the client re-spawns that
            // argv unchanged on every attempt.
            try argv.append(alloc, "--socket-file");
            try argv.append(alloc, f);
            // AND THE OTHER HALF OF THE SAME RECORD. Moving a pane between
            // a host's connections is one write to the file above plus a
            // signal to the transport, so the pool needs the transport's
            // PID — and the transport is the only process that knows it.
            //
            // THESE TWO TRAVELLED TOGETHER AND ONE WAS LEFT BEHIND. The
            // shell did both in one line (`printf %s "$$" > "$2"; exec ssh
            // -S "$(cat "$1")" …`); [[ADR-0020]] step 3 moved the socket
            // half here and not the pid half, so `migratePane` failed its
            // first guard every time and a pane stayed pinned to a
            // saturated connection for its whole life
            // ([[WI-2026-09-09-014]]).
            if (sys.getenv("SYNAPTY_PID_FILE")) |p| {
                if (p.len > 0) {
                    try argv.append(alloc, "--pid-file");
                    try argv.append(alloc, p);
                }
            }
        } else {
            try argv.append(alloc, "--socket");
            try argv.append(alloc, try alloc.dupe(u8, socket));
        }
    } else {
        // NO A2A TUNNEL HERE. Under [[ADR-0008]] stage 3b the agent
        // connects to the hub on its OWN host over loopback, so nothing
        // needs forwarding for it to work; the cross-machine peer link is
        // made by `synapty host-setup` on the master. Only the human's own
        // forwardings ride this ssh.
        for (a.forwards) |f| {
            try argv.append(alloc, "--forward");
            try argv.append(alloc, f);
        }
    }
}

fn writeSocketRecord(path: []const u8, socket: []const u8) void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io_mod.get(), dir) catch {};
    }
    var file = std.Io.Dir.cwd().createFile(io_mod.get(), path, .{}) catch return;
    defer file.close(io_mod.get());
    var w = file.writer(io_mod.get(), &.{});
    w.interface.writeAll(socket) catch {};
}

/// WHAT WOULD RUN, IN A FORM THAT WOULD RUN IF PASTED.
///
/// QUOTED, BECAUSE THE INTERESTING ARGUMENT IS A SCRIPT. `--remote` is a
/// whole shell program and the forwardings carry colons; printed bare they
/// read as several arguments, and a human copying the line to try it by
/// hand would run something else. [[ADR-0020]] asks for the EXACT
/// invocation, and a line that cannot be pasted is not it.
pub fn printArgv(argv: []const []const u8) void {
    for (argv, 0..) |arg, i| {
        if (i > 0) io_mod.stdoutWriteAll(" ") catch {};
        if (needsQuoting(arg)) {
            io_mod.stdoutWriteAll("'") catch {};
            var rest = arg;
            while (std.mem.indexOfScalar(u8, rest, '\'')) |at| {
                io_mod.stdoutWriteAll(rest[0..at]) catch {};
                // The POSIX escape: close, an escaped quote, reopen.
                io_mod.stdoutWriteAll("'\\''") catch {};
                rest = rest[at + 1 ..];
            }
            io_mod.stdoutWriteAll(rest) catch {};
            io_mod.stdoutWriteAll("'") catch {};
        } else {
            io_mod.stdoutWriteAll(arg) catch {};
        }
    }
    io_mod.stdoutWriteAll("\n") catch {};
}

fn needsQuoting(arg: []const u8) bool {
    if (arg.len == 0) return true;
    for (arg) |c| {
        const safe = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '/' or c == '.' or c == '-' or
            c == '_' or c == '@' or c == ':' or c == '=' or c == ',';
        if (!safe) return true;
    }
    return false;
}

/// `synapty connect --transport` — one ssh, and what became of it.
///
/// THE CONNECTION IS RESOLVED HERE, ON EVERY ATTEMPT. The durable client
/// re-runs this argv after every drop, so a socket read once at the dial
/// and written into that argv would be a connection this pane could never
/// leave. `--socket-file` names the file the workbench writes when it
/// moves a pane between connections; reading it here is what makes the
/// move take effect on the next attempt ([[WI-2026-09-02-030]]).
///
/// AND WHO REPORTS DEPENDS ON WHO IS IN FRONT. With a durable client there
/// this EXECS ssh, so the frames pass through nothing: the client owns the
/// account and writes its own `end`. With no client, ssh is the pane's
/// child and nobody else can see what it exited with — so this waits for
/// it and says ([[commands.transportEnd]], [[RFC-0014]] C-OPT-OUT).
pub fn runTransport(alloc: Allocator, a: types.ConnectArgs) !void {
    var live_buf: [1024]u8 = undefined;
    const socket: ?[]const u8 = if (a.socket_file.len > 0)
        readSocketRecord(&live_buf, a.socket_file)
    else if (a.socket.len > 0)
        a.socket
    else
        null;

    const argv = try sshArgv(alloc, .{
        .tty = if (durable()) "-T" else "-t",
        .shape = if (socket) |s| .{ .master = s } else .{ .direct = a.forwards },
        .port = a.port,
        .key = a.key,
        .jump = a.jump,
        .dest = a.dest,
        .remote = a.remote,
    });
    if (a.print) return printArgv(argv);

    // ITS OWN PID, WHERE THE POOL LOOKS FOR IT. Written before the exec
    // because after it there is no `this process` left to ask.
    if (a.pid_file.len > 0) writePid(a.pid_file);

    if (durable()) {
        sys.execInto(alloc, argv);
        try io_mod.stderrWriteAll("synapty connect: could not run ssh\n");
        std.process.exit(1);
    }

    var child = std.process.spawn(io_mod.get(), .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch {
        try io_mod.stderrWriteAll("synapty connect: could not run ssh\n");
        std.process.exit(1);
    };
    const term = std.process.Child.wait(&child, io_mod.get()) catch {
        try io_mod.stderrWriteAll("synapty connect: could not wait for ssh\n");
        std.process.exit(1);
    };
    const status: c_int = switch (term) {
        .exited => |code| @as(c_int, code) << 8,
        .signal => |sig| @intCast(@intFromEnum(sig)),
        else => 0,
    };
    var account = progress_mod.Progress.fromEnv();
    defer account.close();
    if (@import("commands.zig").transportEnd(status)) |word| account.say(.end, word);
    std.process.exit(switch (term) {
        .exited => |code| code,
        else => 1,
    });
}

fn readSocketRecord(buf: []u8, path: []const u8) ?[]const u8 {
    var file = std.Io.Dir.cwd().openFile(io_mod.get(), path, .{}) catch return null;
    defer file.close(io_mod.get());
    var r = file.reader(io_mod.get(), &.{});
    const n = r.interface.readSliceShort(buf) catch return null;
    const text = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return if (text.len == 0) null else text;
}

fn writePid(path: []const u8) void {
    var file = std.Io.Dir.cwd().createFile(io_mod.get(), path, .{}) catch return;
    defer file.close(io_mod.get());
    var body: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&body, "{d}", .{std.c.getpid()}) catch return;
    var w = file.writer(io_mod.get(), &.{});
    w.interface.writeAll(text) catch {};
}

const testing = std.testing;

test "a forwarding rule becomes the flag ssh knows it by" {
    var buf: [256]u8 = undefined;
    const l = Forward.parse(&buf, "local:8080:127.0.0.1:80").?;
    try testing.expectEqualStrings("-L", l.flag);
    try testing.expectEqualStrings("8080:127.0.0.1:80", l.spec);
    const r = Forward.parse(&buf, "remote:9000:localhost:9000").?;
    try testing.expectEqualStrings("-R", r.flag);
    // A KIND THAT IS NOT ONE IS REFUSED RATHER THAN GUESSED. The script
    // answered `echo "Error: unknown forward kind"` and exited; the point
    // is the same, and here it can be asked.
    try testing.expect(Forward.parse(&buf, "sideways:1:h:2") == null);
    try testing.expect(Forward.parse(&buf, "local:1:h") == null);
    try testing.expect(Forward.parse(&buf, "local:1:h:2:3") == null);
    try testing.expect(Forward.parse(&buf, "local::h:2") == null);
}

test "an empty target is the localhost the model promises it is" {
    var buf: [256]u8 = undefined;
    // `PortForward.targetHost` is documented "empty = localhost" and is
    // edited through a bare TextField, so this is the shape the workbench
    // produces when the human clears that box — not a hypothetical.
    const f = Forward.parse(&buf, "local:8080::80").?;
    try testing.expectEqualStrings("-L", f.flag);
    try testing.expectEqualStrings("8080:localhost:80", f.spec);
}

test "an IPv6 target survives a format whose separator it contains" {
    var buf: [256]u8 = undefined;
    const f = Forward.parse(&buf, "local:8080:[::1]:80").?;
    try testing.expectEqualStrings("8080:[::1]:80", f.spec);
    // Unbracketed it is genuinely ambiguous, and is refused rather than
    // split in the wrong place and handed to ssh.
    try testing.expect(Forward.parse(&buf, "local:8080:::1:80") == null);
    try testing.expect(Forward.parse(&buf, "local:8080:[]:80") == null);
    try testing.expect(Forward.parse(&buf, "local:8080:[::1]80") == null);
    try testing.expect(Forward.parse(&buf, "local:8080:[::1]") == null);
}

test "a port is a port, not merely a field that was filled in" {
    var buf: [256]u8 = undefined;
    try testing.expect(Forward.parse(&buf, "local:8080:h:abc") == null);
    try testing.expect(Forward.parse(&buf, "local:abc:h:80") == null);
    // What the editor writes when the human clears a port box.
    try testing.expect(Forward.parse(&buf, "local:0:h:80") == null);
    try testing.expect(Forward.parse(&buf, "local:8080:h:0") == null);
    try testing.expect(Forward.parse(&buf, "local:70000:h:80") == null);
    try testing.expect(Forward.parse(&buf, "local:8080:h:") == null);
}

test "a master's ssh carries no forwardings, and a direct one carries its own" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // THROUGH A MASTER THAT IS ALREADY UP. The forwardings are on it
    // already, and re-adding them is what `ExitOnForwardFailure=yes` turns
    // into a refusal to connect at all.
    const through = try sshArgv(alloc, .{
        .tty = "-T",
        .shape = .{ .master = "/s/ock" },
        .port = 22,
        .key = "",
        .jump = "",
        .dest = "u@h",
        .remote = "exec bash -l",
    });
    try testing.expectEqualStrings("ssh", through[0]);
    try testing.expectEqualStrings("-T", through[1]);
    try testing.expectEqualStrings("-S", through[2]);
    try testing.expectEqualStrings("/s/ock", through[3]);
    for (through) |a| try testing.expect(!std.mem.eql(u8, a, "-L"));
    // THE FAR SIDE'S SCRIPT IS ONE ARGUMENT, WHOLE. Split by anything on
    // this side it arrives as several commands.
    try testing.expectEqualStrings("exec bash -l", through[through.len - 1]);
    try testing.expectEqualStrings("u@h", through[through.len - 2]);

    const direct = try sshArgv(alloc, .{
        .tty = "-t",
        .shape = .{ .direct = &.{ "local:8080:127.0.0.1:80", "remote:9:h:9" } },
        .port = 2222,
        .key = "/k",
        .jump = "b",
        .dest = "u@h",
        .remote = "r",
    });
    for (direct) |a| try testing.expect(!std.mem.eql(u8, a, "-S"));
    try seen(direct, "-L", "8080:127.0.0.1:80");
    try seen(direct, "-R", "9:h:9");
    try seen(direct, "-J", "b");
    try seen(direct, "-i", "/k");
    try seen(direct, "-p", "2222");
    // Every robustness option survives: a missing one is a pane that
    // freezes on a dead link or hangs on a host-key prompt.
    try seen(direct, "-o", "ServerAliveInterval=15");
    try seen(direct, "-o", "ExitOnForwardFailure=yes");
    try seen(direct, "-o", "StrictHostKeyChecking=accept-new");
    try seen(direct, "-o", "ConnectTimeout=10");
    try seen(direct, "-o", "ServerAliveCountMax=3");
}

/// A flag followed by its value, somewhere in the line.
fn seen(argv: []const []const u8, flag: []const u8, value: []const u8) !void {
    for (argv, 0..) |a, i| {
        if (std.mem.eql(u8, a, flag) and i + 1 < argv.len and
            std.mem.eql(u8, argv[i + 1], value)) return;
    }
    std.debug.print("missing {s} {s} in:", .{ flag, value });
    for (argv) |a| std.debug.print(" {s}", .{a});
    std.debug.print("\n", .{});
    return error.NotInInvocation;
}
