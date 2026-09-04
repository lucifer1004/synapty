# The presentation plane

Agents in Synapty are not confined to a text pipe. They can hand a human a
file, put a live page in front of them, or ask a question and wait for the
answer — from any machine the workbench is connected to, through the same
CLI whatever provider the agent came from.

This document is the contract's readable face. The normative text is
[`RFC-0013`](../gov/rfc/RFC-0013); the decision behind it is
[`ADR-0010`](adr/ADR-0010.md). Where they disagree with this file, they win.

## Four primitives, and only four

| verb | what it is | where it lands |
|---|---|---|
| `synapty expose <port>` | **a live surface** — something running now | the panel's Web view |
| `synapty present <path>` | **an artifact** — something finished | the panel's Files view |
| `synapty ask "<q>" --option …` | **a decision** — the agent is blocked | a badge, and the sheet behind it |
| `synapty notify …` | **an event** — nothing is required of you | a notification |

Read them as **live / done / answer me / FYI**.

### A fifth primitive has to earn its place

Adding one requires first showing, in writing, that it is none of the four.
The bound is the point: a plane that gains a verb per idea — `show-diff`,
`show-chart`, `show-table` — ends up with a permission model nobody can
reason about, and every one of those is an artifact, a live surface, or a
question wearing a different noun.

If a capability cannot say which primitive it is, it does not belong here,
whatever its merit.

## What an agent cannot do

Everything an agent presents is a **request**. None of it can seize the
screen.

- **It lands in a queue.** Nothing an agent does opens a panel, switches
  what a panel is showing, or presents a sheet. Arrivals raise a count on
  the status bar and wait there.
- **It is attributed.** Every presented thing names the agent that asked
  for it. There is no anonymous content.
- **It cannot take focus** from a pane you are typing in.
- **It is visually quarantined** — framed, inset, and never drawn in chrome
  that could be mistaken for Synapty's own.

The last one is a security property, not a style rule. Agents act on
material they read, and that material can instruct them. Without the frame,
an agent that had been prompt-injected could draw a convincing credential
prompt inside the window you trust most.

## What an agent cannot reach

- **It does not choose where a delivery lands.** Agent transfers go to a
  fixed inbox on the receiving side. `--into` belongs to your own drag.
- **It cannot move data between your machines without you.** The first
  attempt along a route raises a question; you answer once, and the
  permission covers that route in that direction until you quit Synapty.
  Nothing is written down, so nothing is inherited by a session you were
  not present for.
- **It cannot withdraw another agent's view**, only its own.
- **It cannot fetch from another agent** — reaching into someone else's
  machine on its behalf is a different capability, and nobody agreed to it.

## Why the workbench is in the middle

Your hosts never need to know about each other. A transfer from one to
another relays through this Mac, which is the only party authenticated to
both — a direct path would mean putting a credential for one host on
another, permanently and account-wide, as a side effect of a gesture.

The broker does not avoid creating that capability; it makes it
**governable**. Scoped to an inbox, granted by you, recorded with its
initiator, and gone when Synapty quits. A key in `authorized_keys` has none
of those properties, least of all the last.

## Limits, stated rather than discovered

This is a **control plane**. It carries artifacts, decisions and views
between you and the agents working for you. It is not a data plane and will
not pretend to be one:

- Agent transfers are capped — **256 MB** by default, yours to change in
  Settings → Agents → Agent exec panes — and refused above it by name,
  never truncated. Your own drags are not capped. The setting syncs to
  your other Macs.
- Every relayed byte crosses this Mac twice.
- Transfers ride a dedicated connection so a copy cannot stall your
  terminal — measured, an interactive round trip stayed at 0.36–0.74s
  during a 60 MB transfer that had previously pushed it to 17.9s.

Dataset movement, backup and mirroring are legitimate wants and belong to
tools built for them.

## Reaching an agent rather than a machine

    synapty put ./out.tar --to agent:api-7f3c

The sender names **what** it wants reached. Which machine that agent is on,
and where deliveries land there, are facts that change when an agent moves
and are the workbench's to resolve — not something every caller should have
to carry.
