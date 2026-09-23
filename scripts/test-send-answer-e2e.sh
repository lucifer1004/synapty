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
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

TMP="/tmp/synapty-send-e2e-$$"
mkdir -p "$TMP"
# A CONFIG ROOT AND A PORT OF ITS OWN, so this never speaks to the hub the
# human's workbench is using — a send in the wrong place is mail in the
# wrong mailbox, which is the very defect above.
isolate_config "$TMP"
# NOT IN A PANE. The in-pane path reads the answer and always did; this
# test exists for the path taken when there is no pane daemon to route
# through, so the variable that selects it must be absent.
unset SYNAPTY_SOCK
HUBPID=""
cleanup() {
    [ -n "$HUBPID" ] && kill "$HUBPID" 2>/dev/null
    [ -n "${NODUR:-}" ] && kill "$NODUR" 2>/dev/null
    $BIN end --id undurable-e2e >/dev/null 2>&1
    rm -rf "$TMP"
}
trap cleanup EXIT

start_hub "$TMP"
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
RSOCK="$(pane_socket_path "$RPID")"
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

# --- ONE STRING IS ONE IDENTIFIER ([[WI-2026-09-09-001]]).
#
# Session paths are folded ([[holder.canonical]]) because the filesystem
# under them is case-insensitive, so `--id Foo` and `--id foo` are one
# session. The hub's registry is a plain hash keyed on the raw id, and the
# name escaped into it without passing through any path builder — so a
# session started as `Mixed` registered as `Mixed` while its socket, lock,
# record and `sessions` row all said `mixed`. The same string was one
# identifier to the human and two to the program.
$BIN run --hold --detach --id Mixed-Case-E2E --hub "127.0.0.1:${HUB_PORT}" -- /bin/sh -c 'sleep 30' \
    > "$TMP/mixed.log" 2>&1
for _ in $(seq 50); do
    $BIN agents 2>/dev/null | grep -q mixed-case-e2e && break
    sleep 0.1
done
$BIN agents 2>/dev/null | grep -q mixed-case-e2e \
    || fail "the hub knows this session under a name its own files do not use: $($BIN agents 2>&1)"
[ -f "$SYNAPTY_CONFIG_ROOT/machine/sessions/mixed-case-e2e.json" ] \
    || fail "the record is not under the folded name"
OUT=$($BIN send mixed-case-e2e hello 2>"$TMP/err-mixed"); RC=$?
# NO BACKTICKS IN A MESSAGE. These are inside double quotes, so the shell
# RAN the word this sentence is about: zsh printed "command not found:
# sessions" and the message arrived with a hole where its subject had
# been ([[WI-2026-09-11-002]]). shellcheck classes it SC2006 at style
# level, below this repo's `-S warning` gate, so nothing caught it.
[ "$RC" -eq 0 ] || fail "a send to the name 'sessions' shows failed: rc=$RC $(cat "$TMP/err-mixed")"
printf '%s' "$OUT" | grep -q "delivered" || fail "the send was not delivered: ${OUT}"
$BIN end --id Mixed-Case-E2E >/dev/null 2>&1 || true
echo "ok: a session started under a mixed-case name is one identifier, folded"


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

# --- A HUB THAT CANNOT KEEP THE PROMISE DOES NOT SAY THE WORD
#
# `delivered` is defined as "hosted locally; queued in the local mailbox"
# ([[RFC-0008]] C-MAILBOX), and `mailboxDeliver` says why the order
# matters: "persist BEFORE the caller acks: queued has to mean durable, or
# the ack is a promise the hub cannot keep across a restart". The order
# was right and the ANSWER was discarded — `persistLocked` returned
# nothing — so a hub whose state file could not be written answered
# `delivered` to every send ([[WI-2026-09-13-002]]).
#
# THE SHELL IS WHERE THIS CAN BE ASKED. A failing persist logs at `err`,
# and Zig's test runner counts every error log and fails the run on a
# non-zero count — so no in-process test can take this path. Here the log
# is just output, and what is under test is the exit code and the sentence,
# which is this file's whole reason for existing.
#
# A STATE PATH WHOSE PARENT IS A REGULAR FILE: every write fails, the way
# a full disk or a mistyped `--state-path` does.
DTMP="$TMP/durability"
mkdir -p "$DTMP"
printf 'not a directory\n' > "$DTMP/blocker"
# AND THE FLAG IS WHAT THIS HUB BINDS. `start_hub` exported
# SYNAPTY_HUB_PORT for the FIRST hub, and the variable used to be applied
# over `--port` — so this second hub bound the first one's port and
# refused with `AddressInUse` against a number it was never given. That
# is how the precedence defect was found: by a test that needed a second
# hub ([[WI-2026-09-13-002]]).
DEAD_HUB_PORT="$(free_port)"
$BIN hub --port "$DEAD_HUB_PORT" --strict-port \
    --state-path "$DTMP/blocker/state.json" \
    --discovery-path "$DTMP/hub.json" > "$DTMP/hub.log" 2>&1 &
