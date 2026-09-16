# Synapty

Run coding agents on several machines and let them talk to each other.

Synapty (Synapse + PTY) is a macOS terminal workbench for multi-agent work. The
part that is not like the others: **agents are not confined to the machine in
front of you.** An agent on a server registers with the hub on *its own* host,
keeps working while your laptop is asleep, and can exchange messages with the
agent in the pane next to you. Close the lid, open it later, the mail is still
there.

Everything else — libghostty panes, host management, a GitHub-Issues task
centre — exists to make that usable.

## How it works

Every machine that hosts agents runs one **hub**: a small router the agents on
that machine connect to over loopback. Hubs **peer** with each other over the
SSH connections you already have, so a message to an agent on another box is
forwarded there, or spooled and flushed in order when the link comes back.

```
   your Mac                              a server
┌──────────────────────┐              ┌──────────────────────┐
│  Synapty workbench   │              │  (no GUI needed)     │
│      │               │              │                      │
│   hub ◄── agent      │◄─ SSH ──────►│   hub ◄── agent      │
│      ▲               │  peer link   │      ◄── agent       │
└──────┼───────────────┘              └──────────────────────┘
       └─ subscribes to both, one merged view
```

Three properties this buys, which are easy to get wrong and are enforced here:

- **A hub holds no secrets.** GitHub credentials live in the Keychain and
  execute at the workbench, never in the hub — which is what lets a hub run on
  a Linux server at all.
- **Unreachable is not absent.** When a link drops, that machine's agents stay
  listed and are marked unreachable, rather than disappearing (which reads as
  "they ended") or keeping a stale status (which is indistinguishable from a
  fresh one).
- **No invented ordering.** Each hub's event log is totally ordered within
  itself; the merged view says so instead of implying a global timeline.

## Install

### Homebrew Cask (recommended)

```sh
brew install --cask https://github.com/lucifer1004/synapty/releases/latest/download/synapty.rb
```

### Manual

1. Download `Synapty-<version>.zip` from the [releases page](https://github.com/lucifer1004/synapty/releases).
2. Unzip and drag `Synapty.app` to Applications.
3. Open it.

Signed with a Developer ID certificate and notarized by Apple, with the ticket
stapled — so it opens normally, offline included, with no right-click-Open and
no `xattr`.

### Remote hosts

You do not install anything by hand. Connect to a host from the sidebar and the
workbench uploads the `synapty` binary, starts a hub there if one is not already
running, and opens the peer link. A server reboot self-heals on the next
connect.

## Without the GUI

The hub and CLI are a separate binary with no dependency on the macOS app, so
the cross-machine part works under tmux, plain SSH, or another multiplexer:

```sh
zig build                       # -> zig-out/bin/synapty
just deploy-all                 # cross-compiled linux/macOS binaries

synapty hub --ensure            # idempotent: start a hub here, or report the running one
synapty run --id my-agent -- claude    # wrap an agent so it registers
synapty send other-agent "ready for review"
synapty recv --wait             # block until mail arrives
synapty agents                  # who is registered, and on which machine
synapty wait --agent builder --until done   # event-driven hand-off
```

`send` reports what actually happened rather than a bare success: `delivered`,
`forwarded`, `spooled` (peer is down, held for it), `unknown` (no such agent
anywhere) or `indeterminate` (a peer is unreachable, so the hub cannot tell a
typo from a machine it cannot see).

## Build from source

Prerequisites: Xcode, Zig 0.16.x (`brew install zig`), jj (`brew install jj`), xcodegen (`brew install xcodegen`).

```sh
# 1. Fetch the ghostty submodule (pinned upstream commit)
git submodule update --init

# 2. Build GhosttyKit.xcframework (the submodule stays pristine; if your
#    machine lacks the Metal Toolchain component, set SYNAPTY_METAL_DIR —
#    see scripts/build-ghosttykit.sh)
just ghosttykit

# 3. Build and run the app
just app
open ~/Library/Developer/Xcode/DerivedData/Synapty-*/Build/Products/Debug/Synapty.app

# Tests
just test          # zig build test + the e2e shell suites (connect, holder, send-answer, ssh master)
just test-swift    # the Swift suite (GUI + services)
```

## Packaging

```sh
just package       # Release app, signed and notarized: DMG + zip + rendered cask (version from build.zig.zon)
```

`just package` builds, signs, notarizes and staples, then prints the one
step that cannot be automated: promoting the CloudKit schema from
development to production.

That step is a trap worth naming. CloudKit keeps two schemas, and record
types a development build creates exist only in development — so sync
works throughout development and the shipped build cannot find its record
types at all. The app is signed, notarized and entitled, `--sync-preflight`
reports `available`, and nothing converges. Verify with the shipped build
by editing a host on one Mac and looking for it on another; the preflight
alone cannot see this, because it never performs a record operation.

## What this does not do

- **macOS only**, and there is no mobile or web client. The workbench is a
  native app; the hub protocol is portable, a second surface is not written.
- **No agent of its own.** Synapty runs Claude Code, Codex, Gemini CLI and
  anything else that speaks a terminal; it does not compete with them.
- **Happy-path networking.** No retry queues beyond the spool, no encryption of
  its own (peer links ride SSH), no capability discovery.
- **Identity is self-reported.** Any local process can claim any agent id
  reachable through the loopback hub. That is the same authority a local process
  already has over your shell — but it means Synapty's identity claims are only
  ever as strong as "some process on this machine said so", and nothing here
  presents them as stronger.

## Keyboard

Every chord Synapty answers to is in one table, editable in **Settings ▸
Keys**. One thing the application cannot tell you from inside itself:
**Synapty replaces ghostty's keybindings entirely**, so a `keybind = …`
line in `~/.config/ghostty/config` has no effect here. See
[`docs/keyboard.md`](docs/keyboard.md).

## Design record

Decisions and protocols live in [`gov/`](gov/) — architecture decisions (ADRs),
normative protocol specs (RFCs), and the work-item ledger — managed with
`govctl` rather than edited by hand. RFCs are rendered to [`docs/rfc/`](docs/rfc/).

Start with [`docs/rfc/RFC-0009.md`](docs/rfc/RFC-0009.md) for the federation
protocol, and `gov/adr/ADR-0008-*.toml` for why there is one hub per machine.

## License

MIT — see [LICENSE](LICENSE). The bundled ghostty (submodule) is MIT.
