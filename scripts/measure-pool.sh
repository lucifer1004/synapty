#!/usr/bin/env bash
# Does a connection carrying nothing else actually restore the interactive
# band? ([[RFC-0013]] C-BROKER, [[WI-2026-08-26-001]])
#
# The clause's whole argument rests on a table of numbers, and the table was
# taken against an arrangement that no longer exists — two masters named for
# two traffic classes. What replaced it claims to reach the same outcome by
# observing load instead of naming tenants, and that claim is not verifiable
# from a unit test: the head-of-line blocking is in TCP, below anything a
# fake can stand in for.
#
# WHAT IS MEASURED, and the third column is the one that matters:
#   idle          — a round trip over a quiet master, this host's own baseline
#   shared        — the same round trip WHILE a copy runs on that same master
#   separate      — the same round trip while the copy runs on its own master
#
# A round trip here is `ssh -S <socket> <host> true`: it opens a session
# channel, crosses the link and comes back. NOT `ssh -O check`, which asks
# the local master process for its pid over a unix socket and returns in
# 0.00s against a host 0.55s away — it never leaves this machine.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

HOST="${1:?usage: measure-pool.sh <ssh-host> [megabytes]}"
MB="${2:-60}"

# A SOCKET DIRECTORY OF ITS OWN. Without it this script puts live masters
# beside the ones the human's workbench is using, and its teardown would be
# closing their connections.
DIR="$(mktemp -d -t synapty-measure)"
A="$DIR/a"
B="$DIR/b"
PAYLOAD="$DIR/payload"
REMOTE="/tmp/synapty-measure-$$"

cleanup() {
    ssh -S "$A" -O exit "$HOST" 2>/dev/null
    ssh -S "$B" -O exit "$HOST" 2>/dev/null
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "rm -f '$REMOTE'" 2>/dev/null
    rm -rf "$DIR"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }

# One round trip over a named master, in seconds.
trip() {
    local socket="$1" t0 t1
    t0=$(python3 -c 'import time;print(time.time())')
    ssh -S "$socket" -o BatchMode=yes "$HOST" true >/dev/null 2>&1 || { echo "FAIL"; return; }
    t1=$(python3 -c 'import time;print(time.time())')
    python3 -c "print(f'{$t1-$t0:.2f}')"
}

# The lowest of N, because a baseline is what the link can do rather than
# what it happened to do while something else ran.
quietest() {
    local socket="$1" n="$2" best="" one
    for _ in $(seq "$n"); do
        one=$(trip "$socket")
        [ "$one" = "FAIL" ] && { echo "FAIL"; return; }
        if [ -z "$best" ] || (( $(python3 -c "print(1 if $one < $best else 0)") )); then best="$one"; fi
    done
    echo "$best"
}

say "host: $HOST   payload: ${MB} MB"
say ""

say "opening two masters"
ssh -MNf -S "$A" -o ControlPersist=yes -o BatchMode=yes "$HOST" || { say "FAIL: no master"; exit 1; }
ssh -MNf -S "$B" -o ControlPersist=yes -o BatchMode=yes "$HOST" || { say "FAIL: no second master"; exit 1; }

say "building a ${MB} MB payload"
dd if=/dev/urandom of="$PAYLOAD" bs=1m count="$MB" 2>/dev/null

IDLE=$(quietest "$A" 5)
say ""
say "idle       ${IDLE}s   (quietest of five over master A, nothing else on it)"

# --- shared: the copy rides the SAME master the round trip is measured on
scp -o ControlPath="$A" -o ControlMaster=no -o BatchMode=yes \
    "$PAYLOAD" "$HOST:$REMOTE" >/dev/null 2>&1 &
COPY=$!
C0=$(python3 -c 'import time;print(time.time())')
SHARED_MAX=""
SHARED_N=0
while kill -0 $COPY 2>/dev/null; do
    ONE=$(trip "$A")
    [ "$ONE" = "FAIL" ] && { SHARED_MAX="FAIL"; break; }
    SHARED_N=$((SHARED_N + 1))
    if [ -z "$SHARED_MAX" ] || (( $(python3 -c "print(1 if $ONE > $SHARED_MAX else 0)") )); then
        SHARED_MAX="$ONE"
    fi
done
wait $COPY 2>/dev/null
C1=$(python3 -c 'import time;print(time.time())')
COPY_SHARED=$(python3 -c "print(f'{$C1-$C0:.1f}')")
say "shared     ${SHARED_MAX:-n/a}s   (worst of ${SHARED_N} round trips on A while the copy ran on A; copy took ${COPY_SHARED}s)"
ssh -o BatchMode=yes "$HOST" "rm -f '$REMOTE'" 2>/dev/null

# --- separate: the copy rides master B, the round trip is measured on A
scp -o ControlPath="$B" -o ControlMaster=no -o BatchMode=yes \
    "$PAYLOAD" "$HOST:$REMOTE" >/dev/null 2>&1 &
COPY=$!
C0=$(python3 -c 'import time;print(time.time())')
SEP_MAX=""
SEP_N=0
while kill -0 $COPY 2>/dev/null; do
    ONE=$(trip "$A")
    [ "$ONE" = "FAIL" ] && { SEP_MAX="FAIL"; break; }
    SEP_N=$((SEP_N + 1))
    if [ -z "$SEP_MAX" ] || (( $(python3 -c "print(1 if $ONE > $SEP_MAX else 0)") )); then
        SEP_MAX="$ONE"
    fi
done
wait $COPY 2>/dev/null
C1=$(python3 -c 'import time;print(time.time())')
COPY_SEP=$(python3 -c "print(f'{$C1-$C0:.1f}')")
say "separate   ${SEP_MAX:-n/a}s   (worst of ${SEP_N} round trips on A while the copy ran on B; copy took ${COPY_SEP}s)"

say ""
# THE VERDICT IS THE COMPARISON, NOT ANY ONE NUMBER. What C-BROKER claims
# is that separating the copy brings the interactive round trip back to
# something like its own quiet value, and that sharing does not.
if [ -n "$IDLE" ] && [ -n "$SHARED_MAX" ] && [ -n "$SEP_MAX" ] \
   && [ "$SHARED_MAX" != "FAIL" ] && [ "$SEP_MAX" != "FAIL" ]; then
    python3 - "$IDLE" "$SHARED_MAX" "$SEP_MAX" <<'PY'
import sys
idle, shared, sep = (float(x) for x in sys.argv[1:4])
print(f"sharing costs   x{shared/idle:.1f} of idle")
print(f"separating costs x{sep/idle:.1f} of idle")
print()
if shared > idle * 4 and sep < shared / 2:
    print("C-BROKER holds: sharing stalls the round trip, a connection of its own does not.")
elif shared <= idle * 4:
    print("INCONCLUSIVE: sharing did not stall this link. The clause's premise is not")
    print("reproduced here — either the copy finished too fast or the link is not the")
    print("bottleneck. Try a larger payload before believing either result.")
else:
    print("C-BROKER DOES NOT HOLD HERE: separating did not restore the round trip.")
PY
else
    say "INCONCLUSIVE: a probe failed; nothing above should be read as a result."
fi