NODUR=$!
for _ in $(seq 40); do nc -z 127.0.0.1 "$DEAD_HUB_PORT" 2>/dev/null && break; sleep 0.25; done
nc -z 127.0.0.1 "$DEAD_HUB_PORT" 2>/dev/null \
    || fail "the undurable hub never came up: $(cat "$DTMP/hub.log" 2>&1)"
grep -q "listening on 127.0.0.1:${DEAD_HUB_PORT}\b" "$DTMP/hub.log" \
    || fail "the hub bound a port nobody asked it for, with SYNAPTY_HUB_PORT set: $(cat "$DTMP/hub.log")"

$BIN run --hold --detach --id undurable-e2e --hub "127.0.0.1:${DEAD_HUB_PORT}" -- /bin/sh -c 'sleep 30' \
    > "$DTMP/run.log" 2>&1
for _ in $(seq 50); do
    SYNAPTY_HUB_PORT="$DEAD_HUB_PORT" $BIN agents 2>/dev/null | grep -q undurable-e2e && break
    sleep 0.1
done
SYNAPTY_HUB_PORT="$DEAD_HUB_PORT" $BIN agents 2>/dev/null | grep -q undurable-e2e \
    || fail "the recipient never registered with the undurable hub (see $DTMP/run.log)"

OUT=$(SYNAPTY_HUB_PORT="$DEAD_HUB_PORT" $BIN send undurable-e2e hello 2>"$DTMP/err"); RC=$?
[ "$RC" -eq 0 ] && fail "a hub that could not persist answered a send with success: ${OUT}"
grep -q "durable" "$DTMP/err" \
    || fail "the refusal did not say what was wrong: $(cat "$DTMP/err")"
# AND IT SAYS NOTHING WAS QUEUED, because that is what makes a retry safe:
# a queue still holding a message its sender was told did not arrive is a
# message delivered twice the moment they try again.
grep -q "nothing was queued" "$DTMP/err" \
    || fail "the refusal did not say the message was not kept: $(cat "$DTMP/err")"
# AND THAT IS MEASURED, NOT TAKEN ON THE REFUSAL'S WORD. A queue still
# holding a message its sender was told did not arrive is a message
# delivered twice the moment they retry, and the sentence above is the
# claim rather than the fact ([[WI-2026-09-15-001]]).
UPID=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$SYNAPTY_CONFIG_ROOT/machine/sessions/undurable-e2e.json" | head -1)
[ -n "$UPID" ] || fail "no pid in the undurable recipient's record"
USOCK="$(pane_socket_path "$UPID")"
for _ in $(seq 50); do [ -S "$USOCK" ] && break; sleep 0.1; done
[ -S "$USOCK" ] || fail "the undurable recipient never bound its socket"
DRAINED=$(SYNAPTY_HUB_PORT="$DEAD_HUB_PORT" SYNAPTY_SOCK="$USOCK" $BIN recv 2>&1)
printf '%s' "$DRAINED" | grep -q "hello" \
    && fail "the refused message was queued anyway, so a retry would deliver it twice: $DRAINED"
$BIN end --id undurable-e2e >/dev/null 2>&1 || true
kill "$NODUR" 2>/dev/null
echo "ok: a hub that cannot persist refuses the send instead of promising it"

echo "ALL OK (exit 0 means the message arrived)"
