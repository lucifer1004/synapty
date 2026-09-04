# Synapty — The Agent Workbench

# ---------------------------------------------------------------------------
# External tools
#
# require() resolves at parse time and names the missing tool. Without it a
# fresh checkout fails with a bare "command not found" from inside a
# recipe, which says nothing about WHICH step needed WHAT — and xcodegen
# is exactly the one nobody has by default.
#
# NEITHER TOOL IS RESOLVED AT PARSE TIME. A runner that only checks
# governance has no xcodegen and one that only builds has no govctl, and a
# parse-time require made every `just` invocation there fail before it
# began — the governance job died on a missing xcodegen the first time it
# ran ([[WI-2026-09-02-031]], [[WI-2026-09-02-036]]). The recipes that need
# a tool check for it themselves and say how to get it.
# ---------------------------------------------------------------------------

XCODEGEN := env("XCODEGEN", "xcodegen")
GOVCTL   := env("GOVCTL", "govctl")

[private]
_xcodegen:
    @command -v {{ XCODEGEN }} >/dev/null || { echo "xcodegen is not installed — brew install xcodegen" >&2; exit 1; }

# ---------------------------------------------------------------------------
# The version
#
# ONE PLACE: build.zig.zon. It was hand-synced across three files and the
# three could disagree without anything noticing ([[WI-2026-09-02-028]]).
# project.yml reads it from the environment when the project is generated,
# `package` stamps it on every artifact and refuses a tag that says
# otherwise, and the cask is rendered from it.
# ---------------------------------------------------------------------------

VERSION := shell("sed -n 's/^ *\\.version = \"\\(.*\\)\",$/\\1/p' build.zig.zon")

# Default: build all Zig executables
default: build

# Build the synapty binary
[group("build")]
build:
    zig build

# Run all Zig tests, then the e2e scripts — which run zig-out/bin/synapty,
# so the binary is built first; `zig build test` compiles it but does not
# install it, and a clean checkout had no old one to fall back on
# ([[WI-2026-09-02-036]]).
[group("test")]
test: build
    zig build test
    ./scripts/test-connect-launch.sh
    ./scripts/test-holder-e2e.sh
    ./scripts/test-send-answer-e2e.sh
    ./scripts/test-pane-socket-e2e.sh
    ./scripts/test-setup-host-master.sh

# Lint every shell script ([[WI-2026-09-02-018]]). GATED AT WARNING: the
# e2e scripts split `$BIN` and `$HUB` on purpose, which is shellcheck's
# info-level SC2086 forty times over; a gate that fails on it would be
# silenced wholesale. Warnings (unused variables, an unchecked cd) fail
# the build; `shellcheck -x scripts/*.sh` still lists the rest for a
# reader who wants it.
[doc("Lint every shell script")]
[group("test")]
lint-sh:
    shellcheck -x -S warning scripts/*.sh

# Build GhosttyKit xcframework from submodule
[group("build")]
ghosttykit:
    https_proxy= http_proxy= ./scripts/build-ghosttykit.sh

# Build GhosttyKit (debug)
[group("build")]
ghosttykit-debug:
    https_proxy= http_proxy= ./scripts/build-ghosttykit.sh Debug

# Generate Xcode project from project.yml
[group("build")]
xcgen: _xcodegen
    #!/usr/bin/env bash
    set -euo pipefail
    # REGENERATE ONLY WHEN THE INPUTS CHANGED.
    #
    # xcodegen rewrites the project every time it runs, and a build started
    # immediately after that rewrite intermittently fails in ways that are
    # nothing to do with the code — "The test runner hung before
    # establishing connection", or a bare exit 65 with no compiler error and
    # no failing test named. Three of those cost real time, one of them a
    # round of bisecting three innocent source files.
    #
    # The inputs are the spec and the SET OF FILES, because the spec globs
    # directories: adding or removing a source changes the project, editing
    # one does not. EVERY DIRECTORY THE SPEC GLOBS, which is the part that
    # was wrong: `UITests` was left out when that target was added, so a new
    # UI test file did not regenerate the project and never ran at all — the
    # suite reporting green while testing nothing. Hashing paths rather than
    # contents keeps this cheap enough to run before every build.
    stamp=".xcodegen-stamp"
    # LC_ALL for shasum too: perl warns on this machine's en_CN locale and
    # the warning would end up inside the hash.
    export LC_ALL=C
    # The version is an input too: project.yml takes it from the
    # environment, so a bump with no file added or removed must still
    # regenerate.
    inputs=$( { echo "{{ VERSION }}"; shasum project.yml; \
                find Sources Tests UITests -type f \( -name '*.swift' -o -name '*.h' -o -name '*.m' \) \
                    | sort; } | shasum | cut -d' ' -f1 )
    if [ -d Synapty.xcodeproj ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$inputs" ]; then
        exit 0
    fi
    SYNAPTY_VERSION="{{ VERSION }}" {{ XCODEGEN }} generate --spec project.yml
    printf '%s' "$inputs" > "$stamp"

# Build macOS GUI app (Debug). Depends on `zig build`: the app SPAWNS the
# hub as a supervised sidecar and bundles the CLI binary it spawns
# (zig-out/bin/synapty) — ADR-0008.
[doc("Build the macOS GUI app (Debug)")]
[group("build")]
app: build xcgen
    xcodebuild -project Synapty.xcodeproj -scheme Synapty -configuration Debug -destination 'platform=macOS' build

# Build macOS GUI app (Release)
[group("build")]
app-release: build xcgen
    xcodebuild -project Synapty.xcodeproj -scheme Synapty -configuration Release -destination 'platform=macOS' build

# Run the GUI app
[group("dev")]
run: app
    #!/usr/bin/env bash
    set -euo pipefail
    app="$(echo ~/Library/Developer/Xcode/DerivedData/Synapty-*/Build/Products/Debug/Synapty.app)"
    [ -d "$app" ] || { echo "no Debug build at $app"; exit 1; }
    # ONE AT A TIME. Two instances contend for the hub port, and the
    # loser spends its startup waiting for something it will not get.
    #
    # ASKED TO QUIT, NOT KILLED, and this is load-bearing rather than
    # polite. A Synapty that dies to SIGTERM leaves something behind that
    # keeps the NEXT `xcodebuild test` from ever connecting to its host
    # app: the run fails with "the test runner hung before establishing
    # connection", every time, until the app target is REBUILT. Measured
    # rather than guessed — a graceful quit leaves the gate green; a
    # pkill poisons it; killing every leftover process does not clear it;
    # waiting does not; `lsregister -f -R` does not; touching one source
    # file and rebuilding does. Launching a COPY of the bundle poisons it
    # too, so what is remembered is keyed to the signature and not to the
    # path — which is why a rebuild, and only a rebuild, changes it.
    #
    # Two red `just verify` runs in one session came from this recipe,
    # and both looked like a regression in the code under test.
    if pgrep -x Synapty >/dev/null 2>&1; then
        osascript -e 'tell application "Synapty" to quit' >/dev/null 2>&1 || true
        for _ in $(seq 1 20); do
            pgrep -x Synapty >/dev/null 2>&1 || break
            sleep 0.25
        done
        # It would not go. A wedged instance holding the port is worse
        # than a poisoned gate, so the kill stays as the last resort —
        # and says what it costs.
        if pgrep -x Synapty >/dev/null 2>&1; then
            echo "note: Synapty did not quit when asked; killing it." >&2
            echo "      the next 'just test-swift' will need a rebuild." >&2
            pkill -x Synapty 2>/dev/null || true
        fi
    fi
    # SCRUBBED, AND NOT AS TIDINESS. The app hands its environment to
    # every pane shell, so a launch from inside an agent's terminal puts
    # that agent's session id in front of every agent the workbench
    # starts. One asked for its own resume identity will find that
    # variable and report it in good faith — a resume_ref is VALIDATED
    # for shape and never verified for ownership, so the plan it composes
    # is typed into a pane on somebody else's session.
    #
    # BY PATTERN, NOT BY LIST: the next tool to invent `<TOOL>_SESSION_ID`
    # is the one a list would miss.
    scrub=()
    while read -r name; do scrub+=(-u "$name"); done < <(
        env | cut -d= -f1 | grep -E '^(CLAUDE|ANTHROPIC|CODEX|GEMINI|KIMI)|_SESSION_ID$' || true
    )
    # DIRECTLY, NOT THROUGH `open`: `env -u` cannot reach a process
    # LaunchServices starts on our behalf, and the scrub above is the
    # whole point of the recipe.
    # `${a[@]+"${a[@]}"}` AND NOT `"${a[@]}"`: macOS ships bash 3.2, where
    # expanding an empty array under `set -u` is an error rather than
    # nothing. A shell with none of these variables set — which is the
    # ordinary case, and the one this recipe exists for — would otherwise
    # fail to launch the app at all.
    nohup env ${scrub[@]+"${scrub[@]}"} "$app/Contents/MacOS/Synapty" \
        >/tmp/synapty-run.log 2>&1 &
    disown
    echo "running: $app"
    echo "log: /tmp/synapty-run.log"

