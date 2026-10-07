---
name: orchestration
description: >-
  Coordinate supervised Orca workers: threaded messages, blocking ask/reply,
  task dispatch, worker_done/escalation waits, task DAGs, decision gates,
  coordinator loops, and decomposing work across agents. Use `orca-cli` for full
  ownership handoffs — "hand off", "handoff", "handover", "give this to another
  agent", "another worktree" — unless asked to supervise, monitor, or coordinate
  a DAG, and for terminal control, lightweight terminal prompts, shell commands,
  Orca worktree management, and reading or waiting on terminals.
---

# Orca Orchestration

This file is a discovery stub, not the usage guide. The full, version-matched Orca
orchestration reference is served by the `orca` binary itself — kept out of this file on
purpose so it can never drift from the binary that will actually run your commands.

Engage Orca orchestration whenever you need structured multi-agent coordination: threaded
messages, blocking ask/reply flows, task dispatch, worker_done/escalation waits, task DAGs,
decision gates, coordinator loops, or decomposing work across agents. Use the orca-cli skill
instead for full ownership handoffs ("hand off", "handoff", "handover", "give this to
another agent", "another worktree") when the user did not ask to supervise, monitor, wait
for results, or coordinate a DAG — and for ordinary terminal control, shell commands,
worktree management, and the built-in browser. Coordination requires real Orca runtime
state; never substitute a non-Orca subagent tool.

In a project with the agent team (it has `.claude/agents/elon.md`), the default Orca coordinator
is the `elon` role. Elon owns the cross-project objective, cross-role DAG, dispatch and completion
review. `lead` is a teammate that coordinates engineering integration and reports to Elon. Keep
this split explicit in task messages and completion reports; CEO recommendations never replace
human-owner approval or required independent review.

`worker-watch.sh <run_id>` next to this file flags workers that look alive but stopped (provider
limit, trust dialog, low context); run it as `~/.claude/skills/orchestration/worker-watch.sh`.
`worker-watch.test.sh` is its test.

`worker-panes.sh <run_id> <coordinator_terminal> [dispatch_id ...]` shows workers as colored split panes in the
coordinator's tab (Orca cannot start a worker as a split pane). Each pane runs `worker-pane.sh <dispatch_id> [color]`,
a read-only live mirror of that worker's screen; it shows the final status line when the dispatch ends and stops. Each pane's handle is recorded in `~/.cache/orca-worker-panes/<dispatch_id>`. Run it as
`~/.claude/skills/orchestration/worker-panes.sh`; `worker-panes.test.sh` and `worker-pane.test.sh` are its tests.
After every `worker-release`, the coordinator closes the pane with `~/.claude/skills/orchestration/worker-pane-close.sh <dispatch_id>` (no arguments closes every recorded pane whose dispatch has ended); `worker-pane-close.test.sh` is its test.
Pane color comes from the role in the task title (`<role> - <job>`), looked up in `role-colors.tsv` next to the scripts (unknown role: grey), so always start the title with the role name. Add a line there for a new role.

## Resolve the CLI for this session

Choose the executable once and reuse it for every later command:

- If the `ORCA_CLI_COMMAND` environment variable is set, use its value. Orca exports this
  for managed WSL sessions.
- Otherwise, in a dev checkout whose session exposes `ORCA_DEV_REPO_ROOT`, use `orca-dev`.
- Otherwise, on Linux outside an Orca-managed terminal, use `orca-ide`. Never run bare
  `orca` there — outside Orca's terminals it normally resolves to the
  GNOME Orca screen reader (`/usr/bin/orca`) and starts speech on the user's machine.
- Otherwise, use `orca`.

Below, `ORCA` is a placeholder for the executable you resolved. Substitute it before
running anything; do not create a shell variable or run `ORCA` literally. This works the
same way in POSIX shells, PowerShell, and cmd.exe.

If the selected executable cannot run, report its exact error and stop. Do not fall through
to another executable, which could silently target a different Orca build.

## Load the version-matched guide before running Orca commands

```text
ORCA skills get orchestration
```

That prints the compact, version-matched guide for the exact binary that will handle your
next commands. It covers the normal local coordinator loop. For a conditional action gate
such as remote placement, uncertain release recovery, or expanded DAG work, load only the
reference that gate names with
`ORCA skills get orchestration --reference references/<file>.md`
(`--references` lists the names). If that binary rejects `--reference`, run
`ORCA skills get orchestration --full` and read the named bundled reference before acting.

Prefer `--json`. Use the selected executable's `--help` for commands or flags the guide does
not cover. If a command reports that Orca is not running, start it with `ORCA open --json`
and retry. If it fails with `runtime_access_denied`, your sandbox blocked the connection:
re-run it with escalated permissions, and do not run `ORCA open` or restart Orca. If
`skills get` is unknown, explain that updating Orca restores the guide; use `--help` for
read-only discovery and do not guess unsupported commands.
