---
name: synapty
description: Exist and coordinate inside the Synapty agent workbench — register your presence so the human can find you among many panes, signal when you are working, waiting or done, discover and message other agents, and work the shared task center. Use when SYNAPTY_SOCK is set, or when asked about Synapty agents, messages or tasks.
---

# Synapty

Synapty is a terminal workbench that hosts multiple agents in panes. When
`SYNAPTY_SOCK` is set you are inside one: the `synapty` CLI is on PATH,
`$SYNAPTY_AGENT_ID` is your address, and the GUI shows your identity and
state on this pane's tab. If `SYNAPTY_SOCK` is NOT set, none of this
applies — skip everything below.

## Fast start

```sh
synapty identify                 # which machine and session am I in
synapty register --tool claude --resume-ref "$CLAUDE_CODE_SESSION_ID"
synapty agents                   # who else is here
synapty notify --state done      # how the human finds you among many panes
```

`identify` answers with two names for the workspace you are in and they
are not interchangeable. `workspace` is what the human reads in the
sidebar — it is the shortest name nothing else is using, they can rename
it, and it is handed to the next workspace once this one closes.
`workspace_id` is the one that still means this workspace tomorrow: it is
written down and comes back with the arrangement. Say `workspace` to a
human; write `workspace_id` into anything that will be read later.

Everything here exits **2** when it is run outside a Synapty pane, and
says which piece of the environment was missing. That is the same code the
`synapty-present` verbs use for the same condition, so one check covers
both.

## Register once, first

```sh
synapty register --tool claude --resume-ref "$CLAUDE_CODE_SESSION_ID"
```

`--tool` is your harness: `claude`, `codex`, `gemini`. Until you register,
the human sees a pane with no identity on it.

### Pass `--resume-ref`, or you will not have a name

It is your harness's own session id — the thing that still means THIS
conversation tomorrow. Read it from the environment your harness sets:
`CLAUDE_CODE_SESSION_ID` for Claude Code, the equivalent for yours.

Without it you are named `local-XXXX`, the fallback the hub mints from the
pane wrapper. That name is fine for a bare shell and bad for you, in three
ways a human meets:

- **It says nothing.** Every unregistered session on every machine is
  `local-` plus four hex, so a list of them is a list a human cannot read.
  With a resume_ref you are `claude-<first 8 of the ref>` — the same id
  every time, derived rather than minted, so it survives your restart.
- **It dies with the pane.** The wrapper id is minted when the pane opens
  and gone when it closes. Anything written down under it — a task, a
  claim, a finding — is dangling the moment the pane is closed.
- **Mail follows the durable id.** Tasks, DMs, waits and wake targeting all
  address it; the pane id is only a transport address for wherever you are
  hosted right now.

If your harness gives you nothing to pass, register without it and say so
when a human asks why your name is unreadable — the fallback exists for
exactly that case and is not a failure.

## Signal your state

This is how the human finds you among many panes — tab marker, sidebar,
Dock badge:

```sh
synapty notify --state done      # finished a substantial piece of work
synapty notify --state waiting   # send BEFORE ending a turn that asks the
                                 # human something — you cannot signal
                                 # after your turn ends
synapty notify --state working   # optional: picking work back up
```

Permission prompts already alert the human via the terminal bell — you do
not need to (and cannot) signal those yourself.

## Coordinate — pick the right route

- Durable work items, assignments, results → the shared task center
- Immediate back-and-forth with ONE live agent → direct messages
- The same thing said to SEVERAL agents → a channel, below
- Taking over when another agent finishes or blocks → `synapty wait`
  (event-driven; never poll `synapty agents` in a loop)

## A channel, when more than one agent needs to hear it

```sh
synapty channel list                        # rooms you can see
synapty channel create <name> --description "what it is for"
synapty channel invite <name> <agent-id>    # by the id `agents` reports
synapty send <name> "message"               # same verb as a direct message
synapty channel leave <name>
```

`send` addresses a channel by name exactly as it addresses an agent by id,
so nothing new is needed to talk once you are in one. Use a channel when
the same message would otherwise be sent three times; use a direct message
when it is for one agent and the others would be reading someone else's
mail.

## Running something in a pane of your own

```sh
synapty exec open                    # a pane you own, marked as machine-operated
synapty exec run --pane <id> --cmd "command"
synapty exec wait-output --pane <id> --pattern "pattern"
synapty exec read --pane <id>
synapty exec close --pane <id>
```

ONLY YOUR OWN PANES. These verbs are refused for a pane a human opened,
for another agent's exec pane, and for any pane running a harness — the
scope is exec panes you created and still own.

A HUMAN ARMS THIS, ONCE, PER SESSION. Until they do, `exec open` answers
`{"outcome":"refused"}` and says nothing further, because the answer is
not about your request. If you meant to use it and got that, ask the human
to turn on **Agent exec panes** in the hub status-bar popover rather than
retrying — nothing you can send will change the answer.

## Showing the human something is a different skill

When you have a result, a running server, or a decision you cannot make,
that is `synapty-present` — `expose`, `present`, `ask` and `put`. It is a
separate skill because it is reached for with a different intent, and it
has its own refusals and exit codes.

## References

| Reference | When to use |
|---|---|
| [references/tasks.md](references/tasks.md) | Task center: list / claim / update / comment / create, and the collaboration discipline |
| [references/messaging.md](references/messaging.md) | Agent-to-agent messaging: send / recv / agents / wait, addressing, delivery semantics |
