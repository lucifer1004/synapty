#!/bin/bash
# Regression test for connect.sh's remote launch construction
# ([[WI-2026-08-12-004]], rewritten for [[WI-2026-08-17-008]]). Nested
# quoting across local shell -> ssh -> remote shell is exactly the kind of
# thing that rots silently, so the EXACT commands are asserted here rather
# than assumed.
set -euo pipefail
cd "$(dirname "$0")/.."

AGENT_ID="host-abc1"; FRESH_AGENT_ID="host-9f01"
# THE LAUNCH BLOCK, READ WHOLE. The end marker is a line connect.sh
# carries for this: the range used to stop at the first `fi` at column 0,
# so any conditional added above the launch silently truncated what this
# test evaluated — and the test then failed on an unbound variable rather
# than on the thing it was written to catch.
launch_block() {
    sed -n '/^REMOTE_ENSURE=/,/^# --- end remote launch construction ---$/p' scripts/connect.sh
}
# shellcheck disable=SC1090
eval "$(launch_block)"

fail() { echo "FAIL: $1" >&2; exit 1; }

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
cat > "$SANDBOX/.synapty/bin/synapty" <<EOF
#!/bin/sh
echo "SYNAPTY: \$*" >> "$SANDBOX/synapty.log"
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
case "$log" in
    *tmux*) fail "the launch still speaks tmux: $log" ;;
esac
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
# THE ACCOUNT GOES TO THE WORKBENCH, NOT ONTO THE PANE
# ([[WI-2026-08-17-016]]). On the pane these words are erased by the
# session's own screen a moment later, which is a flash rather than an
# account — so when a channel is named, nothing is said to stderr and
# every line lands there with a time on it.
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
eval "$(sed -n '/^now_ms()/,/^}/p' scripts/connect.sh)"
# shellcheck disable=SC1090
eval "$(sed -n '/^say()/,/^}/p' scripts/connect.sh)"
# shellcheck disable=SC1090
eval "$(sed -n '/^signal()/,/^}/p' scripts/connect.sh)"

LOG="$SANDBOX/connect.log"
: > "$LOG"
said="$(SYNAPTY_CONNECT_LOG="$LOG" say "reusing this host's open connection" 2>&1 >/dev/null || true)"
case "$said" in
    "") ;;
    *) fail "the account was also printed onto the pane: $said" ;;
esac
line="$(cat "$LOG")"
case "$line" in
    [0-9]*" note reusing this host's open connection") ;;
    *) fail "the account line is not <time> note <what happened>: $line" ;;
esac

# `live` is a fact for the workbench, not a word for the human: a host
# that keeps no session has no screen coming, and the pane is all there
# is to show.
: > "$LOG"
said="$(SYNAPTY_CONNECT_LOG="$LOG" signal live "this host keeps no session between connections" 2>&1 >/dev/null || true)"
case "$said" in
    "") ;;
    *) fail "a signal was printed at the human: $said" ;;
esac
case "$(cat "$LOG")" in
    [0-9]*" live this host keeps no session between connections") ;;
    *) fail "the reveal signal is not a line the workbench can read: $(cat "$LOG")" ;;
esac
# With nobody listening it is silent — there is no workbench to tell.
said="$(signal live "nothing to tell" 2>&1 || true)"
case "$said" in
    "") ;;
    *) fail "a signal reached a human who has no workbench: $said" ;;
esac

# And a word with no channel named — a human in their own terminal —
# still reaches them where it always did.
said="$(say "opening a connection to this host" 2>&1 >/dev/null || true)"
case "$said" in
    *"synapty: opening a connection to this host"*) ;;
    *) fail "with nobody listening the words did not reach the human: $said" ;;
esac

# ---------------------------------------------------------------------------
# Non-durable: the child runs directly, with no holder and nothing to
# attach to ([[RFC-0014]] C-OPT-OUT).
# ---------------------------------------------------------------------------
SYNAPTY_DURABLE=0
# shellcheck disable=SC1090
eval "$(launch_block)"
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
# shellcheck disable=SC1090
eval "$(launch_block)"
# shellcheck disable=SC1090
eval "$(sed -n '/^LOCAL_BIN=/,/^fi$/p' scripts/connect.sh)"
# WHICHEVER NAME IT PICKED. The far side decides between the one to
# return to and the one to start under, so the launch relays a variable
# rather than a name this side chose ([[PaneLaunch]]).
case "$REMOTE_LAUNCH" in
    *'attach --relay --id ${SYNAPTY_SESSION_ID}'*) ;;
    *) fail "the far side does not relay the session it picked: $REMOTE_LAUNCH" ;;
esac
case "$LOCAL_CLIENT" in
    *"attach --id $AGENT_ID --"*) ;;
    *) fail "no local client in front of the transport: $LOCAL_CLIENT" ;;
esac
# NO REMOTE TTY when the holder owns one: ssh would both warn about a
# stdin that is a pipe and, succeeding, wrap the frame stream in a second
# terminal that translates newlines and echoes.
[ "$SSH_TTY_FLAG" = "-T" ] || fail "the relay path still asks ssh for a tty: $SSH_TTY_FLAG"
# Read by the eval'd snippet below, which shellcheck cannot see into.
# shellcheck disable=SC2034
SYNAPTY_DURABLE=0
# shellcheck disable=SC1090
eval "$(sed -n '/^LOCAL_BIN=/,/^fi$/p' scripts/connect.sh)"
[ -z "$LOCAL_CLIENT" ] || fail "a non-durable session was given a reconnecting client: $LOCAL_CLIENT"
# A session with no holder needs the terminal ssh can give it.
[ "$SSH_TTY_FLAG" = "-t" ] || fail "the direct path lost its tty: $SSH_TTY_FLAG"
unset SYNAPTY_DURABLE

# ---------------------------------------------------------------------------
# WHERE A DUPLICATED PANE OPENS ([[RFC-0015]] C-LAYOUT). Splitting copies
# the pane, and a terminal copy is REOPENED in the directory the original
# is standing in — which for a remote pane only the far side can do.
# ---------------------------------------------------------------------------
# Read by the eval'd launch block, which shellcheck cannot see into.
# shellcheck disable=SC2034
SYNAPTY_START_CWD="/srv/build it's here"
# shellcheck disable=SC1090
eval "$(launch_block)"
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
# shellcheck disable=SC1090
eval "$(launch_block)"
case "$REMOTE_LAUNCH" in
    *"cd "*) fail "a pane that asked for no directory got a cd: $REMOTE_LAUNCH" ;;
esac

# ---------------------------------------------------------------------------
# The hub is ensured on the agent's OWN host ([[ADR-0008]] stage 3b).
# ---------------------------------------------------------------------------
case "$REMOTE_ENSURE" in
    *"hub --ensure"*) ;;
    *) fail "the launch does not ensure a hub on the remote host" ;;
esac

echo "connect.sh remote-launch: OK (holder start + relay, local client, reattach, non-durable, own-host hub)"
