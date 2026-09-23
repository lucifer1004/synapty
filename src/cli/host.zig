//! PREPARING A HOST TO CARRY PANES, from this side ([[ADR-0020]]).
//!
//! WHAT THIS IS NOT. It is not the dial ([[connect]]): it runs once per
//! host rather than once per pane, and everything it does is a side effect
//! on the far side — a connection opened, a binary uploaded, a terminal
//! description installed, a hub started. The dial then rides what this
//! left behind.
//!
//! THE SAME RULE AS EVERYWHERE ELSE HERE. The pieces that run on the FAR
//! side stay shell, because they run before that machine has anything else
//! to run them with. The pieces that run on THIS one are the binary's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys");
const io_mod = @import("io");
const deploy_targets = @import("../deploy_targets.zig");
const types = @import("types.zig");
const progress_mod = @import("progress.zig");
const connect = @import("connect.zig");

/// WHERE THIS HOST'S FIRST CONNECTION LIVES. The pool may hold more
/// ([[RFC-0013]] C-BROKER); this is the one the setup itself rides and the
/// one a dial falls back to when the workbench has named none.
pub fn socketPath(buf: []u8, a: types.HostArgs) ?[]const u8 {
    const home = sys.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.synapty/sockets/{s}@{s}:{d}", .{
        home, a.user, a.host, a.port,
    }) catch null;
}

/// The arguments every ssh and scp below shares.
fn flags(alloc: Allocator, a: types.HostArgs) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    if (a.jump.len > 0) {
        try out.append(alloc, "-J");
        try out.append(alloc, a.jump);
    }
    if (a.key.len > 0) {
        try out.append(alloc, "-i");
        try out.append(alloc, a.key);
    }
    try out.append(alloc, "-p");
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{d}", .{a.port}));
    for (connect.base_robustness) |f| try out.append(alloc, f);
    return out.toOwnedSlice(alloc);
}

/// The invocation that OPENS a master.
///
/// A CONNECTION IS OPENED BEFORE THE THINGS THAT RIDE IT
/// ([[WI-2026-08-17-021]]). It used to be opened last, because it carries
/// the peer link and which port to forward to is only known once the
/// remote hub has answered — so the probe, the hub and the build query
/// each paid a full authentication first: ~2.2s against ~0.36s over a
/// master. The peer forward is added to a LIVE master at the end instead,
/// with `ssh -O forward`.
///
/// THE HUMAN'S OWN FORWARDINGS ARE KNOWN HERE and ride it from the start.
pub fn openArgv(alloc: Allocator, a: types.HostArgs, socket: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, &.{ "ssh", "-MNf", "-S", socket });
    // ControlPersist is what makes the master outlive this process; the
    // keepalives are what make a dead one noticed rather than waited on.
    try out.appendSlice(alloc, &.{
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
        "-o", "ControlPersist=yes",
    });
    for (a.forwards) |text| {
        var buf: [256]u8 = undefined;
        const f = connect.Forward.parseOrExit(&buf, text, "synapty host-master");
        try out.append(alloc, f.flag);
        try out.append(alloc, try alloc.dupe(u8, f.spec));
    }
    // NOT `ExitOnForwardFailure`. A host that cannot carry one of the
    // human's forwardings still carries panes, and refusing the master
    // would take those with it.
    for (try flags(alloc, a)) |f| try out.append(alloc, f);
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}@{s}", .{ a.user, a.host }));
    return out.toOwnedSlice(alloc);
}

/// `synapty host-master` — make sure this host has a connection to ride.
///
/// A HOST THAT WILL NOT HOLD ONE IS NOT A FAILURE. Every step that follows
/// can open its own, slowly, which is what they all did before the master
/// existed — so a master that cannot be established costs speed and
/// nothing else, and this exits 0 either way.
pub fn runMaster(alloc: Allocator, a: types.HostArgs) !void {
    _ = try ensureMaster(alloc, a);
}

