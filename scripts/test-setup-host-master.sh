#!/bin/bash
# The master socket must reach ssh as ONE argument carrying no quoting of
# its own ([[WI-2026-08-17-017]]). Driven through the real construction in
# setup-host.sh rather than a copy of it: what broke was the difference
# between a string that LOOKS quoted and an argument that IS one.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $1" >&2; exit 1; }

# A space in the path, so a string form cannot pass by luck.
SOCKET="/tmp/synapty test/sock:22"

# Read by the eval'd snippet, which shellcheck cannot see into.
# shellcheck disable=SC2034
CM_ACTIVE=true
# shellcheck disable=SC1090
eval "$(sed -n '/^SSH_MASTER=()/,/^fi$/p' scripts/setup-host.sh)"
set -- ${SSH_MASTER[@]+"${SSH_MASTER[@]}"}
[ "$#" -eq 2 ] || fail "a live master reaches ssh as $# arguments, not 2: $*"
[ "$1" = "-S" ] || fail "the first argument is not -S: $1"
# THE POINT OF THE WHOLE TEST: no apostrophes came along for the ride.
[ "$2" = "$SOCKET" ] || fail "the socket argument is not the socket path: [$2]"

# shellcheck disable=SC2034
CM_ACTIVE=false
# shellcheck disable=SC1090
eval "$(sed -n '/^SSH_MASTER=()/,/^fi$/p' scripts/setup-host.sh)"
set -- ${SSH_MASTER[@]+"${SSH_MASTER[@]}"}
# Absent, and absent WITHOUT tripping `set -u` — which is the hazard the
# broken string form was reaching for when it introduced this one.
[ "$#" -eq 0 ] || fail "with no master, ssh is still given $# arguments: $*"

echo "setup-host master socket: OK (one argument, quotes and all; empty when absent)"
