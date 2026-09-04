#!/bin/bash
# The holder, through the real CLI ([[RFC-0014]], [[WI-2026-08-17-003]]).
#
# The unit tests drive the holder in-process; this drives it the way a
# human does — two separate `synapty attach` invocations against a session
# started by a third process. What it exists to catch is everything that
# is true of the library and false of the program: argument plumbing, the
# socket path a client derives from a name, the terminal the client puts
# into raw mode, and the exit codes.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BIN=./zig-out/bin/synapty
[ -x "$BIN" ] || { echo "FAIL: build $BIN first (zig build)"; exit 1; }

ID="e2e-holder-$$"
# SHORT, AND THAT IS A CONSTRAINT RATHER THAN A PREFERENCE. A holder's
# socket lives under the config root, and a unix socket path is bounded
# at ~104 bytes — `mktemp -d` under /var/folders spends most of that
# before the first directory of ours, and the run fails with NameTooLong.
TMP="/tmp/synapty-e2e-$$"
mkdir -p "$TMP"
# A CONFIG ROOT OF ITS OWN, like every other test here.
#
# Without it this script starts real holders in the human's own
# ~/.config/synapty/machine/sessions — records and live sockets, beside
# the sessions their workbench is using. The cleanup below ends what it
# started, but a run that dies between the two leaves a session in the
# place the product looks: found today, five dead records sitting in the
# real directory from earlier runs of this file. The Swift suite has had
# this discipline since a test clobbered a real hosts.json; the Zig side
# needs it for the same reason and did not have it.
export SYNAPTY_CONFIG_ROOT="$TMP/config"
mkdir -p "$SYNAPTY_CONFIG_ROOT"
HOLDPID=""
HUBPID=""
cleanup() {
    [ -n "$HOLDPID" ] && kill "$HOLDPID" 2>/dev/null
    [ -n "$HUBPID" ] && kill "$HUBPID" 2>/dev/null
    # EVERY SESSION THIS RUN STARTED, ended through the interface rather
    # than by deleting its socket. A test that leaves durable holders
    # behind is the failure the whole mechanism is warned about, arriving
    # from the thing that is supposed to check it — and deleting the
    # socket instead of ending the session makes the holder unreachable
    # rather than gone.
    for s in "$ID" "${DID:-}" "${RID:-}" "${PID:-}" "${LID:-}" "${LID2:-}" "${CID:-}" \
             "${SEEN_ID:-}" "${LOST_ID:-}"; do
        [ -n "$s" ] && $BIN end --id "$s" >/dev/null 2>&1
    done
    [ -n "${KEEP_TMP:-}" ] && echo "kept: $TMP" || rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# ITS OWN HUB, on a port nothing else uses. The wrapper connects to a hub
# at startup whether or not it is holding a terminal, and a test that
# borrowed whichever hub happened to be running on this machine passed or
# failed on that accident — which it did, once.
# THE PORT IS NOT A CONSTANT ([[WI-2026-09-02-018]]): two of these scripts
# hardcoded the same one and collided when run together. Taken from the
# environment, else a free one from the kernel.
HUB_PORT="${HUB_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')}"
# GNU timeout is not on stock macOS; say so instead of failing mid-run.
command -v timeout >/dev/null 2>&1 || { echo "this test needs GNU timeout (brew install coreutils)" >&2; exit 2; }
$BIN hub --port "$HUB_PORT" --strict-port --no-state \
    --discovery-path "$TMP/hub.json" >"$TMP/hub.log" 2>&1 &
HUBPID=$!
for _ in $(seq 1 40); do
    grep -q "\"port\"" "$TMP/hub.json" 2>/dev/null && break
    sleep 0.1
done
kill -0 "$HUBPID" 2>/dev/null || fail "test hub did not start: $(cat "$TMP/hub.log")"
HUB="--hub 127.0.0.1:$HUB_PORT"

# The child touches a file, so "is it still alive" is answerable without
# asking the holder — a holder that lied would otherwise pass its own test.
MARK="$TMP/alive"
$BIN run --hold $HUB --id "$ID" -- \
    /bin/sh -c "touch $MARK; while true; do read l || sleep 1; echo \"GOT[\$l]\"; done" \
    >"$TMP/holder.log" 2>&1 &
HOLDPID=$!
for _ in $(seq 1 40); do [ -e "$MARK" ] && break; sleep 0.1; done
[ -e "$MARK" ] || fail "child never started: $(cat "$TMP/holder.log")"

# C-START: a start against a held name is refused, never joined.
if $BIN run --hold $HUB --id "$ID" -- /bin/sh -c "true" >"$TMP/dup" 2>&1; then
    fail "a second start joined instead of failing"
fi
grep -q "already held" "$TMP/dup" || fail "second start failed for the wrong reason: $(cat "$TMP/dup")"
echo "ok: a start against a held name is refused"

printf 'hello\r' | timeout 10 $BIN attach --id "$ID" >"$TMP/out1" 2>&1
grep -q "GOT\[hello\]" "$TMP/out1" || fail "first client saw no answer: $(cat "$TMP/out1")"
echo "ok: a client attached and its keystrokes reached the child"

# C-HOLDER: the client is gone; the session is not.
sleep 0.5
kill -0 "$HOLDPID" 2>/dev/null || fail "the holder died with its client"

printf 'again\r' | timeout 10 $BIN attach --id "$ID" >"$TMP/out2" 2>&1
grep -q "GOT\[again\]" "$TMP/out2" || fail "second client saw no answer: $(cat "$TMP/out2")"
echo "ok: a second client found the session the first one left"

# C-HOLDER: a session that is gone is said to be gone, not created.
if timeout 10 $BIN attach --id "no-such-session-$$" >"$TMP/miss" 2>&1; then
    fail "attach to a missing session succeeded"
fi
grep -q "no session named" "$TMP/miss" || fail "wrong message for a missing session: $(cat "$TMP/miss")"
echo "ok: attaching to a session that is gone says it is gone"

# --- detaching, and the two commands that can find and end it
# ([[WI-2026-08-17-004]]) ---

DID="e2e-detached-$$"
# Started from a subshell that exits immediately: if the holder needed its
# starter, it would die here.
( $BIN run --hold --detach $HUB --id "$DID" -- /bin/sh -c "while true; do read l || sleep 1; echo \"GOT[\$l]\"; done" ) >"$TMP/detach.log" 2>&1
[ $? -eq 0 ] || fail "--detach did not return cleanly: $(cat "$TMP/detach.log")"
echo "ok: --detach returned once the session answered"

sleep 0.5
$BIN sessions | grep -qE "^$DID	detached	(seen|unclaimed)	running" \
    || fail "sessions did not list the detached session: $($BIN sessions)"
echo "ok: sessions lists it, unattached and running"

# C-ONE-CLIENT: asking must not cost the human their seat.
printf 'held\r' | timeout 10 $BIN attach --id "$DID" >"$TMP/attached.out" 2>&1 &
ATTACH_JOB=$!
sleep 1
$BIN sessions | grep -q "^$DID	attached" || fail "sessions did not see the attached client"
$BIN sessions >/dev/null   # a second query, while that client is still there
sleep 0.5
wait $ATTACH_JOB
grep -q "GOT\[held\]" "$TMP/attached.out" || fail "the query displaced the attached client: $(cat "$TMP/attached.out")"
echo "ok: a status query did not displace the attached client"

# ---------------------------------------------------------------------------
# WHICH PROCESS'S DIRECTORY ([[WI-2026-08-18-004]]). The listing reports
# the FOREGROUND group's and the SHELL's separately, and they differ
# whenever the session is running anything that has `cd`d — which is the
# ordinary case rather than a corner: `jenv rehash` runs from a great many
# `.zshrc` files and spends its life in the shim directory.
#
# AN INTERACTIVE SHELL, AND A TYPED COMMAND, because nothing cheaper
# reproduces the shape. Three fixtures were tried and all three proved
# nothing: a subshell, a script run with `-m`, and a non-interactive `sh`
# all leave the child in the SHELL's process group, so the foreground
# group IS the shell and the two columns agree by accident. Only a shell
# doing real job control hands the terminal to a command, which is
# precisely the state the workbench's panes are in.
# ---------------------------------------------------------------------------
CID="e2e-cwd-$$"
mkdir -p "$TMP/shell-home" "$TMP/elsewhere"
$BIN run --hold --detach $HUB --id "$CID" -- /bin/bash --norc -i \
    >"$TMP/cwd.log" 2>&1
sleep 1
{
    printf "cd '%s'\r" "$TMP/shell-home"; sleep 1
    printf "sh -c 'cd \"%s\" && sleep 30'\r" "$TMP/elsewhere"; sleep 8
} | $BIN attach --id "$CID" >/dev/null 2>&1 &
CWD_JOB=$!
sleep 4
CWD_LINE="$($BIN sessions | grep "^$CID	" || true)"
kill "$CWD_JOB" 2>/dev/null; wait "$CWD_JOB" 2>/dev/null
[ -n "$CWD_LINE" ] || fail "the cwd session was not listed: $($BIN sessions)"
# Columns: name, attached, seen/unclaimed, child state, idle seconds,
# cwd, foreground command, shell cwd.
FG_COL="$(printf '%s' "$CWD_LINE" | cut -f6)"
SHELL_COL="$(printf '%s' "$CWD_LINE" | cut -f8)"
case "$FG_COL" in
    *elsewhere) ;;
    # The command never took the terminal, so this run says nothing about
    # the split. Said out loud rather than passed quietly.
    *) fail "the foreground never moved, so this run proved nothing: $CWD_LINE" ;;
