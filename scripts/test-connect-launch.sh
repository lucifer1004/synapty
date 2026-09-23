#!/bin/bash
# Regression test for the remote launch a pane's connection builds
# ([[WI-2026-08-12-004]], rewritten for [[WI-2026-08-17-008]], moved off
# `connect.sh` by [[ADR-0020]]). Nested quoting across local process ->
# ssh -> remote shell is exactly the kind of thing that rots silently, so
# the EXACT commands are asserted here rather than assumed.
set -euo pipefail
cd "$(dirname "$0")/.."

AGENT_ID="host-abc1"; FRESH_AGENT_ID="host-9f01"
# THE BINARY UNDER TEST. It builds the far side's script, assembles ssh,
# and stands in for nothing here — the fake further down stands in for the
# CLIENT only.
REAL_BIN="$PWD/zig-out/bin/synapty"
[ -x "$REAL_BIN" ] || { echo "FAIL: build $REAL_BIN first (zig build)" >&2; exit 1; }
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
# THE FAR SIDE'S SCRIPT, ASKED OF THE THING THAT BUILDS IT ([[ADR-0020]]).
#
# This used to `sed` a line range out of `connect.sh` and `eval` it, which
# is a shape rather than a boundary: the file's own comments record one
# occasion when the range slid onto unrelated code and the test then failed
# on an unbound variable instead of on what it was written to catch. There
# is no range to slide now — the question is put to the binary, and its
# answer was compared byte for byte against the shell's on all six shapes
# before the shell's was deleted.
remote_launch() {   # $1 = SYNAPTY_DURABLE, $2 = start cwd (optional)
    if [ -n "${2:-}" ]; then
        SYNAPTY_DURABLE="$1" "$REAL_BIN" connect --print-remote \
            --id "$AGENT_ID" --fresh-id "$FRESH_AGENT_ID" \
            --host example.test --user someone --cwd "$2"
    else
        SYNAPTY_DURABLE="$1" "$REAL_BIN" connect --print-remote \
            --id "$AGENT_ID" --fresh-id "$FRESH_AGENT_ID" \
            --host example.test --user someone
    fi
}
REMOTE_LAUNCH="$(remote_launch "${SYNAPTY_DURABLE:-1}" "${SYNAPTY_START_CWD:-}")"



SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/.synapty/bin"

# The fake answers `hub --ensure` with a port DIFFERENT from 9000, so an
# assertion that the agent uses it cannot pass by accidentally matching a
# hardcoded default. Everything else it logs to a FILE: `run --hold` is
# invoked with its output redirected away, so a stdout-based fake would be
# blind to exactly the call this test exists to assert.
#
# `run --hold` FAILS here, which is the reattach path: a start against a
# name already held is refused ([[RFC-0014]] C-START), and the attach that
# follows is what joins the running session. A fake that always succeeded
# would leave that path untested.
# THE REAL BINARY, FOR THE ONE VERB THE FAKE MUST NOT STAND IN FOR.
# `signal` formats its lines through `synapty account` ([[ADR-0020]]), so a
# fake that swallowed it would leave every assertion about the account
# reading an empty file and passing for the wrong reason. The fake stands
# in for the CLIENT; the account is the binary's own job and it does it
# here too.

cat > "$SANDBOX/.synapty/bin/synapty" <<EOF
#!/bin/sh
echo "SYNAPTY: \$*" >> "$SANDBOX/synapty.log"
case "\$1" in
  # THE FAKE STANDS IN FOR THE CLIENT, NOT FOR THE CONNECTION. The account
  # and the dial are the binary's own work and it does them here too;
  # attaching is what this fake exists to be, so a durable case does not
  # dial a stub for real and retry against it forever.
  #
  # NO BACKTICKS IN THIS HEREDOC. It is unquoted, so the shell writing it
  # runs them: a comment mentioning the verb in backticks executed that
  # verb while the file was being created.
  account|connect) exec "$REAL_BIN" "\$@" ;;
esac
case "\$1 \$2" in
  "hub --ensure") echo '{"port":9123,"pid":4242,"started":true}' ; exit 0 ;;
