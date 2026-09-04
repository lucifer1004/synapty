# Synapty — The Agent Workbench

## Vision
Synapty (Synapse + PTY) is a terminal-native orchestration platform for multi-agent systems. It enables AI agents — local or remote, from any provider — to collaborate through a unified PTY substrate. See [[RFC-0001]] for the full five-layer architecture vision.

## Scope
A native macOS GUI application: a graphical terminal multiplexer with built-in A2A routing,
Termius-style host management, and libghostty-powered terminal panes.

THE SHAPE OF THE PRODUCT is [[ADR-0001]]'s and still holds. Its POSTURE does not.
[[ADR-0017]] supersedes it and retires the "V1 defers it" argument: a queue that holds mail
for an unreachable machine, an answer that means what it says, and behaviour that survives a
restart are product requirements, not V2. Encryption stays out — the SSH channel the
workbench establishes is the trust boundary, and that is a scope decision rather than a
deferral.

WHAT ANSWERS A SCOPE QUESTION IS THE RFC THAT OWNS THE OBLIGATION. A normative clause at
`impl` is a commitment this project has made and implemented. Where no clause speaks, the
question is OPEN — not deferred. This file used to carry its own copy of the deliverable
list, which drifted: it still said the hub ran in-process two ADRs after that stopped being
true, and named four CLI subcommands out of twenty-nine.

## Technology Stack
- **Language:** Zig 0.16.x (core engine, hub, CLI, protocol) + Swift (macOS GUI layer)
- **VT Engine:** libghostty via GhosttyKit xcframework — used in V1 for terminal pane rendering. Build: `just ghosttykit` (see Build below).
- **Network:** Raw TCP with JSON envelopes (V1) via a thin POSIX wrapper (`src/sys.zig`) — Zig 0.16 removed `std.net` and `std.Io.net` does not support unix sockets, so Synapty uses `std.posix.system` directly (see src/sys.zig header comment). WebSocket upgrade is V2.
- **GUI:** macOS native (Metal rendering). Swift + Xcode project linked to GhosttyKit xcframework via C bridging header.
- **Dependencies:** libghostty (a path dependency on the submodule) and zig-clap (build.zig.zon); nothing else at runtime.

## Hard Rules
- Pure JSON-RPC routing layer
- Encryption and encrypted handshakes are out of scope; the SSH channel the workbench establishes is the trust boundary. Failure tolerance is NOT out of scope — see [[ADR-0017]].
- Low-latency routing and memory safety via `ArenaAllocator`
- All JSON parsing uses `std.json` with deferred `Value` for payloads
- All governance files (gov/**) managed via `govctl` CLI — never edit directly
- Version control: `jj` (jujutsu), not git. `jj describe` edits the current change's message but does NOT create a new commit — always run `jj new` after to start a fresh change.
- Tasks can be tough but you should never over-simplify or evade problems. You should find root cause and fix.

## Dev Environment
Zig is installed via Homebrew (`brew install zig`, 0.16.x). `jj` and `just` are also available via Homebrew; `govctl` via Cargo.
```sh
just build             # zig build -> zig-out/bin/synapty
just test              # zig build test + the e2e shell suites
```
Prerequisites: Xcode (install from the App Store) is required for macOS SDK headers/linking and GUI builds.

## Build
```sh
# Zig core — single unified binary [[ADR-0004]]: hub/agent/CLI subcommands
zig build              # build the synapty binary
zig build test         # run all tests
just deploy-all        # cross-compile deploy targets (linux musl + macOS)

# GhosttyKit xcframework (from Ghostty submodule)
# `just ghosttykit` (scripts/build-ghosttykit.sh) applies every local patch
# in patches/*.patch idempotently before building — see each patch header
# for why; upstream-worthy. Do not apply them by hand.
# -Dsentry=false is REQUIRED: ghostty's embedded Sentry crash reporter
# (a) phones crashes to ghostty's DSN from OUR app and (b) its
# sentry-init thread itself SIGSEGVed intermittently at launch
# (2026-08-10, two identical .ips).
just ghosttykit        # applies patches/*.patch, builds with -Dsentry=false, copies the xcframework to the repo root
# (needs the Metal toolchain; if `xcodebuild -downloadComponent MetalToolchain`
# fails with a catalog error, see the Xcode 26 known-issue recipe:
# download with an explicit -buildVersion, sed the version in the exported
# bundle's ExportMetadata.plist, then -importComponent.)

# macOS GUI app (Xcode)
just app               # xcodegen + xcodebuild (Debug)
```

## Project Structure
```
Synapty.xcodeproj      — macOS GUI app (Swift + GhosttyKit)
ghostty/               — Ghostty submodule (libghostty source)
ghostty.h              — Ghostty C API header (bridging)
GhosttyKit.xcframework — pre-built universal framework (cached)
src/                   — Zig sources
Sources/               — Swift GUI sources
gov/                   — govctl SSOT files
docs/                  — Rendered govctl docs and other references
```
