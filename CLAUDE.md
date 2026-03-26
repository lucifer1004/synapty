# Synapty - Multi-Agent A2A Terminal

## Project Overview
Synapty (Synapse + PTY) is a terminal multiplexer and A2A (Agent-to-Agent) message router for Multi-Agent Systems (MAS). It uses a Hub-and-Spoke architecture with dual-channel communication multiplexed over SSH.

## Technology Stack
- **Language:** Zig (100% end-to-end, both Hub and Daemon)
- **VT Engine:** `libghostty-vt` (C API) — not yet integrated in V1 bootstrap
- **Network:** WebSockets over TCP, multiplexed via SSH Reverse Port Forwarding
- **Dependencies:** Zero external runtime deps. Zig std library only.

## Hard Rules
- NO Python, Node.js, or third-party frameworks (no MCP)
- Pure raw JSON-RPC routing layer
- V1 is happy-path only — no retry queues, encrypted handshakes, or complex failure tolerance
- Focus on low-latency routing and memory safety via `ArenaAllocator`
- All JSON parsing uses `std.json` with deferred `Value` for payloads

## Architecture
- **Synapty Hub (local):** Central A2A WebSocket router on `127.0.0.1:9000`. Parses PTY streams, intercepts OSC sequences for human-in-the-loop.
- **Synapty Daemon (remote):** Lightweight binary connecting to Hub via SSH reverse tunnel. Spawns AI agent processes, pipes stdout to SSH PTY (data plane), forwards JSON A2A requests via WebSocket (control plane).

## Build
```sh
zig build              # build both executables
zig build hub          # build synapty-hub only
zig build daemon       # build synapty-daemon only
zig build test         # run all tests
```

## Protocol
- A2A envelope: `{ type, id, source, target, payload }` over WebSocket
- OSC notification: `\e]99;id=<agent_id>;status=<status_code>\e\\` on stdout
- Register message: `{ type: "register", agent_id, capabilities }` on WS connect

## Project Structure
```
build.zig
src/
  protocol.zig    — shared A2A types and JSON serialization
  hub.zig         — local Hub router (TCP listener, routing table, message dispatch)
  daemon.zig      — remote Daemon (WS client, process spawner, stream piping)
```
