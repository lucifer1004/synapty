#!/bin/bash
# Synapty session connect script.
# Usage: connect.sh <agent-id> <host> <port> <user> <tunnel-port> <hub-port> <key|''> <jump|''> [fwd-kind listen target-host target-port ...]
#
# Reuses an existing SSH ControlMaster (set up by setup-host.sh) to
# connect and run synapty with the given agent identity.
# NOTE: <key> and <jump> are always present ('' when unused) so the
# positional layout is fixed.
set -euo pipefail

AGENT_ID="${1:?Usage: connect.sh <agent-id> <host> <port> <user> <tunnel-port> <hub-port> <key> <jump> [forwards...]}"
HOST="${2:?Usage: connect.sh <agent-id> <host> <port> <user> <tunnel-port> <hub-port> <key> <jump> [forwards...]}"
PORT="${3:-22}"
USER="${4:-$(whoami)}"
# Args 5 and 6 are kept for positional compatibility with the workbench's
# invocation and are not read here (setup-host.sh says the same of its
# hub-port argument).
# shellcheck disable=SC2034
# $5 is the hub port; the callers still pass it and nothing here reads it.
# shellcheck disable=SC2034
HUB_PORT="${6:-9000}"
KEY="${7:-}"
PROXY_JUMP="${8:-}"

# THE NAME TO START UNDER, when the one to return to is not there.
#
# In the ENVIRONMENT rather than the positional list, for the reason
# SYNAPTY_BIN and SYNAPTY_DURABLE are: that list ends in a variadic run of
# forwarding rules. REQUIRED rather than defaulted to AGENT_ID — the whole
# point is that a fresh child must not take the recorded name, and a
# default would quietly restore the defect it exists to prevent.
FRESH_AGENT_ID="${SYNAPTY_FRESH_ID:?connect.sh: SYNAPTY_FRESH_ID must name the session to start under when \$AGENT_ID is not running}"

# Remaining args: forward rules as (kind listen target-host target-port) quads.
FORWARDS=()
shift 8 2>/dev/null || set --
while [ "$#" -ge 4 ]; do
    FORWARDS+=("$1" "$2" "$3" "$4")
    shift 4
done

DEST="${USER}@${HOST}"

# WHAT THIS CONNECTION IS DOING, SAID TO THE WORKBENCH ([[WI-2026-08-17-016]]).
#
# NOT ONTO THE PANE. The pane is the session's screen ([[ADR-0012]]), and
# the session's own screen arrives a moment later and takes it — so words
# printed there are displaced by the thing the human was waiting for, and
# all they see is a flash. When the workbench names a channel, the account
# goes there and it shows it in front of the pane until there is a screen
# to show instead. When nobody named one — a human running this in their
# own terminal — it goes where it always went.
#
# MILLISECONDS, BECAUSE THIS ACCOUNT HAS MORE THAN ONE WRITER. `date +%s`
# truncates to the second, so a line written 900ms into a second is
# stamped as though it happened at the start of it — and next to the
# workbench's own millisecond stamps that reads as a step happening
# BEFORE the dial that started it, which is what a negative elapsed on
# screen was. macOS ships bash 3.2 (no EPOCHREALTIME) and BSD date has no
# %N; perl is on every host these scripts run on, and the fallback is the
# old truncated stamp rather than no stamp at all.
now_ms() {
    perl -MTime::HiRes -e 'printf "%d", Time::HiRes::time()*1000' 2>/dev/null \
        || printf '%s000' "$(date +%s)"
}

# THROUGH `signal`, WHICH THIS SCRIPT ALREADY HAD. Two functions here built
# the same line and only one was called the writer; the format is a
# cross-process contract (the CLI, the holder and the workbench each write
# it, and none can import another), so what can have an owner is this
# script's own writing of it ([[WI-2026-08-30-010]]).
say() {
    if [ -n "${SYNAPTY_CONNECT_LOG:-}" ]; then
        signal note "$1"
    else
        printf 'synapty: %s\n' "$1" >&2
    fi
}

