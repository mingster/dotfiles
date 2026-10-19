# Verified worker terminal cleanup

Branch: `mingster/dotfiles-pane-close`
Worktree: `~/orca/workspaces/dotfiles/dotfiles-pane-close`

## Cause evidence

Source inspection confirmed that both close paths issued one close request, discarded its
stderr and exit status, and never checked `terminal list`. The coordinator cleanup script
also removed state immediately regardless of close success. A lost or timed-out renderer
request therefore permanently lost its retry opportunity. Explicit dispatch cleanup also
closed recorded panes of running dispatches; only its leftover-terminal discovery was guarded.

An awake diagnostic created a disposable terminal in this worktree, closed only that newly
created handle, captured the close exit status and stderr, and checked the next terminal list.
The close exited **0**, stderr was **empty**, and the handle was **absent** afterwards
(close plus verification took approximately 1.314 seconds). No existing user/worker terminals
were closed for diagnosis. Display-off/screensaver throttling was **not reproduced** in this
session, so renderer suspension remains the owner's plausible explanation rather than a
confirmed runtime cause. No Orca renderer source was inspected.

## Change

Both scripts source a shared plain Bash retry loop. Each handle gets a 30-minute wall-clock
budget; CLI subprocesses are bounded to at most 20 seconds and the remaining budget.
Close requests retry after 5, 15, 30, then 60 seconds until a successful, complete terminal
listing proves the handle absent. A failed/invalid/truncated listing cannot prove absence.
Dispatch status is rechecked before each close, and only completed, failed, cancelled or
released dispatches authorize it. Running or unverifiable dispatches preserve their records. Coordinator cleanup also protects
its own `ORCA_TERMINAL_HANDLE` against stale matching records.

The coordinator script records discovered leftover handles before attempting cleanup and
retains unverified handles after budget expiry. With no arguments it combines recorded IDs
with paginated `worker-list` discovery, and restricts new discovery to the current project identity resolved from live terminal
metadata at the current checkout. Unknown project identity skips new discovery safely.
A live `worker-list --limit 1` receipt reported `scope.source=all` in this dispatched
terminal, so relying solely on the documented implicit Run scope would have crossed
projects. Discovery uses the existing explicit worker handles and exact linked git worktree
matching for created or reused worktrees whose `.git` is a file; main checkouts are matched by worker handle only. The coordinator can run
this sweep on every wake; no OS wake hook was installed.

## Validation

- Red run: close script had 4 expected regression failures (19 passed).
- `worker-pane.test.sh`: 21 passed, 0 failed.
- `worker-pane-close.test.sh`: 30 passed, 0 failed.
- `worker-panes.test.sh`: 11 passed, 0 failed.
- Error-severity ShellCheck on both scripts, the helper and both changed tests: passed.
- `bash script/shellcheck-dotfiles.sh`: passed.
- `git diff --check`: passed.

Tests exercise rejected closes, accepted-but-still-listed handles, backoff, timeout record
retention, failed list reads, explicit running dispatch protection (including recorded panes),
a dispatch changing to running between retries, paginated discovery without a pane record,
and preservation of the coordinator, owner and unrelated projects' terminals. Real display-off/wake verification
and live 30-minute retry exhaustion remain untested; expiry uses a zero-budget test override.