# Full build: Zig + GhosttyKit + GUI app
[group("build")]
all: build ghosttykit app

[private]
_govctl:
    @command -v {{ GOVCTL }} >/dev/null || { echo "govctl is not installed — cargo install govctl" >&2; exit 1; }

# Validate every governed document
[group("gov")]
gov-check: _govctl
    {{ GOVCTL }} check

# Render govctl artifacts to docs/
[group("gov")]
gov-render: _govctl
    {{ GOVCTL }} render

# Show govctl project status
[group("gov")]
gov-status: _govctl
    {{ GOVCTL }} status

# Cross-compile all deploy targets
[group("build")]
deploy-all:
    zig build deploy-linux-aarch64 deploy-linux-x86_64 deploy-linux-riscv64 deploy-macos-aarch64 deploy-macos-x86_64

# Build and test with the Homebrew zig toolchain
[group("test")]
check:
    zig build
    zig build test

# There was a recipe for the Zig tests and none for these, so every run of
# them was a hand-typed xcodebuild invocation — which is how one of the two
# suites gets skipped before a commit without anyone deciding to skip it.
#
# AND IT NEEDS AN UNLOCKED SCREEN TOO — see the note above `test-ui`,
# which is where the measurement is written down. This one is the worse
# of the two to diagnose, because the filter below prints nothing but
# `** TEST FAILED **` when the runner never reaches a test.
[doc("Run the Swift test suite (GUI + services)")]
[group("test")]
test-swift: xcgen
    #!/usr/bin/env bash
    set -euo pipefail
    # CAPTURE ONCE, then filter and judge the same run.
    #
    # This used to run xcodebuild TWICE — once through grep for the human
    # and once discarded for the exit status, because grep reports its own
    # status and a green pipeline can hide a red build. That doubled every
    # test run, and the two builds could disagree: a project regenerated
    # between them produced a passing display and a failing verdict for the
    # same code.
    log=$(mktemp -t synapty-test-swift)
    trap 'rm -f "$log"' EXIT
    status=0
    # UNSIGNED ON A RUNNER. The Debug configuration signs with an Apple
    # Development identity that exists on a developer's Mac and on no CI
    # image; xcodebuild then fails in five seconds before compiling a
    # line, and the tests never run ([[WI-2026-09-02-038]]). Nothing the
    # unit suite checks depends on the signature.
    # `${arr[@]+"${arr[@]}"}` below: under `set -u`, bash 3.2 reads an
    # EMPTY array's expansion as an unbound variable, and this recipe died
    # on line one of xcodebuild while reporting exit 0 to its caller.
    SIGNING=()
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        SIGNING=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=)
    fi
    # BUILD FIRST, AS A BUILD, and this is not the same work `test` does
    # on its way in. Without it this recipe fails outright — "the test
    # runner hung before establishing connection", no test ever run —
    # whenever certain other things happened first: a `zig build` that
    # replaced zig-out/bin/synapty (so `just verify`, which runs the Zig
    # suite before this one, failed every time), or a dev instance that
    # was killed rather than asked to quit.
    #
    # WHAT IS MEASURED AND WHAT IS NOT. Measured: a plain `xcodebuild
    # build` clears it even when it is a no-op, and the run right after
    # is green; killing every leftover process does not clear it; waiting
    # does not; `lsregister -f -R -trusted` does not; the app's signature
    # is valid in the failing state and the bundled helper is unchanged,
    # so it is neither a broken seal nor a stale copy. NOT known: what
    # the build puts back. This line is a workaround with its evidence
    # attached, not an explanation.
    xcodebuild -project Synapty.xcodeproj -scheme Synapty -configuration Debug \
        -destination 'platform=macOS' ${SIGNING[@]+"${SIGNING[@]}"} build >"$log" 2>&1 || {
        # A BUILD THAT FAILS WITHOUT A COMPILER DIAGNOSTIC still has to
        # say something: a signing or destination failure used to leave
        # this recipe exiting 1 in silence.
        grep -E "\.swift:[0-9]+(:[0-9]+)?: error:" "$log" | head -20 >&2 \
            || { echo "xcodebuild failed without a compiler diagnostic; last lines:" >&2; tail -40 "$log" >&2; }
        exit 1
    }
    # ONLY THE UNIT TARGET. The scheme's test action carries every test
    # target, so once SynaptyUITests existed this recipe silently began
    # launching the application five times — a minute of wall clock on a
    # gate that runs before every commit. UI tests have their own recipe.
    xcodebuild -project Synapty.xcodeproj -scheme Synapty -configuration Debug \
        -destination 'platform=macOS' ${SIGNING[@]+"${SIGNING[@]}"} -only-testing:SynaptyTests test >"$log" 2>&1 || status=$?
    # WHAT A FAILING RUN HAS TO SAY, all three parts of it:
    #   `<file>.swift:N: error:`    — an XCTest ASSERTION.
    #   `<file>.swift:N:C: error:`  — a COMPILER diagnostic, which carries a
    #     column the assertion does not. One pattern with the column
    #     optional covers both; two patterns is how the column was missed
    #     the first time this was "fixed".
    #   `\tSuite.testName()`        — the names under "Failing tests:",
    #     without which that heading is a title with no content.
    #
    # The original pattern was `error:.*\.swift:` — the path AFTER the word,
    # which is neither of the two formats, so it matched nothing that
    # mattered and a failing run said only "** TEST FAILED **".
    grep -E "Executed [0-9]+ tests|\.swift:[0-9]+(:[0-9]+)?: error:|Failing tests|^\s+[A-Za-z_][A-Za-z0-9_]*\.test[A-Za-z0-9_]*\(\)|\*\* TEST" "$log" \
        | grep -v "linkd\|NSCocoaErrorDomain" || true
    exit $status

