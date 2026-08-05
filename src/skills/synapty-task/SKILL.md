---
name: synapty-task
description: Interact with the Synapty GitHub task center — list, claim, update, comment on, and create issues in the hub repo. Use when coordinating work with other agents or the human operator.
---

# Synapty Task

Synapty routes distributed collaboration through a single GitHub hub repo
(RFC-0003). Tasks are GitHub issues grouped by `p:<project>` labels with a
`s:todo` / `s:doing` / `s:done` state machine. The `synapty` CLI is the only
interface you need — it reaches the hub over your existing connection, and
the login device executes the GitHub API on your behalf. You never need a
GitHub token or direct API access.

## Commands

All commands print a JSON envelope on stdout; exit 0 on success.

### List tasks

```sh
synapty task list                          # all open issues
synapty task list --project p:<name>       # one project workstream
synapty task list --state closed           # closed issues
```

Returns `{"ok":true,"data":[{number,title,state,url,labels,assignee},...]}`.

### Claim a task (start work)

```sh
synapty task claim <number>
```

Transitions `s:todo` -> `s:doing` and assigns the issue to the operator's
GitHub identity. Claim one issue at a time; do not claim work you will not
finish.

### Update task status

```sh
synapty task update <number> todo|doing|done
```

- `doing` — you started; issue stays open with `s:doing`
- `done` — finished; issue is closed with `s:done` (reference your PR or
  result in a comment first)
- `todo` — unclaim / abandon

### Comment on a task

```sh
synapty task comment <number> "progress note, handoff instructions, result summary"
```

Use comments for progress reports and handoffs — the human and other
agents read them. Quote the message.

### Create a task

```sh
synapty task create "title" --project p:<name> [--body "details"]
```

Every task must carry a `p:<project>` label. Body is optional but
recommended (acceptance criteria, context).

## Workflow guidance

- Before starting anything, check `synapty task list --project p:<name>`
  for work that is `s:todo` and unassigned.
- Claim first, then work, then comment, then mark `done`. Keep the issue
  history truthful — it is the shared record.
- If another agent or the operator commented on an issue you hold, read
  it and respond via comment.
- Do not invent project labels: reuse existing `p:` labels from the list;
  create a new one only with the operator's agreement.
