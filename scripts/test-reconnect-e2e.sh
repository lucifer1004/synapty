#!/usr/bin/env bash
# A dropped link, a reconnect, and a reconnect that finds nothing
# ([[WI-2026-09-07-004]], [[WI-2026-09-07-006]]).
#
# THIS IS A SHELL TEST BECAUSE THE FAULT IS A DEAD PROCESS. Every decision
# here is unit-tested — the backoff, the budget, what each outcome means —
# and none of those tests can kill a transport. The defect this script
# exists for was found by killing one: an unreachable host reported "the
# session is gone" and gave up on its first attempt, because every failure
# to read the welcome was classified as `no_session`. No unit test saw it,
# and the reasoning about the code did not either.
#
# A KILLED TRANSPORT IS NOT A SIMULATION OF A DROPPED LINK. From the
# client's side they are the same event: the process carrying the frames
# went away. That is why this needs no network and no second machine.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BIN=./zig-out/bin/synapty
[ -x "$BIN" ] || { echo "FAIL: build $BIN first (zig build)"; exit 1; }
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

TMP="/tmp/synapty-reconnect-e2e-$$"
mkdir -p "$TMP"
# A CONFIG ROOT OF ITS OWN, so this never touches the sessions the human's
# workbench is holding — this test kills holders, and it must only ever be
# able to kill its own.
isolate_config "$TMP"
unset SYNAPTY_SOCK

# UNIQUE PER RUN, LIKE THE CONFIG ROOT ABOVE IT. The cleanup below is a
# `pkill -f` on this name, and a fixed one matches ANY concurrent run of
# this script — so two of them (a reviewer's and the suite's) killed each
# other's holder, and the case that needs a holder alive failed about one
# run in three. The config root was already per-run; the name was not, and
# a test that is isolated in one dimension and not the other is isolated in
# neither ([[WI-2026-09-08-001]]).
NAME="reconnect-e2e-$$"
CLIENT=""
cleanup() {
    [ -n "$CLIENT" ] && kill -KILL "$CLIENT" 2>/dev/null
    pkill -f "id $NAME" >/dev/null 2>&1
    $BIN end --id "$NAME" >/dev/null 2>&1
    rm -rf "$TMP"
}
trap cleanup EXIT

# ONE SHAPE IN EVERY SUITE ([[WI-2026-09-11-013]]): `$*` so a message
# given unquoted is not truncated to its first word, and stderr so a
# failure is not interleaved with the ok lines on stdout. There were
# four shapes across seven files.
fail() { echo "FAIL: $*" >&2; [ -f "${SYNAPTY_CONNECT_LOG:-}" ] && sed 's/^/    /' "$SYNAPTY_CONNECT_LOG" >&2; exit 1; }

# Wait for a line of a given kind — and optionally a given text — to appear
# in the account, or give up.
#
# THE CHANNEL THE CLIENT IS ACTUALLY WRITING, not a fixed path. This read
# `$TMP/account.log` while a case pointed the client at another file, so it
# waited twenty-five seconds on a log nobody was writing and reported the
# behaviour as absent ([[WI-2026-09-08-015]]).
#
# BY FIELD, NOT BY SUBSTRING. A line is `<milliseconds> <kind> <text>`, and
# matching " $kind " needed a trailing space that the last field on a line
# does not have: `end no_session` was there and this said it was not.
await() {
    local kind="$1" want="${2:-}" deadline=$((SECONDS + ${3:-15}))
    while [ $SECONDS -lt $deadline ]; do
        awk -v k="$kind" -v w="$want" \
            '$2==k && (w=="" || $3==w) { f=1 } END { exit !f }' \
            "$SYNAPTY_CONNECT_LOG" && return 0
        sleep 0.2
    done
    return 1
}

# ---------------------------------------------------------------------
# A host that is not there RETRIES, and never claims the session is gone.
#
# The transport exits at once and says nothing, which is what an ssh to an
# unreachable host does. Reported as `no_session` this ended the pane on
# the first attempt ([[WI-2026-09-07-006]]).
# ---------------------------------------------------------------------
export SYNAPTY_CONNECT_LOG="$TMP/account.log"
: > "$SYNAPTY_CONNECT_LOG"
$BIN attach --id nobody-here -- /usr/bin/false >/dev/null 2>&1 &
CLIENT=$!
sleep 9
# QUIETLY. A killed background job prints "Killed: 9" from the shell's own
# job control, in the middle of the output a human reads to judge the run.
kill -KILL $CLIENT 2>/dev/null
wait $CLIENT 2>/dev/null
CLIENT=""