# A fact for the workbench rather than a word for the human. Nothing is
# printed when nobody is listening: `live` is not narration, it is the
# signal that the pane is now the thing worth looking at.
signal() {
    if [ -n "${SYNAPTY_CONNECT_LOG:-}" ]; then
        printf '%s %s %s\n' "$(now_ms)" "$1" "${2:-}" >> "$SYNAPTY_CONNECT_LOG"
    fi
}

# Robustness (WI-2026-03-31-003): fail fast on unreachable hosts, auto-accept
# new host keys, detect silently dropped connections so the pane never
# freezes on a dead link, and exit if the reverse tunnel cannot be created.
SSH_FLAGS="-p ${PORT} -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes"
if [ -n "$KEY" ]; then
    SSH_FLAGS="-i ${KEY} ${SSH_FLAGS}"
fi
if [ -n "$PROXY_JUMP" ]; then
    SSH_FLAGS="-J ${PROXY_JUMP} ${SSH_FLAGS}"
fi

# Build forwarding args: -L listen:targetHost:targetPort / -R ...
FORWARD_ARGS=()
i=0
while [ $((i + 3)) -lt ${#FORWARDS[@]} ]; do
    KIND="${FORWARDS[$i]}"
    LISTEN="${FORWARDS[$((i + 1))]}"
    THOST="${FORWARDS[$((i + 2))]}"
    TPORT="${FORWARDS[$((i + 3))]}"
    # Map kind -> ssh flag: local=-L, remote=-R
    case "$KIND" in
        local) FLAG="-L" ;;
        remote) FLAG="-R" ;;
        *) echo "Error: unknown forward kind: $KIND" >&2; exit 1 ;;
    esac
    FORWARD_ARGS+=("$FLAG" "${LISTEN}:${THOST}:${TPORT}")
    i=$((i + 4))
done

# WHICH CONNECTION, CHOSEN BY THE WORKBENCH RATHER THAN DERIVED HERE. A
# host holds as many connections as its load has called for ([[RFC-0013]]
# C-BROKER), so the name below is only the FIRST one's — landing every
# pane on it is how a terminal ends up queued behind a port forward
# carrying a sync. The workbench has the round-trip measurements that say
# which connection is quiet and names it in the environment; falling back
# to the first one is right for a host that holds nothing yet, which is
# also the case the check further down already handles.
SOCKET="${SYNAPTY_SOCKET:-$HOME/.synapty/sockets/${USER}@${HOST}:${PORT}}"

# Remote shell preamble: if the remote host cannot resolve the TERM entry
# that ssh forwarded (xterm-ghostty, or plain "ghostty" depending on the
# launching env), fall back to xterm-256color which every ncurses install
# has. Without a resolvable TERM entry, shells (zsh + powerlevel10k etc.)
# mis-encode backspace/delete — the classic "backspace prints a space" bug
# (ghostty#5818). We probe the ACTUAL $TERM value, not a hardcoded name.
REMOTE_PREAMBLE='case "$TERM" in "") TERM=xterm-256color ;; *) infocmp -x "$TERM" >/dev/null 2>&1 || export TERM=xterm-256color ;; esac;'

