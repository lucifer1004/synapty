#!/bin/bash
# Synapty host setup script.
# Usage: setup-host.sh <host> <port> <user> <tunnel-port> <hub-port> <key|''> <jump|''> [fwd-kind listen target-host target-port ...]
#
# Detects remote platform, uploads the synapty binary (if changed),
# and establishes an SSH ControlMaster with a reverse tunnel.
#
# The binary freshness check ALWAYS runs — even when a ControlMaster is
# already active. The master may outlive a rebuild (ControlPersist=300),
# and a stale remote binary keeps old bugs (e.g. the sa_family_t layout
# bug → EAFNOSUPPORT). Reusing the master keeps the check cheap.
# NOTE: <key> and <jump> are always present ('' when unused) so the
# positional layout is fixed.
#
# ControlPersist=yes, NOT a timeout. The master now carries the PEER LINK
# (a -L forward to the remote host's hub), whose lifetime is "as long as
# this host is peered" — not "as long as someone has a pane open". With
# ControlPersist=300 the master exited five minutes after the last
# interactive session, taking the forward and the peer link with it, so
# cross-machine A2A stopped working for no reason a human could see. The
# workbench closes the master explicitly when it stops peering the host.
set -euo pipefail

# PEER_ID (env, optional): a SUGGESTED LABEL, used only if the remote
# machine has not minted an identity yet. [[RFC-0010]] C-PEER-IDENTITY put
# the naming authority on the machine being named: it mints and persists
# its own id and everyone else accepts what it reports. Provisioning may
# suggest and MUST NOT override — an existing hub keeps its name, and no
# path here advises restarting it to adopt a new one, because another
# workbench may be linked to it and that advice would sever their link.
PEER_ID="${PEER_ID:-}"
HOST="${1:?Usage: setup-host.sh <host> <port> <user> <tunnel-port> <hub-port> <key> <jump> [forwards...]}"
PORT="${2:-22}"
USER="${3:-$(whoami)}"
TUNNEL_PORT="${4:-9000}"
# Arg 5 (local hub port) is retained for positional compatibility but is
# no longer used: under [[ADR-0008]] stage 3b the tunnel points AT the
# remote host's hub, not back at this machine's.
# shellcheck disable=SC2034
HUB_PORT="${5:-9000}"
KEY="${6:-}"
PROXY_JUMP="${7:-}"

# Remaining args: forward rules as (kind listen target-host target-port) quads.
FORWARDS=()
shift 7 2>/dev/null || set --
while [ "$#" -ge 4 ]; do
    FORWARDS+=("$1" "$2" "$3" "$4")
    shift 4
done

DEST="${USER}@${HOST}"
# Robustness (WI-2026-03-31-003): fail fast on unreachable hosts, auto-accept
# new host keys, detect silently dropped connections.
SSH_FLAGS="-p ${PORT} -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15 -o ServerAliveCountMax=3"
SCP_FLAGS="-O -P ${PORT}"
if [ -n "$KEY" ]; then
    SSH_FLAGS="-i ${KEY} ${SSH_FLAGS}"
    SCP_FLAGS="-i ${KEY} ${SCP_FLAGS}"
fi
if [ -n "$PROXY_JUMP" ]; then
    SSH_FLAGS="-J ${PROXY_JUMP} ${SSH_FLAGS}"
    SCP_FLAGS="-J ${PROXY_JUMP} ${SCP_FLAGS}"
fi

# WHAT THIS IS DOING, SAID AS IT HAPPENS ([[WI-2026-08-17-016]]).
#
# This script's stdout is CAPTURED by the workbench and parsed when it is
# already over, so nothing it echoes reaches a human who is waiting — and
# this is the slow half of a connection: a platform probe, a binary
# compared and maybe uploaded, a terminfo, a hub, a peer link. These lines
# go to the connection's account, which the workbench reads while it runs.
# Stdout is left exactly as it was: it is a parsed interface, not prose.
# MILLISECONDS, BECAUSE THIS ACCOUNT HAS MORE THAN ONE WRITER. `date +%s`
# truncates to the second, so a line written 900ms into a second is
# stamped as though it happened at the start of it — and next to the
# workbench's own millisecond stamps that reads as a step happening
# BEFORE the dial that started it, which is what a negative elapsed on
# screen was. macOS ships bash 3.2 (no EPOCHREALTIME) and BSD date has no
# %N; perl is on every host these scripts run on, and the fallback is the
# old truncated stamp rather than no stamp at all.
# POSIX single-quoting for a value that reaches the remote shell as data.
shquote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/'\\\\''/g")"; }