# `{ f=1 } END { exit !f }`, NOT `{ exit 0 } END { exit 1 }`. An `exit` in
# a RULE does not end awk — it jumps to END, whose own exit status wins. So
# the second form always exits 1, `&& fail` was unreachable, and this
# assertion had never once been able to fire. It is the assertion this
# whole script's header names as its reason for existing
# ([[WI-2026-09-07-006]], [[WI-2026-09-09-015]]). The `await` helper above
# had the right idiom the whole time.
awk '$2=="end" && $3=="no_session" { f=1 } END { exit !f }' "$TMP/account.log" &&
    fail "an unreachable host was reported as a session that is gone"
# ONE COUNT, BOUNDED FROM BOTH SIDES. The lower bound says it kept
# trying; the upper bound says the waits grew — at a flat second nine
# seconds would hold nine attempts, and the ramp of 1s, 2s, 4s holds
# about four. Two variables were computed from the identical `grep -c`,
# which read as two measurements and was one ([[WI-2026-09-10-004]]).
LOSSES=$(grep -c " lost " "$TMP/account.log")
[ "$LOSSES" -ge 3 ] || fail "expected several attempts in nine seconds, saw $LOSSES"
[ "$LOSSES" -le 5 ] || fail "the wait between attempts is not backing off ($LOSSES in 9s)"
echo "ok: an unreachable host retries, backs off, and claims nothing about the session"

# ---------------------------------------------------------------------
# A DROPPED LINK IS RECOVERED FROM, in the same process and the same pty.
#
# `--hub none` ON EVERY HELD SESSION THIS FILE STARTS, and it is not
# decoration. Nothing here is about a hub — these cases are a transport
# dying, a client pausing and a budget resetting — but `run` dials one
# before the holder binds anything, and with nothing listening it retries
# for EIGHT SECONDS first. The check below waits two, so the case passed
# only where something happened to be on the resolved port: on this
# developer's machine that is their own workbench hub, and on CI it is
# nothing. Green here and red there, for a reason that has nothing to do
# with what is being tested ([[WI-2026-09-15-003]]).
# ---------------------------------------------------------------------
: > "$SYNAPTY_CONNECT_LOG"
$BIN run --hold --detach --id "$NAME" --hub none -- /bin/sh -c 'while :; do sleep 1; done' &
sleep 2
$BIN sessions 2>/dev/null | grep -q "^$NAME" || fail "the holder did not come up"

$BIN attach --id "$NAME" -- $BIN attach --relay --id "$NAME" >/dev/null 2>&1 &
CLIENT=$!
await paint "" 15 || fail "the client never attached"

RELAY=$(pgrep -P $CLIENT | head -1)
[ -n "$RELAY" ] || fail "no transport to kill"
kill -KILL "$RELAY" 2>/dev/null

await lost "" 15 || fail "a killed transport was not reported as a lost link"
await live "" 15 || fail "the client did not return to the session it was in"
kill -0 $CLIENT 2>/dev/null || fail "the client exited instead of reconnecting"
echo "ok: a killed transport is a lost link, and the client returns to where it was"

# ---------------------------------------------------------------------
# A RECONNECT THAT FINDS NOTHING SAYS SO — and is believed, because the
# relay said it rather than because a read failed.
# ---------------------------------------------------------------------
# THE HOLDER GOING IS THE WHOLE OF THE SETUP. An earlier version also
# hunted the transport's pid and killed it, to hurry the client along —
# and that raced: the transport often dies of its own accord the moment
# its holder does, so `pgrep -P` found nothing to kill, and whether the
# case passed depended on which of the two got there first. It failed
# about one run in three.
#
# The client discovers this without help. Waiting is not a slower version
# of the same test; it is the test without a race in it.
pkill -f "run --hold --detach --id $NAME" >/dev/null 2>&1

# LONG ENOUGH FOR THE BACKOFF, on a machine that is also running the rest
# of the suite. The ramp is 1s, 2s, 4s, 8s, so a discovery three attempts
# in is fifteen seconds of waiting before it is even attempted.
await end no_session 45 || fail "a session that is gone was not reported as gone"
echo "ok: a reconnect that finds no session says so"