/// … and whether this host has one, which is what everything after it
/// depends on.
///
/// ANSWERED ONCE, FROM WHAT WAS DONE. It used to be asked again by the
/// setup that follows, which is a second round trip AND a second answer:
/// `ssh -MNf` returns once the master is listening, so re-probing can only
/// agree with it or be wrong. Being wrong is not harmless here — a setup
/// that decides there is no master skips the peer forward and prints no
/// `PEER_PORT`, so the local hub is never told to dial its peer and
/// cross-machine A2A is silently absent ([[WI-2026-09-09-010]]).
pub fn ensureMaster(alloc: Allocator, a: types.HostArgs) !bool {
    var account = if (a.print) progress_mod.Progress{} else progress_mod.Progress.fromEnv();
    defer account.close();

    var sock_buf: [1024]u8 = undefined;
    const socket = if (a.socket.len > 0)
        a.socket
    else
        socketPath(&sock_buf, a) orelse return error.NoSocketPath;
    var dest_buf: [512]u8 = undefined;
    const dest = try std.fmt.bufPrint(&dest_buf, "{s}@{s}", .{ a.user, a.host });

    const argv = try openArgv(alloc, a, socket);
    if (a.print) {
        // WHAT WOULD RUN, AND THE ARGUMENTS EVERY LATER STEP CARRIES.
        // [[ADR-0020]] requires this path to be as inspectable as the
        // script a human could read and run by hand.
        connect.printArgv(argv);
        var m = try masterArgs(alloc, socket);
        defer m.deinit(alloc);
        connect.printArgv(m.items);
        return false;
    }

    if (connect.masterIsUp(socket, dest)) {
        // STDOUT IS A PARSED INTERFACE HERE, not prose: the workbench
        // reads these lines.
        try io_mod.stdoutWriteAll("ControlMaster already active for ");
        try io_mod.stdoutWriteAll(dest);
        try io_mod.stdoutWriteAll("\n");
        return true;
    }
    if (account.on()) account.say(.note, "opening a connection to this host");
    try io_mod.stdoutWriteAll("Starting SSH ControlMaster...\n");

    if (connect.runQuietly(argv)) {
        try io_mod.stdoutWriteAll("ControlMaster established: ");
        try io_mod.stdoutWriteAll(socket);
        try io_mod.stdoutWriteAll("\n");
        return true;
    }
    try io_mod.stderrWriteAll(
        "WARNING: could not establish a ControlMaster on ");
    try io_mod.stderrWriteAll(a.host);
    try io_mod.stderrWriteAll(" — every step will open its own connection\n");
    return false;
}

/// `-S <socket>` when a master is there, and nothing when it is not.
///
/// AN ARRAY, BECAUSE A STRING CANNOT CARRY QUOTING ([[WI-2026-08-17-017]]).
/// This was `SSH_CMD="-S '$SOCKET'"` expanded unquoted, which handed ssh a
/// path whose first and last characters were apostrophes — no such socket,
/// so every step below opened a NEW connection to a host that already had
/// one open. Measured on a live master: 2.175s per call that way against
/// 0.362s multiplexed, which was most of a 28-second reconnection. In a
/// language with argument lists the hazard does not arise; it is recorded
/// because the shape it forced — an array with a `${arr[@]+…}` guard for
/// bash 3.2 — is what this replaces.
pub fn masterArgs(alloc: Allocator, socket: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(alloc, "-S");
    try out.append(alloc, socket);
    return out;
}

/// ONE ROUND TRIP, NOT FOUR ([[WI-2026-08-17-018]]).
///
/// What the setup needs to know before it can decide anything is: what
/// this host is, which binary it already has, and whether it already has
/// the terminal description. Those were three separate ssh invocations
/// plus a mkdir, and each one is a round trip — ~0.36s over a live master
/// and ~2.2s without. They are one call, and it makes its own directories
/// on the way past.
///
/// FAR-SIDE SHELL, DELIBERATELY. It runs before anything of ours is known
/// to be there — it is what reports whether anything is — so `sh` is the
/// only thing available to run it ([[ADR-0020]]).
pub const probe_script =
    \\sum() {
    \\    if [ ! -f "$1" ]; then echo ""; return; fi
    \\    if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print $1}'; else md5 -q "$1"; fi
    \\}
    \\mkdir -p .synapty/bin .terminfo/78 .terminfo/x
    \\echo "PLATFORM=$(uname -sm)"
    \\echo "BIN_MD5=$(sum .synapty/bin/synapty)"
    \\echo "TI78_MD5=$(sum .terminfo/78/xterm-ghostty)"
    \\echo "TIX_MD5=$(sum .terminfo/x/xterm-ghostty)"
;