esac
case "$SHELL_COL" in
    *shell-home) ;;
    *) fail "column 6 followed the command instead of the shell: $CWD_LINE" ;;
esac
echo "ok: the shell's directory and the foreground command's are reported apart"
$BIN end --id "$CID" >/dev/null 2>&1

$BIN end --id "$DID" | grep -q "ended" || fail "end did not report success"
sleep 0.5
$BIN sessions | grep -q "^$DID	" && fail "the session is still listed after end"
echo "ok: end terminated the session"

$BIN end --id "no-such-$$" >"$TMP/endmiss" 2>&1 && fail "end of a missing session succeeded"
grep -q "no session named" "$TMP/endmiss" || fail "wrong message ending a missing session"
echo "ok: ending a session that is not there says so"

echo "ALL OK (detach)"

# --- the screen a cold client is given ([[WI-2026-08-17-007]]) ---

RID="e2e-restore-$$"
( $BIN run --hold --detach $HUB --id "$RID" -- \
    /bin/sh -c "printf 'SCREEN_MARKER_$$\r\n'; while true; do sleep 1; done" ) >/dev/null 2>&1
sleep 1
# A client with nothing must be shown what is on the screen, not a blank
# terminal — the whole point of the screen model.
timeout 5 $BIN attach --id "$RID" >"$TMP/cold.out" 2>&1 </dev/null
grep -q "SCREEN_MARKER_$$" "$TMP/cold.out" || fail "a cold client saw an empty screen: $(cat "$TMP/cold.out" | head -3)"
echo "ok: a cold client was given the screen"
$BIN end --id "$RID" >/dev/null 2>&1

