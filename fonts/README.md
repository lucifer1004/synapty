# Bundled fonts

`SymbolsNerdFont-Regular.ttf` — Nerd Fonts "Symbols Only", MIT (see `LICENSE`).

Vendored rather than referenced from the Ghostty submodule's package cache:
that path is a build artifact keyed by a content hash, so it is neither
stable across dependency bumps nor present in a fresh checkout. The file the
application loads has to be in the repository.

The file browser draws its row icons from this font's Seti-UI and Codicon
ranges ([[WI-2026-08-29-007]]). Ghostty embeds the same font separately, for
terminal glyph fallback; the two uses do not share a copy because one is
compiled into libghostty and the other is registered with CoreText by the
application.