now_ms() {
    perl -MTime::HiRes -e 'printf "%d", Time::HiRes::time()*1000' 2>/dev/null \
        || printf '%s000' "$(date +%s)"
}

say() {
    if [ -n "${SYNAPTY_CONNECT_LOG:-}" ]; then
        printf '%s note %s\n' "$(now_ms)" "$1" >> "$SYNAPTY_CONNECT_LOG"
    fi
}

SOCKET_DIR="$HOME/.synapty/sockets"
SOCKET="${SOCKET_DIR}/${USER}@${HOST}:${PORT}"
mkdir -p "$SOCKET_DIR"

# ---------------------------------------------------------------------------
# Check if ControlMaster is already running
# ---------------------------------------------------------------------------
CM_ACTIVE=false
if ssh -S "$SOCKET" -O check "$DEST" 2>/dev/null; then
    CM_ACTIVE=true
    echo "ControlMaster already active for ${DEST}"
fi

# AN ARRAY, BECAUSE A STRING CANNOT CARRY QUOTING ([[WI-2026-08-17-017]]).
# This was `SSH_CMD="-S '$SOCKET'"` expanded unquoted, which handed ssh a
# path whose first and last characters were apostrophes — no such socket,
# so every one of the ten steps below opened a NEW connection to a host
# that already had one open. Measured on a live master: 2.175s per call
# that way against 0.362s multiplexed, which was most of a 28-second
# reconnection.
#
# The `${arr[@]+"${arr[@]}"}` guard is what makes an empty array safe to
# expand under `set -u` on the bash 3.2 macOS ships — the same guard the
# launch script uses for its forwarding rules. That hazard is real; the
# string was the wrong answer to it.
# THE CONNECTION IS OPENED BEFORE THE THINGS THAT RIDE IT
# ([[WI-2026-08-17-021]]). It used to be opened last, because it carries
# the peer link and which port to forward to is only known once the remote
# hub has answered — so the probe, the hub and the build query each paid a
# full authentication first, ~2.2s against ~0.36s over a master. The
# forward is added to a LIVE master at the end instead, with `ssh -O
# forward`, which is what the already-running-master path has always done.
if ! $CM_ACTIVE; then
    say "opening a connection to this host"
    echo "Starting SSH ControlMaster..."
    # The human's own forwarding rules are known here; only the peer link
    # is not.
    FORWARD_ARGS=()
    i=0
    while [ $((i + 3)) -lt ${#FORWARDS[@]} ]; do
        KIND="${FORWARDS[$i]}"
        LISTEN="${FORWARDS[$((i + 1))]}"
        THOST="${FORWARDS[$((i + 2))]}"
        TPORT="${FORWARDS[$((i + 3))]}"
        case "$KIND" in
            local) FLAG="-L" ;;
            remote) FLAG="-R" ;;
            *) echo "Error: unknown forward kind: $KIND" >&2; exit 1 ;;
        esac
        FORWARD_ARGS+=("$FLAG" "${LISTEN}:${THOST}:${TPORT}")
        i=$((i + 4))
    done
    # A HOST THAT WILL NOT HOLD A CONNECTION IS NOT A FAILURE HERE. Every
    # step below can open its own, slowly, which is what they all did
    # before this existed — so a master that cannot be established costs
    # speed and nothing else.
    if ssh -MNf -S "$SOCKET" \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        -o ControlPersist=yes \
        ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"} \
        $SSH_FLAGS "$DEST"; then
        CM_ACTIVE=true
        echo "ControlMaster established: ${SOCKET}"
    else
        echo "WARNING: could not establish a ControlMaster on ${HOST} — every step will open its own connection" >&2
    fi
fi

