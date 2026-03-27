#!/bin/bash
# Synapty remote deploy script.
# Usage: deploy.sh <agent-id> <host> [port] [user] [ssh-key-path]
#
# Detects the remote platform via uname, selects the matching binary,
# scp's it to the remote host, and connects with a reverse tunnel.
set -euo pipefail

AGENT_ID="${1:?Usage: deploy.sh <agent-id> <host> [port] [user] [ssh-key-path]}"
HOST="${2:?Usage: deploy.sh <agent-id> <host> [port] [user] [ssh-key-path]}"
PORT="${3:-22}"
USER="${4:-$(whoami)}"
KEY="${5:-}"

DEST="${USER}@${HOST}"
SSH_FLAGS="-p ${PORT}"
SCP_FLAGS="-P ${PORT}"
if [ -n "$KEY" ]; then
    SSH_FLAGS="-i ${KEY} ${SSH_FLAGS}"
    SCP_FLAGS="-i ${KEY} ${SCP_FLAGS}"
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
# Locate the local binary (bundled in .app or development build)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_BIN=""
for candidate in \
    "${SCRIPT_DIR}/../deploy/${DEPLOY_DIR}/synapty" \
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
# Deploy and connect
# ---------------------------------------------------------------------------
echo "Deploying synapty (${DEPLOY_DIR}) to ${HOST}..."
ssh $SSH_FLAGS "$DEST" "mkdir -p .synapty/bin"

# Only upload if the binary changed (compare md5 checksums).
LOCAL_MD5=$(md5 -q "$LOCAL_BIN" 2>/dev/null || md5sum "$LOCAL_BIN" | awk '{print $1}')
REMOTE_MD5=$(ssh $SSH_FLAGS "$DEST" "md5sum .synapty/bin/synapty 2>/dev/null | awk '{print \$1}'" || echo "")

if [ "$LOCAL_MD5" = "$REMOTE_MD5" ]; then
    echo "Binary unchanged, skipping upload."
else
    echo "Uploading binary..."
    scp $SCP_FLAGS "$LOCAL_BIN" "$DEST":.synapty/bin/synapty
    ssh $SSH_FLAGS "$DEST" "chmod +x .synapty/bin/synapty"
fi

echo "Connecting with reverse tunnel..."
exec ssh -t -R 9000:localhost:9000 $SSH_FLAGS "$DEST" \
    ".synapty/bin/synapty run --id ${AGENT_ID} --hub 127.0.0.1:9000 -- bash -l"