/// A HUB THAT IS ALREADY RUNNING IS RUNNING THE OLD BINARY.
///
/// `hub --ensure` probes for a live hub and leaves it alone, which is what
/// makes it safe to run on every connect — and which meant a host kept its
/// hub across every upgrade. Measured on a real host: a daemon three days
/// behind the workbench rejected every tool added since with a bare
/// "unknown tool", and nothing anywhere named the version skew.
///
/// BY PID, FROM THE HUB'S OWN DISCOVERY FILE — never by pattern. A
/// `pkill -f "synapty hub"` issued over ssh matches the shell running it,
/// so it reports success while killing something else; this project has
/// been bitten by exactly that once.
pub const replace_hub_script =
    \\HUB_JSON="$HOME/.config/synapty/machine/hub.json"
    \\[ -f "$HUB_JSON" ] || exit 0
    \\PID=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$HUB_JSON")
    \\[ -n "$PID" ] || exit 0
    \\# A recycled pid must not be killed for having once been the hub.
    \\CMD=$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null || ps -o args= -p "$PID" 2>/dev/null)
    \\case "$CMD" in
    \\    *"synapty hub"*) ;;
    \\    *) exit 0 ;;
    \\esac
    \\kill "$PID" 2>/dev/null || exit 0
    \\i=0
    \\while [ $i -lt 10 ]; do
    \\    kill -0 "$PID" 2>/dev/null || break
    \\    sleep 0.3
    \\    i=$((i + 1))
    \\done
    \\kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null
    \\echo "Replaced the running hub (was pid $PID, older binary)."
;

/// WHICH BUILD IS ACTUALLY RUNNING THERE, reported so the workbench can
/// say so rather than leaving the human to infer it from a tool that comes
/// back "unknown".
///
/// hub.json is written by the hub AT STARTUP, so it describes the PROCESS;
/// the binary on disk describes only what would run next. That distinction
/// is the whole bug — an upload that lands while the old hub keeps running
/// leaves the two disagreeing, and comparing files would report everything
/// fine. Both figures are read on the remote side, so nothing here depends
/// on the two machines agreeing about anything but the string.
pub const build_query =
    \\HUB_JSON="$HOME/.config/synapty/machine/hub.json"
    \\RUNNING=$(sed -n "s/.*\"build\":\"\([^\"]*\)\".*/\1/p" "$HUB_JSON" 2>/dev/null)
    \\DEPLOYED=$(.synapty/bin/synapty version 2>/dev/null)
    \\echo "HUB_BUILD=${RUNNING}"
    \\echo "HUB_BINARY=${DEPLOYED}"
;

/// `uname -sm` to the directory the cross-compile lands in.
pub fn deployDir(platform: []const u8) ?[]const u8 {
    // THE SAME LIST `build.zig` CREATES THE STEPS FROM
    // ([[src/deploy_targets.zig]], [[WI-2026-09-11-003]]). This was a
    // second copy, so a target the build produced could be one this
    // lookup had never heard of.
    return deploy_targets.dirFor(platform);
}

/// One `KEY=value` line out of the probe's answer.
pub fn probed(text: []const u8, key: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len <= key.len) continue;
        if (!std.mem.startsWith(u8, t, key)) continue;
        if (t[key.len] != '=') continue;
        return t[key.len + 1 ..];
    }
    return "";
}