# All ssh/scp calls reuse the master when present (no re-auth).
SSH_MASTER=()
if $CM_ACTIVE; then
    SSH_MASTER=(-S "$SOCKET")
fi

# NO SECOND CONNECTION IS OPENED HERE. A host used to gain a "bulk"
# master at setup time, held for a transfer that might never come — and
# copies are a rare event on this bench while the human's port forwards
# are not, so the connection reserved for latency ended up holding the
# continuously-loaded tenant. A host's connections are a pool now and it
# grows when something is observed to need it, which is the workbench's
# job rather than this script's ([[RFC-0013]] C-BROKER).

# ---------------------------------------------------------------------------
# Ask the host everything, once ([[WI-2026-08-17-018]])
# ---------------------------------------------------------------------------
# ONE ROUND TRIP, NOT FOUR. What this needs to know before it can decide
# anything is: what the host is, which binary it already has, and whether
# it already has the terminal description. Those were three separate ssh
# invocations plus a mkdir, and each one is a round trip — measured at
# ~0.36s over a live master and ~2.2s without one. They are one call now,
# and it makes its own directories on the way past.
say "asking this host what it has"
echo "Detecting remote platform..."
PROBE=$(ssh ${SSH_MASTER[@]+"${SSH_MASTER[@]}"} $SSH_FLAGS "$DEST" 'sh -s' <<'PROBE_REMOTE'
sum() {
    if [ ! -f "$1" ]; then echo ""; return; fi
    if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print $1}'; else md5 -q "$1"; fi
}
mkdir -p .synapty/bin .terminfo/78 .terminfo/x
echo "PLATFORM=$(uname -sm)"
echo "BIN_MD5=$(sum .synapty/bin/synapty)"
echo "TI78_MD5=$(sum .terminfo/78/xterm-ghostty)"
echo "TIX_MD5=$(sum .terminfo/x/xterm-ghostty)"
PROBE_REMOTE
)
probed() { printf %s "$PROBE" | sed -n "s/^$1=//p" | head -1; }
REMOTE_PLATFORM="$(probed PLATFORM)"
case "$REMOTE_PLATFORM" in
    "Linux aarch64")  DEPLOY_DIR="linux-aarch64" ;;
    "Linux x86_64")   DEPLOY_DIR="linux-x86_64" ;;
    "Linux riscv64")  DEPLOY_DIR="linux-riscv64" ;;
    "Darwin arm64")   DEPLOY_DIR="macos-aarch64" ;;
    "Darwin x86_64")  DEPLOY_DIR="macos-x86_64" ;;
    *) echo "Error: Unsupported platform: $REMOTE_PLATFORM"
       echo "Supported: Linux/aarch64, Linux/x86_64, Linux/riscv64, Darwin/arm64, Darwin/x86_64"
       exit 1 ;;
esac
echo "Remote platform: ${REMOTE_PLATFORM} -> ${DEPLOY_DIR}"

# ---------------------------------------------------------------------------
# Locate local binary
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_BIN=""
for candidate in \
    "${SCRIPT_DIR}/../zig-out/${DEPLOY_DIR}/synapty" \
    "${SCRIPT_DIR}/../../Resources/deploy/${DEPLOY_DIR}/synapty" \
    "zig-out/${DEPLOY_DIR}/synapty"; do
    if [ -f "$candidate" ]; then
        LOCAL_BIN="$candidate"
        break
    fi
done

if [ -z "$LOCAL_BIN" ]; then
    echo "Error: No binary found for ${DEPLOY_DIR}"
    echo "Run: zig build deploy-${DEPLOY_DIR}"
    exit 1
fi
echo "Local binary: ${LOCAL_BIN}"

# ---------------------------------------------------------------------------
# Upload binary (skip if unchanged) — always runs, even with active master
# ---------------------------------------------------------------------------
LOCAL_MD5=$(md5 -q "$LOCAL_BIN" 2>/dev/null || md5sum "$LOCAL_BIN" | awk '{print $1}')
say "comparing the binary this host has with ours"
REMOTE_MD5="$(probed BIN_MD5)"

