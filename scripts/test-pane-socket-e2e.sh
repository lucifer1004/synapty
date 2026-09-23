#!/usr/bin/env bash
# A pane whose IPC socket path is removed under it heals
# ([[WI-2026-09-03-007]]).
#
# THIS IS A SHELL TEST BECAUSE THE DEFECT IS A LIVE PROCESS. A pane was
# found with its wrapper healthy, its listener still bound, and its path
# gone from the filesystem — so every `connect` answered ENOENT and the
# pane was unreachable for the rest of its life. Nothing inside the
# process could see it: the fd was fine and `accept` simply never heard
# from anyone again. The unit test for `ensureBound` covers the decision;
# only a running daemon shows that the accept loop ever reaches it.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BIN=./zig-out/bin/synapty
[ -x "$BIN" ] || { echo "FAIL: build $BIN first (zig build)"; exit 1; }
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

TMP="/tmp/synapty-pane-sock-e2e-$$"
mkdir -p "$TMP"
# A CONFIG ROOT AND A PORT OF ITS OWN, so this never touches the hub the
# human's workbench is using — this test deletes pane sockets, and it must
# only ever be able to delete its own.
isolate_config "$TMP"
unset SYNAPTY_SOCK
HUBPID=""
cleanup() {
    $BIN end --id pane-sock-e2e >/dev/null 2>&1
    $BIN end --id nohub-e2e >/dev/null 2>&1
    [ -n "$HUBPID" ] && kill "$HUBPID" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

start_hub "$TMP"

$BIN run --hold --detach --id pane-sock-e2e --hub "127.0.0.1:${HUB_PORT}" -- /bin/sh -c 'sleep 120' \
    > "$TMP/run.log" 2>&1
for _ in $(seq 50); do
    $BIN agents 2>/dev/null | grep -q pane-sock-e2e && break
    sleep 0.1
done
$BIN agents 2>/dev/null | grep -q pane-sock-e2e || fail "the pane never registered (see $TMP/run.log)"

PPID_=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$SYNAPTY_CONFIG_ROOT/machine/sessions/pane-sock-e2e.json" | head -1)
[ -n "$PPID_" ] || fail "no pid in the pane's record"
SOCK="$(pane_socket_path "$PPID_")"
for _ in $(seq 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || fail "the pane socket never appeared at $SOCK"

# --- registering through the pane says so, rather than exiting 0 in silence
OUT=$(SYNAPTY_SOCK="$SOCK" $BIN register --tool claude 2>"$TMP/err"); RC=$?
[ "$RC" -eq 0 ] || fail "register through a live pane exited $RC: $(cat "$TMP/err")"
[ -n "$OUT" ] || fail "register succeeded and printed nothing — the silence this work item is about"
echo "ok: a register that worked says so on stdout"

# --- the socket goes; the process does not
rm -f "$SOCK"
[ -S "$SOCK" ] && fail "could not remove $SOCK"
kill -0 "$PPID_" 2>/dev/null || fail "removing the socket killed the pane, which is not the scenario"

# --- and the pane binds it again, without being restarted
for _ in $(seq 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || fail "the pane never re-bound $SOCK — it is unreachable for the rest of its life"
kill -0 "$PPID_" 2>/dev/null || fail "the pane died while re-binding"
echo "ok: a pane whose socket path was removed binds it again"

# --- reachable again means SERVING, not merely present
OUT=$(SYNAPTY_SOCK="$SOCK" $BIN register --tool claude --session "after the rebind" 2>"$TMP/err2"); RC=$?
[ "$RC" -eq 0 ] || fail "register through the re-bound socket exited $RC: $(cat "$TMP/err2")"
[ -n "$OUT" ] || fail "register through the re-bound socket printed nothing"
$BIN agents 2>/dev/null | grep -q "after the rebind" \
    || fail "the re-bound pane's registration never reached the hub: $($BIN agents 2>&1)"
echo "ok: the re-bound socket serves a request all the way to the hub"

# --- A SOCKET THAT IS NOT A PANE DAEMON IS NOT A SUCCESS. The holder's own
# --- session socket accepts a connection and speaks another protocol; it
# --- was reached by mistake and `register` exited 0 having done nothing.
HOLDER_SOCK="$SYNAPTY_CONFIG_ROOT/machine/sessions/pane-sock-e2e.sock"
[ -S "$HOLDER_SOCK" ] || fail "no holder socket to test the wrong-protocol case with"
OUT=$(SYNAPTY_SOCK="$HOLDER_SOCK" $BIN register --tool codex 2>"$TMP/err3"); RC=$?
[ "$RC" -eq 0 ] && fail "register against a socket that never answered exited 0, printing: '${OUT}'"
[ -s "$TMP/err3" ] || fail "register against a mute socket failed with nothing on stderr"
grep -q "not set" "$TMP/err3" \
    && fail "the refusal said SYNAPTY_SOCK was not set, and it was set: $(cat "$TMP/err3")"
$BIN agents 2>/dev/null | grep -q codex \
    && fail "a register that reported failure still changed the agent's tool"
echo "ok: a socket that accepts and never answers is a failure, and says which"

# --- A MACHINE WITH NO HUB IS A FACT THE PANE CAN BE TOLD
#
# [[WI-2026-09-10-008]] took the hub port off a `?? 9000` fallback in
# seven places, because 9000 is the one number that must not stand in for
# "no hub": it names the hub an adoption may have just REFUSED. For the
# pane it did that by OMITTING `--hub` — and an absent `--hub` resolves
# (SYNAPTY_HUB_PORT, then the discovery file, then 9000), so the pane went
# on registering into the refused hub and only the command string had
# changed ([[WI-2026-09-12-002]]).
#
# THE SHELL IS WHERE THIS CAN BE ASKED. The unit test on the Swift side
# can only see the command it builds; whether the pane LANDS on a hub is
# the far side's answer, and a hub is the only thing that can give it.
$BIN run --hold --detach --id nohub-e2e --hub none -- /bin/sh -c 'sleep 120' \
    > "$TMP/nohub.log" 2>&1
for _ in $(seq 50); do
    $BIN sessions 2>/dev/null | grep -q "^nohub-e2e" && break
    sleep 0.1
done
$BIN sessions 2>/dev/null | grep -q "^nohub-e2e" \
    || fail "a pane with no hub did not come up at all (see $TMP/nohub.log)"

# It had every chance to register: the hub above is up, and the pane that
# WANTED one reached it within five seconds at the top of this file.
sleep 1
$BIN agents 2>/dev/null | grep -q nohub-e2e \
    && fail "a pane told there is no hub registered with one anyway: $($BIN agents 2>&1)"

# DEGRADED, NOT BROKEN. The session is held, and the pane serves its own
# socket — everything that is the pane's alone still works.
NPID=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$SYNAPTY_CONFIG_ROOT/machine/sessions/nohub-e2e.json" | head -1)
[ -n "$NPID" ] || fail "no pid in the hubless pane's record"
NSOCK="$(pane_socket_path "$NPID")"
for _ in $(seq 50); do [ -S "$NSOCK" ] && break; sleep 0.1; done
[ -S "$NSOCK" ] || fail "the hubless pane never bound its socket at $NSOCK"

# And a verb that NEEDS the hub says so rather than exiting zero.
OUT=$(SYNAPTY_SOCK="$NSOCK" $BIN register --tool claude 2>"$TMP/nohub-err"); RC=$?
[ "$RC" -eq 0 ] && fail "register inside a hubless pane exited 0, saying: '${OUT}'"
[ -s "$TMP/nohub-err" ] || fail "register inside a hubless pane failed with nothing on stderr"
$BIN end --id nohub-e2e >/dev/null 2>&1 || true
echo "ok: a pane told there is no hub holds its session and registers with nobody"

echo "ALL OK (a pane that loses its socket gets it back)"
