# Wrap-up: agent temp files

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

The inbox waiter script and its output file live in `~/.local/state/agent-team/` (`elon-wait.sh`, `elon-waiter.json`), not in `/tmp`. A coordinator that still uses the old `/tmp` paths keeps working because wrap-up leaves both locations alone. Switch by pointing the waiter script and its fleet-watch pattern at the new paths, then delete the old files by hand.

## Where workers write

Temp files go only inside the session scratch dir or `<worktree>/.scratch/`, never loose in `/tmp`, so this inventory stays complete.

## Testing

`script/tests/wrap-up-temp-files.test.sh`. Any test that runs `wrap-up.sh --apply` must point `WRAP_UP_SCRATCH_ROOT`, `WRAP_UP_LOOSE_ROOT` and `WRAP_UP_STATE_DIR` at disposable dirs, or it cleans the real host.

## Branch safety and planning

Both preview and apply run a real `git fetch --prune origin` before planning. Preview
updates remote-tracking refs while leaving local and remote branches, worktrees,
and files intact.

Local and remote branches are kept when they are the repository default branch,
`gh-pages`, the GitHub Pages source branch, or a protected branch. The default comes
from GitHub with `origin/HEAD` as a fallback; Pages and protected branch metadata
come from GitHub. Unavailable or malformed safety metadata keeps all branches,
with a reason, rather than guessing that they are disposable.

Apply checks each remote branch with `git ls-remote` immediately before deletion.
A missing branch, a changed SHA, or a failed lookup is reported as kept. Deletion
leases also reject a change after the check; batch pushes are atomic and failed
batches retry branches individually with fresh checks.

When `lsof` is missing, the summary includes one line with the counts of worktrees
and Chrome clones kept because process activity could not be checked.

Run `bash script/tests/wrap-up-branch-safety.test.sh` for branch protection,
fetch/prune and deletion races, and the missing-`lsof` summary.