# Methods a test exercises and nothing ships
#
# NOT A DEAD-CODE CHECK, and the difference is the whole reason it is
# narrow enough to be read. A general one is loud here — protocol
# conformances, SwiftUI hooks and selector targets all look unreferenced —
# and a loud report is one nobody opens.
#
# WHAT IT LOOKS FOR is the pair that let three defects reach a green suite
# in one session: a helper with tests, and a shipped path holding an
# inlined copy of it that had already drifted. `migratePane` had two
# tests, no production caller, and a twin at the call site that had
# inverted the very property those tests pin.
#
# A finding is not "delete this". It is "wire it or drop it, and say
# which" — a method kept for a caller nobody has written is a decision,
# and this asks for it to be a recorded one rather than an accident.
[doc("Find methods a test exercises and no shipped code calls")]
[group("test")]
unshipped:
    python3 scripts/unshipped.py

# Measure what a copy costs a terminal on the same connection
#
# NOT PART OF `verify` and never will be: it opens real masters to a real
# host, moves hundreds of megabytes over somebody's link and takes minutes.
# It exists because [[RFC-0013]] C-BROKER rests on a table of numbers that
# no unit test can produce — the head-of-line blocking is in TCP, below
# anything a fake can stand in for.
#
# THE PAYLOAD SIZE IS NOT A DETAIL. On a fast link 60 MB finishes before
# the send buffer ever fills and the run says INCONCLUSIVE rather than
# reporting a pass; 300 MB reproduced it. Raise it until the shared column
# stalls, then read the separate one.
[doc("Measure interactive latency against a copy on one host (minutes, real traffic)")]
[group("test")]
measure-pool host size="300":
    bash scripts/measure-pool.sh {{host}} {{size}}

# NOT PART OF `verify`, deliberately: these launch the application, click
# menus and press chords, so they cost a minute where the unit suite costs
# nine seconds. A pre-commit gate that slow is one people learn to skip.
#
# BOTH OF THESE NEED AN UNLOCKED SCREEN, and the failure does not say so.
#
# A test with a host app needs a login session somebody is logged into
# with the screen awake. Locked, the two suites fail differently and
# neither failure names the cause: `test-ui` reports "Timed out while
# enabling automation mode", and `test-swift` reports "The test runner
# hung before establishing connection" — or, through the filter below,
# nothing at all but `** TEST FAILED **` with not one failing case
# printed. That reads exactly like a code defect.
#
# Measured, after a session spent blaming the code: the same commit is
# green with the screen awake and red with it locked, and none of the
# remedies the `run` recipe records for the SIGTERM poisoning help here,
# because that poisoning is not what is happening — the two failures wear
# the same words and have different causes. Deleting DerivedData does not
# help; touching a source file and rebuilding does not help; unregistering
# the installed copy does not help. Unlocking the screen does.
#
# So a red here is worth one question before it is worth any debugging:
# is somebody logged in at that machine with the screen on?
#
# WHAT GOES IN HERE is a defect that reached the human. Two of the five
# are from the day the suite was written: a reference sheet that was
# complete and instantiated nowhere, and a chord that ran its command
# twice because consuming an event in a monitor does not stop a menu's key
# equivalent. Neither is visible to a unit test.
#
# On failure the result bundle keeps the screenshots each test took;
# `just test-ui-shots` unpacks them.
[doc("Run the UI test suite (launches the app; ~1 min)")]
[group("test")]
test-ui: xcgen
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf /tmp/synapty-uitest.xcresult
    status=0
    xcodebuild -project Synapty.xcodeproj -scheme Synapty -configuration Debug \
        -destination 'platform=macOS' -only-testing:SynaptyUITests \
        -resultBundlePath /tmp/synapty-uitest.xcresult test 2>&1 \
        | grep -E "Test Case .* (passed|failed)|\.swift:[0-9]+(:[0-9]+)?: error:|\*\* TEST" \
        | grep -v "linkd\|NSCocoaErrorDomain" || status=$?
    echo "result bundle: /tmp/synapty-uitest.xcresult"
    exit ${status}

