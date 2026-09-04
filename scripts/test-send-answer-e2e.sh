#!/usr/bin/env bash
# What `synapty send` says when the hub says no ([[RFC-0009]] C-DELIVERY,
# [[WI-2026-08-27-001]] item 2).
#
# THIS IS A SHELL TEST BECAUSE THE DEFECT IS AN EXIT CODE. The out-of-pane
# path wrote its envelope, printed "sent to X" and exited 0 whatever the hub
# answered — for a typo the hub had already answered `unknown` about. A unit
# test cannot see that: `runSend` ends in `std.process.exit`, so the thing
# under test is the process.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BIN=./zig-out/bin/synapty
[ -x "$BIN" ] || { echo "FAIL: build $BIN first (zig build)"; exit 1; }

TMP="/tmp/synapty-send-e2e-$$"
mkdir -p "$TMP"
# A CONFIG ROOT AND A PORT OF ITS OWN, so this never speaks to the hub the
# human's workbench is using — a send in the wrong place is mail in the
# wrong mailbox, which is the very defect above.
export SYNAPTY_CONFIG_ROOT="$TMP/config"
mkdir -p "$SYNAPTY_CONFIG_ROOT"
# NOT IN A PANE. The in-pane path reads the answer and always did; this
# test exists for the path taken when there is no pane daemon to route
# through, so the variable that selects it must be absent.
unset SYNAPTY_SOCK
HUB_PORT="${HUB_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')}"
export SYNAPTY_HUB_PORT="$HUB_PORT"
HUBPID=""
cleanup() { [ -n "$HUBPID" ] && kill "$HUBPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }

$BIN hub --port "$HUB_PORT" --strict-port --no-state \
    --discovery-path "$TMP/hub.json" > "$TMP/hub.log" 2>&1 &
HUBPID=$!
for _ in $(seq 50); do
    nc -z 127.0.0.1 "$HUB_PORT" 2>/dev/null && break
    sleep 0.1
done
nc -z 127.0.0.1 "$HUB_PORT" 2>/dev/null || fail "the hub never came up (see $TMP/hub.log)"

# --- a name nobody registered: the hub answers `unknown`, and so must this
OUT=$($BIN send nobody-here-0000 hello 2>"$TMP/err"); RC=$?
if [ "$RC" -eq 0 ]; then
    fail "sending to an unregistered name exited 0, saying: ${OUT}"
fi
grep -q "unknown" "$TMP/err" || fail "the failure did not name the hub's status: $(cat "$TMP/err")"
echo "ok: a send to a name nobody registered fails, and names the status"

# --- a registered name: still succeeds, so the fix is not "refuse everything"
$BIN run --hold --detach --id recipient-e2e --hub "127.0.0.1:${HUB_PORT}" -- /bin/sh -c 'sleep 30' \
    > "$TMP/run.log" 2>&1
for _ in $(seq 50); do
    $BIN agents 2>/dev/null | grep -q recipient-e2e && break
    sleep 0.1
done
$BIN agents 2>/dev/null | grep -q recipient-e2e || fail "the recipient never registered (see $TMP/run.log)"

OUT=$($BIN send recipient-e2e hello 2>"$TMP/err2"); RC=$?
[ "$RC" -eq 0 ] || fail "a send to a registered agent failed: rc=$RC $(cat "$TMP/err2")"
printf '%s' "$OUT" | grep -q "delivered" || fail "a successful send did not report its status: ${OUT}"
echo "ok: a send to a registered agent succeeds, and reports what became of it"

# --- recv --wait waits for as long as it takes ([[WI-2026-09-02-036]]). The
# --- ten-second reply deadline is for a daemon that has wedged; a wait that
# --- has heard nothing for eleven seconds is doing its job. The pane daemon
# --- is the held session's wrapper; its socket is named after its pid.
RPID=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$SYNAPTY_CONFIG_ROOT/machine/sessions/recipient-e2e.json" | head -1)
[ -n "$RPID" ] || fail "no pid in the recipient's record"
RSOCK="/tmp/synapty-${RPID}.sock"
for _ in $(seq 50); do [ -S "$RSOCK" ] && break; sleep 0.1; done
[ -S "$RSOCK" ] || fail "the recipient's pane socket never appeared at $RSOCK"
SYNAPTY_SOCK="$RSOCK" $BIN recv > /dev/null 2>&1 || true   # drain the hello above
( sleep 11; $BIN send recipient-e2e late-mail > /dev/null 2>&1 ) &
LATE=$!
T0=$(date +%s)
OUT=$(SYNAPTY_SOCK="$RSOCK" timeout 40 $BIN recv --wait 2>"$TMP/err3"); RC=$?
ELAPSED=$(( $(date +%s) - T0 ))
wait "$LATE" 2>/dev/null || true
[ "$RC" -eq 0 ] || fail "recv --wait exited $RC after ${ELAPSED}s: $(cat "$TMP/err3")"
printf '%s' "$OUT" | grep -q "late-mail" || fail "recv --wait returned without the late mail: ${OUT}"
[ "$ELAPSED" -ge 10 ] || fail "recv --wait returned after ${ELAPSED}s, before the mail could have been sent"
echo "ok: recv --wait waited ${ELAPSED}s for mail sent late, and returned it"

# Ended through the interface, not by killing the process behind it.
$BIN end --id recipient-e2e >/dev/null 2>&1 || true

# EVERY TOOL VERB SAYS THE SAME THING WHEN THE HUB IS NOT THERE.
#
# [[RFC-0003]] C-CLI-TOOLS asks the CLI for a human-readable error, and one
# verb did not give one: `ask` connected with a bare `try`, so with no hub
# it propagated ConnectionRefused out of main as a stack trace over this
# repository's own source paths. The two round trips have one owner now
# ([[WI-2026-08-30-006]]); this is the half of that a unit test cannot
# reach, because the failure path exits the process.
# A port nothing in this file uses, checked rather than assumed.
DEAD_PORT=19417
nc -z 127.0.0.1 "$DEAD_PORT" 2>/dev/null && fail "something is listening on the port this test needs empty"
for verb in "task list" "task show 1" "ask q --option a --option b"; do
    OUT=$(SYNAPTY_AGENT_ID=e2e-probe SYNAPTY_HUB_PORT=$DEAD_PORT $BIN $verb 2>&1); RC=$?
    printf '%s' "$OUT" | grep -q "cannot reach the hub" \
        || fail "'$verb' with no hub did not say so in a sentence: $OUT"
    printf '%s' "$OUT" | grep -q "sys.zig\|0x[0-9a-f]\{6\}" \
        && fail "'$verb' with no hub dumped a stack trace: $OUT"
    [ "$RC" -eq 4 ] || fail "'$verb' with no hub exited $RC, not 4"
done
echo "ok: every tool verb answers an absent hub with a sentence and exit 4"

echo "ALL OK (exit 0 means the message arrived)"