esac
case "\$1 \$2 \$3" in
  # WHETHER THE NAME TO RETURN TO IS RUNNING. The launch asks this
  # BEFORE it starts anything, because a recorded id must not be
  # conferred on a fresh child ([[RFC-0015]] C-PERSIST).
  "sessions --id $AGENT_ID") exit "\${FAKE_SESSION_STATUS:-1}" ;;
esac
case "\$1" in
  run)
    # A REAL START COMPLAINS ON STDERR before it exits non-zero, and the
    # whole point of the branch under test is what becomes of that.
    [ -n "\${FAKE_START_MESSAGE:-}" ] && echo "synapty run --hold --detach: \${FAKE_START_MESSAGE}" >&2
    exit "\${FAKE_START_STATUS:-0}" ;;
esac
exit 0
EOF
chmod +x "$SANDBOX/.synapty/bin/synapty"

run_launch() {
    rm -f "$SANDBOX/synapty.log"
    (cd "$SANDBOX" && SHELL=/bin/zsh bash -c "$1") >/dev/null 2>&1 || true
    cat "$SANDBOX/synapty.log"
}

# ---------------------------------------------------------------------------
# Durable, NOTHING TO RETURN TO: the name to return to is asked about
# first, and a holder is started under the OTHER one.
#
# A RECORDED AGENT ID IS A RECORD AND NOT A GRANT ([[RFC-0015]]
# C-PERSIST): it returns a pane to a child that SURVIVED and must not be
# conferred on one that is newly started, because that name routes A2A
# mail. Starting under it and reading the exit code afterwards cannot
# prevent it — by then the child has the name.
# ---------------------------------------------------------------------------
log="$(run_launch "$REMOTE_LAUNCH")"

case "$log" in
    *"sessions --id $AGENT_ID"*) ;;
    *) fail "the launch started something without asking what was there: $log" ;;
esac
case "$log" in
    *"run --hold --detach --id $FRESH_AGENT_ID"*) ;;
    *) fail "no holder was started under the fresh id: $log" ;;
esac
case "$log" in
    *"run --hold --detach --id $AGENT_ID"*)
        fail "a fresh child was handed the identity of the one it replaced: $log" ;;
esac
# $SHELL is expanded by the REMOTE shell, never left for something further
# down the line to interpret.
case "$log" in
    *'-- /bin/zsh -l'*) ;;
    *) fail "\$SHELL was not expanded before the holder saw it: $log" ;;
esac
# The hub port comes from `hub --ensure`'s output, not from a default: the
# ladder may have moved the hub off 9000.
case "$log" in
    *"--hub 127.0.0.1:9123"*) ;;
    *) fail "the agent was not pointed at the port hub --ensure reported: $log" ;;
esac
# The FAR side relays; the client that attaches is local, and is
# asserted separately below ([[WI-2026-08-17-009]]).
case "$log" in
    *"attach --relay --id $FRESH_AGENT_ID"*) ;;
    *) fail "the far side does not relay the session it started: $log" ;;
esac
# NO TMUX GUARD HERE, and its absence is deliberate. One stood on this
# line watching `$log` — which is the FAKE binary's own record, every
# entry of which begins "SYNAPTY: " followed by argv. A relapse into
# [[ADR-0012]]'s shape would invoke `tmux` DIRECTLY, never touching the
# fake and never reaching that file, so the guard could not fire for the
# regression it named. Measured with a launch script in the pre-ADR-0012
# shape: the assertion passed ([[WI-2026-09-11-002]]).
#
# What the far side actually runs is `$REMOTE_LAUNCH`, asserted from here
# down; a guard belongs there or nowhere, and tmux has been gone from
# the product since ADR-0012, so it is nowhere.
# SAID AS IT HAPPENS. A first connection does several slow things in a
# row, and a spinner with no words makes all of them look like one hang.
case "$REMOTE_LAUNCH" in
    *"synapty: ensuring a hub on this host"*) ;;
    *) fail "the launch does not say it is ensuring a hub" ;;
esac
case "$REMOTE_LAUNCH" in
    *"started a session on this host"*) ;;
    *) fail "the launch does not say when it starts a session" ;;
esac
case "$REMOTE_LAUNCH" in
    *"returning to the session already running here"*) ;;
    *) fail "the launch does not distinguish a reattach" ;;