# ---------------------------------------------------------------------
# THE CLIENT STOPS DIALLING, SAYS SO, AND COMES BACK WHEN TOLD.
#
# UNREACHABLE UNTIL THE BUDGET COULD BE SHORTENED. Thirty minutes is not a
# thing a script can wait for, so the pause, the resume, the retry marker
# and every word they write had no test at all — and the busy-spin that
# made the pause burn a core was found by READING, in exactly the function
# this drives ([[WI-2026-09-08-015]]).
#
# AND THIS IS THE NON-INTERACTIVE CALLER. The client runs here with no
# terminal, which is the case whose `is_tty` guard turned the loop's only
# blocking call into a spin.
# ---------------------------------------------------------------------
export SYNAPTY_CONNECT_LOG="$TMP/pause.log"
: > "$SYNAPTY_CONNECT_LOG"
SYNAPTY_RETRY_BUDGET_MS=2500 $BIN attach --id nobody-here -- /usr/bin/false >/dev/null 2>&1 &
CLIENT=$!

await paused "" 25 || fail "the client never stopped dialling"
kill -0 $CLIENT 2>/dev/null || fail "it exited instead of pausing — the pty goes with it"

# A PAUSE THAT COSTS A CORE IS NOT A PAUSE, and driving the path is not
# enough to notice: with the busy-spin restored this whole case still
# passed, because a spinning client still answers the marker — it just
# burns a core until it does. Measured rather than assumed, as processor
# time actually consumed across a window of wall clock.
cpu_centis() {   # a pid's consumed CPU, in hundredths of a second
    ps -o cputime= -p "$1" 2>/dev/null |
        awk -F'[:.]' 'NF>=3 { print ($(NF-2)*60 + $(NF-1))*100 + $NF }'
}
BEFORE=$(cpu_centis $CLIENT)
sleep 2
AFTER=$(cpu_centis $CLIENT)
[ -n "$BEFORE" ] && [ -n "$AFTER" ] || fail "could not measure the paused client's cpu"
BURNED=$((AFTER - BEFORE))
# Two seconds of wall clock is 200 centiseconds of one core. A pause that
# rests uses single digits; the spin used most of it.
[ "$BURNED" -lt 50 ] || fail "the paused client burned ${BURNED}cs of cpu in 2s — it is spinning, not waiting"

# TOLD BY THE MARKER, which is how the workbench's button reaches it. The
# path is derived from the account channel on both sides and neither can
# import the other's.
: > "$SYNAPTY_CONNECT_LOG.retry"
await resumed "" 15 || fail "the marker did not bring it back"
[ -e "$SYNAPTY_CONNECT_LOG.retry" ] && fail "the marker was left behind: one press would resume every pause after"

kill -KILL $CLIENT 2>/dev/null
wait $CLIENT 2>/dev/null
CLIENT=""
echo "ok: a client that gave up pauses, says so, and comes back when told"

# ---------------------------------------------------------------------
# A RECONNECT THAT SUCCEEDS ENDS THE OUTAGE, even when the session was
# idle and there was nothing new to show for it.
#
# THE RESET USED TO ASK THE WRONG QUESTION. It tested whether more BYTES
# had been rendered — but a resumed attach sets `rendered` from
# `welcome.position`, and an idle session's position is identical on every
# reconnect. So a client that reached the far side every single time still
# doubled its wait and still spent its budget from the FIRST loss, and
# after half an hour of successful reconnects said "stopped dialling after
# 30 minutes down" ([[WI-2026-09-09-002]]).
#
# BINARY, NOT TIMED. With a 2.5s budget, a client that resets on a
# successful reconnect never pauses however often the link is cut; one
# that does not pauses within a few seconds. Nothing here measures a gap.
# ---------------------------------------------------------------------
RNAME="$NAME-reset"
export SYNAPTY_CONNECT_LOG="$TMP/reset.log"
: > "$SYNAPTY_CONNECT_LOG"
$BIN run --hold --detach --id "$RNAME" --hub none -- /bin/sh -c 'while :; do sleep 1; done' &
sleep 2
$BIN sessions 2>/dev/null | grep -q "^$RNAME" || fail "the holder did not come up"

SYNAPTY_RETRY_BUDGET_MS=2500 \
    $BIN attach --id "$RNAME" -- $BIN attach --relay --id "$RNAME" >/dev/null 2>&1 &
CLIENT=$!
await paint "" 15 || fail "the client never attached"