# Detachment ([[ADR-0008]] stage 3a, now by way of [[ADR-0012]]): the
# agent runs under a HOLDER — this project's own wrapper, keeping the
# child's pseudoterminal — so the laptop sleeping or the SSH link
# dropping no longer SIGHUPs the work.
#
# WHAT CHANGED FROM tmux, and why it was worth changing: the holder is
# not a terminal server, so the scrollback stays in the client where the
# wheel already works and a resize reflows locally. It answers a
# returning client from the position it stopped reading, so a blip leaves
# no seam; it hands a client that holds nothing the screen; and it is the
# binary the deploy path already installs, so durability stopped
# depending on what a machine happens to have.
# [[ADR-0008]] stage 3b (WI-2026-08-12-008): the agent connects to the hub
# on ITS OWN host over loopback, not back through the reverse tunnel to the
# laptop's hub. That is what lets a remote agent keep working — and keep
# receiving mail from its neighbours on the same box — while the laptop is
# asleep or gone. Cross-machine traffic rides an authenticated peer link
# between the two hubs instead (RFC-0009), so the reverse tunnel leaves the
# A2A path entirely.
#
# `hub --ensure` is idempotent by probing before it spawns: running it on
# every connect is how a server reboot self-heals without anyone ssh-ing in.
# The port comes from ITS output rather than being assumed, because the
# ladder may have moved the hub off 9000.
# SAID AS IT HAPPENS, not summarised afterwards. A first connection does
# several slow things in a row — a platform probe, a binary upload, a
# tunnel, a hub, a session — and a spinner with no words makes all of them
# look like one hang.
#
# THESE ARE SAID ON THE FAR SIDE, so they travel as the transport's
# stderr. The client reads that into the connection's account rather than
# letting it reach the pane ([[WI-2026-08-17-016]]): on the pane they were
# erased by the restoration a moment later, which is a flash rather than
# an account.
REMOTE_ENSURE='SYNAPTY_REMOTE_BIN="$PWD/.synapty/bin/synapty"
printf "synapty: ensuring a hub on this host\\n" >&2
SYNAPTY_HUB_JSON="$(.synapty/bin/synapty hub --ensure 2>/dev/null || true)"
SYNAPTY_REMOTE_PORT="$(printf %s "$SYNAPTY_HUB_JSON" | sed -n "s/.*\"port\":\\([0-9][0-9]*\\).*/\\1/p")"
if [ -z "$SYNAPTY_REMOTE_PORT" ]; then
  echo "synapty: no hub could be started on this host — A2A is unavailable for this agent" >&2
  SYNAPTY_REMOTE_PORT=9000
fi'

# WHERE A DUPLICATED PANE OPENS ([[RFC-0015]] C-LAYOUT). Splitting is
# copying the pane, and a copy of a shell that is not standing where the
# original stands is a different pane wearing its name.
#
# AFTER THE BINARY IS RESOLVED, NEVER BEFORE. Everything here addresses
# `.synapty/bin/synapty` relative to the login directory, so a cd that
# ran first would leave the launch unable to find the thing it launches.
# `|| true`: a directory that is gone since it was read is a reason to
# open at home, not a reason to fail to open.
REMOTE_CD=""
if [ -n "${SYNAPTY_START_CWD:-}" ]; then
  # SINGLE QUOTES, NOT `printf %q`. What reads this is the FAR side's
  # shell, which may be a plain POSIX sh; %q is a bashism that emits
  # $'\''...'\'' for anything unusual and would arrive as a literal.
  REMOTE_CD="cd '$(printf %s "$SYNAPTY_START_CWD" | sed "s/'/'\\\\''/g")' 2>/dev/null || true
"
fi

REMOTE_RUN="\"\${SYNAPTY_REMOTE_BIN}\" run --id ${AGENT_ID} --hub 127.0.0.1:\${SYNAPTY_REMOTE_PORT} --"
# ${SHELL} and the hub port are left for the REMOTE shell to expand (\$
# below): the port is not known here, and the shell is the far side's
# preference rather than ours.
#
# NO STATUS LINE TO SILENCE. tmux's sat at the bottom of the screen,
# which is exactly the region RFC-0004's detection manifests read, and
# turning it off was load-bearing rather than cosmetic. A holder draws
# nothing at all, so that whole class of interference is gone rather than
# suppressed.
# SYNAPTY_DURABLE=0 is the human's own opt-out, set per host in the
# workbench when a plain shell is wanted. Passed in the environment and
# not as an argument: the positional list ends in a variadic run of
# forwarding rules, and squeezing a flag in front of it is how that
# parsing breaks.
#
# NOTHING IS PROBED ANY MORE. Durability used to depend on what the host
# happened to have installed; it now depends on the binary this project
# already requires, so there is no capability to detect and no degraded
# path to explain ([[ADR-0012]]).
if [ "${SYNAPTY_DURABLE:-1}" = "0" ]; then
  REMOTE_LAUNCH="${REMOTE_ENSURE}