# Unpack the screenshots the UI tests took, into /tmp/synapty-uishots
[doc("Unpack UI-test screenshots from the last run")]
[group("test")]
test-ui-shots:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf /tmp/synapty-uishots && mkdir -p /tmp/synapty-uishots
    xcrun xcresulttool export attachments \
        --path /tmp/synapty-uitest.xcresult --output-path /tmp/synapty-uishots >/dev/null
    python3 - <<'EOF'
    import json
    for test in json.load(open('/tmp/synapty-uishots/manifest.json')):
        for a in test.get('attachments', []):
            print(f"/tmp/synapty-uishots/{a['exportedFileName']}  <-  {a.get('suggestedHumanReadableName','')}")
    EOF

# Throw away Xcode's build cache for this project
#
# WHEN TO REACH FOR THIS: xcodebuild reports "The test runner hung before
# establishing connection" and the suite fails with NO compiler error and NO
# failing test named. That is not your code — it is a corrupted DerivedData,
# and it survives a clean build. It cost an hour of bisecting source files
# that turned out to be innocent, so it has a recipe rather than a memory.
[doc("Throw away Xcode's build cache (fixes 'test runner hung before establishing connection')")]
[group("test")]
clean-derived:
    #!/usr/bin/env bash
    set -euo pipefail
    dir=$(xcodebuild -project Synapty.xcodeproj -scheme Synapty -showBuildSettings 2>/dev/null \
        | awk '/ BUILD_DIR = /{print $3}' | head -1)
    [ -n "${dir:-}" ] || { echo "could not resolve DerivedData"; exit 1; }
    root="${dir%/Build/*}"
    echo "removing $root"
    rm -rf "$root"

# The tests the ordinary suite skips, because their timing is not ours
#
# TWO KINDS OF TEST LIVE HERE and both are opt-in for the same reason: they
# depend on something outside this repository — a reachable host, a system
# notification service — so a red result does not reliably mean the code is
# wrong. A test like that in the pre-commit gate teaches the reader that red
# means "run it again", and that lesson is already learned on the day it
# goes red for a real reason.
#
# They are not decoration. The live-host tests caught that SFTP has no
# tilde, which twelve offline tests had agreed with the codec about, and
# real sshd rejects.
#
# LIVE HOST tests need a ControlMaster already up; the ordinary way to get
# one is to connect to the host in the app first.
[doc("Opt-in tests: real host, real Notification Center")]
[group("test")]
test-integration socket="" userhost="":
    #!/usr/bin/env bash
    set -euo pipefail
    log=$(mktemp -t synapty-test-integration)
    trap 'rm -f "$log"' EXIT
    status=0
    # TEST_RUNNER_ prefix: xcodebuild passes these to the test process with
    # the prefix stripped. Without it they stay in this shell and every
    # test skips while reporting success.
    TEST_RUNNER_SYNAPTY_TEST_NOTIFICATIONS=1 \
    TEST_RUNNER_SYNAPTY_LIVE_SOCKET="{{socket}}" \
    TEST_RUNNER_SYNAPTY_LIVE_USERHOST="{{userhost}}" \
    xcodebuild -project Synapty.xcodeproj -scheme Synapty -configuration Debug \
        -destination 'platform=macOS' \
        -only-testing:SynaptyTests/NotificationDeliveryTests \
        -only-testing:SynaptyTests/RemoteFSLiveTests test >"$log" 2>&1 || status=$?
    grep -E "Test Case.*(passed|failed|skipped)|\.swift:[0-9]+: error:|Executed [0-9]+ tests|\*\* TEST" "$log" \
        | grep -v "linkd\|NSCocoaErrorDomain" || true
    exit $status

# These were run by hand, in whatever order I remembered, and the exit
# codes were read through a pipe — which reports the exit status of
# `tail`, not of the build. That is how a green result gets reported for a
# binary that does not compile.
[doc("Everything that must pass before a commit: both suites + governance")]
[group("test")]
verify: test test-swift
    #!/usr/bin/env bash
    set -euo pipefail
    # Capture, THEN inspect. Piping govctl into grep makes grep's exit
    # status the verdict, so a govctl that crashed outright would read as
    # "no errors" — the failure mode this gate exists to catch.
    OUT=$({{ GOVCTL }} check 2>&1) || true
    if printf '%s\n' "$OUT" | grep -qE "^error"; then
        printf '%s\n' "$OUT" | grep -E "^error" >&2
        exit 1
    fi
    echo "govctl: no errors"
    just --justfile {{justfile()}} gov-lint
    # A CHECK THAT PRINTS FOREVER IS A CHECK NOBODY READS, which is why
    # this waited: `unshipped` exits non-zero, so it could not join the
    # gate until its list was empty. It is empty, so it joins — and the
    # next method a test believes ships while nothing calls it fails the
    # build rather than scrolling past in a report.
    just --justfile {{justfile()}} unshipped
    just --justfile {{justfile()}} lint-sh
    # TWO HUBS AND A REAL LINK, because the production path is the thing
    # under test. Every unit test in the federation area builds its
    # directory by calling `directoryAdvertise` — which is the function
    # the identity-upgrade path does not call, so no unit test could see
    # that peers never learnt a durable id.
    ./scripts/test-federation-e2e.sh
    echo "zig + swift + governance + unshipped + shellcheck + federation: all clear"

# Mechanical checks on governance prose — damage fails, the rest is advice
#
# PART OF `verify`. It exits non-zero only on damage a sentence cannot
# survive, which is why it is safe on a shared gate: a citation worth
# re-reading is reported and does not fail the run.
[doc("Check gov/ prose for edit damage and citations worth re-reading")]
[group("gov")]
gov-lint:
    python3 scripts/gov-lint.py