/// MD5, COMPUTED RATHER THAN SHELLED OUT FOR. The script ran `md5 -q` or
/// `md5sum` depending on the platform it happened to be on; the far side
/// still does, because that is where it must.
pub fn md5Of(path: []const u8, out: *[32]u8) bool {
    var file = std.Io.Dir.cwd().openFile(io_mod.get(), path, .{}) catch return false;
    defer file.close(io_mod.get());
    var h = std.crypto.hash.Md5.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var r = file.reader(io_mod.get(), &.{});
    while (true) {
        const n = r.interface.readSliceShort(&buf) catch return false;
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [16]u8 = undefined;
    h.final(&digest);
    _ = std.fmt.bufPrint(out, "{x}", .{&digest}) catch return false;
    return true;
}

/// Where a cross-compiled binary for `dir` might be, in the order the
/// script looked.
///
/// RELATIVE TO THIS EXECUTABLE, not to a script. The candidates were
/// `${SCRIPT_DIR}/../zig-out/...` and `${SCRIPT_DIR}/../../Resources/...`
/// — the same two places, reached from where the running binary is rather
/// than from where a file that no longer exists used to be.
fn findDeployed(alloc: Allocator, dir: []const u8) !?[]const u8 {
    var exe_buf: [1024]u8 = undefined;
    const exe = sys.selfExePath(&exe_buf) orelse "";
    const here = std.fs.path.dirname(exe) orelse ".";
    const candidates = [_][]const u8{
        try std.fmt.allocPrint(alloc, "{s}/../{s}/synapty", .{ here, dir }),
        try std.fmt.allocPrint(alloc, "{s}/../Resources/deploy/{s}/synapty", .{ here, dir }),
        try std.fmt.allocPrint(alloc, "zig-out/{s}/synapty", .{dir}),
    };
    for (candidates) |c| {
        if (exists(c)) return c;
    }
    return null;
}

/// THE COMPILED TERMINFO ENTRY for xterm-ghostty (ghostty#5818).
///
/// Remote shells (zsh with powerlevel10k and friends) misbehave when the
/// TERM entry is missing on the server: backspace outputs a space instead
/// of deleting. Copied into BOTH common layouts — the `78` hash and the
/// `x` first-letter — because different ncurses builds look in different
/// places. The dial additionally falls back to xterm-256color when
/// nothing resolves, so this is best-effort.
fn findTerminfo(alloc: Allocator) !?[]const u8 {
    var exe_buf: [1024]u8 = undefined;
    const exe = sys.selfExePath(&exe_buf) orelse "";
    const here = std.fs.path.dirname(exe) orelse ".";
    const candidates = [_][]const u8{
        try std.fmt.allocPrint(alloc, "{s}/../Resources/terminfo/78/xterm-ghostty", .{here}),
        try std.fmt.allocPrint(alloc, "{s}/../../ghostty/zig-out/share/terminfo/78/xterm-ghostty", .{here}),
        "ghostty/zig-out/share/terminfo/78/xterm-ghostty",
    };
    for (candidates) |c| {
        if (exists(c)) return c;
    }
    return null;
}

fn exists(path: []const u8) bool {
    var f = std.Io.Dir.cwd().openFile(io_mod.get(), path, .{}) catch return false;
    f.close(io_mod.get());
    return true;
}

/// An ssh to this host, carrying `remote` as its command.
fn sshArgv(alloc: Allocator, a: types.HostArgs, master: ?[]const u8, remote: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, "ssh");
    if (master) |m| {
        try out.append(alloc, "-S");
        try out.append(alloc, m);
    }
    for (try flags(alloc, a)) |f| try out.append(alloc, f);
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}@{s}", .{ a.user, a.host }));
    if (remote.len > 0) try out.append(alloc, remote);
    return out.toOwnedSlice(alloc);
}

/// A copy to this host, THROUGH the master when there is one.
fn scpArgv(alloc: Allocator, a: types.HostArgs, master: ?[]const u8, src: []const u8, dst: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, "scp");
    if (a.jump.len > 0) {
        try out.append(alloc, "-J");
        try out.append(alloc, a.jump);
    }
    if (a.key.len > 0) {
        try out.append(alloc, "-i");
        try out.append(alloc, a.key);
    }
    // `-O` is the old protocol: scp's SFTP mode does not honour a
    // ControlPath, which is the whole point of the two options below.
    try out.append(alloc, "-O");
    try out.append(alloc, "-P");
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{d}", .{a.port}));
    if (master) |m| {
        try out.append(alloc, "-o");
        try out.append(alloc, try std.fmt.allocPrint(alloc, "ControlPath={s}", .{m}));
        try out.append(alloc, "-o");
        try out.append(alloc, "ControlMaster=auto");
    }
    try out.append(alloc, src);
    try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}@{s}:{s}", .{ a.user, a.host, dst }));
    return out.toOwnedSlice(alloc);
}

/// Say it to the human's log, and to the account when the workbench named
/// one.
///
/// THIS SCRIPT'S STDOUT IS CAPTURED AND PARSED WHEN IT IS ALREADY OVER, so
/// nothing echoed there reaches somebody who is waiting — and this is the
/// slow half of a connection ([[WI-2026-08-17-016]]). The account is where
/// the words go while it runs; stdout stays exactly as it was, because the
/// workbench reads it.
fn step(account: *const progress_mod.Progress, said: []const u8, logged: []const u8) void {
    if (said.len > 0) account.say(.note, said);
    if (logged.len > 0) {
        io_mod.stdoutWriteAll(logged) catch {};
        io_mod.stdoutWriteAll("\n") catch {};
    }
}

