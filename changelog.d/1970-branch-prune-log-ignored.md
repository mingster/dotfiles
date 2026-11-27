The daily prune restore log is now `~/agent-state/branch-prune/<date>.log`, which agent-state already ignores, so a host that is not the coordinator no longer leaves agent-state dirty.