BINARY_REPLACED=false
if [ "$LOCAL_MD5" = "$REMOTE_MD5" ]; then
    say "this host already has the current binary"
    echo "Binary unchanged, skipping upload."
else
    BINARY_REPLACED=true
    say "sending the binary to this host"
    echo "Uploading binary..."
    # Remove first — Linux allows unlinking a running executable (it stays in
    # memory), but writes to an active text segment fail with ETXTBSY.
    ssh ${SSH_MASTER[@]+"${SSH_MASTER[@]}"} $SSH_FLAGS "$DEST" "rm -f .synapty/bin/synapty"
    if $CM_ACTIVE; then
        # Transfer through the master connection.
        scp $SCP_FLAGS -o "ControlPath=$SOCKET" -o ControlMaster=auto "$LOCAL_BIN" "$DEST":.synapty/bin/synapty
    else
        scp $SCP_FLAGS "$LOCAL_BIN" "$DEST":.synapty/bin/synapty
    fi
    ssh ${SSH_MASTER[@]+"${SSH_MASTER[@]}"} $SSH_FLAGS "$DEST" "chmod +x .synapty/bin/synapty"
    echo "Upload complete."
fi

# ---------------------------------------------------------------------------
# Deploy ghostty terminfo to the remote host (ghostty#5818)
# ---------------------------------------------------------------------------
# Remote shells (zsh + powerlevel10k etc.) misbehave when the TERM entry
# (xterm-ghostty) is missing on the server: backspace outputs a space
# instead of deleting. The bundled file is a COMPILED terminfo entry, so
# we copy it into the user's terminfo db in BOTH common layouts
# (~/.terminfo/78/… hash and ~/.terminfo/x/… first-letter) — different
# ncurses builds look in different places. connect.sh additionally falls
# back to TERM=xterm-256color when nothing resolves, so this is best-effort.
TERMINFO_SRC=""
for candidate in \
    "${SCRIPT_DIR}/../../Resources/terminfo/78/xterm-ghostty" \
    "${SCRIPT_DIR}/../ghostty/zig-out/share/terminfo/78/xterm-ghostty" \
    "ghostty/zig-out/share/terminfo/78/xterm-ghostty"; do
    if [ -f "$candidate" ]; then
        TERMINFO_SRC="$candidate"
        break
    fi
done

if [ -n "$TERMINFO_SRC" ]; then
    TERMINFO_MD5=$(md5 -q "$TERMINFO_SRC" 2>/dev/null || md5sum "$TERMINFO_SRC" | awk '{print $1}')
    # SENT ONLY WHEN IT IS NOT ALREADY THERE ([[WI-2026-08-17-018]]).
    # This was four round trips — a mkdir, two copies and a verify —
    # executed unconditionally to install a file that had not changed
    # since the last time it was installed, on every connect. Measured at
    # ~9 seconds of a 28-second reconnection. The binary beside it has
    # always compared checksums first; this now does the same, with the
    # answer already in hand from the probe above.
    if [ "$TERMINFO_MD5" = "$(probed TI78_MD5)" ] && [ "$TERMINFO_MD5" = "$(probed TIX_MD5)" ]; then
        say "this host already has the terminal description"
        echo "terminfo installed (~/.terminfo/{78,x}/xterm-ghostty)"
    else
        say "sending the terminal description"
        echo "Deploying ghostty terminfo to remote..."
        if $CM_ACTIVE; then
            scp $SCP_FLAGS -o "ControlPath=$SOCKET" -o ControlMaster=auto "$TERMINFO_SRC" "$DEST":.terminfo/78/xterm-ghostty
            scp $SCP_FLAGS -o "ControlPath=$SOCKET" -o ControlMaster=auto "$TERMINFO_SRC" "$DEST":.terminfo/x/xterm-ghostty
        else
            scp $SCP_FLAGS "$TERMINFO_SRC" "$DEST":.terminfo/78/xterm-ghostty
            scp $SCP_FLAGS "$TERMINFO_SRC" "$DEST":.terminfo/x/xterm-ghostty
        fi
        ssh ${SSH_MASTER[@]+"${SSH_MASTER[@]}"} $SSH_FLAGS "$DEST" "test -f .terminfo/78/xterm-ghostty && test -f .terminfo/x/xterm-ghostty && echo 'terminfo installed (~/.terminfo/{78,x}/xterm-ghostty)'"
    fi
