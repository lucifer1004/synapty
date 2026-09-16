#!/bin/bash
# What `synapty host-setup` DOES to a host, recorded ([[ADR-0020]] step 5,
# [[WI-2026-09-09-010]]).
#
# THIS EXISTS BECAUSE THE MOVE COULD NOT BE DIFFED. The far side's launch
# script could be compared against the shell that used to build it, byte
# for byte; this half is a sequence of side effects on a machine, and there
# was no test for any of it — not the upload, not the terminfo, not the hub
# replacement, not the peer link.
#
# A SEQUENCE OF SIDE EFFECTS IS A TRANSCRIPT once the boundary is stubbed.
# `ssh`, `scp` and the probe answers are the whole boundary, so a fake host
# that records what it was asked turns "what does this do" into something
# that can be asserted. The same harness, run against the deleted script,
# is what established that the move preserved behaviour.
#
# ASSERTED AS PROPERTIES, NOT AS A GOLDEN FILE. A recorded transcript
# compared whole is a test whose failure mode is "update it until green";
# what matters here is which calls happen and which do NOT.
set -euo pipefail
cd "$(dirname "$0")/.."
# ONE SHAPE IN EVERY SUITE ([[WI-2026-09-11-013]]): `$*` so a message
# given unquoted is not truncated to its first word, and stderr so a
# failure is not interleaved with the ok lines on stdout. There were
# four shapes across seven files.
fail() { echo "FAIL: $*" >&2; [ -n "${TRACE:-}" ] && sed 's/^/    /' "$TRACE" >&2; exit 1; }

REAL_BIN="$PWD/zig-out/bin/synapty"
[ -x "$REAL_BIN" ] || { echo "FAIL: build $REAL_BIN first (zig build)" >&2; exit 1; }
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"

# THE PAYLOADS ARE MADE HERE, NOT FOUND ([[WI-2026-09-09-015]]).
#
# This used to require a real cross-compiled binary and a real compiled
# terminfo entry, and SKIP with exit 0 when either was absent. Neither
# `just deploy-all` nor `just ghosttykit` is in `just test`'s dependency
# chain, and CI runs ghosttykit AFTER it — so on the gate the first guard
# fired and a hundred and sixty lines guarding the newest code in the repo
# reported success having asserted nothing. Measured in an empty tree
# holding only the CLI: `SKIP: no linux-x86_64 deploy binary`, exit 0.
#
# WHAT IS UNDER TEST IS THE SEQUENCE OF SIDE EFFECTS, not the contents of
# what is copied: the checksum comparison works on any bytes. So the binary
# is copied into a tree of its own and both payloads are synthesised where
# it looks for them — `<exe>/../<platform>/synapty` and
# `<exe>/../../ghostty/…`. The suite now needs nothing but `zig build`, and
# there is no path through it that passes without asserting.
mkdir -p "$SANDBOX/tree/zig-out/bin" "$SANDBOX/tree/zig-out/linux-x86_64" \
         "$SANDBOX/tree/ghostty/zig-out/share/terminfo/78"
cp "$REAL_BIN" "$SANDBOX/tree/zig-out/bin/synapty"
BIN="$SANDBOX/tree/zig-out/bin/synapty"
DEPLOY="$SANDBOX/tree/zig-out/linux-x86_64/synapty"
TERMINFO="$SANDBOX/tree/ghostty/zig-out/share/terminfo/78/xterm-ghostty"
printf 'a cross-compiled binary, for the purposes of a checksum\n' > "$DEPLOY"
printf 'a compiled terminal description\n' > "$TERMINFO"

# THE HOST THAT IS NOT THERE. It records every call with its arguments and
# its standard input, answers the three scripts the setup sends, and obeys
# the knobs each case sets. `-MNf` leaves a marker so a check that FOLLOWS
# it succeeds, which is what a real host does: ssh returns from -MNf once
# the master is listening.
cat > "$SANDBOX/bin/ssh" <<'STUB'
#!/bin/bash
{ printf 'ssh'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$TRACE"
for a in "$@"; do
  [ "$a" = "-MNf" ] && { [ "${FAKE_OPEN_FAILS:-0}" = 1 ] && exit 1; : > "$TRACE.master"; exit 0; }
done
for a in "$@"; do
  [ "$a" = "check" ] && { [ -e "$TRACE.master" ] && exit 0; exit 1; }
  [ "$a" = "forward" ] && exit "${FAKE_FORWARD_OK:-0}"
done
last="${!#}"
case "$last" in
  "sh -s")
    IN=$(cat)
    { echo "--- stdin ---"; printf '%s\n' "$IN"; echo "--- end stdin ---"; } >> "$TRACE"
    case "$IN" in
      *"PLATFORM="*) printf 'PLATFORM=%s\nBIN_MD5=%s\nTI78_MD5=%s\nTIX_MD5=%s\n' \
          "${FAKE_PLATFORM:-Linux x86_64}" "${FAKE_BIN_MD5:-stale}" \
          "${FAKE_TI_MD5:-stale}" "${FAKE_TI_MD5:-stale}" ;;
      *"kill -0"*) echo "Replaced the running hub (was pid 4242, older binary)." ;;
      *"HUB_BUILD="*) echo "HUB_BUILD=abc123"; echo "HUB_BINARY=abc123" ;;
    esac
    exit 0 ;;
  *"hub --ensure"*)
    # `${VAR-default}`, NOT `${VAR:-default}`. The second substitutes for
    # an EMPTY value too, so the case that sets it empty to mean "this
    # host has no hub" answered with a hub anyway and tested nothing.
    port="${FAKE_HUB_PORT-9123}"
    [ -n "$port" ] && echo "{\"port\":${port},\"pid\":7,\"started\":false}"
    exit 0 ;;