# A RESTORATION IS A REPAINT, NOT A DESCRIPTION ([[WI-2026-08-17-013]]).
# The row a marker is on must be ADDRESSED, and every row of the screen
# must be painted — a description carries only the rows that have
# something on them, and then the last row of the screen is never
# mentioned and everything lands wherever the paint began.
PID="e2e-repaint-$$"
( $BIN run --hold --detach $HUB --id "$PID" -- \
    /bin/sh -c "printf '\033[10;1HROW_TEN_$$'; while true; do sleep 1; done" ) >/dev/null 2>&1
sleep 1
timeout 5 $BIN attach --id "$PID" >"$TMP/repaint.out" 2>&1 </dev/null
grep -qF "ROW_TEN_$$" "$TMP/repaint.out" || fail "the repaint did not carry the screen"
grep -qF $'\033[10;1H' "$TMP/repaint.out" || fail "the marker's row was not addressed"
grep -qF $'\033[24;1H' "$TMP/repaint.out" || fail "the last row of the screen was never painted"
echo "ok: the restoration addressed every row, including the blank ones"
$BIN end --id "$PID" >/dev/null 2>&1

echo "ALL OK (restore)"

# --- a dropped transport is a reconnect, not a lost pane
# ([[WI-2026-08-17-009]]) ---

LID="e2e-local-$$"
( $BIN run --hold --detach $HUB --id "$LID" -- \
    /bin/sh -c "i=0; while true; do i=\$((i+1)); echo \"TICK\$i\"; sleep 0.5; done" ) >/dev/null 2>&1
sleep 1

# The client is LOCAL and drives a transport it can lose. The relay lives
# in a SCRIPT rather than on the command line, so that killing it by
# pattern cannot also match the client — whose own arguments contain the
# transport command by construction, which is how the first version of
# this test killed the thing it was testing.
cat > "$TMP/relay.sh" <<RELAY
#!/bin/sh
exec $BIN attach --relay --id $LID
RELAY
chmod +x "$TMP/relay.sh"
timeout 20 $BIN attach --id "$LID" -- /bin/sh "$TMP/relay.sh" >"$TMP/local.out" 2>&1 &
CLIENT=$!
sleep 2

