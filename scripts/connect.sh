#!/bin/bash
# Synapty session connect script.
# Usage: connect.sh <agent-id> <host> <port> <user> <tunnel-port> [ssh-key-path]
#
# Reuses an existing SSH ControlMaster (set up by setup-host.sh) to
# connect and run synapty with the given agent identity.
set -euo pipefail

AGENT_ID="${1:?Usage: connect.sh <agent-id> <host> <port> <user> <tunnel-port> [ssh-key-path]}"
HOST="${2:?Usage: connect.sh <agent-id> <host> <port> <user> <tunnel-port> [ssh-key-path]}"
PORT="${3:-22}"
USER="${4:-$(whoami)}"
TUNNEL_PORT="${5:-9000}"
KEY="${6:-}"

DEST="${USER}@${HOST}"
# Robustness (WI-2026-03-31-003): fail fast on unreachable hosts, auto-accept
# new host keys, detect silently dropped connections so the pane never
# freezes on a dead link, and exit if the reverse tunnel cannot be created.
SSH_FLAGS="-p ${PORT} -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes"
if [ -n "$KEY" ]; then
    SSH_FLAGS="-i ${KEY} ${SSH_FLAGS}"
fi

SOCKET="$HOME/.synapty/sockets/${USER}@${HOST}:${PORT}"

# Check if ControlMaster is active; if not, fall back to direct connection with tunnel
if ssh -S "$SOCKET" -O check "$DEST" 2>/dev/null; then
    echo "Using existing tunnel (ControlMaster)..."
    exec ssh -t -S "$SOCKET" $SSH_FLAGS "$DEST" \
        ".synapty/bin/synapty run --id ${AGENT_ID} --hub 127.0.0.1:${TUNNEL_PORT} -- \$SHELL -l"
else
    echo "No ControlMaster found. Connecting with new tunnel..."
    exec ssh -t -R "${TUNNEL_PORT}:localhost:${TUNNEL_PORT}" $SSH_FLAGS "$DEST" \
        ".synapty/bin/synapty run --id ${AGENT_ID} --hub 127.0.0.1:${TUNNEL_PORT} -- \$SHELL -l"
fi