# Photograph a stuck workbench: run this WHILE it is stuck.
#
# THE ONE QUESTION A FREEZE ASKS is whether the main thread is inside
# something, or idle and simply not being reached. A sample answers it and
# nothing else does: a main thread parked in a read, a sleep or a lock
# names the culprit on the spot, and a main thread sitting in the run loop
# says the clicks are being lost before the model ever hears them — two
# different bugs that look identical from the outside.
[doc("Sample the running app for N seconds while it is stuck")]
[group("dev")]
freeze secs="5":
    #!/usr/bin/env bash
    set -euo pipefail
    # `|| true`: pgrep exits 1 when nothing matches, and under pipefail
    # that would end the recipe before it could say why.
    PID=$(pgrep -x Synapty | head -1 || true)
    if [ -z "$PID" ]; then echo "Synapty is not running" >&2; exit 1; fi
    OUT=/tmp/synapty-freeze-$(date +%H%M%S).txt
    /usr/bin/sample "$PID" {{secs}} -f "$OUT" >/dev/null
    echo "wrote $OUT"
    # SELECTED BY ITS LABEL, not by being first: sample does not promise
    # an order, and the wrong thread's stack answers the wrong question.
    awk '/Thread_/ { p = /main-thread/ } p' "$OUT" | head -40

# A file on another machine is what SSH is for. Carrying log lines over
# the A2A protocol would give that protocol a reader it should not have,
# and would blur RFC-0009's rule that event logs are per-machine and peer
# events are never replayed — so the transport here is deliberately the
# boring one.
#
# The ControlMaster the workbench established for a connected host is
# reused when present, so this does not re-authenticate.
[doc("Read a hub's log — `just hub-log remotehost` for a remote one")]
[group("dev")]
hub-log host="" follow="":
    #!/usr/bin/env bash
    set -euo pipefail
    FLAGS=""
    [ -n "{{follow}}" ] && FLAGS="--follow"
    if [ -z "{{host}}" ]; then
        exec ./zig-out/bin/synapty hub --log $FLAGS
    fi
    SOCKET="$HOME/.synapty/sockets/{{host}}"
    CTL=""
    # Reuse the master if one exists for this destination; the socket is
    # named user@host:port, so match on the host part.
    FOUND=$(ls "$HOME/.synapty/sockets/" 2>/dev/null | grep -F "{{host}}" | head -1 || true)
    [ -n "$FOUND" ] && CTL="-o ControlPath=$HOME/.synapty/sockets/$FOUND -o ControlMaster=auto"
    # shellcheck disable=SC2086
    exec ssh $CTL "{{host}}" ".synapty/bin/synapty hub --log $FLAGS"

# /usr/bin/log by ABSOLUTE PATH on purpose: `log` is a shell builtin or
# function in some setups, and it silently swallowed a `log stream`
# invocation here — producing an empty capture that was read as "the app
# logged nothing", which was wrong and sent the investigation the wrong
# way for twenty minutes.
#
[doc("Tail the app's unified log — `just logs Sync` filters by category")]
[group("dev")]
logs category="":
    #!/usr/bin/env bash
    set -euo pipefail
    # BOTH PROCESSES. The workbench is "Synapty" and the hub it spawns is
    # a separate executable named "synapty" — filtering on the app alone
    # showed none of the hub's lines, which is the half this was extended
    # to cover in the first place.
    #
    # And both SHAPES: the Swift side logs through os_log, which renders
    # as `[com.synapty.app:Category]`, while the Zig hub reaches the same
    # log through syslog and renders as `[scope]`. One grep for both.
    PRED='process == "Synapty" OR process == "synapty"'
    if [ -n "{{category}}" ]; then
        /usr/bin/log show --last 10m --info --predicate "$PRED" --style compact \
            | grep -iE "com\.synapty\.app:{{category}}|\[{{category}}\]" \
            || echo "(no {{category}} lines in the last 10m)"
    else
        /usr/bin/log show --last 10m --info --predicate "$PRED" --style compact \
            | grep -E "\[com\.synapty\.app:|\] \[?(hub|run|cli|mcp)\]?" \
            || echo "(no app or hub lines in the last 10m)"
    fi

# Install the CURRENT source as /Applications/Synapty.app, and prove it.
#
# This existed as a sequence I retyped: quit, wait, remove, ditto, open.
# Retyping it is how a build from twenty minutes ago ends up installed
# while someone is asked to look for a fix written since — which happened,
# and cost a round trip. A recipe cannot forget a step; a person can.
#
# THE WAIT FOR THE HUB IS NOT PADDING. The hub is a supervised sidecar and
# outlives the workbench by design ([[ADR-0008]]): quit the app and it
# stays up through its grace window, so a relaunch ADOPTS the old process
# and keeps running the old Zig binary. The GUI updates and the hub does
# not, which is invisible unless you go looking — the popover says
# "Adopted hub" and nothing says it is stale.
#
[doc("Build Release, quit cleanly, install to /Applications, verify, relaunch")]
[group("dist")]
install: app-release
    #!/usr/bin/env bash
    set -euo pipefail
    # shasum is perl, and this machine's locale makes it warn twice per
    # call — noise in the middle of the one output a human reads to decide
    # whether the install is the build they just made.
    #
    # PER COMMAND, NOT EXPORTED. `open` hands this shell's environment to
    # the app and the app hands it to every pane, so a recipe-wide
    # LC_ALL=C put every terminal into the C locale — where the human's
    # Chinese came out as garbage. The scrub below existed for exactly
    # this hazard and did not cover the variable the recipe set itself.
    SHA="env LC_ALL=C shasum -a 256"
    APP=$(find ~/Library/Developer/Xcode/DerivedData/Synapty-*/Build/Products/Release \
        -name 'Synapty.app' -maxdepth 1 -print0 2>/dev/null | xargs -0 ls -dt | head -1)
    [ -n "$APP" ] || { echo "Error: no Release build found." >&2; exit 1; }

    echo "==> Quitting (gracefully, so the session snapshot is written)..."
    osascript -e 'tell application "Synapty" to quit' 2>/dev/null || true
    for _ in $(seq 1 15); do pgrep -f "Synapty.app/Contents/MacOS/Synapty" >/dev/null || break; sleep 1; done

    echo "==> Waiting for the hub to exit (it outlives the workbench on purpose)..."
    for _ in $(seq 1 30); do pgrep -f "synapty hub" >/dev/null || break; sleep 2; done
    if pgrep -f "synapty hub" >/dev/null; then
        echo "!! A hub is still running. The new app will ADOPT it and keep" >&2
        echo "!! running the OLD Zig binary. Stop it first, or expect the" >&2
        echo "!! GUI to update while the hub does not." >&2
    fi

    # ONE previous install is kept, as the rollback for a bad build. Every
    # earlier one goes: unrotated, this reached 114 bundles and 6 GB on
    # the developer's Mac before anyone looked.
    if [ -d /Applications/Synapty.app ]; then
        for OLD in /Applications/Synapty.app.bak-*; do
            [ -d "$OLD" ] && rm -rf "$OLD"
        done
        BAK="/Applications/Synapty.app.bak-$(date +%Y%m%d-%H%M%S)"
        mv /Applications/Synapty.app "$BAK"
        echo "==> Previous install kept at $BAK (older backups removed)"
    fi
    # ditto, not cp -R: it preserves the signature and the stapled ticket.
    ditto "$APP" /Applications/Synapty.app

    echo "==> Verifying the install is the build we just made..."
    diff <($SHA < "$APP/Contents/MacOS/Synapty") \
         <($SHA < /Applications/Synapty.app/Contents/MacOS/Synapty) >/dev/null \
        && echo "    binary matches"
    diff <($SHA < "$APP/Contents/Helpers/synapty") \
         <($SHA < /Applications/Synapty.app/Contents/Helpers/synapty) >/dev/null \
        && echo "    hub binary matches"
    codesign --verify --deep --strict /Applications/Synapty.app && echo "    signature valid"

    # SCRUBBED. `open` hands the caller's environment to the app, and the
    # app hands it to every pane shell — so installing from an agent's
    # shell leaks CLAUDE_*/ANTHROPIC_* into every terminal the human then
    # opens, where a claude started in a pane reports its transcript off.
    # LC_ALL joins the list on its own account: whatever set it, a
    # terminal that inherits it stops rendering the human's own language.
    UNSET_FLAGS=$(env | grep -E '^(CLAUDE|ANTHROPIC|LC_ALL)' | cut -d= -f1 | sed 's/^/-u /' | tr '\n' ' ')
    eval "env $UNSET_FLAGS open /Applications/Synapty.app"
    echo "==> Installed and launched."