# Kill the transport, which is what a dropped link does.
pkill -f "attach --relay --id $LID" || fail "no relay to kill"
sleep 4
kill -0 "$CLIENT" 2>/dev/null || fail "the client died with its transport"
grep -q "link lost — reconnecting" "$TMP/local.out" || fail "the reconnect was silent: $(cat "$TMP/local.out" | tail -3)"
echo "ok: a dropped transport was reported and retried"

# AND THE OTHER HALF OF THE RULE: with a workbench listening, the same
# notice goes to it and the session's screen is left alone. A pane is the
# session's screen and a full-screen program owns every cell of it, so a
# line written among them corrupts what the human is reading and stays
# corrupted — a resumed attach continues from a position and never
# repaints ([[WI-2026-08-29-004]]).
LID2="e2e-quiet-$$"
( $BIN run --hold --detach $HUB --id "$LID2" -- \
    /bin/sh -c "i=0; while true; do i=\$((i+1)); echo \"TOCK\$i\"; sleep 0.5; done" ) >/dev/null 2>&1
sleep 1
cat > "$TMP/relay2.sh" <<RELAY2
#!/bin/sh
exec $BIN attach --relay --id $LID2
RELAY2
chmod +x "$TMP/relay2.sh"
SYNAPTY_CONNECT_LOG="$TMP/account.log" timeout 20 $BIN attach --id "$LID2" \
    -- /bin/sh "$TMP/relay2.sh" >"$TMP/quiet.out" 2>&1 &
CLIENT2=$!
sleep 2
pkill -f "attach --relay --id $LID2" || fail "no second relay to kill"
sleep 4
grep -q "lost" "$TMP/account.log" \
    || fail "the workbench was told nothing: $(tail -3 "$TMP/account.log" 2>/dev/null)"
grep -q "link lost" "$TMP/quiet.out" \
    && fail "the notice was written into the session's screen as well: $(tail -3 "$TMP/quiet.out")"
kill "$CLIENT2" 2>/dev/null
wait "$CLIENT2" 2>/dev/null
$BIN end --id "$LID2" >/dev/null 2>&1 || true
echo "ok: with a workbench listening, the screen is left alone"

sleep 2
kill "$CLIENT" 2>/dev/null
wait "$CLIENT" 2>/dev/null
# TICKS FROM BOTH SIDES OF THE BREAK. The session kept counting while the
# client was away, and the client came back to a stream that continues
# rather than restarts.
first_tick=$(grep -o "TICK[0-9]*" "$TMP/local.out" | head -1 | tr -d 'TICK')
last_tick=$(grep -o "TICK[0-9]*" "$TMP/local.out" | tail -1 | tr -d 'TICK')
[ -n "$last_tick" ] || fail "no output at all: $(head -5 "$TMP/local.out")"
[ "$last_tick" -gt "$first_tick" ] || fail "the stream restarted instead of continuing ($first_tick -> $last_tick)"
echo "ok: the session continued across the break ($first_tick -> $last_tick)"

$BIN end --id "$LID" >/dev/null 2>&1
echo "ALL OK (local client)"

# ---------------------------------------------------------------------
# What becomes of a session nobody is using ([[RFC-0014]] C-END,
# [[WI-2026-08-22-001]])
#
# NOTHING. An agent's window is closed by the human and by nothing else.
# What the clause requires is that this be SAID, and that a human be able
# to find such a session in order to decide about it — so these check the
# declaration and the two facts a decision is made on.
# ---------------------------------------------------------------------

SEEN_ID="e2e-seen-$$"
$BIN run --hold --detach $HUB --id "$SEEN_ID" -- \
    /bin/sh -c "while true; do sleep 1; done" >"$TMP/seen.log" 2>&1
$BIN sessions | grep -q "^${SEEN_ID}	detached	unclaimed" \
    || fail "a session nobody has attached to did not say so: $($BIN sessions | grep "$SEEN_ID")"

printf '\r' | timeout 5 $BIN attach --id "$SEEN_ID" >/dev/null 2>&1
sleep 3
$BIN sessions | grep -q "^${SEEN_ID}	detached	seen" \
    || fail "a session somebody attached to is still called unclaimed"
echo "ok: whether anybody has ever attached is reported, and it changes"

# HOW LONG NOBODY HAS BEEN HERE — the other fact C-END requires, and the
# one a human uses to tell a session they left an hour ago from one they
# left in March.
idle="$($BIN sessions | grep "^${SEEN_ID}" | cut -f5)"
[ -n "$idle" ] && [ "$idle" -ge 1 ] \
    || fail "enumeration does not report how long nobody has been attached (got '$idle')"