/// `synapty host-setup` — everything a host needs before a pane can ride it.
pub fn runSetup(alloc: Allocator, a: types.HostArgs) !void {
    // THE CONNECTION FIRST, BECAUSE EVERYTHING BELOW RIDES IT
    // ([[WI-2026-08-17-021]]). Opened here rather than by a separate call
    // so there is one command to run and one thing to get the order of;
    // `host-master` remains its own verb because a human debugging a host
    // wants to ask that question alone.
    const have_master = try ensureMaster(alloc, a);

    // A DRY RUN LEAVES NOTHING BEHIND, INCLUDING THE ACCOUNT. `ensureMaster`
    // already guarded both; this did not, so `--print` appended to the
    // account of a real connection ([[WI-2026-09-10-001]]).
    var account = if (a.print) progress_mod.Progress{} else progress_mod.Progress.fromEnv();
    defer account.close();

    var sock_buf: [1024]u8 = undefined;
    const socket = if (a.socket.len > 0)
        a.socket
    else
        socketPath(&sock_buf, a) orelse return error.NoSocketPath;
    const master: ?[]const u8 = if (have_master) socket else null;

    if (a.print) {
        // WHAT IT WOULD ASK THE HOST, AND THEN NOTHING.
        //
        // `--print` said "touch nothing" and then carried straight on into
        // the probe — a real ssh, whose first act on the far side is
        // `mkdir -p`, and whose success would have carried the run into
        // `rm -f`, `scp`, `chmod +x` and the script that kills the host's
        // running hub by pid. A dry run that stops the thing it was
        // inspecting ([[WI-2026-09-10-001]]).
        //
        // THROUGH THE MASTER IT JUST PRINTED. `ensureMaster` answers false
        // under `--print` because it opened nothing, but what a real run
        // would use after opening it is the socket — so that is what this
        // shows, rather than the connection-per-step shape that would
        // follow from a master nobody made.
        connect.printArgv(try sshArgv(alloc, a, socket, "sh -s"));
        // AND NOT THE REST, because the rest is decided by the answer:
        // which platform, whether the checksums differ, whether a hub is
        // already there. A dry run cannot know them without asking, and
        // asking is the thing it must not do.
        return;
    }

    step(&account, "asking this host what it has", "Detecting remote platform...");
    const probe = connect.runCapturing(alloc, try sshArgv(alloc, a, master, "sh -s"), probe_script) orelse {
        try io_mod.stdoutWriteAll("Error: the host did not answer the platform probe\n");
        std.process.exit(1);
    };
    const platform = probed(probe, "PLATFORM");
    const dir = deployDir(platform) orelse {
        try io_mod.stdoutWriteAll("Error: Unsupported platform: ");
        try io_mod.stdoutWriteAll(platform);
        // DERIVED FROM THE TABLE THAT DECIDES, so the sentence cannot
        // name a different set from the one that answers — and the two
        // already disagreed in FORM, this line writing `Linux/aarch64`
        // where `uname -sm` and the table both say `Linux aarch64`.
        var supported: [256]u8 = undefined;
        try io_mod.stdoutWriteAll("\nSupported: ");
        try io_mod.stdoutWriteAll(deploy_targets.unamesJoined(&supported));
        try io_mod.stdoutWriteAll("\n");
        std.process.exit(1);
    };
    try io_mod.stdoutWriteAll("Remote platform: ");
    try io_mod.stdoutWriteAll(platform);
    try io_mod.stdoutWriteAll(" -> ");
    try io_mod.stdoutWriteAll(dir);
    try io_mod.stdoutWriteAll("\n");

    const local_bin = (try findDeployed(alloc, dir)) orelse {
        try io_mod.stdoutWriteAll("Error: No binary found for ");
        try io_mod.stdoutWriteAll(dir);
        try io_mod.stdoutWriteAll("\nRun: zig build deploy-");
        try io_mod.stdoutWriteAll(dir);
        try io_mod.stdoutWriteAll("\n");
        std.process.exit(1);
    };
    try io_mod.stdoutWriteAll("Local binary: ");
    try io_mod.stdoutWriteAll(local_bin);
    try io_mod.stdoutWriteAll("\n");

    var local_md5: [32]u8 = undefined;
    if (!md5Of(local_bin, &local_md5)) {
        try io_mod.stdoutWriteAll("Error: could not read the binary to send\n");
        std.process.exit(1);
    }
    step(&account, "comparing the binary this host has with ours", "");
    const replaced = !std.mem.eql(u8, &local_md5, probed(probe, "BIN_MD5"));
    if (!replaced) {
        step(&account, "this host already has the current binary", "Binary unchanged, skipping upload.");
    } else {
        step(&account, "sending the binary to this host", "Uploading binary...");
        // REMOVED FIRST. Linux allows unlinking a running executable (it
        // stays in memory), but writes to an active text segment fail with
        // ETXTBSY.
        _ = connect.runQuietly(try sshArgv(alloc, a, master, "rm -f .synapty/bin/synapty"));
        _ = connect.runQuietly(try scpArgv(alloc, a, master, local_bin, ".synapty/bin/synapty"));
        _ = connect.runQuietly(try sshArgv(alloc, a, master, "chmod +x .synapty/bin/synapty"));
        try io_mod.stdoutWriteAll("Upload complete.\n");
    }

    try deployTerminfo(alloc, a, master, probe, &account);
    try ensureHub(alloc, a, master, replaced, socket, &account);
}

