# shellcheck shell=bash
# Shared scaffolding for the end-to-end suites.
#
# WHY THIS EXISTS. Seven suites each stood entirely alone, and the parts
# that are not about what a suite tests were written out once per file:
# `fail` in four shapes, the free-port one-liner four times, the
# config-root preamble four times, the hub-start-and-wait block
# byte-identical in two, and the pane socket's `/tmp/synapty-<pid>.sock`
# convention a fourth time beyond the three in `src/`
# ([[WI-2026-09-11-017]]).
#
# THE SHAPES WERE ALREADY DIVERGING, which is what makes it worth a file
# rather than a preference: `fail` took `$1` in four suites and `$*` in
# two, so a message given unquoted was truncated to its first word, and
# three of them wrote to stdout where a failure interleaves with the ok
# lines.
#
# WHAT STAYS IN EACH SUITE is everything about what it tests — its fakes,
# its assertions, and any extra a failure should dump. A suite is still
# runnable on its own: `bash scripts/test-holder-e2e.sh` sources this by
# path relative to itself, not through the justfile.
#
# `shellcheck -x` follows the source, so the gate reads this file too.

# FAIL, IN ONE SHAPE. `$*` so a message given unquoted is not truncated;
# stderr so it does not interleave with the ok lines a human is reading.
fail() { echo "FAIL: $*" >&2; exit 1; }

# A PORT NOTHING IS ON. Asked of the kernel rather than guessed: bind to
# 0, read back what was given, close. The override a human debugging pins
# is `HUB_PORT`, and it is honoured one function down in `start_hub` —
# this said so here, about a function that takes no arguments and reads no
# variable ([[WI-2026-09-12-002]]).
free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

# THE PANE IPC SOCKET, NAMED THE WAY THE BINARY NAMES IT
# ([[ipc.pane_socket]]). The convention had four authors — the creator,
# the sweeper, `mcp-serve`'s discoverer, and here.
pane_socket_dir="/tmp"
pane_socket_prefix="synapty-"
pane_socket_suffix=".sock"
pane_socket_path() { printf '%s/%s%s%s' "$pane_socket_dir" "$pane_socket_prefix" "$1" "$pane_socket_suffix"; }

# A CONFIG ROOT OF ITS OWN, so a suite never reads or writes the config
# the operator actually uses. This project has clobbered a real
# hosts.json and renamed a real machine from a test.
isolate_config() {
    mkdir -p "$1/config"
    export SYNAPTY_CONFIG_ROOT="$1/config"
}

# A HUB ON A PORT OF ITS OWN, AND WAITED FOR. Sets HUB_PORT and HUBPID.
# `--strict-port` so it fails rather than climbing the ladder into
# somebody else's hub; `--no-state` so it carries nothing between runs.
start_hub() {   # $1 = the temp directory to log and discover in
    HUB_PORT="${HUB_PORT:-$(free_port)}"
    export SYNAPTY_HUB_PORT="$HUB_PORT"
    "$BIN" hub --port "$HUB_PORT" --strict-port --no-state \
        --discovery-path "$1/hub.json" > "$1/hub.log" 2>&1 &
    # shellcheck disable=SC2034  # read by the sourcing suite's cleanup trap
    HUBPID=$!
    for _ in $(seq 50); do
        nc -z 127.0.0.1 "$HUB_PORT" 2>/dev/null && return 0
        sleep 0.1
    done
    fail "the hub never came up on $HUB_PORT: $(cat "$1/hub.log" 2>/dev/null)"
}