esac
exit 0
STUB
cat > "$SANDBOX/bin/scp" <<'STUB'
#!/bin/bash
{ printf 'scp'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$TRACE"
exit 0
STUB
chmod +x "$SANDBOX/bin/ssh" "$SANDBOX/bin/scp"

setup() {   # runs host-setup against the fake host; $OUT/$ERR/$TRACE hold what happened
    TRACE="$SANDBOX/$1.trace"; OUT="$SANDBOX/$1.out"; ERR="$SANDBOX/$1.err"
    : > "$TRACE"; rm -f "$TRACE.master"
    [ "${PREOPEN:-0}" = 1 ] && : > "$TRACE.master"
    rm -rf "${SANDBOX:?}/home"; mkdir -p "$SANDBOX/home"
    TRACE="$TRACE" HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" \
        "$BIN" host-setup --host example.test --port 2222 --user someone \
        --tunnel-port "${TUNNEL_PORT:-9000}" --key /keys/id --peer-id "lab one" \
        --forward local:8080:localhost:80 > "$OUT" 2> "$ERR" || true
}
saw()    { grep -qF "$1" "$TRACE" || fail "$2"; }
saw_not(){ grep -qF "$1" "$TRACE" && fail "$2"; return 0; }
said()   { grep -qF "$1" "$OUT" || fail "$2 — said: $(cat "$OUT")"; }
said_not(){ grep -qF "$1" "$OUT" && fail "$2 — said: $(cat "$OUT")"; return 0; }

# ---------------------------------------------------------------------------
# A HOST WITH NOTHING ON IT.
# ---------------------------------------------------------------------------
FAKE_BIN_MD5=stale FAKE_TI_MD5=stale setup fresh

saw "[-MNf]" "no ControlMaster was opened"
saw "[-L] [8080:localhost:80]" "host-setup: the human's own forwarding does not ride the master"
saw "[sh -s]" "the host was never asked what it has"
saw 'echo "PLATFORM=$(uname -sm)"' "the probe does not ask what the host is"
# REMOVED BEFORE IT IS WRITTEN. Linux allows unlinking a running
# executable — it stays in memory — but writing to an active text segment
# fails with ETXTBSY.
saw "[rm -f .synapty/bin/synapty]" "the old binary is overwritten in place"
saw ":.synapty/bin/synapty]" "the binary was never sent"
saw "[chmod +x .synapty/bin/synapty]" "the binary was sent without being made runnable"
saw ":.terminfo/78/xterm-ghostty]" "the terminal description was not sent to the 78 layout"
saw ":.terminfo/x/xterm-ghostty]" "the terminal description was not sent to the x layout"
# THE COPIES GO THROUGH THE MASTER. Each one that does not is a full
# authentication: ~2.2s against ~0.36s.
grep -c "ControlPath=" "$TRACE" | grep -qv '^0$' || fail "the copies did not ride the master"
# A HUB LEFT RUNNING IS RUNNING THE OLD BINARY, and the condition is
# exactly that the upload happened.
saw 'kill -0 "$PID"' "the stale hub was not replaced after an upload"
saw "hub --ensure --peer-id 'lab one'" "the peer id did not reach the hub, quoted whole"
saw "[-O] [forward]" "the peer link was not added to the connection"
said "PEER_PORT=9000" "the workbench was not told which port reaches this host's hub"
said "SETUP_OK" "the run did not report success"
said "Replaced the running hub" "the hub replacement was silent"
said "HUB_BUILD=abc123" "which build is running there was not reported"

# ---------------------------------------------------------------------------
# A HOST THAT ALREADY HAS EVERYTHING. The checksums are the point: this is
# ~9 seconds of a 28-second reconnection ([[WI-2026-08-17-018]]).
# ---------------------------------------------------------------------------
BIN_MD5="$(md5 -q "$DEPLOY" 2>/dev/null || md5sum "$DEPLOY" | awk '{print $1}')"
TI_MD5="$(md5 -q "$TERMINFO" 2>/dev/null || md5sum "$TERMINFO" | awk '{print $1}')"
PREOPEN=1 FAKE_BIN_MD5="$BIN_MD5" FAKE_TI_MD5="$TI_MD5" setup warm

saw_not "[-MNf]" "a second ControlMaster was opened beside the live one"
saw_not "scp" "something was copied to a host that already had it"
saw_not "kill -0" "the hub was replaced although nothing was uploaded"
said "Binary unchanged, skipping upload." "the skip was not reported"
said "PEER_PORT=9000" "a host that needed nothing lost its peer link"

# ---------------------------------------------------------------------------
# A HOST WHOSE HUB WILL NOT START. Honest degradation: the shell works,
# A2A for this host does not, and we say which.
# ---------------------------------------------------------------------------
PREOPEN=1 FAKE_BIN_MD5="$BIN_MD5" FAKE_TI_MD5="$TI_MD5" FAKE_HUB_PORT='' setup nohub
grep -qF "no hub could be started" "$ERR" || fail "a host with no hub said nothing"
said_not "PEER_PORT=" "a peer link was advertised to a hub that is not there"
said "SETUP_OK" "a host without A2A is still a host that works"

# ---------------------------------------------------------------------------
# A HOST THAT WILL NOT HOLD A CONNECTION. Every step opens its own, slowly
# — so the setup still runs, and the peer link is the one thing that
# cannot be carried. Saying so is what stops the local hub dialling a port
# nothing is listening on.
# ---------------------------------------------------------------------------
FAKE_OPEN_FAILS=1 FAKE_BIN_MD5="$BIN_MD5" FAKE_TI_MD5="$TI_MD5" setup nomaster
grep -qF "could not establish a ControlMaster" "$ERR" || fail "a master that failed was not reported"
grep -qF "the peer link cannot be carried" "$ERR" || fail "the missing peer link was not reported"
said_not "PEER_PORT=" "a peer port was advertised with no connection to carry it"
said "SETUP_OK" "a host without a master is still usable"
saw_not "ControlPath=" "a copy claimed to ride a master that was never opened"

# ---------------------------------------------------------------------------
# A MACHINE THIS PROJECT BUILDS NOTHING FOR.
#
# `FAKE_PLATFORM` sat in the stub with nothing ever setting it, so every
# case answered `Linux x86_64` and the one row of a five-row table was the
# only one exercised — while the `null` return, the branch that decides a
# host gets no binary at all, was reached by nothing
# ([[WI-2026-09-11-003]]).
#
# AND THE SENTENCE IS DERIVED NOW, from the same table that refuses. It
# used to be prose written out beside it, and the two had already drifted
# in form: the message said `Linux/aarch64` where `uname -sm` and the
# table both say `Linux aarch64`.
# ---------------------------------------------------------------------------
FAKE_PLATFORM="SunOS sun4v" FAKE_BIN_MD5=stale FAKE_TI_MD5=stale setup alien
said "Unsupported platform: SunOS sun4v" "an unsupported host was not named"
said "Linux aarch64" "the supported list does not name what uname actually says"
said_not "SETUP_OK" "a host with no binary for it was reported as set up"
saw_not ":.synapty/bin/synapty]" "a binary was sent to a machine that cannot run one"

# ---------------------------------------------------------------------------
# A PEER FORWARD THE MASTER REFUSED.
#
# `FAKE_FORWARD_OK` sat in the stub from the day it was written and
# nothing ever set it, so `ssh -O forward` succeeded on every run of every
# case and this branch was reached by no layer — not Zig, not Swift, not
# here. The code it guards carries its own note that the failure is worse
# than the absence of the feature: "VERIFY RATHER THAN ASSUME: a PEER_PORT
# nobody is listening on is worse than none" ([[WI-2026-09-11-002]]).
#
# NOT THE SAME BRANCH AS `nomaster`. That one has no master to add a
# forward to; this one has a master that REFUSED the request, and the two
# say different things.
#
# THE PORT IS PROBED FIRST, because the production check is a real connect
# to loopback and this machine may well be running a hub on 9000.
# ---------------------------------------------------------------------------
# NAMED APART FROM [[lib.sh]]'s `free_port`, WHICH THIS FILE SOURCES.
# This one takes a port to skip, walks a fixed range and returns non-zero
# when all five are busy; that one takes nothing and asks the kernel. The
# local definition wins, so the day this suite calls `start_hub` — which
# does `HUB_PORT="${HUB_PORT:-$(free_port)}"` — it would silently get the
# five-port version and, on exhaustion, an empty HUB_PORT with no message.
# That is the class of failure the shared library was written to end
# ([[WI-2026-09-12-002]]).
spare_port() {   # $1 = a port to skip, if any
    local p
    for p in 9471 9472 9473 9474 9475; do
        [ "$p" = "${1:-}" ] && continue
        nc -z 127.0.0.1 "$p" >/dev/null 2>&1 || { printf '%s' "$p"; return 0; }
    done
    return 1
}
DEAD_PORT="$(spare_port)" || fail "no free loopback port to test a refused forward with"

FAKE_FORWARD_OK=1 TUNNEL_PORT="$DEAD_PORT" \
    FAKE_BIN_MD5="$BIN_MD5" FAKE_TI_MD5="$TI_MD5" setup refused
saw "[forward]" "the peer forward was never attempted"
grep -qF "could not establish the peer forward on $DEAD_PORT" "$ERR" \
    || fail "a refused forward was not reported — said: $(cat "$ERR")"
said_not "PEER_PORT=" "a peer port was advertised for a forward the master refused"
said "SETUP_OK" "a refused peer forward took the whole host down with it"

# AND THE OTHER HALF: refused because it is ALREADY THERE. Same exit
# status from ssh, opposite meaning — and the only way to tell them apart
# is that something answers on the port, which is why the check exists.
LIVE_PORT="$(spare_port "$DEAD_PORT")" || fail "no free loopback port to listen on"
# `-k`, OR THE PROBE BELOW KILLS WHAT IT IS PROBING FOR: BSD `nc -l`
# serves one connection and exits, and both the readiness check here and
# `listening()` in the binary are connects.
nc -k -l "$LIVE_PORT" >/dev/null 2>&1 &
NC_PID=$!
trap 'kill "$NC_PID" 2>/dev/null' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
    nc -z 127.0.0.1 "$LIVE_PORT" >/dev/null 2>&1 && break
    sleep 0.2
done
nc -z 127.0.0.1 "$LIVE_PORT" >/dev/null 2>&1 \
    || fail "could not put a listener on $LIVE_PORT to test the present-forward branch"

FAKE_FORWARD_OK=1 TUNNEL_PORT="$LIVE_PORT" \
    FAKE_BIN_MD5="$BIN_MD5" FAKE_TI_MD5="$TI_MD5" setup present
said "peer forward $LIVE_PORT already present" \
    "a forward that was already there was reported as a failure"
said "PEER_PORT=$LIVE_PORT" "a working peer link was not advertised"
kill "$NC_PID" 2>/dev/null; trap - EXIT

# ---------------------------------------------------------------------------
# A DRY RUN TOUCHES NOTHING.
#
# `--print` promises to say what would run and connect to nothing. It
# printed the master invocation and then carried straight on into the
# probe — a real ssh, whose first act on the far side is `mkdir -p`, and
# whose success would have carried the run into `rm -f`, `scp`, `chmod +x`
# and the script that kills the host's running hub by pid. A dry run that
# stops the thing it was inspecting ([[WI-2026-09-10-001]]).
#
# ASSERTED ON THE TRACE, because "touched nothing" is a claim about what
# was spawned rather than about what was printed.
# ---------------------------------------------------------------------------
TRACE="$SANDBOX/print.trace"; OUT="$SANDBOX/print.out"
: > "$TRACE"; rm -f "$TRACE.master"
rm -rf "${SANDBOX:?}/home"; mkdir -p "$SANDBOX/home"
TRACE="$TRACE" HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" \
    SYNAPTY_CONNECT_LOG="$SANDBOX/print-account.log" \
    "$BIN" host-setup --print --host example.test --port 2222 --user someone \
    --tunnel-port 9000 --peer-id "lab one" > "$OUT" 2>&1 || true

[ ! -s "$TRACE" ] || fail "a dry run spawned ssh: $(cat "$TRACE")"
[ ! -s "$SANDBOX/print-account.log" ] \
    || fail "a dry run wrote the account of a real connection: $(cat "$SANDBOX/print-account.log")"
# AND IT STILL SAYS WHAT IT WOULD DO, which is the whole point of the flag.
grep -q -- "-MNf" "$OUT" || fail "a dry run did not say how it would open the connection: $(cat "$OUT")"
grep -q -- "sh -s" "$OUT" || fail "a dry run did not say how it would ask the host what it has: $(cat "$OUT")"

echo "host-setup: OK (fresh, warm, no hub, no master, unsupported platform, forward refused, forward present, dry run)"