/// SENT ONLY WHEN IT IS NOT ALREADY THERE ([[WI-2026-08-17-018]]).
///
/// This was four round trips — a mkdir, two copies and a verify —
/// executed unconditionally to install a file that had not changed since
/// the last time it was installed, on every connect. Measured at ~9
/// seconds of a 28-second reconnection. The binary beside it has always
/// compared checksums first; this does the same, with the answer already
/// in hand from the probe.
fn deployTerminfo(
    alloc: Allocator,
    a: types.HostArgs,
    master: ?[]const u8,
    probe: []const u8,
    account: *const progress_mod.Progress,
) !void {
    const src = (try findTerminfo(alloc)) orelse {
        try io_mod.stdoutWriteAll(
            "Warning: xterm-ghostty terminfo source not found locally; skipping deploy.\n");
        return;
    };
    var md5: [32]u8 = undefined;
    if (!md5Of(src, &md5)) return;
    const installed = "terminfo installed (~/.terminfo/{78,x}/xterm-ghostty)";
    if (std.mem.eql(u8, &md5, probed(probe, "TI78_MD5")) and
        std.mem.eql(u8, &md5, probed(probe, "TIX_MD5")))
    {
        step(account, "this host already has the terminal description", installed);
        return;
    }
    step(account, "sending the terminal description", "Deploying ghostty terminfo to remote...");
    _ = connect.runQuietly(try scpArgv(alloc, a, master, src, ".terminfo/78/xterm-ghostty"));
    _ = connect.runQuietly(try scpArgv(alloc, a, master, src, ".terminfo/x/xterm-ghostty"));
    // VERIFIED ON THE FAR SIDE, and the line only printed if both landed.
    if (connect.runQuietly(try sshArgv(alloc, a, master,
        "test -f .terminfo/78/xterm-ghostty && test -f .terminfo/x/xterm-ghostty")))
    {
        try io_mod.stdoutWriteAll(installed);
        try io_mod.stdoutWriteAll("\n");
    }
}

/// The remote hub, the build it is running, and the link between the two
/// hubs ([[ADR-0008]] stage 3b, [[WI-2026-08-12-008]]).
///
/// THE TUNNEL GOES THE OTHER WAY THAN IT USED TO. The old reverse tunnel
/// carried remote agents back to the laptop's hub; each hub is local to
/// its agents now and the two hubs peer, so what is needed is a FORWARD
/// tunnel giving the local hub a loopback port that reaches the remote
/// one. [[RFC-0009]] C-BOUNDARIES: the relay link is authenticated by the
/// transport it rides — the SSH channel the human already established —
/// which is why there is no credential to configure.
fn ensureHub(
    alloc: Allocator,
    a: types.HostArgs,
    master: ?[]const u8,
    replaced: bool,
    socket: []const u8,
    account: *const progress_mod.Progress,
) !void {
    // THE CONDITION IS EXACTLY "WE JUST REPLACED THE BINARY": if the
    // upload happened, whatever is running cannot be it. No version probe
    // is needed and none would be more reliable. Connect is the moment for
    // it — the tunnel and the peer link are being rebuilt here anyway, and
    // panes reconnect to whatever hub next binds the port with their
    // identity replayed ([[WI-2026-08-11-017]]), so the cost is a gap
    // rather than a lost session.
    if (replaced) {
        if (connect.runCapturing(alloc, try sshArgv(alloc, a, master, "sh -s"), replace_hub_script)) |said| {
            if (said.len > 0) try io_mod.stdoutWriteAll(said);
        } else {
            try io_mod.stderrWriteAll("WARNING: could not replace the running hub on ");
            try io_mod.stderrWriteAll(a.host);
            try io_mod.stderrWriteAll(" — it may still be the old binary\n");
        }
    }

    step(account, "making sure this host has a hub", "");
    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(alloc);
    try cmd.appendSlice(alloc, ".synapty/bin/synapty hub --ensure");
    if (a.peer_id.len > 0) {
        try cmd.appendSlice(alloc, " --peer-id ");
        try connect.shellQuote(&cmd, alloc, a.peer_id);
    }
    var hub_port: []const u8 = "";
    if (connect.runCapturing(alloc, try sshArgv(alloc, a, master, cmd.items), "")) |json| {
        hub_port = jsonPort(json);
    }
    if (hub_port.len == 0) {
        // Honest degradation, matching the tmux-absent precedent: the
        // shell still works, A2A for this host does not, and we say which.
        try io_mod.stderrWriteAll("WARNING: no hub could be started on ");
        try io_mod.stderrWriteAll(a.host);
        try io_mod.stderrWriteAll(" — agents there will have no A2A\n");
    } else {
        step(account, "this host's hub is ready", "");
        try io_mod.stdoutWriteAll("Remote hub ready on ");
        try io_mod.stdoutWriteAll(a.host);
        try io_mod.stdoutWriteAll(":");
        try io_mod.stdoutWriteAll(hub_port);
        try io_mod.stdoutWriteAll(" (loopback there)\n");
        step(account, "asking which build is running there", "");
        if (connect.runCapturing(alloc, try sshArgv(alloc, a, master, "sh -s"), build_query)) |builds| {
            if (builds.len > 0) try io_mod.stdoutWriteAll(builds);
        }
    }

    hub_port = try peerForward(alloc, a, master, socket, hub_port, account);

    // Machine-readable tail for the workbench: which loopback port reaches
    // this host's hub, so it can tell the LOCAL hub to dial its peer there.
    if (hub_port.len > 0) {
        try io_mod.stdoutWriteAll("PEER_PORT=");
        try io_mod.stdoutWriteAll(try std.fmt.allocPrint(alloc, "{d}", .{a.tunnel_port}));
        try io_mod.stdoutWriteAll("\n");
    }
    try io_mod.stdoutWriteAll("SETUP_OK\n");
    step(account, "this host is ready", "");
}

