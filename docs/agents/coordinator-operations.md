# Coordinator operations

Start remote workers through `bash script/start-remote-worker.sh` with the same
arguments as `orca orchestration worker-start`, including `--on <environment>`
and `--agent claude|cursor|antigravity`. The helper checks the required CLI
on the execution environment's login-shell PATH in an Orca terminal before
dispatch. A missing CLI, failed probe, or unconfirmed exit refuses dispatch and
names the required CLI. Install missing tools on that environment with
`script/install-agent-clis.sh`; sign-in remains an owner action. Direct Orca
invocations bypass this dotfiles preflight. The Cursor helper below includes it.

The standard bootstrap runs `script/install-agent-clis.sh` after platform setup
supplies Node/npm. It skips installed tools, removes vendor additions to tracked
shell rc files while preserving prior local changes, and lists outside rc files
the installers touched. Vendor CLIs under `arch/bin` are ignored to protect
existing Linux bin-directory symlinks. New setups already copy helper scripts.

`script/setup-check.sh` reports each provider CLI and sign-in file presence
without reading credentials. Cursor uses `.cursor/auth.json` on macOS and
`$XDG_CONFIG_HOME/cursor/auth.json` (default `~/.config`) on Linux. Antigravity
uses the system keyring, so its sign-in file status is unavailable; see its
[official authentication description](https://github.com/google-antigravity/antigravity-cli#authentication).
File presence does not establish valid sign-in, and absent files can coexist
with keyring or API-key authentication. Owner sign-in checks remain separate.

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
