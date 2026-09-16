#!/bin/bash
# The master socket must reach ssh as ONE argument carrying no quoting of
# its own ([[WI-2026-08-17-017]]).
#
# WHAT BROKE, AND WHY THE SHAPE IS THE TEST. The socket was passed as a
# STRING — `SSH_CMD="-S '$SOCKET'"`, expanded unquoted — which handed ssh a
# path whose first and last characters were apostrophes. No such socket, so
# every step of a host's setup opened a NEW connection to a host that
# already had one open: 2.175s per call against 0.362s multiplexed, most of
# a 28-second reconnection. A string that LOOKS quoted is not an argument
# that IS one.
#
# ASKED OF THE BINARY THAT BUILDS IT ([[ADR-0020]]). This used to `sed` a
# line range out of setup-host.sh and `eval` it; that file is gone, and the
# question is now put to the thing that answers it. `--print` shows the
# arguments as they would be passed, so a value carrying a space appears as
# one quoted word.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$PWD/zig-out/bin/synapty"
[ -x "$BIN" ] || { echo "FAIL: build $BIN first (zig build)" >&2; exit 1; }
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

# A space in the path, so a string form cannot pass by luck.
SOCKET="/tmp/synapty test/sock:22"

printed="$("$BIN" host-master --print --host example.test --user someone \
    --socket "$SOCKET" | tail -1)"
[ "$printed" = "-S '/tmp/synapty test/sock:22'" ] \
    || fail "the socket does not reach ssh as one argument: [$printed]"

# AND THE MASTER IT WOULD OPEN CARRIES THE SAME SOCKET, whole, plus what
# makes it outlive this process and what makes a dead one noticed.
opened="$("$BIN" host-master --print --host example.test --user someone \
    --socket "$SOCKET" --forward local:8080:127.0.0.1:80 | head -1)"
case "$opened" in
    "ssh -MNf -S '/tmp/synapty test/sock:22' "*) ;;
    *) fail "the master is not opened on that socket: $opened" ;;
esac
case "$opened" in
    *"-o ControlPersist=yes"*) ;;
    *) fail "the master would not outlive this process: $opened" ;;
esac
case "$opened" in
    *"-L 8080:127.0.0.1:80"*) ;;
    # NAMED FOR ITS ENTRY POINT. `test-host-setup.sh` asserts the same
    # property of the same function through the other subcommand, and the
    # two messages were identical — so a failure could not say which
    # caller had stopped carrying it ([[WI-2026-09-11-013]]).
    *) fail "host-master: the human's own forwarding does not ride the master: $opened" ;;
esac
# NOT ExitOnForwardFailure. A host that cannot carry one of the human's
# forwardings still carries panes, and refusing the master would take
# those with it — which is the one option the dial has and this does not.
case "$opened" in
    *ExitOnForwardFailure*) fail "a forwarding it cannot make would refuse the master: $opened" ;;
esac

echo "host-master socket: OK (one argument, quotes and all; persists; carries forwardings)"
