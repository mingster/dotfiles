wrap-up now drops idle build caches (`.next` by default, names set by `WRAP_UP_BUILD_CACHE_DIRS`) in the worktrees it keeps, and a failed single delete (worktree, local branch or remote branch) warns and counts as kept instead of stopping the run.

The fleet run now allows each host 900 seconds by default (was 300), since a host with a large backlog of finished worktrees needs more than 5 minutes.