${REMOTE_CD}exec ${REMOTE_RUN} \${SHELL:-/bin/sh} -l"
else
  # START, THEN ATTACH, as two requests ([[RFC-0014]] C-START): a start
  # against a name already held fails and says so, which is exactly the
  # reattach path — the failure is expected and the attach that follows
  # is what joins the running session.
  #
  # ONE FAILURE IS EXPECTED AND THE REST ARE NOT ([[WI-2026-08-17-015]]).
  # Exit 3 is the held name, and only that is a reattach. Exit 1 is a
  # session that did not come up, or an init that names the hub it could
  # not reach — reported as a reattach, those produce a pane that says
  # the session is fine, then says there is no such session, then dies,
  # with the one process that knew why having written it to /dev/null.
  # So the start's own words are kept and said.
  # ASKED BEFORE ANYTHING IS STARTED, because afterwards is too late.
  #
  # A RECORDED AGENT ID IS A RECORD AND NOT A GRANT ([[RFC-0015]]
  # C-PERSIST): it may return a pane to a child that SURVIVED, and must
  # not be conferred on one that is newly started — the name routes A2A
  # mail, so a fresh child wearing it receives what was addressed to the
  # one it replaced. Starting under it and reading the exit code afterwards
  # cannot prevent that: by then the child has the name.
  #
  # TWO NAMES ARE SENT AND THIS SIDE PICKS. The workbench cannot ask first
  # — the answer is here and restore must not block on a connection
  # ([[RFC-0015]] C-UNARCHIVE) — so it hands over the one to RETURN to and
  # the one to START under. It does not need to be told which was used:
  # only one of them can exist, and the registration says which one did.
  REMOTE_LAUNCH="${REMOTE_ENSURE}
${REMOTE_CD}if \"\${SYNAPTY_REMOTE_BIN}\" sessions --id ${AGENT_ID} >/dev/null 2>&1; then
  SYNAPTY_SESSION_ID=${AGENT_ID}
  printf 'synapty: returning to the session already running here\\n' >&2
else
  SYNAPTY_SESSION_ID=${FRESH_AGENT_ID}
  SYNAPTY_START_ERR=\"\$(\"\${SYNAPTY_REMOTE_BIN}\" run --hold --detach --id \${SYNAPTY_SESSION_ID} --hub 127.0.0.1:\${SYNAPTY_REMOTE_PORT} -- \${SHELL:-/bin/sh} -l 2>&1 >/dev/null)\"
  SYNAPTY_START_CODE=\$?
  case \${SYNAPTY_START_CODE} in
    0) printf 'synapty: started a session on this host\\n' >&2 ;;
    *) printf 'synapty: could not start a session on this host (exit %s): %s\\n' \"\${SYNAPTY_START_CODE}\" \"\${SYNAPTY_START_ERR}\" >&2 ;;
  esac
fi
exec \"\${SYNAPTY_REMOTE_BIN}\" attach --relay --id \${SYNAPTY_SESSION_ID}"
fi
# --- end remote launch construction ---
# READ BY [[scripts/test-connect-launch.sh]], which evals everything from
# REMOTE_ENSURE= down to this line to assert the exact commands the far
# side receives. It used to stop at the first `fi` at column 0, which made
# adding any conditional above this point silently truncate the block the
# test was checking — the test then failed on an unbound variable rather
# than on anything it was written to catch.

# THE CLIENT IS ON THIS SIDE ([[WI-2026-08-17-009]]). The far end relays
# frames and remembers nothing; this end owns the terminal and counts what
# it has rendered, which is the only count that can be trusted — bytes
# that died in a broken pipe were sent and never seen, and resuming from
# the sender's number would leave a hole nothing announced.
#
# SYNAPTY_BIN rides in the environment for the same reason SYNAPTY_DURABLE
# does: the positional list ends in a variadic run of forwarding rules.
LOCAL_BIN="${SYNAPTY_BIN:-synapty}"
# NO REMOTE TTY WHEN THE HOLDER OWNS ONE. `-t` asks sshd for a
# pseudoterminal, and with the local client in front the transport's
# stdin is a pipe — so ssh both warns about it and, if it succeeded,
# would wrap the frame stream in a second terminal that translates
# newlines and echoes. The pty that matters is the holder's, on the far
# side of the relay ([[WI-2026-08-17-009]]).
if [ "${SYNAPTY_DURABLE:-1}" = "0" ]; then
  # Nothing to reconnect to: a non-durable session ends with its
  # connection by definition ([[RFC-0014]] C-OPT-OUT), so the ssh runs
  # directly with no client in front of it — and it needs the terminal
  # that the holder would otherwise have provided.
  LOCAL_CLIENT=""
  SSH_TTY_FLAG="-t"
  # AND NOTHING WILL EVER PAINT. There is no holder to hand a screen
  # back, so no client says the pane has something on it; without this
  # the workbench would show progress in front of a working terminal
  # until it gave up on the silence ([[WI-2026-08-17-016]]).
  signal live "this host keeps no session between connections"