# FOUR OUTAGES OVER SIX SECONDS, each one recovered from. Well past a 2.5s
# budget in total, and each one well inside it on its own.
for _ in 1 2 3 4; do
    R=$(pgrep -P $CLIENT | head -1)
    [ -n "$R" ] && kill -KILL "$R" 2>/dev/null
    sleep 1.5
done

awk '$2=="paused" { f=1 } END { exit !f }' "$SYNAPTY_CONNECT_LOG" &&
    fail "the client stopped dialling although every reconnect reached the session"
LIVES=$(awk '$2=="live" { n++ } END { print n+0 }' "$SYNAPTY_CONNECT_LOG")
[ "$LIVES" -ge 3 ] || fail "expected the session to be rejoined repeatedly, saw $LIVES"
kill -0 $CLIENT 2>/dev/null || fail "the client exited instead of reconnecting"

kill -KILL $CLIENT 2>/dev/null
wait $CLIENT 2>/dev/null
CLIENT=""
$BIN end --id "$RNAME" >/dev/null 2>&1
echo "ok: reaching the session ends the outage, whether or not it had anything to say"


# ---------------------------------------------------------------------
# BOTH HOLES IN WHAT A PANE CAN SHOW, ASKED OF THE CLIENT THAT ANNOUNCES
# THEM ([[progress.Hole]], [[RFC-0015]] C-FAILURE).
#
# NOT BY ROLLING A REAL HOLDER, WHICH IS WHERE THIS STARTED. The case
# that lived here rolled the holder's 1 MiB retention window by VOLUME,
# so how long it took was a property of the machine: a holder feeds the
# child's bytes through its screen, and that measured 59 KB/s for short
# lines and 170 KB/s for long ones HERE. It passed on this machine and
# failed on CI at a twelve-second window, and again at a hundred and
# eighty, and flaked once locally under the load of the rest of the
# suite. No number written here is safe, because it is a bet on somebody
# else's machine ([[WI-2026-09-15-003]]).
#
# THE FAR SIDE IS FIFTY-ONE BYTES IN A FILE. The transport is whatever
# `--` names, and the holder's answers are frames — so a holder that
# refuses a position and then reports a gap is a canned stream and
# `cat`. It costs no throughput, so nothing here is a bet on a machine's
# speed; and it drives the client's real handshake and its real frame
# loop, which is the half [[progress.Hole]]'s unit test cannot reach:
# that test pins the MAPPING, and this pins that the CLI arrives at it.
#
# A FRAME IS `<kind><len as u32 LE><payload>` ([[holder.writeFrame]]).
# ---------------------------------------------------------------------
CANNED="$TMP/canned-holder"
{
    # welcome: version 1, answer 2 (unavailable — the position could not
    # be honoured), incarnation 42, position 0, retention 1 MiB.
    printf '\007\032\000\000\000'
    printf '\001\002'
    printf '\052\000\000\000\000\000\000\000'
    printf '\000\000\000\000\000\000\000\000'
    printf '\000\000\020\000\000\000\000\000'
    # gap: live output resumes at 1000, and what is between is gone.
    printf '\013\010\000\000\000'
    printf '\350\003\000\000\000\000\000\000'
    # exit 0, so the client stops rather than redialling this file forever.
    printf '\004\002\000\000\000\000\000'
} > "$CANNED"
SIZE=$(wc -c < "$CANNED" | tr -d ' ')
# THE BYTES BEFORE THE BEHAVIOUR. A `printf` that lost an escape would
# make the client read one frame and stop, and the assertions below would
# report a client that never announced the holes — which is the defect
# they exist to catch, indistinguishable from a typo here.
[ "$SIZE" = 51 ] || fail "the canned holder is $SIZE bytes, not 51 — the frames are malformed"

export SYNAPTY_CONNECT_LOG="$TMP/holes.log"
: > "$SYNAPTY_CONNECT_LOG"
$BIN attach --id canned-holes -- /bin/cat "$CANNED" >/dev/null 2>&1 &
CLIENT=$!
await hole "too" 15 \
    || fail "a position the holder refused was announced to nobody"
await hole "output" 15 \
    || fail "a catch-up the child outran was announced to nobody"
wait $CLIENT 2>/dev/null
CLIENT=""

