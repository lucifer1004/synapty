# Synapty — The Agent Workbench

## Vision
Synapty (Synapse + PTY) is a terminal-native orchestration platform for multi-agent systems. It enables AI agents — local or remote, from any provider — to collaborate through a unified PTY substrate. See [[RFC-0001]] for the full five-layer architecture vision.

## V1 Scope (per [[ADR-0001]])
Native macOS GUI application — a graphical terminal multiplexer with built-in A2A routing, Termius-style host management, and libghostty-powered terminal panes. Seven deliverables:
1. **Native GUI App** — macOS, libghostty via GhosttyKit xcframework, Metal-rendered terminal panes. Swift UI + Zig core (cmux pattern).
2. **Host Management Sidebar** — preconfigured remote hosts (label, address, credentials). Reusable Identities. Host Groups with inheritance. One-click deploy.
3. **Embedded Hub** — A2A message router in-process. No separate Hub binary to manage.
4. **One-Click Agent Deploy** — click host → SSH + scp daemon + reverse tunnel + open pane.
5. **CLI (`synapty`)** — agent-side integration: `register`, `send`, `recv`, `agents`.
6. **Agent Skills** — teach Claude Code / Codex to use the CLI.
7. **Agent Status Bar** — registered agents, connection state, message activity, notification badges.

**V1 defers:** L2 full orchestration cockpit, L3 terminal introspection (2D DOM export to agents), OSC-to-A2A bridging, WebSocket framing, capability-based discovery, failure tolerance, encryption, cross-platform (Linux/Windows).

## Technology Stack
- **Language:** Zig 0.16.x (core engine, daemon, CLI, protocol) + Swift (macOS GUI layer)
- **VT Engine:** libghostty via GhosttyKit xcframework — used in V1 for terminal pane rendering. Build: `cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast`
- **Network:** Raw TCP with JSON envelopes (V1) via a thin POSIX wrapper (`src/sys.zig`) — Zig 0.16 removed `std.net` and `std.Io.net` does not support unix sockets, so Synapty uses `std.posix.system` directly (see src/sys.zig header comment). WebSocket upgrade is V2.
- **GUI:** macOS native (Metal rendering). Swift + Xcode project linked to GhosttyKit xcframework via C bridging header.
- **Dependencies:** Zero external runtime deps beyond libghostty. Zig std library + Ghostty submodule.

## Hard Rules
- Pure JSON-RPC routing layer
- V1 is happy-path only — no retry queues, encrypted handshakes, or complex failure tolerance
- Low-latency routing and memory safety via `ArenaAllocator`
- All JSON parsing uses `std.json` with deferred `Value` for payloads
- All governance files (gov/**) managed via `govctl` CLI — never edit directly
- Version control: `jj` (jujutsu), not git. `jj describe` edits the current change's message but does NOT create a new commit — always run `jj new` after to start a fresh change.
- Tasks can be tough but you should never over-simplify or evade problems. You should find root cause and fix.

## Dev Environment
Zig is installed via Homebrew (`brew install zig`, 0.16.x). `jj` and `just` are also available via Homebrew; `govctl` via Cargo.
```sh
just build             # zig build (all Zig executables)
just test              # zig build test
```
Prerequisites: Xcode (install from the App Store) is required for macOS SDK headers/linking and GUI builds.
Note: the legacy Nix-based `devenv` setup is no longer used (Nix was removed from this machine); the stale `.devenv/` directory and `devenv.yaml`/`devenv.nix` remain only as historical references.

## Build
```sh
# Zig core — single unified binary [[ADR-0004]]: hub/daemon/CLI subcommands
zig build              # build the synapty binary
zig build test         # run all tests
zig build deploy-all   # cross-compile deploy targets (linux musl + macOS)

# GhosttyKit xcframework (from Ghostty submodule)
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast

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
