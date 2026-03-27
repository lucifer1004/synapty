# Claude Agent SDK for Python — Research Notes

> **Date:** 2026-03-26
> **SDK Version:** Python 0.1.50 (CLI 2.1.81) / TypeScript 0.2.71
> **Sources:** Official Anthropic documentation, GitHub repository, engineering blog
> **Relevance to Synapty:** High — potential integration surface for agent orchestration

---

## Table of Contents

1. [What Is It?](#1-what-is-it)
2. [Architecture](#2-architecture)
3. [Multi-Agent Support](#3-multi-agent-support)
4. [Tool System](#4-tool-system)
5. [MCP Integration](#5-mcp-integration)
6. [Orchestration Patterns](#6-orchestration-patterns)
7. [Terminal / PTY Interaction](#7-terminal--pty-interaction)
8. [Key Abstractions](#8-key-abstractions)
9. [Sessions and Continuity](#9-sessions-and-continuity)
10. [Hosting and Deployment](#10-hosting-and-deployment)
11. [Comparison to Synapty](#11-comparison-to-synapty)
12. [Integration Scenarios](#12-integration-scenarios)
13. [Lessons for Synapty](#13-lessons-for-synapty)
14. [Sources](#14-sources)

---

## 1. What Is It?

The Claude Agent SDK (formerly "Claude Code SDK", renamed September 2025) exposes the
same agent runtime that powers Claude Code as a programmable library for Python and
TypeScript. It provides:

- **The full Claude Code agent loop** — prompt → evaluate → tool call → observe → repeat
- **14+ built-in tools** — Read, Write, Edit, Bash, Glob, Grep, WebSearch, WebFetch,
  Agent, Skill, AskUserQuestion, TodoWrite, ToolSearch, NotebookEdit
- **Automatic context management** — compaction when the context window fills, with
  CLAUDE.md re-injection after compaction
- **Session persistence** — conversations written to disk, resumable and forkable
- **MCP integration** — both external (stdio/HTTP/SSE) and in-process SDK MCP servers
- **Subagent orchestration** — spawn specialized agents with isolated context windows

**What problem it solves:** Before this SDK, building autonomous agents with Claude
required manually implementing the tool-use loop (send prompt → parse tool_use blocks →
execute tools → send results → repeat). The SDK eliminates that boilerplate and provides
production-grade context management, permission controls, and tool execution.

**Relationship to Claude Code:** The SDK *is* Claude Code's runtime, extracted as a
library. `pip install claude-agent-sdk` bundles the Claude Code CLI. The SDK spawns a
Claude Code process and communicates with it via stdin/stdout JSON messages. Your
application is the orchestrator; Claude Code is the execution engine.

```
┌─────────────────────────────────┐
│  Your Python Application        │
│  ┌───────────────────────────┐  │
│  │  claude-agent-sdk         │  │
│  │  (query / ClaudeSDKClient)│  │
│  └──────────┬────────────────┘  │
│             │ stdin/stdout JSON  │
│  ┌──────────▼────────────────┐  │
│  │  Claude Code CLI (bundled)│  │
│  │  • Agent loop             │  │
│  │  • Tool execution         │  │
│  │  • Context management     │  │
│  │  • MCP client             │  │
│  └───────────────────────────┘  │
└─────────────────────────────────┘
         │
         │ Anthropic API (HTTPS)
         ▼
   Claude Model (sonnet/opus/haiku)
```

**Source:** [Agent SDK Overview](https://platform.claude.com/docs/en/agent-sdk/overview),
[GitHub README](https://github.com/anthropics/claude-agent-sdk-python)

---

## 2. Architecture

### 2.1 The Agent Loop

Every agent session follows a deterministic cycle:

1. **Receive prompt** — prompt + system prompt + tool definitions + conversation history
   sent to Claude. SDK yields a `SystemMessage` with subtype `"init"`.
2. **Evaluate and respond** — Claude returns text, tool calls, or both. SDK yields
   `AssistantMessage`.
3. **Execute tools** — SDK runs each tool, collects results. Hooks can intercept/block.
4. **Repeat** — Steps 2-3 repeat. Each cycle = one "turn".
5. **Return result** — When Claude produces a text-only response (no tool calls), the
   loop ends. SDK yields final `AssistantMessage` + `ResultMessage`.

A "turn" is one round-trip: Claude requests tools → SDK executes → results feed back.
The loop runs autonomously until Claude finishes or hits a limit (`max_turns`,
`max_budget_usd`).

### 2.2 Execution Model

- **Long-running process** — not a stateless API call. The CLI process persists for the
  duration of the session.
- **Streaming** — messages are yielded as an async iterator. You can display progress
  in real-time or collect results at the end.
- **Parallel tool execution** — read-only tools (Read, Glob, Grep, read-only MCP tools)
  run concurrently. Mutating tools (Edit, Write, Bash) run sequentially.
- **Effort levels** — `"low"` / `"medium"` / `"high"` / `"max"` control reasoning depth
  per turn, trading cost for accuracy.

### 2.3 Context Management

Everything accumulates in the context window across turns: system prompt, tool
definitions, conversation history, tool inputs, tool outputs.

**Automatic compaction:** When the context window approaches its limit, the SDK
summarizes older history. A `SystemMessage` with subtype `"compact_boundary"` fires.
CLAUDE.md is re-injected after compaction so persistent instructions survive.

**Prompt caching:** Content that stays the same across turns (system prompt, tool
definitions, CLAUDE.md) is automatically prompt-cached, reducing cost and latency.

**Source:** [Agent Loop](https://platform.claude.com/docs/en/agent-sdk/agent-loop)

---

## 3. Multi-Agent Support

### 3.1 Subagent Model

The SDK supports **subagents** — separate agent instances with isolated context windows
spawned by a parent agent via the built-in `Agent` tool. This is the *only* multi-agent
pattern natively supported.

Key properties:

| Property | Behavior |
|----------|----------|
| **Context isolation** | Each subagent starts with a fresh conversation. Only its final message returns to the parent. |
| **Parallelization** | Multiple subagents can run concurrently (Claude decides when). |
| **Specialized instructions** | Each subagent has its own system prompt and tool restrictions. |
| **No nesting** | Subagents cannot spawn their own subagents. One level of delegation only. |
| **Communication** | Parent → subagent: prompt string only. Subagent → parent: final result only. No back-channel. |
| **Model override** | Each subagent can use a different model (`sonnet`, `opus`, `haiku`). |

### 3.2 How Subagents Are Defined

Three ways:

1. **Programmatic** (`AgentDefinition` in `agents` param) — recommended for SDK apps:
   ```python
   agents={
       "code-reviewer": AgentDefinition(
           description="Expert code reviewer for security reviews.",
           prompt="Analyze code quality and suggest improvements.",
           tools=["Read", "Glob", "Grep"],
           model="sonnet",
       )
   }
   ```

2. **Filesystem-based** — markdown files in `.claude/agents/` directories.

3. **Built-in general-purpose** — Claude can spawn a `general-purpose` subagent at any
   time when `Agent` is in `allowedTools`, without any definition needed.

### 3.3 What Subagents Do NOT Provide

- **No agent-to-agent protocol.** Subagents cannot communicate with each other. They
  only communicate with their parent via the Agent tool's prompt/result.
- **No A2A protocol support.** The SDK itself has no built-in A2A (Google's Agent-to-Agent
  protocol) support. A2A integration is available via external frameworks like
  Microsoft Agent Framework.
- **No peer-to-peer messaging.** There is no message bus, no pub/sub, no shared memory
  between agents.
- **No discovery.** Agents cannot discover other agents at runtime. The parent defines
  all available subagents upfront.

### 3.4 External Multi-Agent Frameworks

The Claude Agent SDK can integrate with external multi-agent frameworks:

- **Microsoft Agent Framework** (`pip install agent-framework-claude --pre`) — provides
  sequential, concurrent, handoff, and group chat workflows. Claude agents implement
  `BaseAgent` interface alongside Azure OpenAI, OpenAI, and GitHub Copilot agents.
- **A2A Protocol** — Google's agent-to-agent protocol for cross-vendor agent discovery
  and delegation. The SDK doesn't implement A2A natively, but agents built with the SDK
  could be wrapped as A2A-compatible endpoints.

**Source:** [Subagents](https://platform.claude.com/docs/en/agent-sdk/subagents),
[Microsoft Integration](https://devblogs.microsoft.com/semantic-kernel/build-ai-agents-with-claude-agent-sdk-and-microsoft-agent-framework/)

---

## 4. Tool System

### 4.1 Built-in Tools

| Category | Tools | Description |
|----------|-------|-------------|
| File operations | `Read`, `Edit`, `Write` | Read, modify, create files |
| Search | `Glob`, `Grep` | Pattern-based file/content search |
| Execution | `Bash` | Shell commands, scripts, git |
| Web | `WebSearch`, `WebFetch` | Search and fetch web content |
| Discovery | `ToolSearch` | Dynamically find/load tools on-demand |
| Orchestration | `Agent`, `Skill`, `AskUserQuestion`, `TodoWrite` | Subagents, skills, user interaction, task tracking |

### 4.2 Custom Tools (SDK MCP Servers)

Custom tools are implemented as **in-process MCP servers** using the `@tool` decorator:

```python
from claude_agent_sdk import tool, create_sdk_mcp_server

@tool("greet", "Greet a user", {"name": str})
async def greet_user(args):
    return {"content": [{"type": "text", "text": f"Hello, {args['name']}!"}]}

server = create_sdk_mcp_server(name="my-tools", version="1.0.0", tools=[greet_user])
```

Benefits over external MCP servers:
- No subprocess management — runs in-process
- No IPC overhead — direct Python function calls
- Shared memory space — easier debugging
- Single Python process deployment

Tool annotations control parallel execution and hints:
- `readOnlyHint` — tool is safe for parallel execution
- `destructiveHint` — tool modifies state
- `idempotentHint` — safe to retry
- `openWorldHint` — may interact with external systems

### 4.3 Permission System

Three-tier permission model:

1. **`allowed_tools`** — auto-approve listed tools (permission allowlist)
2. **`disallowed_tools`** — block listed tools regardless of other settings
3. **`permission_mode`** — controls unlisted tools:
   - `"default"` — trigger approval callback
   - `"acceptEdits"` — auto-approve file edits
   - `"plan"` — no execution, plan only
   - `"bypassPermissions"` — run everything (sandboxed environments only)

Scoped permissions are supported: `"Bash(npm:*)"` allows only npm commands.

**Source:** [Agent Loop — Tool Execution](https://platform.claude.com/docs/en/agent-sdk/agent-loop),
[Python SDK Reference](https://platform.claude.com/docs/en/agent-sdk/python)

---

## 5. MCP Integration

### 5.1 Overview

The SDK is a **full MCP client**. It can connect to any MCP server via three transport
types:

| Transport | Use Case | Config |
|-----------|----------|--------|
| **stdio** | Local process servers | `{"command": "npx", "args": [...]}` |
| **HTTP** | Cloud-hosted servers | `{"type": "http", "url": "https://..."}` |
| **SSE** | Streaming remote servers | `{"type": "sse", "url": "https://..."}` |
| **SDK (in-process)** | Custom Python tools | `create_sdk_mcp_server(...)` |

### 5.2 Configuration

```python
options = ClaudeAgentOptions(
    mcp_servers={
        "github": {
            "command": "npx",
            "args": ["-y", "@modelcontextprotocol/server-github"],
            "env": {"GITHUB_TOKEN": os.environ["GITHUB_TOKEN"]},
        },
        "remote-api": {
            "type": "http",
            "url": "https://api.example.com/mcp",
            "headers": {"Authorization": f"Bearer {token}"},
        },
        "custom": sdk_mcp_server,  # in-process
    },
    allowed_tools=[
        "mcp__github__*",          # wildcard: all tools from github server
        "mcp__remote-api__query",  # specific tool only
        "mcp__custom__greet",      # specific tool only
    ],
)
```

Tool naming convention: `mcp__<server-name>__<tool-name>`.

### 5.3 Runtime MCP Management

`ClaudeSDKClient` supports dynamic MCP server management mid-session:

```python
await client.add_mcp_server("new-server", {"command": "...", "args": [...]})
await client.remove_mcp_server("old-server")
status = await client.get_mcp_status()  # Returns list[McpServerStatus]
```

### 5.4 MCP Tool Search

When many MCP tools are configured, tool definitions consume significant context. The
`ToolSearch` tool (enabled by default) solves this by withholding tool definitions and
loading only what Claude needs per turn.

### 5.5 The SDK Does NOT Expose an MCP Server

The SDK is an MCP **client** only. It consumes MCP servers but does not expose itself as
one. An agent built with the SDK cannot be discovered or invoked via MCP by other agents.
This is a key architectural boundary.

**Source:** [MCP](https://platform.claude.com/docs/en/agent-sdk/mcp),
[Custom Tools](https://platform.claude.com/docs/en/agent-sdk/custom-tools)

---

## 6. Orchestration Patterns

### 6.1 Single Agent, Multiple Tools

The simplest pattern. One agent with access to multiple tools (built-in + MCP).

```python
async for message in query(
    prompt="Fix the failing tests",
    options=ClaudeAgentOptions(
        allowed_tools=["Read", "Edit", "Bash", "Glob", "Grep"],
        permission_mode="acceptEdits",
    ),
):
    ...
```

### 6.2 Parent + Specialized Subagents

Define subagents for domain-specific tasks. The parent agent delegates automatically
based on the subagent's `description` field, or explicitly when named in the prompt.

```python
agents={
    "security-reviewer": AgentDefinition(
        description="Security code reviewer",
        prompt="Analyze code for vulnerabilities...",
        tools=["Read", "Grep", "Glob"],
        model="opus",
    ),
    "test-runner": AgentDefinition(
        description="Runs and analyzes test suites",
        prompt="Run tests and analyze results...",
        tools=["Bash", "Read", "Grep"],
        model="sonnet",
    ),
}
```

### 6.3 Parallel Research Pattern

From the demo repository — a master agent breaks a research request into subtopics,
spawns parallel researcher subagents, then synthesizes their findings.

### 6.4 Session Fork Pattern

Fork a session to explore alternative approaches without losing the original thread:

```python
# Fork: try a different approach
async for message in query(
    prompt="Try OAuth2 instead",
    options=ClaudeAgentOptions(resume=session_id, fork_session=True),
):
    forked_id = message.session_id  # new session
```

### 6.5 External Framework Orchestration

Via Microsoft Agent Framework: sequential pipelines where a Claude agent reviews output
from an OpenAI agent, or concurrent workflows where multiple agents work in parallel.

### 6.6 Plugin System

Plugins extend agents with packaged capabilities:

```python
options = ClaudeAgentOptions(
    plugins=[
        {"type": "local", "path": "./my-plugin"},  # skills, agents, hooks, MCP servers
    ]
)
```

Plugin structure:
```
my-plugin/
├── .claude-plugin/plugin.json   # manifest
├── skills/                       # agent skills (SKILL.md files)
├── agents/                       # subagent definitions
├── hooks/                        # event handlers
└── .mcp.json                     # MCP server definitions
```

**Source:** [Subagents](https://platform.claude.com/docs/en/agent-sdk/subagents),
[Plugins](https://platform.claude.com/docs/en/agent-sdk/plugins),
[Demo Repository](https://github.com/anthropics/claude-agent-sdk-demos)

---

## 7. Terminal / PTY Interaction

### 7.1 What It Does

The SDK interacts with the terminal via the **Bash tool** — it runs shell commands in a
persistent shell environment within the working directory. This is the *only* terminal
interaction model.

The Bash tool:
- Executes arbitrary shell commands
- Persists working directory between commands (within a session)
- Can run interactive-ish commands (though primarily designed for non-interactive use)
- Captures stdout/stderr as text

### 7.2 What It Does NOT Do

- **No PTY allocation.** The SDK does not allocate or manage PTYs. It runs commands
  through the Claude Code CLI's shell execution.
- **No terminal state introspection.** There is no concept of reading the terminal grid,
  cursor position, or screen buffer.
- **No VT parsing.** Output is captured as flat text, not parsed as VT escape sequences.
- **No OSC/escape sequence awareness.** The SDK has no mechanism to detect or emit
  custom OSC sequences.
- **No multi-pane/multiplexer functionality.** Each agent runs in a single execution
  context. There is no concept of panes, splits, or windows.
- **No agent identity in the terminal.** Agents don't have terminal-level identifiers
  that other processes could discover.

### 7.3 Hosting: Single Container Multi-Agent

The hosting documentation describes a "Single Container" pattern where multiple SDK
processes run in one container for agent collaboration — but explicitly warns that
"you will have to prevent agents from overwriting each other." There is no built-in
coordination mechanism.

**Source:** [Hosting](https://platform.claude.com/docs/en/agent-sdk/hosting),
[Agent Loop](https://platform.claude.com/docs/en/agent-sdk/agent-loop)

---

## 8. Key Abstractions

### 8.1 Core Types

| Type | Role |
|------|------|
| `ClaudeAgentOptions` | Configuration dataclass — tools, permissions, MCP, agents, sessions, limits, hooks |
| `AgentDefinition` | Defines a subagent: description, prompt, tools, model |
| `ClaudeSDKClient` | Stateful client for multi-turn conversations with automatic session tracking |
| `query()` | Async generator for one-shot or simple interactions |
| `HookMatcher` | Matches tool names (regex) and routes to hook callbacks |

### 8.2 Message Types

| Type | When Emitted |
|------|-------------|
| `SystemMessage` | Session lifecycle: `"init"` (session start), `"compact_boundary"` (after compaction) |
| `AssistantMessage` | After each Claude response (text + tool calls). Contains `content: list[ContentBlock]` |
| `UserMessage` | After tool execution with results. Also for user inputs mid-loop |
| `StreamEvent` | Raw API streaming events (when `include_partial_messages=True`) |
| `ResultMessage` | Always last. Contains `result`, `total_cost_usd`, `usage`, `session_id`, `stop_reason` |

### 8.3 Content Block Types

| Type | Contents |
|------|----------|
| `TextBlock` | `text: str` |
| `ThinkingBlock` | `thinking: str`, `signature: str` |
| `ToolUseBlock` | `id: str`, `name: str`, `input: dict` |
| `ToolResultBlock` | `tool_use_id: str`, `content: str \| list`, `is_error: bool` |

### 8.4 Result Subtypes

| Subtype | Meaning |
|---------|---------|
| `success` | Task completed normally |
| `error_max_turns` | Hit `max_turns` limit |
| `error_max_budget_usd` | Hit `max_budget_usd` limit |
| `error_during_execution` | API failure or cancelled request |
| `error_max_structured_output_retries` | Structured output validation exhausted retries |

### 8.5 Hook Events

`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `UserPromptSubmit`, `Stop`,
`SubagentStop`, `SubagentStart`, `PreCompact`, `Notification`, `PermissionRequest`

Hooks run in the application process (not in the agent's context), so they don't consume
context tokens. A `PreToolUse` hook can reject a tool call before execution.

**Source:** [Python SDK Reference](https://platform.claude.com/docs/en/agent-sdk/python)

---

## 9. Sessions and Continuity

### 9.1 Session Lifecycle

- Sessions are stored as `.jsonl` files under `~/.claude/projects/<encoded-cwd>/`
- Each `query()` call creates a new session by default
- `ClaudeSDKClient` automatically continues the same session across `client.query()` calls

### 9.2 Session Operations

| Operation | How | Use Case |
|-----------|-----|----------|
| **New** | Default `query()` | Fresh task |
| **Continue** | `continue_conversation=True` | Most recent session in current directory |
| **Resume** | `resume=session_id` | Specific past session |
| **Fork** | `resume=session_id, fork_session=True` | Branch to explore alternatives |

### 9.3 Cross-Host Sessions

Sessions are local to the machine. To resume on another host:
- Move the `.jsonl` file to the same path on the new host, or
- Capture results as application state and pass them into a fresh session's prompt

### 9.4 Session Inspection

```python
from claude_agent_sdk import list_sessions, get_session_messages

sessions = list_sessions(directory="/path/to/project")
messages = get_session_messages(session_id="abc-123")
```

**Source:** [Sessions](https://platform.claude.com/docs/en/agent-sdk/sessions)

---

## 10. Hosting and Deployment

### 10.1 Requirements

- Python 3.10+ or Node.js 18+
- Node.js (required by Claude Code CLI regardless of SDK language)
- ~1 GiB RAM, 5 GiB disk, 1 CPU per instance
- Outbound HTTPS to `api.anthropic.com`

### 10.2 Deployment Patterns

| Pattern | Description | Use Case |
|---------|-------------|----------|
| **Ephemeral** | New container per task, destroy on completion | Bug fixes, data processing |
| **Long-running** | Persistent container, multiple SDK processes | Email agent, site builder |
| **Hybrid** | Ephemeral containers hydrated with session history | Research, support agents |
| **Single container** | Multiple SDK processes in one container | Agent simulations |

### 10.3 Sandbox Providers

Modal, Cloudflare Sandboxes, Daytona, E2B, Fly Machines, Vercel Sandbox.

### 10.4 Authentication

- **Anthropic API key** (`ANTHROPIC_API_KEY`)
- **Amazon Bedrock** (`CLAUDE_CODE_USE_BEDROCK=1` + AWS credentials)
- **Google Vertex AI** (`CLAUDE_CODE_USE_VERTEX=1` + GCP credentials)
- **Microsoft Azure** (`CLAUDE_CODE_USE_FOUNDRY=1` + Azure credentials)

**Source:** [Hosting](https://platform.claude.com/docs/en/agent-sdk/hosting)

---

## 11. Comparison to Synapty

### 11.1 Fundamental Difference

| Aspect | Synapty | Claude Agent SDK |
|--------|---------|-----------------|
| **What it is** | Terminal-native orchestration platform with VT engine | LLM agent runtime library |
| **Core primitive** | PTY + VT state machine | LLM prompt + tool loop |
| **Agent model** | Provider-agnostic, any process in a PTY | Claude-only (Anthropic models) |
| **Communication** | A2A message routing (Hub-and-Spoke, JSON/TCP) | Parent-child subagent (prompt string / result string) |
| **Terminal awareness** | Full VT introspection (L3: 2D DOM, cell-level) | None (Bash tool captures flat text) |
| **Agent identity** | First-class (agent_id, capabilities, registration) | Implicit (subagent name in config) |
| **Discovery** | Runtime registration + capability queries | Static upfront definition only |
| **Multiplexing** | Core feature (multiple panes, Metal rendering) | Not applicable |
| **Deployment** | Native macOS app (V1), potential remote | Python/TS library, containerized |

### 11.2 What Claude Agent SDK Lacks That Synapty Provides

1. **Terminal introspection** — The SDK has zero awareness of terminal state. It treats
   command output as flat text. Synapty's L3 (2D DOM) exports cell-level terminal state
   with attributes (fg, bg, bold, etc.) as structured data for LLM consumption.

2. **Agent-to-agent messaging** — SDK subagents cannot talk to each other. Synapty's L4
   Hub provides a message bus where any registered agent can address any other agent.

3. **Runtime discovery** — SDK agents are statically defined. Synapty agents register
   dynamically with capabilities and can discover each other at runtime.

4. **PTY management** — The SDK has no concept of PTY allocation. Synapty's L1 provides
   daemon-per-session PTY management with crash isolation and state persistence.

5. **Provider agnosticism** — The SDK only works with Claude models. Synapty's agent
   model is provider-agnostic: any process that speaks the A2A protocol can participate.

6. **OSC-based notifications** — Synapty's L2 uses OSC sequences for agent status
   reporting. The SDK has no awareness of terminal escape sequences.

### 11.3 What Claude Agent SDK Provides That Synapty Does Not

1. **LLM integration** — The SDK provides a complete, production-ready LLM agent loop
   with context management, compaction, prompt caching, and cost tracking.

2. **Built-in tools** — 14+ tools for file operations, web search, code editing, etc.

3. **MCP ecosystem** — Access to hundreds of pre-built MCP servers for external service
   integration.

4. **Session management** — Sophisticated session persistence, resumption, and forking.

5. **Permission system** — Fine-grained tool permission controls with hooks.

6. **Hosting patterns** — Documented patterns for containerized deployment with sandbox
   providers.

### 11.4 Complementary, Not Competing

These systems are **complementary layers** in the agent stack:

```
┌─────────────────────────────────────────────────┐
│  Claude Agent SDK (or any LLM agent runtime)    │  ← Agent "brain"
│  • LLM reasoning, tool selection, context mgmt  │
├─────────────────────────────────────────────────┤
│  Synapty (Terminal orchestration platform)       │  ← Agent "body"
│  • PTY substrate, VT introspection, A2A routing │
│  • Agent identity, discovery, multiplexing      │
└─────────────────────────────────────────────────┘
```

The SDK provides the *cognitive* layer (what to do, which tools to use). Synapty provides
the *physical* layer (where agents run, how they see terminal state, how they communicate).

---

## 12. Integration Scenarios

### 12.1 Scenario A: Claude Agent SDK Agent Running Inside a Synapty Pane

**Most natural integration.** A Python script using the Claude Agent SDK runs inside a
Synapty terminal pane. The agent uses its built-in tools (Read, Edit, Bash) while Synapty
provides:

- **Terminal multiplexing** — the agent's pane alongside other agent panes
- **VT introspection** — Synapty can read the agent's terminal output at cell level
- **A2A identity** — the agent registers with the Hub via the `synapty` CLI
- **Cross-agent messaging** — the agent receives/sends A2A messages via `synapty send/recv`

```
┌─ Synapty App ──────────────────────────────────────┐
│  ┌─ Pane 1 ───────────┐  ┌─ Pane 2 ────────────┐  │
│  │ Claude Agent SDK    │  │ Codex Agent          │  │
│  │ (Python process)    │  │ (any provider)       │  │
│  │                     │  │                      │  │
│  │ Uses: Bash, Read,   │◄─►│ Uses: synapty CLI   │  │
│  │   Edit + synapty    │  │   for A2A messaging  │  │
│  │   CLI for A2A       │  │                      │  │
│  └─────────────────────┘  └──────────────────────┘  │
│                    ▲                  ▲               │
│                    └──── Hub (L4) ────┘               │
└──────────────────────────────────────────────────────┘
```

**How the agent uses Synapty:**

The Claude Agent SDK agent would use its `Bash` tool to invoke the `synapty` CLI:

```python
# The agent would naturally use Bash to call synapty commands:
# synapty register --agent-id "claude-reviewer" --capabilities '["code-review"]'
# synapty send --target "codex-agent" --payload '{"task": "review auth.py"}'
# synapty recv  (blocking receive for incoming messages)
```

Alternatively, a custom MCP tool could wrap the Synapty CLI for cleaner integration:

```python
@tool("synapty_send", "Send a message to another Synapty agent", {
    "target": str, "payload": dict
})
async def synapty_send(args):
    import subprocess
    result = subprocess.run(
        ["synapty", "send", "--target", args["target"],
         "--payload", json.dumps(args["payload"])],
        capture_output=True, text=True
    )
    return {"content": [{"type": "text", "text": result.stdout}]}
```

### 12.2 Scenario B: Synapty MCP Server for Claude Agent SDK

Build a Synapty MCP server that exposes Hub capabilities to any Claude Agent SDK agent:

```python
# Hypothetical Synapty MCP server
@tool("list_agents", "List all registered Synapty agents", {})
async def list_agents(args):
    # Connect to Synapty Hub, query registered agents
    ...

@tool("send_message", "Send A2A message via Synapty Hub", {
    "target": str, "message": dict
})
async def send_message(args):
    # Route message through Hub
    ...

@tool("read_terminal", "Read terminal state of another agent's pane", {
    "agent_id": str
})
async def read_terminal(args):
    # Use L3 introspection to get 2D DOM of target pane
    ...

synapty_server = create_sdk_mcp_server(
    name="synapty", version="1.0.0",
    tools=[list_agents, send_message, read_terminal]
)
```

This would give Claude Agent SDK agents native access to Synapty's capabilities without
requiring Bash tool invocations.

### 12.3 Scenario C: Synapty as Hosting Platform for SDK Agents

Synapty's daemon-per-session model (L1) could serve as a hosting platform for Claude
Agent SDK processes:

1. User clicks "Deploy Claude Agent" in Synapty's host sidebar
2. Synapty SSHs to the target host, deploys the SDK process
3. The process runs in a Synapty-managed PTY with VT introspection
4. The agent registers with the Hub for A2A messaging
5. Synapty's status bar shows agent state, messages, activity
6. The human operator can inspect the agent's terminal output at any time

### 12.4 Scenario D: Claude Agent SDK Subagents + Synapty Hub Hybrid

Use the SDK's subagent model for Claude-to-Claude delegation, while using Synapty's Hub
for cross-provider communication:

```
Claude Agent (SDK parent)
  ├── Subagent: code-reviewer (SDK, Claude sonnet)
  ├── Subagent: test-runner (SDK, Claude haiku)
  └── Synapty A2A:
      ├── Codex agent (via Hub)
      ├── Gemini agent (via Hub)
      └── Custom tool agent (via Hub)
```

The SDK handles same-provider delegation efficiently (shared context model, prompt
caching). Synapty handles cross-provider routing where the SDK's model is insufficient.

---

## 13. Lessons for Synapty

### 13.1 Patterns to Adopt

1. **Session persistence and forking.** The SDK's session model (`.jsonl` files,
   resume by ID, fork to branch) is elegant. Synapty could adopt a similar pattern for
   agent execution histories — persistent transcripts that can be resumed or branched.

2. **Permission system with hooks.** The three-tier permission model
   (allowed / disallowed / mode) with hook interception points is a good pattern for
   Synapty's agent capability authorization. An agent registering with the Hub could
   declare what it's allowed to do, and the Hub could enforce it.

3. **Tool search / lazy loading.** The `ToolSearch` pattern (withhold tool definitions
   until needed) is relevant for Synapty's capability discovery. When many agents are
   registered, don't dump all capabilities into every agent's context — let them
   discover on demand.

4. **Context compaction.** Agents running long sessions in Synapty panes will face the
   same context window pressure. The compaction + re-injection pattern (summarize old
   history, re-inject persistent instructions) is worth documenting as a best practice
   for agents running inside Synapty.

5. **Plugin system architecture.** The plugin structure (manifest + skills + agents +
   hooks + MCP servers in a directory) is a clean packaging model. Synapty's agent
   skills concept could follow a similar structure for distributable agent capabilities.

6. **Cost tracking.** The SDK tracks `total_cost_usd` and `usage` per session. Synapty
   could aggregate cost data across all agent panes for operator visibility.

### 13.2 Anti-Patterns to Avoid

1. **Single-provider lock-in.** The SDK only works with Claude. Synapty's provider
   agnosticism is a key differentiator — don't compromise it.

2. **Flat text terminal output.** The SDK treats terminal output as flat text. This is
   exactly the problem Synapty's L3 (2D DOM) solves. Don't regress to text scraping.

3. **No peer-to-peer communication.** The SDK's subagent model is strictly hierarchical
   (parent → child, no sibling communication). Synapty's Hub-and-Spoke model is more
   flexible — preserve it.

4. **CLI-as-runtime dependency.** The SDK bundles and spawns the Claude Code CLI as a
   subprocess. This adds Node.js as a runtime dependency and creates process management
   complexity. Synapty's pure-Zig approach avoids this dependency chain.

### 13.3 Design Insights

1. **Three-layer stack vision.** Anthropic explicitly describes their agent stack as:
   MCP (agent-to-tool) + Agent Skills (portable capabilities) + Agent SDK (runtime).
   Synapty sits *below* this stack as the execution substrate. This positioning is
   correct and should be maintained.

2. **MCP as the integration protocol.** MCP is becoming the standard for agent-to-tool
   communication. Synapty should seriously consider exposing Hub capabilities as an MCP
   server (Scenario 12.2) to enable seamless integration with any MCP-aware agent
   runtime, not just the Claude Agent SDK.

3. **A2A protocol gap.** Neither MCP nor the Claude Agent SDK address agent-to-agent
   communication. Google's A2A protocol attempts this but is nascent. Synapty's L4 Hub
   fills a real gap in the ecosystem. Consider aligning the Hub's message format with
   A2A's Agent Card / Task model for future interoperability.

4. **The "single container multi-agent" pain point.** The SDK's hosting docs explicitly
   call out the difficulty of running multiple agents in one container. This is precisely
   the problem Synapty solves with daemon-per-session isolation and the Hub message bus.
   This is a strong value proposition to emphasize.

---

## 14. Sources

### Official Documentation
- [Agent SDK Overview](https://platform.claude.com/docs/en/agent-sdk/overview) — primary entry point
- [Quickstart](https://platform.claude.com/docs/en/agent-sdk/quickstart) — setup and first agent
- [How the Agent Loop Works](https://platform.claude.com/docs/en/agent-sdk/agent-loop) — execution model
- [Subagents](https://platform.claude.com/docs/en/agent-sdk/subagents) — multi-agent patterns
- [Sessions](https://platform.claude.com/docs/en/agent-sdk/sessions) — session management
- [MCP Integration](https://platform.claude.com/docs/en/agent-sdk/mcp) — MCP server configuration
- [Plugins](https://platform.claude.com/docs/en/agent-sdk/plugins) — plugin system
- [Python SDK Reference](https://platform.claude.com/docs/en/agent-sdk/python) — full API reference
- [Hosting](https://platform.claude.com/docs/en/agent-sdk/hosting) — deployment patterns
- [Permissions](https://platform.claude.com/docs/en/agent-sdk/permissions) — tool permission system

### GitHub
- [anthropics/claude-agent-sdk-python](https://github.com/anthropics/claude-agent-sdk-python) — Python SDK source
- [anthropics/claude-agent-sdk-demos](https://github.com/anthropics/claude-agent-sdk-demos) — example agents
- [CHANGELOG.md](https://github.com/anthropics/claude-agent-sdk-python/blob/main/CHANGELOG.md) — release history

### Engineering Blog
- [Building Agents with the Claude Agent SDK](https://claude.com/blog/building-agents-with-the-claude-agent-sdk) — architecture deep-dive

### External Integration
- [Microsoft Agent Framework + Claude](https://devblogs.microsoft.com/semantic-kernel/build-ai-agents-with-claude-agent-sdk-and-microsoft-agent-framework/) — cross-framework integration
- [AI Agent Protocol Ecosystem Map 2026](https://www.digitalapplied.com/blog/ai-agent-protocol-ecosystem-map-2026-mcp-a2a-acp-ucp) — MCP, A2A, ACP, UCP landscape

### Version Information
- **Python SDK:** v0.1.50 (bundled CLI v2.1.81), published 2026-03-26
- **TypeScript SDK:** v0.2.71
- **Requires:** Python 3.10+, Node.js 18+ (for bundled CLI)
- **License:** MIT (SDK), Anthropic Commercial Terms (usage)
