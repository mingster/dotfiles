# Coordinator operations

Start Cursor through `script/start-cursor-worker.sh` so the exact worktree is trusted before the worker starts.

For remote Cursor, pass `--on <environment>` with a saved Orca environment and absolute repository paths on that environment. The brief file remains local to the coordinator.

```sh
script/start-cursor-worker.sh --on <environment> \
  --run <run-id> --spec <brief-file> --title <task-title> \
  --name <worktree-name> --repo <remote-repository-path> \
  --base-branch origin/main --model <model-id> --from <terminal-handle>
```

The helper creates the worktree through `orca worktree create --environment`, then runs Python 3 in an Orca terminal on the same environment. The command writes `.workspace-trusted` under the remote user HOME for the returned absolute worktree path. A successful terminal exit is required before `worker-start --on` receives that existing worktree. No SSH command is used.

Python 3 must be available locally and remotely. If the trust command fails or its exit cannot be confirmed within 60 seconds, dispatch stops and the terminal remains available for inspection. The helper closes the trust terminal after a confirmed successful exit.

For an existing remote worktree, replace the creation flags with `--worktree-path <absolute-remote-path>`. If the base branch is omitted during remote creation, Orca uses the remote repository default branch. Without `--on`, local creation, trust and dispatch follow the existing behavior.