# AND ON THE CHANNEL THE WORKBENCH CAN ACT ON. Said as `lost` this set
# [[ConnectProgress]]`.lostSince`, which only `paint` and `live` clear and
# neither follows a gap — so the pane wore "Link lost — reconnecting" for
# the rest of its attach ([[WI-2026-09-11-020]]). Said as `note` it
# reached the dialling placeholder, which a painted pane no longer has
# ([[WI-2026-09-16-002]]). Neither is a channel a human hears on.
awk '$2=="lost"' "$SYNAPTY_CONNECT_LOG" | grep -q . \
    && fail "a hole in the scrollback was announced as a dead link: $(cat "$SYNAPTY_CONNECT_LOG")"
HOLES=$(awk '$2=="hole" { n++ } END { print n+0 }' "$SYNAPTY_CONNECT_LOG")
[ "$HOLES" = 2 ] || fail "expected both holes on their own channel, saw $HOLES"
echo "ok: both holes in what a pane can show reach the workbench, on their own channel"


# ---------------------------------------------------------------------
# A TRANSPORT THAT LEAVES SOMETHING BEHIND STILL ENDS THE ATTEMPT.
#
# The transport's stderr is read on a thread, and the attempt joined that
# thread before returning. A pipe reaches end-of-stream only when EVERY
# holder of its write end has closed it — so a transport that backgrounds
# anything (ssh autostarting a ControlMaster, `ssh -f`, any remote command
# that daemonizes) left a grandchild holding the pipe, and the join waited
# for the grandchild. Nothing bounds that: no deadline covers a defer.
#
# THE GRANDCHILD'S STDOUT IS REDIRECTED, and that is the point of the
# case rather than an incidental. Holding STDOUT delays the handshake
# instead, and that is bounded — `readWelcomeWithin` gives up at 30s
# (measured: 30143ms for a grandchild sleeping 45). Leaving stdout held
# would test the deadline and pass either way. With only stderr held,
# measured on one build with the pump's read blocking and polling in turn:
# 46316ms against 120ms ([[WI-2026-09-09-002]]).
# ---------------------------------------------------------------------
export SYNAPTY_CONNECT_LOG="$TMP/grandchild.log"
: > "$SYNAPTY_CONNECT_LOG"
$BIN attach --id nobody-here-gc -- /bin/sh -c "sleep 30 >/dev/null & exit 7" >/dev/null 2>&1 &
CLIENT=$!
await lost "" 8 || fail "the attempt was held open by a process the transport left behind"
kill -KILL $CLIENT 2>/dev/null
wait $CLIENT 2>/dev/null
CLIENT=""
pkill -f "sleep 30" >/dev/null 2>&1
echo "ok: a transport that backgrounds something does not hold the attempt open"

# ---------------------------------------------------------------------
# A TRANSPORT'S LAST WORD IS ITS EXIT STATUS, and closing stdout is not
# the same event as exiting.
#
# The relay says "no session named X" by exiting 9, and ssh propagates a
# remote command's status unchanged — so that 9 is how a human is told the
# session is gone rather than being retried at forever. `transportVerdict`
# polled for it for a fifth of a second and then killed the transport,
# which makes 200ms a RACE rather than a bound: a transport whose stdout
# closes measurably before it exits had its status discarded and the pane
# retried against a host that will never have the session. Measured, one
# case differing from another only by the gap:
#
#     sh -c 'exec 1>&-; exit 9'            -> end no_session at +18ms
#     sh -c 'exec 1>&-; sleep 5; exit 9'   -> killed at 200ms, 9 discarded
#
# The discriminating fact was in hand and thrown away. A read that ended
# at END OF STREAM says the transport has finished writing and is on its
# way out, and waiting for it is right; a read that ended any other way —
# a deadline, a MOTD, a frame that is not a welcome — is a transport that
# is alive and not speaking, and there is nothing to wait for at all
# ([[WI-2026-09-09-003]]).
# ---------------------------------------------------------------------
export SYNAPTY_CONNECT_LOG="$TMP/slowexit.log"
: > "$SYNAPTY_CONNECT_LOG"
$BIN attach --id nobody-here-slow -- /bin/sh -c 'exec 1>&-; sleep 1; exit 9' >/dev/null 2>&1 &
CLIENT=$!
await end no_session 20 \
    || fail "a relay that took a second to exit had its answer discarded and was retried"
kill -KILL $CLIENT 2>/dev/null
wait $CLIENT 2>/dev/null
CLIENT=""
echo "ok: a transport that closes stdout before it exits is still heard"

echo "reconnect: all clear"
