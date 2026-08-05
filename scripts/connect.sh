#!/bin/bash
# Synapty session connect script.
# Usage: connect.sh <agent-id> <host> <port> <user> <tunnel-port> [ssh-key-path] [proxy-jump] [fwd-kind listen target-host target-port ...]
#
# Reuses an existing SSH ControlMaster (set up by setup-host.sh) to
# connect and run synapty with the given agent identity.
set -euo pipefail

AGENT_ID="${1:?Usage: connect.sh <agent-id> <host> <port> <user> <tunnel-port> [ssh-key-path] [proxy-jump] [forwards...]}"
HOST="${2:?Usage: connect.sh <agent-id> <host> <port> <user> <tunnel-port> [ssh-key-path] [proxy-jump] [forwards...]}"
PORT="${3:-22}"
USER="${4:-$(whoami)}"
TUNNEL_PORT="${5:-9000}"
KEY="${6:-}"
PROXY_JUMP="${7:-}"

# Remaining args: forward rules as (kind listen target-host target-port) quads.
FORWARDS=()
shift 7 2>/dev/null || true
while [ "$#" -ge 4 ]; do
    FORWARDS+=("$1" "$2" "$3" "$4")
    shift 4
done

DEST="${USER}@${HOST}"
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

SOCKET="$HOME/.synapty/sockets/${USER}@${HOST}:${PORT}"

# Check if ControlMaster is active; if not, fall back to direct connection with tunnel
if ssh -S "$SOCKET" -O check "$DEST" 2>/dev/null; then
    echo "Using existing tunnel (ControlMaster)..."
    # Forwardings are already established on the master; do not re-add them.
    exec ssh -t -S "$SOCKET" $SSH_FLAGS "$DEST" \
        ".synapty/bin/synapty run --id ${AGENT_ID} --hub 127.0.0.1:${TUNNEL_PORT} -- \$SHELL -l"
else
    echo "No ControlMaster found. Connecting with new tunnel..."
    exec ssh -t -R "${TUNNEL_PORT}:localhost:${TUNNEL_PORT}" "${FORWARD_ARGS[@]}" $SSH_FLAGS "$DEST" \
        ".synapty/bin/synapty run --id ${AGENT_ID} --hub 127.0.0.1:${TUNNEL_PORT} -- \$SHELL -l"
fi
