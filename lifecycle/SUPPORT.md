# Adapter-pack support matrix (WI-2026-08-11-011)

Coverage across the 19-tool detection fleet, column by column. DATA-first:
detection = `detect/*.json`, resume/launch = `lifecycle/*.json`, hooks =
`synapty hooks install <tool>` / hook-event dispatch. "unknown" means
NOT researched or NOT verified — never assumed.

Verified entries carry the verification date; sources are the tools' own
docs (claude/codex/gemini/cursor/opencode/amp checked 2026-08-11).

| tool        | detection manifest | hooks channel                                        | resume entry point                     | session id shape        | lifecycle file |
|-------------|--------------------|------------------------------------------------------|----------------------------------------|-------------------------|----------------|
| claude      | yes (calibrated)   | native hooks — SessionStart/UserPromptSubmit/Notification/Stop/SessionEnd via `hook-event claude` | `claude --resume <id>` (verified)      | UUID                    | claude.json    |
| codex       | yes (calibrated)   | `notify` program → `hook-event codex` (agent-turn-complete carries thread-id + done; verified) | `codex resume <id>` (verified)         | UUID (thread-id)        | codex.json     |
| gemini      | yes (calibrated)   | none found (passive-only)                            | `gemini --resume <id>` (verified)      | UUID or numeric index   | gemini.json    |
| cursor      | yes                | unknown                                              | `cursor-agent --resume <id>` (verified; upstream notes chat-id persistence gaps) | UUID (chat id) | cursor.json    |
| opencode    | yes                | plugin/event system exists — adopt-or-defer: DEFERRED (plugin install is invasive; passive detection suffices for V1) | `opencode --session <id>` (verified)   | `ses_` + slug           | opencode.json  |
| amp         | yes                | unknown                                              | `amp threads continue <id>` (verified) | thread id (slug)        | amp.json       |
| antigravity | yes                | unknown                                              | unknown                                | unknown                 | —              |
| cline       | yes                | unknown                                              | unknown                                | unknown                 | —              |
| copilot     | yes                | unknown                                              | unknown                                | unknown                 | —              |
| devin       | yes                | unknown                                              | unknown                                | unknown                 | —              |
| droid       | yes                | unknown                                              | unknown                                | unknown                 | —              |
| grok        | yes                | unknown                                              | unknown                                | unknown                 | —              |
| hermes      | yes                | unknown                                              | unknown                                | unknown                 | —              |
| kilo        | yes                | unknown                                              | unknown                                | unknown                 | —              |
| kimi        | yes                | none found (passive-only; no hooks, no session env var, cannot self-report — checked 2026-08-21) | `kimi --session session_<uuid>` (verified 2026-08-21) | `session_` + UUID — the prefix is PART of the ref | kimi.json      |
| kiro        | yes                | unknown                                              | unknown                                | unknown                 | —              |
| maki        | yes                | unknown                                              | unknown                                | unknown                 | —              |
| pi          | yes                | unknown                                              | unknown                                | unknown                 | —              |
| qodercli    | yes                | unknown                                              | unknown                                | unknown                 | —              |

Degradation is safe by design: a tool without a lifecycle file simply
never composes a resume incantation (launch-fresh honesty per RFC-0006
C-RESUME-PLAN); a session id failing the RFC-0008 allowlist falls back
to pane identity; a tool without hooks stays passive-only (detection
manifests carry presence). Extending a column is a data change plus, for
hooks, a `plan<Tool>HookEvent` mapping.

gemini hook note: no notify/hook mechanism found in gemini-cli as of
2026-08-11 — passive-only, revisit when upstream grows one.

kimi note: the resume ENTRY POINT is verified and the template is written,
but nothing can supply the ref. kimi-code 0.36.1 has no hook or notify
mechanism, exports no session-id variable to the tools it runs, and an agent
asked for its own session id cannot determine it — measured: it answered with
a `*_SESSION_ID` belonging to a DIFFERENT tool that happened to be in its
environment. So both routes RFC-0006 C-RESUME-PLAN provides are closed, and
kimi panes degrade to launch-fresh. `kimi --continue` would need no ref, and
is refused for the reason the clause names in its own example: it continues
"the previous session for the working directory", which cannot address a
specific session and MUST NOT be presented as precise continuity.

THAT MEASUREMENT IS ALSO A WARNING. A resume_ref is VALIDATED and not
VERIFIED — it is checked for shape, not for belonging to the agent that
supplied it. An agent that reads a foreign session id out of its environment
and offers it in good faith produces a plan that, on restore, types someone
else's session into a pane. Whatever supplies the ref has to know it is its
own.
