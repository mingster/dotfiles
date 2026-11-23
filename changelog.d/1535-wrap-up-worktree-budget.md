wrap-up: a scheduled child limits its worktree loop to WRAP_UP_SCHEDULED_WORKTREE_BUDGET (120 s), so slow worktrees no longer starve branch cleanup and the repo run ends before exit 124 (#1535).