# Is the installed app older than the source it claims to be?
#
# NOT a hash comparison, which is what this tried first and got wrong:
# Xcode builds are not reproducible — embedded paths, build timestamps and
# the signature's own secure timestamp all differ run to run — so both the
# byte hash and the cdhash change even when nothing in the source did. The
# recipe reported STALE for an install that was perfectly current, which
# is the wrong direction for a staleness check to fail in.
#
# Modification time answers the question that actually cost a round trip:
# "is the app I am looking at older than my last edit?" It cannot catch
# same-age-different-content — for that the check below asks the binaries
# themselves, now that build_id is a hash of the sources rather than the
# constant "dev" it used to be (WI-2026-08-14-005). mtime still covers the
# Swift side, which carries no such stamp.
[doc("Is the installed app older than the source?")]
[group("dist")]
installed-matches-source:
    #!/usr/bin/env bash
    set -euo pipefail
    APP=/Applications/Synapty.app
    [ -d "$APP" ] || { echo "Not installed." >&2; exit 1; }

    NEWEST=$(find Sources src -type f \( -name '*.swift' -o -name '*.zig' \) \
        -newer "$APP/Contents/MacOS/Synapty" -print -quit 2>/dev/null || true)
    if [ -n "$NEWEST" ]; then
        echo "STALE: source is newer than the install — e.g. $NEWEST" >&2
        echo "       run: just install" >&2
        exit 1
    fi
    echo "installed app is at least as new as every source file"

    # The Zig side is now EXACT rather than mtime-approximate: build_id is
    # a hash of src/**.zig, so "is this the same code?" has a real answer.
    # `zig build` is cached — it costs a rebuild only when there is one.
    zig build
    SRC_ID=$(zig-out/bin/synapty version)
    APP_ID=$("$APP/Contents/Helpers/synapty" version 2>/dev/null || echo "pre-version-build")
    if [ "$SRC_ID" != "$APP_ID" ]; then
        echo "STALE: installed hub binary is $APP_ID, source builds $SRC_ID" >&2
        echo "       run: just install" >&2
        exit 1
    fi
    echo "installed hub binary matches the source ($SRC_ID)"

    # And the RUNNING hub, which is the one that actually answers agents.
    # It publishes its build in the discovery file, so this needs no
    # connection and cannot be confused by a hub on a ladder rung.
    DISCOVERY=~/.config/synapty/machine/hub.json
    if [ -f "$DISCOVERY" ] && pgrep -f "synapty hub" >/dev/null; then
        RUN_ID=$(sed -n 's/.*"build":"\([^"]*\)".*/\1/p' "$DISCOVERY")
        if [ "$RUN_ID" != "$SRC_ID" ]; then
            echo "STALE: the RUNNING hub is $RUN_ID, not $SRC_ID" >&2
            echo "       it was started before the last install and still" >&2
            echo "       runs the old binary. Restart the app." >&2
            exit 1
        fi
        echo "running hub matches too ($RUN_ID)"
    fi

