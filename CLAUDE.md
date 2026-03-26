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
- **Language:** Zig 0.15.x (core engine, daemon, CLI, protocol) + Swift (macOS GUI layer)
- **VT Engine:** libghostty via GhosttyKit xcframework — used in V1 for terminal pane rendering. Build: `cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast`
- **Network:** Raw TCP with JSON envelopes (V1). WebSocket upgrade is V2.
- **GUI:** macOS native (Metal rendering). Swift + Xcode project linked to GhosttyKit xcframework via C bridging header.
- **Dependencies:** Zero external runtime deps beyond libghostty. Zig std library + Ghostty submodule.

## Hard Rules
- NO Python, Node.js, or third-party frameworks (no MCP)
- Pure JSON-RPC routing layer
- V1 is happy-path only — no retry queues, encrypted handshakes, or complex failure tolerance
- Low-latency routing and memory safety via `ArenaAllocator`
- All JSON parsing uses `std.json` with deferred `Value` for payloads
- All governance files (gov/**) managed via `govctl` CLI — never edit directly
- Version control: `jj` (jujutsu), not git. `jj describe` edits the current change's message but does NOT create a new commit — always run `jj new` after to start a fresh change.

## Dev Environment
Managed by `devenv` (Nix-based). Provides: Zig 0.15.x, jj, govctl.
```sh
devenv shell           # enter dev environment with all tools pinned
```
Prerequisites not managed by devenv: Xcode (install from App Store).

## Build
```sh
# Zig core (daemon, CLI, protocol)
zig build              # build all Zig executables
zig build daemon       # build synapty-daemon only
zig build test         # run all tests

# GhosttyKit xcframework (from Ghostty submodule)
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast

# macOS GUI app (Xcode)
xcodebuild -project Synapty.xcodeproj -scheme Synapty -configuration Debug build
```

## Project Structure
```
Synapty.xcodeproj      — macOS GUI app (Swift + GhosttyKit)
ghostty/               — Ghostty submodule (libghostty source)
ghostty.h              — Ghostty C API header (bridging)
GhosttyKit.xcframework — pre-built universal framework (cached)
src/
  protocol.zig         — shared A2A types and JSON serialization
  hub.zig              — Hub router (routing table, message dispatch)
  daemon.zig           — Daemon (SSH tunnel, process spawner, CLI host)
  cli.zig              — CLI tool (register, send, recv, agents)
Sources/               — Swift GUI sources (terminal panes, host sidebar, status bar)
gov/
  config.toml          — govctl configuration
  rfc/RFC-0001/        — vision RFC (normative, finalized)
  adr/                 — ADR-0001 V1 scope (proposed)
  work/                — work items
docs/
  rfc/RFC-0001.md      — rendered RFC
```