esac

# ---------------------------------------------------------------------------
# Reattach: the name to return to IS running there, so nothing is started
# and the pane rejoins it. This is the ordinary reconnect, not an error
# path — and it is the one case where the recorded id is used, because
# here it re-associates a pane with a child that survived rather than
# conferring a name on a new one.
# ---------------------------------------------------------------------------
rm -f "$SANDBOX/synapty.log"
said="$( (cd "$SANDBOX" && SHELL=/bin/zsh FAKE_SESSION_STATUS=0 bash -c "$REMOTE_LAUNCH") 2>&1 >/dev/null || true )"
log="$(cat "$SANDBOX/synapty.log")"
case "$log" in
    *"attach --relay --id $AGENT_ID"*) ;;
    *) fail "a live session was not rejoined: $log" ;;
esac
case "$log" in
    *"run --hold --detach"*)
        fail "a second holder was started beside a live session: $log" ;;
esac
case "$said" in
    *"returning to the session already running here"*) ;;
    *) fail "a live session was not described as a reattach: $said" ;;
esac

# ---------------------------------------------------------------------------
# A START THAT DID NOT HAPPEN SAYS SO ([[WI-2026-08-17-015]]). Only the
# held name is a reattach; every other failure is a session that is not
# there, and the reason belongs to the human rather than to /dev/null —
# reported as a reattach, it produced a pane that said the session was
# fine, then that there was no such session, and then died.
# ---------------------------------------------------------------------------
rm -f "$SANDBOX/synapty.log"
said="$( (cd "$SANDBOX" && SHELL=/bin/zsh FAKE_START_STATUS=1 FAKE_START_MESSAGE="the session did not come up" \
    bash -c "$REMOTE_LAUNCH") 2>&1 >/dev/null || true )"
case "$said" in
    *"returning to the session already running here"*)
        fail "a start that failed was described as a reattach: $said" ;;
esac
case "$said" in
    *"the session did not come up"*) ;;
    *) fail "the start's own words were discarded: $said" ;;
esac
case "$said" in
    *"exit 1"*) ;;
    *) fail "the failure did not carry its exit code: $said" ;;
esac
# And the attach still runs, ON THE NAME THE START WAS FOR: a start can
# fail because the session came up a moment after the wait for it gave up.
log="$(cat "$SANDBOX/synapty.log")"
case "$log" in
    *"attach --relay --id $FRESH_AGENT_ID"*) ;;
    *) fail "a failed start stopped the attach that might still have worked: $log" ;;
esac



# ---------------------------------------------------------------------------
# Non-durable: the child runs directly, with no holder and nothing to
# attach to ([[RFC-0014]] C-OPT-OUT).
# ---------------------------------------------------------------------------
SYNAPTY_DURABLE=0
REMOTE_LAUNCH="$(remote_launch "${SYNAPTY_DURABLE:-1}" "${SYNAPTY_START_CWD:-}")"
log="$(run_launch "$REMOTE_LAUNCH")"
case "$log" in
    *"--hold"*) fail "a host with durability off still started a holder: $log" ;;
esac
case "$log" in
    *"attach"*) fail "a host with durability off still attached: $log" ;;
esac
case "$log" in
    *"run --id $AGENT_ID"*) ;;
    *) fail "the non-durable path did not run the agent directly: $log" ;;
esac

# ---------------------------------------------------------------------------
# The client is LOCAL: the far side relays, and this side owns the
# terminal ([[WI-2026-08-17-009]]).
# ---------------------------------------------------------------------------
unset SYNAPTY_DURABLE
REMOTE_LAUNCH="$(remote_launch "${SYNAPTY_DURABLE:-1}" "${SYNAPTY_START_CWD:-}")"
# WHICHEVER NAME IT PICKED. The far side decides between the one to
# return to and the one to start under, so the launch relays a variable
# rather than a name this side chose ([[PaneLaunch]]).
unset SYNAPTY_DURABLE
REMOTE_LAUNCH="$(remote_launch "${SYNAPTY_DURABLE:-1}" "${SYNAPTY_START_CWD:-}")"
case "$REMOTE_LAUNCH" in
    *'attach --relay --id ${SYNAPTY_SESSION_ID}'*) ;;
    *) fail "the far side does not relay the session it picked: $REMOTE_LAUNCH" ;;