else
    echo "Warning: xterm-ghostty terminfo source not found locally; skipping deploy."
fi

# ---------------------------------------------------------------------------
# Remote hub + peer link ([[ADR-0008]] stage 3b, WI-2026-08-12-008)
#
# The machine that HOSTS agents runs the hub they connect to, so a remote
# host needs one of its own. `hub --ensure` is idempotent (it probes before
# it spawns), which is what makes running it on every setup safe and what
# makes a server reboot self-heal without anyone ssh-ing in.
#
# The tunnel then goes the OTHER WAY than it used to. The old reverse
# tunnel carried remote agents back to the laptop's hub; now each hub is
# local to its agents and the two hubs peer, so we need a FORWARD tunnel
# (-L) giving the local hub a loopback port that reaches the remote one.
# RFC-0009 C-BOUNDARIES: the relay link is authenticated by the transport
# it rides — this SSH channel the human already established — which is why
# there is no credential to configure here.
# ---------------------------------------------------------------------------

# A HUB THAT IS ALREADY RUNNING IS RUNNING THE OLD BINARY.
#
# `hub --ensure` probes for a live hub and leaves it alone, which is what
# makes it safe to run on every connect — and which meant a host kept its
# hub across every upgrade. Measured on a real host: a daemon three days
# behind the workbench rejected every tool added since with a bare
# "unknown tool", and nothing anywhere named the version skew.
#
# The condition is exactly "we just replaced the binary": if the upload
# happened, whatever is running cannot be it. No version probe is needed
# and none would be more reliable.
#
# CONNECT IS THE MOMENT FOR IT. The tunnel and the peer link are being
# rebuilt here anyway, and panes reconnect to whatever hub next binds the
# port with their identity replayed (WI-2026-08-11-017), so the cost is a
# gap rather than a lost session.
if [ "$BINARY_REPLACED" = true ]; then
    # BY PID, FROM THE HUB'S OWN DISCOVERY FILE — never by pattern. A
    # `pkill -f "synapty hub"` issued over ssh matches the shell running
    # it, so it reports success while killing something else; this project
    # has already been bitten by exactly that trap once.
    ssh ${SSH_MASTER[@]+"${SSH_MASTER[@]}"} $SSH_FLAGS "$DEST" 'sh -s' <<'REPLACE_HUB' \
        || echo "WARNING: could not replace the running hub on ${HOST} — it may still be the old binary" >&2
HUB_JSON="$HOME/.config/synapty/machine/hub.json"
[ -f "$HUB_JSON" ] || exit 0
PID=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$HUB_JSON")
[ -n "$PID" ] || exit 0
# A recycled pid must not be killed for having once been the hub.
CMD=$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null || ps -o args= -p "$PID" 2>/dev/null)
case "$CMD" in
    *"synapty hub"*) ;;
    *) exit 0 ;;
esac
kill "$PID" 2>/dev/null || exit 0
i=0
while [ $i -lt 10 ]; do
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.3
    i=$((i + 1))
done
kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null
echo "Replaced the running hub (was pid $PID, older binary)."
REPLACE_HUB
fi

REMOTE_HUB_PORT=""
say "making sure this host has a hub"
ENSURE_CMD=".synapty/bin/synapty hub --ensure"
if [ -n "$PEER_ID" ]; then
    ENSURE_CMD="$ENSURE_CMD --peer-id $(shquote "$PEER_ID")"
fi
if REMOTE_HUB_JSON=$(ssh ${SSH_MASTER[@]+"${SSH_MASTER[@]}"} $SSH_FLAGS "$DEST" "$ENSURE_CMD" 2>/dev/null); then
    REMOTE_HUB_PORT=$(printf %s "$REMOTE_HUB_JSON" | sed -n 's/.*"port":\([0-9][0-9]*\).*/\1/p')
