---
name: synapty-present
description: Show the human something from inside a Synapty pane — a service you are running, a file you finished, a question only they can answer, or a file another machine needs. Also read back what you showed them. Use when you have a result, a running server, or a decision you cannot make yourself, and SYNAPTY_AGENT_ID is set.
---

# Showing the human something

Your pane is a text pipe, but you are not limited to it. **Four verbs, and
only four.** Pick by what the thing IS:

| you have | verb |
|---|---|
| something **running now** | `synapty expose <port>` |
| something **finished** | `synapty present <path>` |
| a **decision** you cannot make | `synapty ask "<q>" --option …` |
| a **file for another machine** | `synapty put <path> --to <target>` |

## Fast start

```sh
synapty identify                              # which machine and workspace am I in
synapty expose 8080 --title "dev server"      # something running
synapty expose 8888 --at "/lab?token=abc"     # …at a particular page
synapty exposed                               # did it load? what does it say?
synapty unexpose 8080

synapty present ./report.html --title "coverage"
answer=$(synapty ask "Drop the legacy column?" --option proceed --option skip)
synapty put ./out.tar --to agent:api-7f3c
```

All of these need `$SYNAPTY_AGENT_ID` — they exit **2** outside a pane.

## Exit codes

| code | meaning | what to do |
|---|---|---|
| `0` | done | carry on |
| `2` | you used the command wrong, or are not inside a Synapty pane | fix the call |
| `3` | **a human was asked and has not answered** | **retry later** |
| `4` | the workbench will not do this as asked | read the error; do not loop |

`3` is the one that matters. The first transfer along a route needs the
human's agreement, and `3` means the question is now in front of them:

```sh
for attempt in 1 2 3 4 5; do
    synapty put ./out.tar --to prod-1 && break
    [ $? -eq 3 ] || break        # 4 means retrying is a loop
    sleep 60                     # they are being asked; give them time
done
```

`expose`, `present` and `put` also print the hub's whole envelope on
stdout, so `payload.error` always carries the reason. The exit code says
what to do; the JSON says why.

## Everything here is a REQUEST

Nothing you do opens a panel, switches what the human is looking at, or
takes focus from a pane they are typing in. Your content arrives as a
count on the status bar and waits.

That is not a limitation to work around. **Do not** call these in a loop
to get attention, and do not re-`ask` the same question to raise its
prominence — a repeat is treated as the same question.

Everything you present names you. There is no anonymous content, and it
is drawn inside a frame that marks it as an agent's, so it can never be
mistaken for the application's own interface.

## Limits, so you do not discover them by hitting them

- **You do not choose where a delivery lands.** Agent transfers go to
  `~/.synapty/inbox` on the receiving machine. `--into` is ignored for you.
- **Nothing you send overwrites anything.** A name already taken gets the
  next one — `report.html` becomes `report 2.html`.
- **Transfers are capped at 256 MB** by default. Over it you are refused
  by name, never truncated. This is a control plane, not a data plane.
- **`fetch` cannot address an agent** — reaching into another agent's
  machine on its behalf is a capability nobody agreed to.
- **You can only withdraw or read back your OWN views.**
- **An exposure dies when Synapty quits.** Do not treat it as durable.
- **`--at` takes a path, not a URL.** It must begin with `/`; anything
  naming a scheme, host or port is refused.

## References

| Reference | When to use |
|---|---|
| [references/verbs.md](references/verbs.md) | Every argument, what each verb returns, and every refusal with its cause |

## A fifth verb has to earn its place

Adding one requires first showing, in writing, that it is none of the
four. `identify` and `exposed` are not exceptions to that rule: neither
presents anything. One tells you where you already are; the other is the
half of `expose` that reads back what you already sent.