esac

# ---------------------------------------------------------------------------
# WHO GOES IN FRONT OF THE TRANSPORT, AND WHICH TERMINAL IT ASKS FOR.
#
# ASKED OF THE BINARY, WHICH DECIDES IT ([[ADR-0020]]). This used to `eval`
# a range out of the script and read the variables it set — which broke the
# moment the script's shape changed, and could only ever check what the
# shell would have done. `--print` is the same question put to the thing
# that answers it now, and [[ADR-0020]] requires it to be answerable
# without making a connection.
# ---------------------------------------------------------------------------
plan() {   # $1 = SYNAPTY_DURABLE, prints the handover then the ssh
    SYNAPTY_DURABLE="$1" SYNAPTY_SOCKET="$SANDBOX/no-such.sock" \
        "$REAL_BIN" connect --print --id "$AGENT_ID" --host example.test \
        --user someone --port 22 --remote "$REMOTE_LAUNCH"
}
durable_plan="$(plan 1)"
case "$durable_plan" in
    *"attach --id $AGENT_ID --"*) ;;
    *) fail "no local client in front of the transport: $durable_plan" ;;
esac
# NO REMOTE TTY when the holder owns one: ssh would both warn about a
# stdin that is a pipe and, succeeding, wrap the frame stream in a second
# terminal that translates newlines and echoes.
case "$durable_plan" in
    *"ssh -T "*) ;;
    *) fail "the relay path still asks ssh for a tty: $durable_plan" ;;
esac

direct_plan="$(plan 0)"
case "$direct_plan" in
    *"attach --id"*) fail "a non-durable session was given a reconnecting client: $direct_plan" ;;
esac
# A session with no holder needs the terminal ssh can give it.
case "$direct_plan" in
    *"ssh -t "*) ;;
    *) fail "the direct path lost its tty: $direct_plan" ;;
esac
# AND THE FAR SIDE'S SCRIPT SURVIVES AS ONE ARGUMENT. It is a whole shell
# program — several lines, with single quotes of its own — so what proves
# it was not split is its LAST characters arriving immediately before the
# closing quote of one argument. Comparing the printed form against the
# raw string cannot work: the printed form escapes the quotes the script
# contains, which is the whole point of printing it that way.
printf '%s\n' "$direct_plan" \
    | grep -qF 'attach --relay --id ${SYNAPTY_SESSION_ID}'"'" \
    || fail "the remote script did not reach ssh whole: $direct_plan"

# ---------------------------------------------------------------------------
# A FORWARDING RULE EITHER REACHES SSH OR STOPS THE DIAL.
#
# BOTH SUBCOMMANDS ANSWER THE SAME INPUT THE SAME WAY. `host-master` said
# which rule and exited 2; `connect` did `orelse continue` and dialled a
# pane whose forwarding was simply absent — and `connect` is the path the
# human watches ([[WI-2026-09-10-002]]).
# ---------------------------------------------------------------------------
fwd_plan() {   # $1 = the --forward argument
    SYNAPTY_DURABLE=0 SYNAPTY_SOCKET="$SANDBOX/no-such.sock" \
        "$REAL_BIN" connect --print --id "$AGENT_ID" --host example.test \
        --user someone --port 22 --remote 'true' --forward "$1" 2>&1
}
master_plan() {   # $1 = the --forward argument
    "$REAL_BIN" host-master --print --host example.test --user someone \
        --forward "$1" 2>&1
}

# The empty target the model documents as localhost, and the IPv6 literal
# the editor lets a human type: both are shapes the workbench produces.
#
# CAPTURED ONCE, AND THE MESSAGE SHOWS WHAT FAILED. Each of these ran
# `fwd_plan` twice — once for the test and once inside the failure text —
# so a message reported a DIFFERENT RUN than the one that failed, which is
# the shape this whole round has been removing ([[WI-2026-09-11-013]]).
said="$(fwd_plan 'local:8080::80')"
case "$said" in
    *"-L 8080:localhost:80"*) ;;
    *) fail "an empty target did not become localhost: $said" ;;
