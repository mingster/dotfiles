---
name: wrap-up
description: Clean finished branches, worktrees and ended Orca panes at the end of a session, after a batch of merges, or before a release.
---

# Wrap up

Run in the repository being cleaned. Requires Git, gh and jq; sign in to gh for PR status checks.

1. Run `~/dotfiles/script/wrap-up.sh --repo "$PWD"` to preview cleanup. Dry run is the default and uses existing `origin/main` refs while previewing the fetch. Read every proposed deletion and the kept list.
2. Once cleanup is authorized by the coordinating role, run `~/dotfiles/script/wrap-up.sh --apply --repo "$PWD"`. This fetches origin, removes eligible clean worktrees, prunes worktree metadata, deletes finished local and remote branches, closes ended Orca panes, deletes Chrome `code_sign_clone` dirs (macOS per-user temp, about 750M each) that no running process holds open, and fast forwards a clean main checkout. Remote deletion is a push, so workers whose role prohibits pushing report the preview to Elon for application.
3. Read the final counts and kept list. Report dirty, active, protected and unmerged entries with their reasons; preserve work that still needs attention.

The script protects main, master, staging, production, web2 branches, staging and production suffixes, and branches checked out in retained worktrees. A merged commit or a closed PR makes a branch eligible; an open PR overrides a historical closed PR. Unknown Orca terminal ownership retains its worktree. When Orca is unavailable, the script warns that the active dispatch check was skipped; resolve that warning before applying if workers may still be running.

Chrome clones are listed in the preview as `Remove Chrome clone <path>`. A clone any process holds open (checked with lsof) is kept and reported; when lsof is missing, all clones are kept.

Completion means the cleanup counts and every retained item have been reviewed and reported to the coordinator.