else
  LOCAL_CLIENT="$LOCAL_BIN attach --id ${AGENT_ID} --"
  SSH_TTY_FLAG="-T"
fi

# WHICH CONNECTION IS RE-READ ON EVERY ATTEMPT, not fixed at launch.
#
# The client in front of this already reconnects: it spawns the transport,
# and when the transport dies it waits a second and spawns it again, in the
# same process and the same pty — which is why a dropped link leaves the
# pane's scrollback where it was. But it spawns the SAME argv, so a socket
# baked into that argv is a connection this pane can never leave.
#
# A host holds as many connections as its load has called for ([[RFC-0013]]
# C-BROKER), and a pane that is already open when a port forward starts
# moving data needs to be able to move off it. So the transport resolves
# the socket from a FILE each time it starts, and records its own pid: the
# workbench migrates a pane by writing a different socket there and ending
# the transport. The client's existing reconnect does the rest, and the
# holder on the far side resumes it from where it stopped reading.
#
# The client stays transport-agnostic — it runs a command and knows nothing
# about ControlPaths — because the re-resolution happens in the shell it
# spawns rather than inside it.
# Check if ControlMaster is active; if not, fall back to direct connection with tunnel
if ssh -S "$SOCKET" -O check "$DEST" 2>/dev/null; then
    say "reusing this host's open connection"
    # Forwardings are already established on the master; do not re-add them.
    if [ -n "${SYNAPTY_SOCKET_FILE:-}" ]; then
        # THE WORKBENCH NAMED THE FILE, and that one file is the whole
        # record: the pool counts it, this transport re-reads it on every
        # attempt, and a migration is one write to it. Nothing derives a
        # second path to the same fact.
        mkdir -p "$(dirname "$SYNAPTY_SOCKET_FILE")"
        printf %s "$SOCKET" > "$SYNAPTY_SOCKET_FILE"
        exec $LOCAL_CLIENT bash -c 'printf %s "$$" > "$2"; exec ssh -S "$(cat "$1")" "${@:3}"' \
            synapty-pane-transport "$SYNAPTY_SOCKET_FILE" "${SYNAPTY_PID_FILE:-/dev/null}" \
            $SSH_TTY_FLAG $SSH_FLAGS "$DEST" \
            "$REMOTE_PREAMBLE $REMOTE_LAUNCH"
    fi
    # NOBODY NAMED ONE, so this pane is not in the pool and cannot be
    # moved — run without the indirection rather than invent a path the
    # workbench does not know to look at. A second deriver of one name is
    # how the two copies this replaced came to disagree.
    exec $LOCAL_CLIENT ssh $SSH_TTY_FLAG -S "$SOCKET" $SSH_FLAGS "$DEST" \
        "$REMOTE_PREAMBLE $REMOTE_LAUNCH"
else
    say "opening a connection to this host"
    # macOS ships bash 3.2: expanding an empty array under `set -u`
    # ("${FORWARD_ARGS[@]}") errors with "unbound variable". Use the
    # ${var[@]+...} guard so an empty array expands to nothing.
    # NO A2A tunnel here. Under [[ADR-0008]] stage 3b the agent connects
    # to the hub on its OWN host over loopback, so nothing needs
    # forwarding for it to work. The cross-machine PEER link is set up by
    # setup-host.sh on the ControlMaster, which is the branch above; this
    # fallback therefore gives a working agent with LOCAL A2A only, and
    # cross-machine messaging starts once the master exists. Keeping the
    # old reverse tunnel here would forward a port nothing reads.
    exec $LOCAL_CLIENT ssh $SSH_TTY_FLAG ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"} $SSH_FLAGS "$DEST" \
        "$REMOTE_PREAMBLE $REMOTE_LAUNCH"
fi
