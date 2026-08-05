#!/bin/bash
# Synapty host setup script.
# Usage: setup-host.sh <host> <port> <user> <tunnel-port> <key|''> <jump|''> [fwd-kind listen target-host target-port ...]
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
set -euo pipefail

HOST="${1:?Usage: setup-host.sh <host> <port> <user> <tunnel-port> <key> <jump> [forwards...]}"
PORT="${2:-22}"
USER="${3:-$(whoami)}"
TUNNEL_PORT="${4:-9000}"
KEY="${5:-}"
PROXY_JUMP="${6:-}"

# Remaining args: forward rules as (kind listen target-host target-port) quads.
FORWARDS=()
shift 6 2>/dev/null || set --
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

# All ssh/scp calls reuse the master when present (no re-auth).
# NOTE: with `set -u`, expanding an empty array ("${SSH_MASTER[@]}")
# errors, so we build a plain string instead and use eval-free $SSH_CMD.
SSH_CMD=""
if $CM_ACTIVE; then
    SSH_CMD="-S '$SOCKET'"
fi

# ---------------------------------------------------------------------------
# Detect remote platform
# ---------------------------------------------------------------------------
echo "Detecting remote platform..."
REMOTE_PLATFORM=$(ssh $SSH_CMD $SSH_FLAGS "$DEST" "uname -sm")
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
ssh $SSH_CMD $SSH_FLAGS "$DEST" "mkdir -p .synapty/bin"

LOCAL_MD5=$(md5 -q "$LOCAL_BIN" 2>/dev/null || md5sum "$LOCAL_BIN" | awk '{print $1}')
REMOTE_MD5=$(ssh $SSH_CMD $SSH_FLAGS "$DEST" "md5sum .synapty/bin/synapty 2>/dev/null | awk '{print \$1}' || md5 -q .synapty/bin/synapty 2>/dev/null" || echo "")

if [ "$LOCAL_MD5" = "$REMOTE_MD5" ]; then
    echo "Binary unchanged, skipping upload."
else
    echo "Uploading binary..."
    # Remove first — Linux allows unlinking a running executable (it stays in
    # memory), but writes to an active text segment fail with ETXTBSY.
    ssh $SSH_CMD $SSH_FLAGS "$DEST" "rm -f .synapty/bin/synapty"
    if $CM_ACTIVE; then
        # Transfer through the master connection.
        scp $SCP_FLAGS -o "ControlPath=$SOCKET" -o ControlMaster=auto "$LOCAL_BIN" "$DEST":.synapty/bin/synapty
    else
        scp $SCP_FLAGS "$LOCAL_BIN" "$DEST":.synapty/bin/synapty
    fi
    ssh $SSH_CMD $SSH_FLAGS "$DEST" "chmod +x .synapty/bin/synapty"
    echo "Upload complete."
fi

# ---------------------------------------------------------------------------
# Establish ControlMaster with reverse tunnel (only if not already active)
# ---------------------------------------------------------------------------
if $CM_ACTIVE; then
    echo "ControlMaster already established (reusing)."
else
    echo "Starting SSH ControlMaster with reverse tunnel (port ${TUNNEL_PORT})..."
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
    ssh -MNf -S "$SOCKET" -R "${TUNNEL_PORT}:localhost:${TUNNEL_PORT}" \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        -o ControlPersist=300 \
        ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"} \
        $SSH_FLAGS "$DEST"
    echo "ControlMaster established: ${SOCKET}"
fi
echo "SETUP_OK"
