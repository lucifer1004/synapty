#!/bin/bash
# Synapty host setup script.
# Usage: setup-host.sh <host> <port> <user> <tunnel-port> [ssh-key-path]
#
# Detects remote platform, uploads the synapty binary (if changed),
# and establishes an SSH ControlMaster with a reverse tunnel.
set -euo pipefail

HOST="${1:?Usage: setup-host.sh <host> <port> <user> <tunnel-port> [ssh-key-path]}"
PORT="${2:-22}"
USER="${3:-$(whoami)}"
TUNNEL_PORT="${4:-9000}"
KEY="${5:-}"

DEST="${USER}@${HOST}"
SSH_FLAGS="-p ${PORT}"
SCP_FLAGS="-O -P ${PORT}"
if [ -n "$KEY" ]; then
    SSH_FLAGS="-i ${KEY} ${SSH_FLAGS}"
    SCP_FLAGS="-i ${KEY} ${SCP_FLAGS}"
fi

SOCKET_DIR="$HOME/.synapty/sockets"
SOCKET="${SOCKET_DIR}/${USER}@${HOST}:${PORT}"
mkdir -p "$SOCKET_DIR"

# ---------------------------------------------------------------------------
# Check if ControlMaster is already running
# ---------------------------------------------------------------------------
if ssh -S "$SOCKET" -O check "$DEST" 2>/dev/null; then
    echo "ControlMaster already active for ${DEST}"
    echo "SETUP_OK"
    exit 0
fi

# ---------------------------------------------------------------------------
# Detect remote platform
# ---------------------------------------------------------------------------
echo "Detecting remote platform..."
REMOTE_PLATFORM=$(ssh $SSH_FLAGS "$DEST" "uname -sm")
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
# Upload binary (skip if unchanged)
# ---------------------------------------------------------------------------
ssh $SSH_FLAGS "$DEST" "mkdir -p .synapty/bin"

LOCAL_MD5=$(md5 -q "$LOCAL_BIN" 2>/dev/null || md5sum "$LOCAL_BIN" | awk '{print $1}')
REMOTE_MD5=$(ssh $SSH_FLAGS "$DEST" "md5sum .synapty/bin/synapty 2>/dev/null | awk '{print \$1}' || md5 -q .synapty/bin/synapty 2>/dev/null" || echo "")

if [ "$LOCAL_MD5" = "$REMOTE_MD5" ]; then
    echo "Binary unchanged, skipping upload."
else
    echo "Uploading binary..."
    # Remove first — Linux allows unlinking a running executable (it stays in
    # memory), but writes to an active text segment fail with ETXTBSY.
    ssh $SSH_FLAGS "$DEST" "rm -f .synapty/bin/synapty"
    scp $SCP_FLAGS "$LOCAL_BIN" "$DEST":.synapty/bin/synapty
    ssh $SSH_FLAGS "$DEST" "chmod +x .synapty/bin/synapty"
    echo "Upload complete."
fi

# ---------------------------------------------------------------------------
# Establish ControlMaster with reverse tunnel
# ---------------------------------------------------------------------------
echo "Starting SSH ControlMaster with reverse tunnel (port ${TUNNEL_PORT})..."
ssh -MNf -S "$SOCKET" -R "${TUNNEL_PORT}:localhost:${TUNNEL_PORT}" \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o ControlPersist=300 \
    $SSH_FLAGS "$DEST"
echo "ControlMaster established: ${SOCKET}"
echo "SETUP_OK"