esac
said="$(fwd_plan 'local:8080:[::1]:80')"
case "$said" in
    *"8080:[::1]:80"*) ;;
    *) fail "a bracketed IPv6 target did not reach ssh: $said" ;;
esac

# ONE BAD RULE, NOT FIVE, AND THE POINT IS THE TWO CALLERS.
#
# What only this layer can show is that `connect` and `host-master` answer
# the SAME input the same way — the disagreement [[WI-2026-09-10-002]] was
# about, where one exited 2 and the other dialled a pane with no `-L` in
# it. Which rules the parser refuses is a question about
# `Forward.parse`, and `connect.zig` asks it directly of the function, for
# all five shapes, without a subprocess. Ten spawns here re-proved that
# slowly and kept a second copy of its table ([[WI-2026-09-11-013]]).
bad='local:8080:::1:80'
out="$(fwd_plan "$bad")" && fail "a bad rule still dialled: $bad -> $out"
rc=$?
[ "$rc" = 2 ] || fail "connect answered $rc rather than 2 for $bad"
case "$out" in
    *"not a forwarding: $bad"*) ;;
    *) fail "connect did not name the rule it refused: $out" ;;
esac
case "$out" in
    *" ssh "*|ssh\ *) fail "connect refused a rule and dialled anyway: $out" ;;
esac

mout="$(master_plan "$bad")" && fail "host-master accepted $bad"
mrc=$?
[ "$mrc" = "$rc" ] \
    || fail "the two callers answered one rule differently: connect $rc, host-master $mrc"
case "$mout" in
    *"not a forwarding: $bad"*) ;;
    *) fail "host-master did not name the rule it refused: $mout" ;;
esac

# ---------------------------------------------------------------------------
# WHERE A DUPLICATED PANE OPENS ([[RFC-0015]] C-LAYOUT). Splitting copies
# the pane, and a terminal copy is REOPENED in the directory the original
# is standing in — which for a remote pane only the far side can do.
# ---------------------------------------------------------------------------
SYNAPTY_START_CWD="/srv/build it's here"
REMOTE_LAUNCH="$(remote_launch "${SYNAPTY_DURABLE:-1}" "${SYNAPTY_START_CWD:-}")"
case "$REMOTE_LAUNCH" in
    *"cd '/srv/build it'\\''s here'"*) ;;
    *) fail "the starting directory did not survive quoting: $REMOTE_LAUNCH" ;;
esac
# AFTER THE BINARY IS RESOLVED, NEVER BEFORE: everything here addresses
# the binary relative to the login directory, so a cd that ran first would
# leave the launch unable to find what it launches.
case "$REMOTE_LAUNCH" in
    *'SYNAPTY_REMOTE_BIN="$PWD/.synapty/bin/synapty"'*"cd '/srv/build"*) ;;
    *) fail "the cd runs before the binary is resolved: $REMOTE_LAUNCH" ;;
esac
log="$(run_launch "$REMOTE_LAUNCH")"
case "$log" in
    *"run --hold --detach --id $FRESH_AGENT_ID"*) ;;
    *) fail "a starting directory stopped the holder from starting: $log" ;;
esac

# NO DIRECTORY IS THE ORDINARY CASE and must add nothing at all — a bare
# `cd` would send every pane that did not ask to the home directory it was
# already going to, and an empty one would send it to the filesystem root.
unset SYNAPTY_START_CWD
REMOTE_LAUNCH="$(remote_launch "${SYNAPTY_DURABLE:-1}" "${SYNAPTY_START_CWD:-}")"
case "$REMOTE_LAUNCH" in
    *"cd "*) fail "a pane that asked for no directory got a cd: $REMOTE_LAUNCH" ;;
esac

# ---------------------------------------------------------------------------
# The hub is ensured on the agent's OWN host ([[ADR-0008]] stage 3b).
# ---------------------------------------------------------------------------
case "$REMOTE_LAUNCH" in
    *"hub --ensure"*) ;;
    *) fail "the launch does not ensure a hub on the remote host" ;;
esac