/// ADDED TO THE LIVE MASTER, at the end ([[WI-2026-08-17-021]]).
///
/// A master does NOT carry the forward we are about to advertise just
/// because it exists: one established before peering — or under a
/// different peer port, or at the top of the setup, before the remote hub
/// had answered — has no `-L` for it, and printing PEER_PORT anyway would
/// have the local hub dial a port nothing is listening on and report a
/// peer that does not exist. A duplicate request is harmless; a missing
/// one is not.
///
/// Returns the hub port still worth advertising, which is nothing when the
/// link could not be carried.
fn peerForward(
    alloc: Allocator,
    a: types.HostArgs,
    master: ?[]const u8,
    socket: []const u8,
    hub_port: []const u8,
    account: *const progress_mod.Progress,
) ![]const u8 {
    if (master == null) {
        // NO MASTER TO ADD IT TO. Every step above opened its own
        // connection, and there is nothing here that could carry a peer
        // link. Said, because the local hub would otherwise be told to
        // dial a port nothing is listening on.
        if (hub_port.len > 0) {
            try io_mod.stderrWriteAll("WARNING: no ControlMaster on ");
            try io_mod.stderrWriteAll(a.host);
            try io_mod.stderrWriteAll(" — the peer link cannot be carried\n");
        }
        return "";
    }
    // NOTHING TO POINT THE LINK AT. `ensureHub` has already said that no
    // hub could be started there and that agents on this host will have no
    // A2A; this branch used to answer "ControlMaster already established
    // (reusing)." — a sentence about a different subject, reassuring, and
    // printed exactly where the operator needed the bad news to stand
    // ([[WI-2026-09-10-003]]).
    if (hub_port.len == 0) return "";
    step(account, "opening the link between the two hubs", "");
    const spec = try std.fmt.allocPrint(alloc, "{d}:localhost:{s}", .{ a.tunnel_port, hub_port });
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "ssh", "-O", "forward", "-S", socket, "-L", spec });
    for (try flags(alloc, a)) |f| try argv.append(alloc, f);
    try argv.append(alloc, try std.fmt.allocPrint(alloc, "{s}@{s}", .{ a.user, a.host }));
    if (connect.runQuietly(argv.items)) {
        try io_mod.stdoutWriteAll(try std.fmt.allocPrint(alloc,
            "ControlMaster reused; peer forward {d} → remote hub {s} ensured.\n",
            .{ a.tunnel_port, hub_port }));
        return hub_port;
    }
    // Already present, or refused. VERIFY RATHER THAN ASSUME: a PEER_PORT
    // nobody is listening on is worse than none.
    if (!listening(a.tunnel_port)) {
        try io_mod.stderrWriteAll(try std.fmt.allocPrint(alloc,
            "WARNING: could not establish the peer forward on {d}\n", .{a.tunnel_port}));
        return "";
    }
    try io_mod.stdoutWriteAll(try std.fmt.allocPrint(alloc,
        "ControlMaster reused; peer forward {d} already present.\n", .{a.tunnel_port}));
    return hub_port;
}