fi
if [ -n "$REMOTE_HUB_PORT" ]; then
    say "this host's hub is ready"
    echo "Remote hub ready on ${HOST}:${REMOTE_HUB_PORT} (loopback there)"
    # WHICH BUILD IS ACTUALLY RUNNING THERE, reported so the workbench can
    # say so rather than leaving the human to infer it from a tool that
    # comes back "unknown".
    #
    # hub.json is written by the hub AT STARTUP, so it describes the
    # PROCESS; the binary on disk describes only what would run next. That
    # distinction is the whole bug — an upload that lands while the old
    # hub keeps running leaves the two disagreeing, and comparing files
    # would report everything fine.
    #
    # Both figures are read on the remote side, so nothing here depends on
    # the two machines agreeing about anything but the string.
    say "asking which build is running there"
    HUB_BUILDS=$(ssh ${SSH_MASTER[@]+"${SSH_MASTER[@]}"} $SSH_FLAGS "$DEST" '
        HUB_JSON="$HOME/.config/synapty/machine/hub.json"
        RUNNING=$(sed -n "s/.*\"build\":\"\([^\"]*\)\".*/\1/p" "$HUB_JSON" 2>/dev/null)
        DEPLOYED=$(.synapty/bin/synapty version 2>/dev/null)
        echo "HUB_BUILD=${RUNNING}"
        echo "HUB_BINARY=${DEPLOYED}"
    ' 2>/dev/null) || HUB_BUILDS=""
    if [ -n "$HUB_BUILDS" ]; then
        printf '%s\n' "$HUB_BUILDS"
    fi
else
    # Honest degradation, matching the tmux-absent precedent: the shell
    # still works, A2A for this host does not, and we say which.
    echo "WARNING: no hub could be started on ${HOST} — agents there will have no A2A" >&2
fi

# ---------------------------------------------------------------------------
# Add the peer link to the connection that has been carrying everything
# ([[WI-2026-08-17-021]])
# ---------------------------------------------------------------------------
say "opening the link between the two hubs"
if $CM_ACTIVE; then
    # A master does NOT carry the forward we are about to advertise just
    # because it exists. One established before peering — or under a
    # different peer port, or at the top of this script, before the remote
    # hub had answered — has no -L for it, and printing PEER_PORT anyway
    # would have the local hub dial a port nothing is listening on and
    # report a peer that does not exist. `ssh -O forward` adds one to a
    # LIVE master, which is now the only case there is.
    # A duplicate request is harmless; a missing one is not.
    if [ -n "$REMOTE_HUB_PORT" ]; then
        if ssh -O forward -S "$SOCKET" -L "${TUNNEL_PORT}:localhost:${REMOTE_HUB_PORT}" \
            $SSH_FLAGS "$DEST" 2>/dev/null; then
            echo "ControlMaster reused; peer forward ${TUNNEL_PORT} → remote hub ${REMOTE_HUB_PORT} ensured."
        else
            # Already present, or refused. Verify rather than assume: a
            # PEER_PORT nobody is listening on is worse than none.
            if ! nc -z 127.0.0.1 "$TUNNEL_PORT" 2>/dev/null; then
                echo "WARNING: could not establish the peer forward on ${TUNNEL_PORT}" >&2
                REMOTE_HUB_PORT=""
            else
                echo "ControlMaster reused; peer forward ${TUNNEL_PORT} already present."
            fi
        fi
    else
        echo "ControlMaster already established (reusing)."
    fi
else
    # NO MASTER TO ADD IT TO. The connection was attempted at the top and
    # could not be made, so every step above opened its own — and there is
    # nothing here that could carry a peer link. Said, because the local
    # hub would otherwise be told to dial a port nothing is listening on.
    if [ -n "$REMOTE_HUB_PORT" ]; then
        echo "WARNING: no ControlMaster on ${HOST} — the peer link cannot be carried" >&2
        REMOTE_HUB_PORT=""
    fi
fi

# Machine-readable tail for the workbench: which loopback port reaches this
# host's hub, so it can tell the LOCAL hub to dial its peer there.
if [ -n "$REMOTE_HUB_PORT" ]; then
    echo "PEER_PORT=${TUNNEL_PORT}"
fi
echo "SETUP_OK"
say "this host is ready"
