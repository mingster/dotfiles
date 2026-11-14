# Worktree cleanup: agent temp files

`script/wrap-up.sh` also clears the temp files agents leave behind. Read this before changing what it removes or where agents write.

## Inventory

| Location | What it holds | Rule |
|----------|---------------|------|
| `/tmp/claude-<uid>/<worktree-slug>/<session>/` | Claude Code per-project scratch tree, including throwaway Chrome profiles | Removed per session dir. The slug is the worktree path with every non alphanumeric character turned into `-`. |
| `/tmp/claude-<uid>/qa-*` | Loose QA and screenshot dirs, including Chrome Dev throwaway profiles | Age rule only. |
| `/tmp/NNNN-*.log`, `/tmp/NNNN-*.sh` | Loose logs and scripts workers wrote straight to `/tmp` | Age rule only, files you own. |
| `/tmp/playwright-artifacts-*`, `/tmp/playwright_chromiumdev_profile-*` | Playwright output and profiles | Age rule only. |
| Per-user temp dir `com.google.Chrome*.code_sign_clone` (macOS) | Chrome launch clones | Held open check only. |

Not in the inventory, so never touched: Bun and package caches (not created by agents), anything else in `/tmp`, and anything under a worktree.

## When an item is removable

Preview (the default) lists each item with its size. `--apply` removes it. An item is removable when no process holds it open (`lsof`) and either:

- its worktree no longer exists (a session dir whose slug matches no directory on disk), or
- nothing inside it changed for 24 hours.

## Never removed

- Anything a running process holds open, or any item when `lsof` is missing or fails.
- The current session's own scratch dir (the session id env var, or a dir that contains the working directory).
- The coordinator inbox waiter files `elon-wait.sh` and `elon-waiter.json`, and everything under the state dir.

## Coordinator waiter location

The inbox waiter script and its output file live in `~/.local/state/agent-team/` (`elon-wait.sh`, `elon-waiter.json`), not in `/tmp`. A coordinator that still uses the old `/tmp` paths keeps working because worktree cleanup leaves both locations alone. Switch by pointing the waiter script and its fleet-watch pattern at the new paths, then delete the old files by hand.

## Where workers write

Temp files go only inside the session scratch dir or `<worktree>/.scratch/`, never loose in `/tmp`, so this inventory stays complete.

## Testing

`script/tests/wrap-up-temp-files.test.sh`. Any test that runs `wrap-up.sh --apply` must point `WRAP_UP_SCRATCH_ROOT`, `WRAP_UP_LOOSE_ROOT` and `WRAP_UP_STATE_DIR` at disposable dirs, or it cleans the real host.

## Branch safety and planning

Both preview and apply run a real `git fetch --prune origin` before planning. Preview
updates remote-tracking refs while leaving local and remote branches, worktrees,
and files intact.

Local and remote branches are kept when they are the repository default branch,
`gh-pages`, the GitHub Pages source branch, a protected branch, or an `archive/*`
branch (kept on every delete route, including ancestor, closed-PR, patch-merged,
stale, `--worktrees-only` and `--branch`). The default comes from GitHub with
`origin/HEAD` as a fallback; Pages and protected branch metadata come from GitHub.
Unavailable or malformed safety metadata keeps all branches, with a reason, rather
than guessing that they are disposable. When `wrap-up.sh` fast-forwards a clean
`main` checkout, it runs `script/setup-orca.sh` so `~/.orca/presets.json` stays
linked on every host.

Apply checks each remote branch with `git ls-remote` immediately before deletion.
A missing branch, a changed SHA, or a failed lookup is reported as kept. Deletion
leases also reject a change after the check; batch pushes are atomic and failed
batches retry branches individually with fresh checks.

When `lsof` is missing, the summary includes one line with the counts of worktrees
and Chrome clones kept because process activity could not be checked.

Run `bash script/tests/wrap-up-branch-safety.test.sh` for branch protection,
fetch/prune and deletion races, and the missing-`lsof` summary.

## Terminals and worktrees

A fleet host (`--worktrees-only`) closes the terminals of its own Orca, by the same rules as the coordinator. Before this, it closed none, so every old terminal looked like a user and kept its worktree.

A local terminal with no dispatch and no running agent is closed, and its worktree is then removed if it is clean and merged (untracked `.orca-install-stamp`, `.continual-learning.json` and image files do not count as dirty). Kept, with the reason printed: a running agent, an unsettled or never-settled dispatch, a `lead-` worktree, uncommitted work, the main checkout, the caller's own terminal, output in the last 10 minutes, and anything the holder check cannot clear. Ended worker panes are swept within a bounded per-round budget, pruned only when `worker-list` is complete, and removed through `pane_record_rm` only after strict terminal inventory proof confirms the pane terminal is gone. Test: `script/tests/wrap-up-unknown-owner.test.sh`.

### Release and close on every environment

Each run reads every Run on this Orca and on every environment, then does two fleet wide steps before the worktree check.

Release: a worker whose state is succeeded, stopped or failed, or whose liveness is exited or sleep, and whose terminal state is not released, retained, or `release_unknown`, gets `worker-release --dispatch <id>` (with `--environment` for a remote one). A row already in `release_unknown` has a recorded terminal that no longer resolves; it is not asked again and is counted once in the summary as needing no action. Fleet watch stops counting that row once it proves the worker is gone. A ready or in progress worker that is live is never touched, nor the caller's `$ORCA_TERMINAL_HANDLE` or a Run coordinator's terminal.

Close: on a remote environment a terminal whose worktree has only settled dispatches is closed (setup and plain shell panes included), and so is one whose worktree this run removed (a second pass after the worktree step). A terminal in a worktree with no dispatch record stays kept as unknown user, since it may be a user session, a dev server or another coordinator. Kept: a terminal outside a worktree, a running agent, a main terminal, and, on a scheduled round, a local shell whose last output is inside 60 minutes. A scheduled round closes a local shell with no dispatch and no agent once that output is at least 60 minutes old. A shell whose worktree or working directory belongs to a live dispatch stays open on a scheduled round and on a manual run. A worker that has ended (worker_done, stopped, exited, or a gone terminal) does not keep its terminal open merely because release has not finished. Terminal close runs before worker release.

The dry run lists every `Release worker` and `Close terminal` line, and apply does exactly that list. Test: `script/tests/wrap-up-fleet-release.test.sh`.

### One apply at a time, and runtime bounds

`--apply` takes a lock file (`wrap-up-apply.lock` in `WRAP_UP_STATE_DIR`, default `~/.local/state/agent-team`). A second apply prints the holder and exits 75; a scheduled round logs it as a skip. A dry run takes no lock. The summary counts print before the pane close step. Worst case for `--apply`: `WRAP_UP_TOTAL_TIMEOUT` (900 s) plus the pane step, which is capped at `WRAP_UP_PANE_TIMEOUT` (1800 s) with every call inside it limited to `WRAP_UP_PANE_CALL_TIMEOUT` (10 s). A dry run takes about 5 minutes for one repo.

## Browser sweep

After the dispatch inventory, worktree cleanup closes stale throwaway browsers: a main Chrome Dev or Chromium process whose `--user-data-dir` is under a temp root, and agent-browser daemons. Stable Chrome and any profile outside temp are never candidates. It keeps a browser younger than 2 hours, with a live parent that is not pid 1, in an active dispatch path, with an unreadable working directory, or when no complete dispatch inventory was read. It stops by pid with TERM after rereading the pid. Tests: `script/tests/wrap-up-browsers.test.sh` (seams `WRAP_UP_PS_CMD`, `WRAP_UP_KILL_CMD`; in test mode the sweep runs only when both are set).