# ---------------------------------------------------------------------------
# WHAT BECAME OF A NON-DURABLE CONNECTION, said by the only process that
# can see it.
#
# On a host that keeps no session there is no client in front of ssh, so
# ssh IS the pane's child — and its death was said to be indistinguishable
# from the human typing `exit`, both arriving as the pane's child dying
# with libghostty's exit code always zero (every pane is spawned through
# `/usr/bin/login`). ssh(1) says otherwise: "ssh exits with the exit status
# of the remote command or with 255 if an error occurred". The script is
# standing right there when it exits and could not look only because it
# `exec`ed ([[WI-2026-09-09-004]]).
#
# RUN WHOLE, NOT eval'd IN PIECES. `handover` is outside the range the
# other cases here extract, and a second sed range would be a second thing
# to keep in step with the file. A stubbed `ssh` on PATH drives the real
# script instead.
# ---------------------------------------------------------------------------
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/ssh" <<'EOF'
#!/bin/sh
# The ControlMaster probe (`-O check`) fails by default so the dial takes
# the branch that opens its own connection; a case that needs a LIVE
# master — the only branch that writes the pool's records — sets
# FAKE_MASTER_UP=1. Everything else is the transport itself.
for a in "$@"; do
  [ "$a" = "check" ] && { [ "${FAKE_MASTER_UP:-0}" = 1 ] && exit 0; exit 1; }
done
exit "${FAKE_SSH_STATUS:-0}"
EOF
chmod +x "$SANDBOX/bin/ssh"

run_connect() {   # $1 = ssh's exit status, $2 = SYNAPTY_DURABLE
    ACCT="$SANDBOX/account-$1-$2.log"
    : > "$ACCT"
    FAKE_SSH_STATUS="$1" SYNAPTY_DURABLE="$2" \
        SYNAPTY_CONNECT_LOG="$ACCT" \
        SYNAPTY_BIN="$SANDBOX/.synapty/bin/synapty" \
        PATH="$SANDBOX/bin:$PATH" HOME="$SANDBOX" \
        "$REAL_BIN" connect --id "$AGENT_ID" --fresh-id "$FRESH_AGENT_ID" \
        --host example.test --port 22 --user someone \
        >/dev/null 2>"$SANDBOX/stderr.log" || true
    cat "$ACCT"
}

acct="$(run_connect 255 0)"
case "$acct" in
    *"end link_severed"*) ;;
    *) fail "a link that dropped was not told apart from a shell that ended: $acct" ;;
esac

# ---------------------------------------------------------------------------
# THE ACCOUNT GOES TO THE WORKBENCH, NOT ONTO THE PANE
# ([[WI-2026-08-17-016]]), AND THE BINARY FORMATS IT ([[ADR-0020]]).
#
# ASSERTED ON A REAL RUN. This used to `eval` three `sed` ranges out of the
# script — `now_ms`, `say`, `signal` — and call them here. Two of the three
# no longer exist, and an arrangement that reaches its subject by line
# ranges is how moving the binary's resolution broke this file silently.
# The run above already exercises all of it.
# ---------------------------------------------------------------------------
# EVERY LINE, NOT ONLY THE ONE THIS CASE CAME FOR: a writer that formats
# one kind correctly and another wrongly is what having ONE implementation
# is supposed to make impossible, so all of them are checked.
bad="$(printf '%s\n' "$acct" | grep -vcE '^[0-9]{13} [a-z_]+( |$)' || true)"
[ "$bad" = "0" ] || fail "not every line is <milliseconds> <kind> <text>: $acct"
case "$acct" in
    *" note opening a connection to this host"*) ;;
    *) fail "the script's own words did not reach the account: $acct" ;;
esac

# AND NOTHING WAS SAID AT THE HUMAN. On the pane these words are erased by
# the session's own screen a moment later, which is a flash rather than an
# account — so with a channel named, stderr stays empty of them.
case "$(cat "$SANDBOX/stderr.log")" in
    *"synapty: opening a connection"*)
        fail "the account was also printed onto the pane: $(cat "$SANDBOX/stderr.log")" ;;
esac

# AND WITH NO CHANNEL NAMED the words still reach the human where they
# always did, because WHERE a line goes is still the script's decision —
# only the formatting of it moved.
said="$(SYNAPTY_DURABLE=0 FAKE_SSH_STATUS=0 \
    SYNAPTY_BIN="$SANDBOX/.synapty/bin/synapty" PATH="$SANDBOX/bin:$PATH" HOME="$SANDBOX" \
    "$REAL_BIN" connect --id "$AGENT_ID" --fresh-id "$FRESH_AGENT_ID" \
    --host example.test --port 22 --user someone 2>&1 >/dev/null || true)"
