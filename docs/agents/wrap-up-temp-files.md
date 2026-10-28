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