echo "ok: how long nobody has been attached is reported"

# AND IT IS STILL HERE. No threshold, no timer, no clock of any kind.
sleep 3
$BIN sessions | grep -q "^${SEEN_ID}	detached	seen	running" \
    || fail "something ended a session the human did not end"
echo "ok: nothing ends a session but the human"

$BIN sessions | grep -q "^policy	sessions are never ended except by you" \
    || fail "the policy was not declared: $($BIN sessions | tail -1)"

# A TOMBSTONE IS SWEPT, NOT REPORTED FOREVER.
#
# A holder that is killed outright, or that a reboot takes with it, never
# reaches its own cleanup and leaves a record naming a pid the kernel has
# never heard of. Those rows offered nothing to attach to and nothing to
# end, and nothing removed them: the machine that prompted this had a
# hundred and fourteen of them burying its one live session.
#
# THE RECORD AND THE UNCLAIMED LOCK BESIDE IT, because that is what a
# holder leaves: the claim is taken on a file of its own and released by
# the kernel however the holder died ([[WI-2026-09-03-009]]). A record on
# its own is a different shape and reads `absent`, not `free`.
TOMB="$SYNAPTY_CONFIG_ROOT/machine/sessions/tombstone-e2e.json"
printf '{"pid":2147483647}\n' > "$TOMB"
: > "$SYNAPTY_CONFIG_ROOT/machine/sessions/tombstone-e2e.lock"
$BIN sessions | grep -q "tombstone-e2e" \
    && fail "a record whose process is gone was still listed: $($BIN sessions)"
[ -f "$TOMB" ] && fail "the tombstone was not swept: $TOMB"
[ -f "${TOMB%.json}.lock" ] && fail "the tombstone's claim outlived it: ${TOMB%.json}.lock"
echo "ok: a record whose process is gone is swept rather than listed"

# AND A PID IS A NUMBER, NOT AN IDENTITY.
#
# This record names a process that is unquestionably running — this shell —
# and yet no holder owns it, which is exactly what a reused pid looks like.
# `kill(pid, 0)` cannot tell the two apart, so the row was unsweepable and
# `synapty end` on it would have signalled the stranger.
REUSED="$SYNAPTY_CONFIG_ROOT/machine/sessions/pid-reused-e2e.json"
printf '{"pid":%d}\n' "$$" > "$REUSED"
: > "$SYNAPTY_CONFIG_ROOT/machine/sessions/pid-reused-e2e.lock"
$BIN sessions | grep -q "pid-reused-e2e" \
    && fail "a record whose holder is gone was listed because its pid was reused: $($BIN sessions)"
[ -f "$REUSED" ] && fail "the reused-pid record was not swept: $REUSED"
echo "ok: a record is swept on its holder being gone, not on its pid being free"
echo "ok: the policy is declared rather than left to be discovered by waiting"

# THE ROW THAT USED TO BE INVISIBLE. `/tmp` is not ours: the system sweeps
# it and any user can empty it. With the socket gone the holder and its
# child run on — and while the listing WAS the socket directory, nothing
# could name them.
LOST_ID="e2e-lost-$$"
$BIN run --hold --detach $HUB --id "$LOST_ID" -- \
    /bin/sh -c "while true; do sleep 1; done" >"$TMP/lost.log" 2>&1
LOST_SOCK="$(ls "$SYNAPTY_CONFIG_ROOT"/machine/sessions/"${LOST_ID}".sock 2>/dev/null | head -1)"
[ -n "$LOST_SOCK" ] || fail "the session left no socket to remove"
rm -f "$LOST_SOCK"

$BIN sessions | grep -q "^${LOST_ID}	unreachable" \
    || fail "a holder whose socket is gone is invisible: $($BIN sessions | grep "$LOST_ID")"
echo "ok: a session whose socket is gone is still listed, with its process"

# AND IT CAN BE ENDED. Seeing an orphan without being able to end it is
# half an answer.
$BIN end --id "$LOST_ID" | grep -q "unreachable" \
    || fail "end could not reach a session whose socket is gone"
sleep 1
$BIN sessions | grep -q "^${LOST_ID}" \
    && fail "the ended session is still listed"
echo "ok: and it can be ended, by the process its record names"

$BIN end --id "$SEEN_ID" >/dev/null 2>&1

echo "ALL OK (nothing ends a session but you)"