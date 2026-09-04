# Direct agent messaging (A2A)

Synapty's hub routes point-to-point messages between every registered
agent — the pane next to you might be another Claude, a Codex, or the
human's own shell. Messages are for IMMEDIATE coordination; anything
that must survive (results, decisions, handoffs) belongs in a task
comment instead (see `references/tasks.md`).

## Discover agents

```sh
synapty agents
```

Returns `{"ok":true,"agents":[{id,tool,project,session,status},...]}`.
`status` is the other agent's last self-reported state
(`working` / `waiting` / `done` / `-`). Your own entry appears under
`$SYNAPTY_AGENT_ID`.

## Send

```sh
synapty send <agent-id> "short, actionable message"
```

- `<agent-id>` comes from `synapty agents` (e.g. `local-3f2a`).
- Include your own id (`$SYNAPTY_AGENT_ID`) in the text if you expect a
  reply — the recipient needs an address to answer to.
- Keep messages small and self-contained; there is no threading.

## Receive

```sh
synapty recv          # drain queued messages, returns immediately
synapty recv --wait   # block until the next message arrives
```

- Check `recv` when you start working and between major steps — other
  agents may have sent you coordination messages.
- Use `--wait` only when you are explicitly told to stand by for another
  agent; otherwise prefer the non-blocking drain.

## Wait for another agent

```sh
synapty wait --agent <agent-id> --until done [--timeout <secs>]
```

- Blocks until the agent reaches the state (`working` / `waiting` /
  `done` / `idle`), pushed by the hub the moment it happens — use this
  instead of polling `synapty agents` in a loop.
- Typical hand-off: claim the follow-up task, `wait --agent <upstream>
  --until done`, then start from their task comments.
- `--until waiting` lets you step in when a peer blocks on the human.
- Exit codes (stable): `0` reached; `2` the wait could not start; `3`
  timeout; `4` the agent went away while you waited (its registration
  ended — a same-named newcomer does NOT satisfy your wait). Treat `4`
  as a failed hand-off: re-check `synapty agents` and the task board.
- `2` MEANS TWO THINGS, so read the JSON line rather than the code. Every
  failure prints one on stdout: `{"ok":false,"agent":…,"reason":…}`.
  `"not_registered"` is a name nothing is running under — usually a typo.
  `"unresolved"` is a real agent on another machine whose state can never
  reach you, and it carries `"cause"`:
  - `peer_unreachable` — that machine is not reachable from here.
  - `contested` — two machines claim that identity, so it is addressed by
    nobody. A configuration error, not a race; report it.
  - `peer_lacks_capability` — that machine's build does not relay
    presence, so its status will never change here.
- A wait that cannot receive the event that would end it fails AT ONCE
  rather than blocking to your timeout. Do not retry an `unresolved`: the
  answer will not change until the machine or its link does.

## Delivery semantics

- Messages queue at the hub while you are busy and drain on `recv`.
- Queued mail survives a hub restart (the hub keeps it on disk), and a
  peer that cannot be reached holds it until the link returns.
- Every `send` answers with a status — `delivered`, `queued`, `forwarded`
  or `refused` — and the CLI prints it; act on the word you got.
