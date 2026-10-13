---
name: orca-team
description: >-
  Show supervised Orca workers in colored panes, close ended worker panes and
  terminals, and detect stalled workers with worker-watch. Complements Orca's
  orchestration skill for projects using the agent team.
---

# Orca team tooling

This skill complements Orca's `orchestration` skill. Load its version-matched guide
with `orca skills get orchestration` before coordinating workers; Orca owns that
skill and its lifecycle commands. Dotfiles owns the pane and watch helpers here.

In a project with the agent team (it has `.claude/agents/elon.md`), the default Orca coordinator
is the `elon` role. Elon owns the cross-project objective, cross-role DAG, dispatch and completion
review. `lead` is a teammate that coordinates engineering integration and reports to Elon. Keep
this split explicit in task messages and completion reports; CEO recommendations never replace
human-owner approval or required independent review.

`worker-watch.sh <run_id>` next to this file flags workers that look alive but stopped (provider
limit, trust dialog, low context); run it as `~/.claude/skills/orca-team/worker-watch.sh`.
`worker-watch.test.sh` is its test.

`worker-panes.sh <run_id> <coordinator_terminal> [dispatch_id ...]` shows workers as colored split panes in the
coordinator's tab (coordinator left; the first pane splits it to the right, later panes stack in that right column, and the coordinator is split again only when no worker pane is left) (Orca cannot start a worker as a split pane). Each pane runs `worker-pane.sh <dispatch_id> [color]`,
a read-only live mirror of that worker's screen; it shows the final status line when the dispatch ends, waits about 10 seconds (`ORCA_PANE_CLOSE_DELAY`) and closes its own terminal through `ORCA_TERMINAL_HANDLE` (skipped when unset), verifying that the handle disappears from `orca terminal list` and retrying failed or lingering closes after 5, 15, 30, then 60 seconds for up to 30 minutes in a plain shell loop (CLI calls are bounded too), so a pane whose split timed out and was never recorded does not linger. A failing `worker-show` keeps it running. Each pane's handle is recorded in `~/.cache/orca-worker-panes/<dispatch_id>`. Run it as
`~/.claude/skills/orca-team/worker-panes.sh`; `worker-panes.test.sh` and `worker-pane.test.sh` are its tests.
The moment the coordinator validates a worker's report (or the worker fails), it runs `worker-release`, then `~/.claude/skills/orca-team/worker-pane-close.sh <dispatch_id>`. That closes the recorded pane and every terminal of the dispatch still in `orca terminal list`: the handles `worker-show` reports (agent and setup terminals) and any terminal whose cwd is the worktree Orca created for the worker, so a pane whose split timed out is covered too (`worker-panes.sh` records the one new pane that appears in the tab after a timed out split). A dispatch still running keeps its terminals, and the owner's own sessions and other projects' terminals are never matched. Records are removed only after verified disappearance; unfinished closes remain recorded for a later sweep. Only positively ended dispatches (`completed`, `failed`, `cancelled`, `released`) authorize closure, including recorded panes. Run with no arguments on every wake to close recorded ended panes and discover leftover terminals via every page of `worker-list`, restricting newly discovered dispatches to the current project's identity from live terminal metadata (discovery is skipped if that identity is unknown), using the same worker-handle and exact created-worktree matching rules; `worker-pane-close.test.sh` is its test.
Pane color comes from the role in the task title (`<role> - <job>`), looked up in `role-colors.tsv` next to the scripts (unknown role: grey), so always start the title with the role name. Add a line there for a new role.
