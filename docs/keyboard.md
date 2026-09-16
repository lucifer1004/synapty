# Keyboard shortcuts

Every chord Synapty answers to lives in one table. You can see all of them,
and change any of them, in **Settings ▸ Keys**; the same list is in
**Help ▸ Keyboard Shortcuts**.

This document exists for the one thing the application cannot tell you from
inside itself. The rules behind it are [[RFC-0016]].

## Synapty's table replaces ghostty's keybindings entirely

Synapty embeds ghostty as its terminal engine, and ghostty has a keybinding
system of its own with a configuration file at
`~/.config/ghostty/config`.

**Synapty empties it.** The configuration Synapty writes begins with
`keybind = clear`, and it is loaded after ghostty's own files, so it clears
both ghostty's shipped defaults and anything you have written there
yourself.

A `keybind = …` line in ghostty's config therefore does nothing in Synapty.
It will not warn you: Synapty never reads that file to know you tried, and
ghostty is not asked about a key after the table has spoken. This page is
the only place that says so, which is why it exists.

What to do instead: bind it in **Settings ▸ Keys**. The terminal's own
commands — copy, paste, find in scrollback, clear screen, font size — are
in the same table as everything else, and they are dispatched as ghostty
actions when a terminal has focus.

Only ghostty's BINDINGS are cleared. Its input handling, its escape
sequences, and whatever the shell, editor or multiplexer inside a pane does
with a keystroke are untouched.

## Chords Synapty will not bind

`⌘Q`, `⌘H` and `⌘M` are refused: they belong to macOS and Synapty declines
to contest them. Everything else is yours, including `⌘,`.

A chord must carry at least one of `⌘`, `⌃` or `⌥`. Without one it would
take a character away from whatever has focus, which in a terminal is
usually you typing.

## If a shortcut does nothing

Another application may have registered it system-wide. Such a chord never
reaches Synapty at all, and **Synapty cannot detect this** — from inside the
process it is indistinguishable from a key nobody pressed. That is why
nothing in the interface tells you a chord is "available" or "in use
elsewhere": it would be a claim the application cannot check.

The remedy is to pick another chord.

## The numbered families

`⌘1–9` (workspaces), `⌥⌘1–9` (tabs) and `⌃⌘1–9` (panes) are three
*families* rather than twenty-seven shortcuts. You rebind a family as a
whole, by pressing its new modifier with any digit; all nine move together.
Individual members cannot be rebound or cleared — a family whose members
carried different modifiers would be a set of bindings nobody could
describe.

## Where your changes are kept

In `~/.config/synapty/shared/keys.json`, which means they follow you
between machines along with your appearance settings.

Only what you changed is stored, so a default Synapty corrects in a later
version still reaches you. A command you cleared is stored as cleared —
`null` against its name — because "no entry" would be indistinguishable
from never having touched it, and your cleared chord would come back at
the next launch.

You may edit that file. Anything in it faces the same rules as a chord
recorded in the panel: an entry naming a command that does not exist, one
that is not a chord, or two commands on one chord are resolved or discarded
when the table is built, and what happened is shown in **Settings ▸ Keys**.
