# libghostty Integration Reference

## GUI Embedding (cmux pattern — V1 uses this)

- GhosttyKit xcframework built by `just ghosttykit` (scripts/build-ghosttykit.sh applies patches/*.patch, then `zig build -Demit-xcframework=true -Dxcframework-target=universal -Dsentry=false -Doptimize=ReleaseFast`)
- Opaque handles: `ghostty_app_t` (one per app), `ghostty_surface_t` (one per terminal pane), `ghostty_config_t`
- Host provides NSView + CAMetalLayer; Ghostty owns PTY + VT + Metal rendering internally
- Callback-driven: `wakeup_cb` → main queue dispatch → `ghostty_app_tick(app)`
- Action system: ~60 action types (title change, bell, split, close, OSC events)
- Surface config: `ghostty_surface_config_s` with `working_directory`, `command`, `env_vars`
- Single app instance, multiple surfaces — maps to: one Synapty app, multiple agent panes
- Env var injection for agent discovery (e.g., `SYNAPTY_SOCK`, `SYNAPTY_AGENT_ID`)

## Headless VT API (ghostty-web pattern — V2 introspection)

- Upstream ghostty ships the C API wrapper at `src/terminal/c/terminal.zig`; no local patch is involved
- Build: `zig build -Demit-lib-vt=true` for headless use (`zig build test-lib-vt` runs its tests)
- Terminal lifecycle: `ghostty_terminal_new/free/resize/write`
- `ghostty_terminal_write(term, data, len)` feeds PTY bytes → VT parsing internally
- `ghostty_render_state_update(term)` syncs snapshot, returns dirty state
- `ghostty_render_state_get_viewport(term, buf, size)` bulk dumps all cells (ONE call)
- Per-row dirty tracking for incremental updates

### GhosttyCell struct (16 bytes packed — L3 introspection format)

```
codepoint(u32) fg_rgb(3B) bg_rgb(3B) flags(u8) width(u8) hyperlink_id(u16) grapheme_len(u8) pad(u8)
```

Pre-resolved RGB, no palette lookups needed by receiver.
Flags: bold|italic|underline|strike|inverse|invisible|blink|faint.

### ResponseHandler pattern

Programs (vim, tmux) send DSR/DA queries. The terminal generates responses that must be written back to the PTY. The pane process must queue and relay these — without this, modal editors and capability-querying programs will not function correctly.
