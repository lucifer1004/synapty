# Agent Platform Integration — Skills

Synapty teaches agents the `synapty task` CLI through skill documents
(RFC-0003 C-SKILLS). No MCP configuration is needed.

## One-time setup

1. `synapty github login` — configure the hub repo + token (login device)
2. `synapty skills install` — copies the skill to each platform's
   skill directory (loads on demand, never pollutes global instructions):
   - Claude Code: `~/.claude/skills/synapty-task/SKILL.md`
   - Codex: `~/.codex/skills/synapty-task/SKILL.md`
   - Gemini CLI: `~/.gemini/skills/synapty-task/SKILL.md`

The canonical skill document lives at `src/skills/synapty-task/SKILL.md`
(embedded into the binary at compile time; `skills install` always
distributes the version matching your binary).

## Requirements

- `synapty` binary in PATH
- Agent running inside `synapty run --id <id> -- <command>` (provides the
  hub connection), or the hub reachable on localhost:9000

## Historical note

The old MCP-based integration (configs/claude-code/.mcp.json,
configs/codex/config.toml, configs/gemini/settings.json) was removed in
favor of the CLI + skills model. `synapty mcp-serve` remains as a
deprecated compatibility layer.