/// `"port":<n>` out of the hub's answer.
fn jsonPort(text: []const u8) []const u8 {
    const key = "\"port\":";
    const at = std.mem.indexOf(u8, text, key) orelse return "";
    var i = at + key.len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    const start = i;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') i += 1;
    return text[start..i];
}

/// IS ANYTHING ANSWERING ON THIS LOOPBACK PORT? The script asked `nc -z`;
/// a connect is the same question without a dependency on which netcat the
/// machine has.
fn listening(port: u16) bool {
    const fd = sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0) catch return false;
    defer sys.close(fd);
    const loopback = [4]u8{ 127, 0, 0, 1 };
    const sa = sys.sockaddr_in.init(@bitCast(loopback), port);
    sys.connect(fd, &sa, @sizeOf(sys.sockaddr_in)) catch return false;
    return true;
}

const testing = std.testing;

test "a platform answer becomes the directory its cross-compile lands in" {
    // EVERY TARGET THE BUILD PRODUCES, not three of them. This named a
    // fixed subset, so it could not have noticed a sixth
    // ([[WI-2026-09-11-003]]).
    for (deploy_targets.all) |t| {
        try testing.expectEqualStrings(t.name, deployDir(t.uname).?);
    }
    // REFUSED RATHER THAN GUESSED. A host this project has no binary for
    // is told so by name, because the alternative is uploading something
    // that cannot run and discovering it at the far end.
    try testing.expect(deployDir("SunOS sparc") == null);
    try testing.expect(deployDir("Linux") == null);
    try testing.expect(deployDir("") == null);
}

test "the probe's answer is read by whole key, not by prefix" {
    const answer =
        \\PLATFORM=Linux x86_64
        \\BIN_MD5=abc123
        \\TI78_MD5=
        \\TIX_MD5=def456
    ;
    try testing.expectEqualStrings("Linux x86_64", probed(answer, "PLATFORM"));
    try testing.expectEqualStrings("abc123", probed(answer, "BIN_MD5"));
    // A FILE THAT IS NOT THERE ANSWERS EMPTY, and empty must not match a
    // local checksum — which is what decides whether anything is sent.
    try testing.expectEqualStrings("", probed(answer, "TI78_MD5"));
    try testing.expectEqualStrings("def456", probed(answer, "TIX_MD5"));
    // `TI78_MD5` starts with neither of these, and `BIN` is a prefix of
    // nothing here: a reader matching on prefix alone would answer for the
    // wrong line.
    try testing.expectEqualStrings("", probed(answer, "TI"));
    try testing.expectEqualStrings("", probed(answer, "MD5"));
    try testing.expectEqualStrings("", probed(answer, "ABSENT"));
}

test "the hub's port is read out of its answer" {
    try testing.expectEqualStrings("9123", jsonPort("{\"port\":9123,\"pid\":42,\"started\":true}"));
    try testing.expectEqualStrings("9000", jsonPort("{\"pid\":1,\"port\": 9000}"));
    // NO PORT IS NOT PORT ZERO. An empty answer is what makes the setup
    // say the host has no A2A rather than advertise a peer link to
    // nothing.
    try testing.expectEqualStrings("", jsonPort("{\"pid\":42}"));
    try testing.expectEqualStrings("", jsonPort(""));
    try testing.expectEqualStrings("", jsonPort("{\"port\":}"));
}

test "an md5 is the one the far side would compute" {
    // THE FAR SIDE RUNS `md5sum` OR `md5 -q`; this side no longer shells
    // out for it. They must agree, so the value is pinned against the
    // known digest of a known string rather than against another
    // implementation of the same function.
    var root: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&root, "/tmp/synapty-md5-{d}", .{std.c.getpid()});
    std.Io.Dir.cwd().createDirPath(io_mod.get(), dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_mod.get(), dir) catch {};
    var pbuf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/abc", .{dir});
    var f = try std.Io.Dir.cwd().createFile(io_mod.get(), path, .{});
    var w = f.writer(io_mod.get(), &.{});
    try w.interface.writeAll("abc");
    f.close(io_mod.get());

    var out: [32]u8 = undefined;
    try testing.expect(md5Of(path, &out));
    try testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", &out);

    // A FILE THAT IS NOT THERE HAS NO CHECKSUM, and must not answer with
    // one: the comparison it feeds decides whether anything is uploaded.
    var missing: [256]u8 = undefined;
    const nope = try std.fmt.bufPrint(&missing, "{s}/not-here", .{dir});
    try testing.expect(!md5Of(nope, &out));
}
