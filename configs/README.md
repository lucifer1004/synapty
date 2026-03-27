# Agent Platform Configuration

Synapty integrates with AI coding agents via MCP (Model Context Protocol).
Each agent platform needs a one-time configuration to discover the `synapty` MCP server.

## Prerequisites
- `synapty` binary in PATH
- Agent running inside `synapty run --id <id> -- <command>`

## Claude Code
Copy `claude-code/.mcp.json` to your project root, or add the mcpServers entry to your existing `.mcp.json`.

## Codex CLI
Add the contents of `codex/config.toml` to `~/.codex/config.toml`.

## Gemini CLI
Add the mcpServers entry from `gemini/settings.json` to `~/.gemini/settings.json`.