[doc("Build, sign, notarize, staple, and produce the installer DMG, zip and cask")]
[group("dist")]
package: deploy-all _xcodegen
    #!/usr/bin/env bash
    set -euo pipefail
    VERSION="{{ VERSION }}"
    # A TAG THAT DISAGREES WITH THE SOURCE IS A RELEASE OF THE WRONG
    # THING. The workflow hands the tag in as SYNAPTY_VERSION (with the
    # "v" Git tags carry, WI-2026-08-08-089); it must name what
    # build.zig.zon says, or the zip, the app and the cask would each
    # claim a version the binary does not.
    if [ -n "${SYNAPTY_VERSION:-}" ] && [ "${SYNAPTY_VERSION#v}" != "$VERSION" ]; then
        echo "!! version skew: SYNAPTY_VERSION=${SYNAPTY_VERSION} but build.zig.zon says ${VERSION}." >&2
        echo "!! build.zig.zon is the one source; bump it and tag again." >&2
        exit 1
    fi
    DMG_NAME="Synapty-${VERSION}-universal"
    STAGE="zig-out/package/${DMG_NAME}"

    # FAIL CLOSED. An artifact that is not signed and notarized hits the
    # Gatekeeper detour on every machine that downloads it, and the cask
    # says it will not. These branches used to warn and carry on, and the
    # release workflow — on a runner with neither an identity nor a
    # notary profile — published the result ([[WI-2026-09-02-028]]).
    # SYNAPTY_UNSIGNED_OK=1 keeps the warning path for a local build that
    # is not going anywhere.
    refuse() {
        echo "!! $1" >&2
        if [ "${SYNAPTY_UNSIGNED_OK:-}" != 1 ]; then
            echo "!! Refusing to package an artifact that will not pass Gatekeeper." >&2
            echo "!! SYNAPTY_UNSIGNED_OK=1 builds it anyway, for local use only." >&2
            exit 1
        fi
    }

    echo "==> Building Release GUI app (${VERSION})..."
    SYNAPTY_VERSION="$VERSION" {{ XCODEGEN }} generate --spec project.yml
    xcodebuild -project Synapty.xcodeproj -scheme Synapty -configuration Release \
        -destination 'platform=macOS' build

    echo "==> Assembling DMG staging area..."
    rm -rf "$STAGE" "zig-out/package/${DMG_NAME}.dmg" "zig-out/package/${DMG_NAME}-rw.dmg"
    mkdir -p "$STAGE/.deploy"

    # Find the most recently built Synapty.app — check BOTH DerivedData
    # locations (default and .build/DerivedData, WI-2026-08-08-088).
    # Search only the locations that EXIST. `find` returns non-zero for a
    # missing path, and under `set -euo pipefail` that aborts the whole
    # recipe — so a developer who has never used the sandboxed
    # DerivedData location could not package at all, with the failure
    # printed as a bare exit code.
    SEARCH_DIRS=()
    for d in .build/DerivedData/Build/Products/Release \
             ~/Library/Developer/Xcode/DerivedData/Synapty-*/Build/Products/Release; do
        [ -d "$d" ] && SEARCH_DIRS+=("$d")
    done
    APP_PATH=""
    if [ ${#SEARCH_DIRS[@]} -gt 0 ]; then
        APP_PATH=$(find "${SEARCH_DIRS[@]}" -name 'Synapty.app' -maxdepth 1 -print0 2>/dev/null \
            | xargs -0 ls -dt 2>/dev/null | head -1)
    fi
    if [ -z "$APP_PATH" ]; then
        echo "Error: Synapty.app not found in DerivedData." && exit 1
    fi
    cp -R "$APP_PATH" "$STAGE/"
    echo "    Synapty.app: $APP_PATH"

    # Notarize and STAPLE the app before it goes into anything.
    #
    # Order matters and is easy to get backwards: stapling attaches the
    # ticket to the artifact you staple, and nothing else. Notarizing only
    # the DMG leaves the app — the thing the human actually drags out and
    # keeps — without a ticket of its own, so it validates online and
    # fails closed on a machine that is offline or behind a filter. So the
    # app is stapled HERE, and both the Homebrew zip and the DMG below
    # then carry an already-stapled app.
    #
    # WHY THE PROBE DISTINGUISHES TWO FAILURES. This asked
    # `notarytool history` and treated ANY non-zero exit as "no profile
    # configured", so a network blip skipped notarisation and produced an
    # unsigned-for-Gatekeeper app with one line on stderr among nine
    # hundred. That happened. A missing profile is a local-development
    # state worth continuing from; a profile that exists and cannot be
    # reached is a broken release build and stops here.
    NOTARY_PROFILE="${SYNAPTY_NOTARY_PROFILE:-synapty-notary}"
    probe="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1)" && probe_rc=0 || probe_rc=$?
    if [ "$probe_rc" -ne 0 ] && ! printf '%s' "$probe" | grep -qi "keychain\|profile\|credential"; then
        echo "!! NOTARISATION UNAVAILABLE, and the profile exists — this is not" >&2
        echo "!! a machine without credentials, it is a request that failed:" >&2
        printf '%s\n' "$probe" | sed 's/^/!!   /' >&2
        echo "!! Refusing to ship an unnotarised build. Re-run when it is reachable." >&2
        exit 1
    fi
    if [ "$probe_rc" -eq 0 ]; then
        echo "==> Notarizing Synapty.app (profile: $NOTARY_PROFILE)..."
        ditto -c -k --keepParent "$STAGE/Synapty.app" "zig-out/package/.notarize-app.zip"
        xcrun notarytool submit "zig-out/package/.notarize-app.zip" \
            --keychain-profile "$NOTARY_PROFILE" --wait
        rm -f "zig-out/package/.notarize-app.zip"
        xcrun stapler staple "$STAGE/Synapty.app"
        # The check that actually predicts what a downloading human sees.
        # `codesign --verify` passes on an unnotarized app; only Gatekeeper
        # assessment answers the question they will ask.
        spctl -a -vvv -t install "$STAGE/Synapty.app"
    else
        echo "!! No notarytool keychain profile '$NOTARY_PROFILE'. Create one with:" >&2
        echo "!!   xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
        echo "!!     --apple-id <id> --team-id HSEZTB9EQB --password <app-specific>" >&2
        refuse "NOT NOTARIZED: the app will hit the Gatekeeper detour on every machine that downloads it."
    fi

    # Applications symlink for drag-to-install
    ln -s /Applications "$STAGE/Applications"

    # Zip artifact for Homebrew Cask (WI-2026-08-08-088): the cask points
    # at the GitHub Release zip asset and needs its sha256 — so the cask
    # is RENDERED HERE from cask/synapty.rb.in and released beside the
    # zip, rather than kept in the tree with a placeholder hash that was
    # never filled in.
    echo "==> Creating zip and cask for Homebrew..."
    ditto -c -k --keepParent "$STAGE/Synapty.app" "zig-out/package/Synapty-${VERSION}.zip"
    SHA256=$(shasum -a 256 "zig-out/package/Synapty-${VERSION}.zip" | awk '{print $1}')
    sed -e "s/@VERSION@/${VERSION}/g" -e "s/@SHA256@/${SHA256}/g" cask/synapty.rb.in \
        > zig-out/package/synapty.rb
    echo "    Synapty-${VERSION}.zip: $(ls -lh "zig-out/package/Synapty-${VERSION}.zip" | awk '{print $5}')"
    echo "    sha256: ${SHA256}"
    echo "    synapty.rb: rendered for ${VERSION}"

    # Copy all deploy binaries (hidden in .deploy so DMG window stays clean)
    for target in linux-aarch64 linux-x86_64 linux-riscv64 macos-aarch64 macos-x86_64; do
        if [ ! -f "zig-out/$target/synapty" ]; then
            echo "Error: zig-out/$target/synapty not found. Run deploy-all first." && exit 1
        fi
        mkdir -p "$STAGE/.deploy/$target"
        cp "zig-out/$target/synapty" "$STAGE/.deploy/$target/"
        # The macOS payloads are Mach-O and notarization scans the WHOLE
        # DMG, not just the app — these are copied straight from zig-out
        # and are NOT the already-signed copies inside the bundle. The
        # Linux ELFs are data as far as macOS is concerned.
        case "$target" in
            macos-*)
                if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
                    codesign --force --options runtime --timestamp \
                        -s "Developer ID Application" "$STAGE/.deploy/$target/synapty"
                else
                    refuse "DEPLOY BINARY NOT SIGNED: no 'Developer ID Application' identity for .deploy/$target/synapty."
                fi
                ;;
        esac
        echo "    .deploy/$target/synapty: $(ls -lh "zig-out/$target/synapty" | awk '{print $5}')"
    done

    # Generate .icns from app icon for DMG volume icon
    ICONSET=$(mktemp -d)/Synapty.iconset
    mkdir -p "$ICONSET"
    ICON_SRC="Sources/App/Assets.xcassets/AppIcon.appiconset"
    cp "$ICON_SRC/icon_16x16.png"     "$ICONSET/icon_16x16.png"
    cp "$ICON_SRC/icon_32x32.png"     "$ICONSET/icon_16x16@2x.png"
    cp "$ICON_SRC/icon_32x32.png"     "$ICONSET/icon_32x32.png"
    cp "$ICON_SRC/icon_64x64.png"     "$ICONSET/icon_32x32@2x.png"
    cp "$ICON_SRC/icon_128x128.png"   "$ICONSET/icon_128x128.png"
    cp "$ICON_SRC/icon_256x256.png"   "$ICONSET/icon_128x128@2x.png"
    cp "$ICON_SRC/icon_256x256.png"   "$ICONSET/icon_256x256.png"
    cp "$ICON_SRC/icon_512x512.png"   "$ICONSET/icon_256x256@2x.png"
    cp "$ICON_SRC/icon_512x512.png"   "$ICONSET/icon_512x512.png"
    cp "$ICON_SRC/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o "$STAGE/.VolumeIcon.icns"

    # Create read-write DMG, configure installer layout, then compress
    echo "==> Creating installer DMG..."
    hdiutil create -volname "$DMG_NAME" -srcfolder "$STAGE" \
        -ov -format UDRW "zig-out/package/${DMG_NAME}-rw.dmg"

    MOUNT_DIR=$(hdiutil attach "zig-out/package/${DMG_NAME}-rw.dmg" -readwrite \
        | grep '/Volumes/' | awk -F'\t' '{print $NF}')

    # Set volume icon
    SetFile -a C "$MOUNT_DIR"

    hdiutil detach "$MOUNT_DIR"
    hdiutil convert "zig-out/package/${DMG_NAME}-rw.dmg" -format UDZO \
        -o "zig-out/package/${DMG_NAME}.dmg"
    rm -f "zig-out/package/${DMG_NAME}-rw.dmg"

    # The DMG is a separate artifact and needs its own signature and
    # ticket — the app's says nothing about the container it arrived in.
    SIGN_ID="${SYNAPTY_SIGN_IDENTITY:-Developer ID Application}"
    if security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
        echo "==> Signing DMG..."
        codesign --force --timestamp -s "$SIGN_ID" "zig-out/package/${DMG_NAME}.dmg"
        if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
            echo "==> Notarizing DMG..."
            xcrun notarytool submit "zig-out/package/${DMG_NAME}.dmg" \
                --keychain-profile "$NOTARY_PROFILE" --wait
            xcrun stapler staple "zig-out/package/${DMG_NAME}.dmg"
            spctl -a -vvv -t open --context context:primary-signature \
                "zig-out/package/${DMG_NAME}.dmg"
        else
            refuse "DMG NOT NOTARIZED: no notarytool keychain profile '$NOTARY_PROFILE'."
        fi
    else
        refuse "DMG NOT SIGNED: no '$SIGN_ID' identity in the keychain."
    fi
    echo "==> Created: zig-out/package/${DMG_NAME}.dmg"

    # ------------------------------------------------------------------
    # CLOUDKIT SCHEMA — the release trap, checked rather than remembered.
    #
    # CloudKit keeps a development schema and a production schema. Record
    # types created by a development build exist ONLY in development, so
    # everything works while you build it and the SHIPPED build cannot
    # find its record types at all. Nothing about the app looks wrong: it
    # is signed, notarized, entitled, and syncing simply never converges.
    #
    # There is no API to promote a schema, so this cannot be automated —
    # which is exactly why it is printed here, at the moment a shippable
    # artifact exists, instead of living in someone's memory.
    # ------------------------------------------------------------------
    echo ""
    echo "==> BEFORE PUBLISHING THIS BUILD:"
    echo "    1. CloudKit Console -> iCloud.com.synapty.app -> Schema"
    echo "    2. Promote the DEVELOPMENT schema to PRODUCTION"
    echo "    3. Verify with the SHIPPED build, not a development one:"
    echo "         /Applications/Synapty.app/Contents/MacOS/Synapty --sync-preflight"
    echo "       'available' means the account is reachable. A missing"
    echo "       production schema shows up as schemaMissing on the first"
    echo "       real record operation, NOT here — so also confirm a host"
    echo "       edited on one Mac appears on another."
    echo ""

# Clean build artifacts
[group("dev")]
clean:
    rm -rf zig-out/ .zig-cache/
    rm -rf ~/Library/Developer/Xcode/DerivedData/Synapty-*
    rm -rf GhosttyKit.xcframework/
    rm -rf Synapty.xcodeproj/