case "$said" in
    *"synapty: opening a connection to this host"*) ;;
    *) fail "with nobody listening the words did not reach the human: $said" ;;
esac

# NO PERL IS INVOLVED IN TELLING THE TIME any more, and the assertion for
# that is the one above rather than a stub. The stamp used to come from
# `perl -MTime::HiRes` because macOS ships bash 3.2 with no EPOCHREALTIME
# and BSD `date` has no %N, and the fallback when perl was absent was a
# stamp truncated to the second — which reads as a step happening BEFORE
# the dial that started it. A thirteen-digit stamp is that outcome; perl
# was only ever one means to it, and a stub watching for a call the binary
# cannot make would be a green assertion that can never fail.

acct="$(run_connect 0 0)"
case "$acct" in
    *"end child_exited"*) ;;
    *) fail "a remote shell the human exited was not reported as one: $acct" ;;
esac
case "$acct" in
    *"link_severed"*) fail "an ordinary exit was reported as a dropped link: $acct" ;;
esac

# AND A DURABLE HOST SAYS NOTHING HERE, because the client in front of ssh
# is the thing that knows — whether the session was displaced, gone, or
# ended — and this script execs out of the way for it.
acct="$(run_connect 255 1)"
# THE POSITIVE FIRST, so the negative below is a statement about a run
# that happened. An empty account satisfies "no end line" perfectly, and
# an empty account is what every way of this failing to run at all
# produces ([[WI-2026-09-10-004]]).
case "$acct" in
    *" note opening a connection to this host"*) ;;
    *) fail "the durable dial wrote nothing to the account: $acct" ;;
esac
case "$acct" in
    *" end "*) fail "the dial spoke over the client that owns this answer: $acct" ;;
esac

# ---------------------------------------------------------------------------
# THE TWO RECORDS THE POOL COUNTS ON, WRITTEN BY THE DIAL THAT MAKES THEM.
#
# A pane rides one of a host's connections, and moving it between them is
# one write to the socket file plus a signal to the transport — so the pool
# needs the transport's PID, and the transport is the only process that
# knows it. The workbench names both files in the environment; the dial
# passes the socket one to the transport and forgot the pid one, so
# `migratePane` failed its first guard every time and a pane stayed pinned
# to a saturated connection for its whole life ([[WI-2026-09-09-014]]).
#
# ASSERTED TOGETHER, because the defect was one of a pair going missing.
# ---------------------------------------------------------------------------
PIDFILE="$SANDBOX/tenant.pid"; SOCKFILE="$SANDBOX/tenant"
rm -f "$PIDFILE" "$SOCKFILE"
ACCT="$SANDBOX/records.log"; : > "$ACCT"
FAKE_MASTER_UP=1 SYNAPTY_DURABLE=0 FAKE_SSH_STATUS=0 \
    SYNAPTY_CONNECT_LOG="$ACCT" \
    SYNAPTY_BIN="$SANDBOX/.synapty/bin/synapty" \
    SYNAPTY_SOCKET="$SANDBOX/live.sock" \
    SYNAPTY_SOCKET_FILE="$SOCKFILE" SYNAPTY_PID_FILE="$PIDFILE" \
    PATH="$SANDBOX/bin:$PATH" HOME="$SANDBOX" \
    "$REAL_BIN" connect --id "$AGENT_ID" --fresh-id "$FRESH_AGENT_ID" \
    --host example.test --port 22 --user someone >/dev/null 2>&1 || true

[ -s "$SOCKFILE" ] || fail "the pool's record of which connection this pane rides was not written"
[ -s "$PIDFILE" ] \
    || fail "the transport did not record its pid, so the pane can never be moved"
grep -qE '^[0-9]+$' "$PIDFILE" || fail "the pid record is not a pid: $(cat "$PIDFILE")"

echo "connect: remote launch + dial OK (holder start + relay, local client, reattach, non-durable, own-host hub, non-durable outcome)"
