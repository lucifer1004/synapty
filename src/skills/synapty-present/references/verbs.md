# The verbs in detail

Every argument, what each verb returns, and every refusal with its
cause. The SKILL that points here carries the summary, the exit codes and
the limits; this is the page you open when one of them refuses and you
want to know why.

`synapty notify --state …` is a different thing and lives in the
`synapty` skill: it signals your own state rather than showing anything.

All of these require `$SYNAPTY_AGENT_ID` — they exit **2** outside a
Synapty pane.

## Exit codes

The table is in SKILL.md; the codes are the same for every verb here.
`ask` uses the same table: `0` answered (the choice is on stdout), `3`
nobody answered in time.

## expose — something running now

```sh
synapty expose 8080 --title "dev server"
synapty expose 8888 --title "notebook" --at "/lab?token=abc123"
synapty unexpose 8080
```

On success `payload.data` carries `local_port` and `url` — the address on
the human's machine that now reaches your service. The workbench opens a
forward on the connection it already has and shows the page in its Web
view; the human can hand it to their real browser from there.

- **You name YOUR port**, the one on your machine. Which local port
  reaches it is the workbench's to choose — you cannot see that machine.
- **`--at` takes a PATH, not a URL.** It must begin with `/`; anything
  naming a scheme, host or port is refused. This exists because a service
  worth showing is rarely at the root — say `--at "/lab?token=…"` rather
  than making the human land on a login page.
- **Exposing the same port again re-points it** at the new `--at`. It
  does not open a second forward, and it is not an error.
- **`unexpose` only works on your own views.** Hiding another agent's is
  refused by name.
- If you are on the human's own Mac you get a refusal saying the port is
  already reachable at `127.0.0.1`. That is correct — nothing needs to be
  forwarded from a machine to itself.

The exposure ends when Synapty quits. Do not treat it as durable.

## present — something finished

```sh
synapty present ./report.html --title "coverage report"
synapty present ./out/diagram.png
```

On success `payload.data.artifact_id` identifies it. The file is copied
to the human's machine and appears in the panel's Files view.

Use this for the OUTPUT of your work. If the thing is still changing,
it is a live surface — use `expose`.

## ask — a decision you cannot make

```sh
answer=$(synapty ask "Migration will drop the legacy column. Proceed?" \
    --option "proceed" --option "skip" --timeout 600)
```

Prints the chosen option on stdout and exits **0**. Exit **3** means
nobody answered in time — which is not the same as "no", and your script
must be able to tell them apart. (Same **3** as a transfer waiting on a
human: in both, the person has not acted yet.)

- **Offer options.** At least one and at most 8, and the human's answer is
  always one of them; an answer you have no branch for is worse than no
  answer. A question with none is refused: the human answers by choosing,
  so a card with no choices is one nobody can answer or clear.
- **`--timeout` is YOUR patience**, in seconds (default 300). You are the
  only one who knows what you are holding open while you wait. A human
  who has stepped away can outlast any timeout.
- **Ask when you are genuinely blocked**, not to confirm something you
  should decide. Every question costs the human an interruption.

## put — a file for another machine

```sh
synapty put ./out.tar --to prod-1        # a host the human configured
synapty put ./out.tar --to agent:api-7f3c   # whichever machine that agent is on
synapty fetch /var/log/app.log --from prod-1
```

On success `payload.data` carries `transfer_id` and `state` (`queued`).

- **You do not choose where it lands.** Agent transfers go to
  `~/.synapty/inbox` on the receiving machine. `--into` is ignored for
  you — it belongs to the human's own drag.
- **The first transfer along a route needs the human's agreement.** You
  get **exit 3** and `waiting for approval to send from X to Y — a human
  has been asked`. **This is not a permanent failure**: once they agree,
  retry and it goes. The permission covers that route in that direction
  until Synapty quits, and is never written to disk.
- **They can also say no**, and then you get **exit 4** and `a human
  refused ... Retrying will not change it`. That is the whole difference
  between the two codes: `3` means not yet, `4` means no. A refusal
  stands for the session, and undoing it is theirs to do — do not ask
  again along that route.
- **Addressing an agent**: `--to agent:<id>` lets the workbench resolve
  which machine that agent is on. Prefer it over naming a host when what
  you mean is "give this to that agent".
- **`fetch` cannot address an agent.** Reaching into another agent's
  machine on its behalf is a different capability and nobody agreed to
  it.
- **Transfers are capped at 256 MB** by default (the human can change
  it). Over the cap you are refused by name, never truncated. This is a
  control plane — datasets and backups belong in tools built for them.

## identify — where you are

```sh
synapty identify
```

`payload.data` carries `agent`, `machine`, `is_local`, `workspace`,
`workspace_id`, and `exposed` (the remote ports you currently have up).

A shell can see its own environment and nothing about the window it is
drawn in. Before this existed, an agent that wanted to know which of
several panes it was had to probe the workbench with side-effect-free
calls and read which refusal came back.

## exposed — what became of what you showed them

```sh
synapty exposed            # everything you have up
synapty exposed 9090       # one of them
```

`payload.data.views` is a list carrying `remote_port`, `local_port`,
`url`, `reachable`, `http_status`, and `title` when the page has one.

**THIS IS THE HALF OF `expose` THAT READS BACK.** Exposing alone is
write-only: you put a page in front of a human and had no way to learn
whether it loaded, what it said, or that your dev server had died and you
were confidently pointing at nothing.

**It probes the SERVICE, not the human's screen.** The web view exists
only while someone is looking at that panel, so "what is rendered" is
unanswerable most of the time and would make the answer depend on where
the human happens to be looking. Whether your forwarded address answers
is a fact about YOUR service — always available, and the one you can act
on.

**The title is the point.** A status code tells you something answered;
the title tells you it was YOUR page and not another service that took
the port.

Refused for a port you did not expose, like `unexpose`: reading back
another agent's view is reading something it put in front of a human.

## Choosing between them

- The thing is still changing → `expose`. It is done → `present`.
- You want the human to LOOK → `expose` / `present`.
  You need them to DECIDE → `ask`.
- You want another MACHINE to have the bytes → `put`.
  You want the HUMAN to have them → `present`.
- You do not know where you are → `identify`.
  You do not know whether they can see it → `exposed`.

If a capability you want is none of the four, it does not exist here.
That bound is deliberate: a plane that grows a verb per idea ends up with
a permission model nobody can reason about.
