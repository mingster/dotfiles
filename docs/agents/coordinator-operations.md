# Coordinator operations

Start remote workers through `bash script/start-remote-worker.sh` (or `bash script/worker-startup.sh`)
with the same arguments as `orca orchestration worker-start`, including `--on <environment>`
and `--agent claude|cursor|antigravity`. The helper first checks `script/usage-gate.py` for the
target provider and model (exiting 3 if refused), then probes the required CLI on the execution
environment's login-shell PATH in an Orca terminal and refreshes `~/dotfiles` and the `~/.orca/presets.json`
symlink (`script/setup-orca.sh`) on that host before dispatch. A missing CLI, failed probe, or
unconfirmed exit refuses dispatch and names the required CLI. Install missing tools on that
environment with `script/install-agent-clis.sh`; sign-in remains an owner action. `script/usage-gate-hook.py`
blocks direct `orca orchestration worker-start --on` invocations so remote starts always pass
this preflight. The Cursor helper below includes the same usage gate and preset refresh.

`script/worker-startup.sh` provides a single entry point for daily host readiness (`--host-check`)
and worker dispatch (`--run <id> --spec <file> --title "<role>: <job>" --agent <name> --model <id>`).
Before starting a worker, it verifies or repairs the target host's `~/dotfiles` checkout, Orca preset
link, repository checkout, Node pin (`.tool-versions` via `asdf`) and Bun pin (`package.json`),
checks `usage-gate.py`, and delegates to `start-cursor-worker.sh` or `start-remote-worker.sh`.

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

## Fleet and load distribution

The team coordinates work across a fleet of Macs paired in Orca ADE (`orca environment list`). One host is the active coordinator (`agent-state/coordinator.conf`); the remaining hosts share builder, reviewer, browser, release and heavy-check workloads.

### Host specialization and routing order

Check fleet load before dispatch with `~/.claude/state/fleet-load.sh`:

1. **Primary code host (also hosts the coordinator):** first choice for code, test and review while 1-minute load < 12.
2. **First overflow host:** next choice while 1-minute load < 8.
3. **Second overflow host:** next choice while 1-minute load < 12.
4. **Browser and secrets host:** always used for browser tasks, secrets and main-checkout operations.
5. **Release-manager host:** runs only on a host named in the project's `docs/agents/deploy-facts.md`.
6. **Database and heavy host:** runs the dev database and remote Playwright or `head-checks.sh` jobs via `script/remote-heavy.sh`; never runs interactive agent workers. `head-checks.sh` may also run on the least loaded host that has the repository and `~/dotfiles`.
7. **QA placement (`script/qa-admission.py`, owner 2026-11-06):** `qa-sdet` runs on any host except Elon's host, picking the lightest host first.

### Worker admission and load balancing

- **Admission rule (owner 2026-11-04):** admit a new worker on a host when `(1-minute load / CPU cores) < 0.7` and `free memory >= 4 GB`, within the host's worker cap (`host_caps`).
- **Load band target:** host caps are a ceiling, never a target. Fill an idle host up to its cap before any host with queued work waits, and keep each active host between `0.4` and `0.7` load per core.
- **Counted slots:** count builders, reviewers, child dispatches and finished committers still holding a pending-push slot (`crew/OPERATIONS.md`).
- **Heavy job gate (`script/heavy-gate.sh` and `script/heavy-gate.py`):** at most 2 heavy jobs run on a host at once (or the host's calibrated limit in `~/.config/heavy-gate/slots.conf` from `script/hw-probe.sh --calibrate`), waiting until 1-minute load is below the ceiling (default 12) and free RAM is at least 20%. `tsc` and `bun test` take `--weight 1`; `next build`, Playwright and regressions take `--weight 2`; `HEAVY_GATE_CLASS=long` leaves 1 slot free for short checks.
- **Quota publication across hosts (`script/usage-gate.py --publish`):** the coordinator refreshes provider usage readings (`claude`, `cursor`, `antigravity`) and publishes `~/.claude/state/usage-gate.json` to runner hosts so local and remote hooks enforce the same 95% weekly ceiling.

## Taking over the coordinator

Do this only when the owner says so. Failover is never automatic and nothing schedules it. Roles live in the private agent-state repo, in `coordinator.conf`: one `coordinator <name>` line and ordered `backup <name>` lines, where each name is what `hostname -s` prints on that host.

On the host that is taking over, run:

```sh
bash script/take-over-coordinator.sh --yes            # --dry-run to look first
```

It prints its plan and refuses without `--yes`. In order, it:

1. fetches and fast-forwards the agent-state checkout (`~/agent-state`, or `--state-dir`). It stops if there are unpushed commits or uncommitted changes, and lists them.
2. checks this host is a `backup` line. If an earlier backup answers ssh it stops and names that host; run the command there, or pass `--skip-order` to continue anyway.
3. sets `coordinator <this host>` in `coordinator.conf`, commits only that file and pushes. A rejected push is retried once after a fresh fetch. The old coordinator takes this host's place in the backup list, so it can hand back later.
4. stops the old host's sync over ssh (6 second timeout). It reports `old host sync stopped` or `old host unreachable, fenced by coordinator.conf`. Unreachable is a pass, because step 3 already holds it.
5. restores live state with `sync.sh pull`, keeping this host's own `~/.zshenv.local`.
6. installs and loads only the sync LaunchAgent, then touches `.sync-ok`.
7. runs one `sync.sh push` and prints the result.

Any failure stops at that step and prints the state and the next command. Running it again is safe. On a host that is already the coordinator it only repeats the restore, the LaunchAgent and the push.

Left for the owner afterwards: pair Orca on the new host and start the coordinator agent there.

### When the old host comes back

Every `sync.sh push` first fetches origin and reads the `coordinator` line. If this host is not named, it refuses with `coordinator refused: this host is not <name>`, writes `.sync-refused`, alerts the fleet terminals and exits 1, before copying, committing or pushing anything. A failed fetch refuses too. The old host's live files stay as they were and origin is unchanged. The owner decides what to keep from them.

### Handing back

Run the same command on the other host: `bash script/take-over-coordinator.sh --yes`. The current coordinator is stopped and fenced the same way, and the host handing back becomes a backup again.

## Coordinator check

`script/elon-startup.sh` opens with `== 0 coordinator`, before the pull. It only reports and never blocks or changes anything. It fetches the private state repo (`${AGENT_STATE_DIR:-$HOME/agent-state}`, 10 second limit), reads `coordinator` from `origin/main:coordinator.conf`, and runs three checks:

1. This host is the coordinator (`hostname -s`, compared without case).
2. The local state repo is not behind `origin/main`.
3. `.sync-ok` in the state repo is under 30 minutes old (three sync periods). A missing file counts as stale.

Each failure prints a `PROBLEM` line and a `NO DISPATCH: <reason>` line. A missing state repo, a missing `coordinator` line and a failed fetch also print `NO DISPATCH`. When all pass it prints `ok coordinator <name>, state fresh`.

`NO DISPATCH` means start no worker and ask the owner. Failover is never automatic: only the owner changes the coordinator.

## Tools

| Tool | Role in coordinator and fleet operations |
| --- | --- |
| `script/elon-startup.sh` | Verifies coordinator identity and `.sync-ok` freshness in `agent-state`, runs `fleet-pull.sh`, and reports host health. |
| `script/new-coordinator.sh` | Sets up a new Mac as the coordinator from `agent-state` (`--dry-run` first). |
| `script/take-over-coordinator.sh` | Manual coordinator failover and handback using `coordinator.conf` (`--yes`). |
| `script/coordinator-waiter.sh` | Drains orchestration messages, binds Run and dispatch receipts, and rearms the background inbox waiter. |
| `script/orca-reply.sh` | Replies to a worker's orchestration message and nudges its terminal so an idle session wakes up. |
| `script/fleet-pull.sh` | Fast-forwards clean `main` checkouts across fleet hosts and runs `secrets-sync.sh`. |
| `script/fleet-watch.py` | 5-minute watchdog checking inbox waiters, host caps, stalled workers, backup freshness, PR checks, `heavy-gate` wait times, `wrap-up` freshness and `coordinator_watch` (see [Fleet watch](fleet-watch.md)). |
| `script/fleet-workers.py` | Lists active Orca workers across local and remote fleet environments. |
| `script/worker-startup.sh` | Daily `--host-check` and unified worker launcher (aligns `~/dotfiles`, Orca presets, repo `main`, Node and Bun pins, checks `usage-gate.py`, and starts the worker). |
| `script/start-remote-worker.sh` | Checks `usage-gate.py`, probes the remote CLI in an Orca terminal, refreshes `~/dotfiles` and presets, and calls `worker-start --on`. |
| `script/start-cursor-worker.sh` | Creates the worktree, writes `.workspace-trusted` via Python 3, checks `usage-gate.py`, and starts a Cursor worker. |
| `script/on-worker-done.sh` | Publishes a builder's branch (`coordinator-publication.sh`), starts `head-checks.sh`, and triggers `qa-admission.py`. |
| `script/worker-done-relay.sh` | Relays a builder's `worker_done` to the owning coordinator terminal and releases the committer once. |
| `script/qa-admission.py` | Dispatches an independent cross-family `qa-sdet` reviewer on the lightest fleet host other than Elon's. |
| `script/lead-merge.sh` | Elon's merge gate from `lead-*` worktrees (`--pr` or `--batch`). |
| `script/heavy-gate.sh`, `script/heavy-gate.py`, `script/hw-probe.sh`, `script/remote-heavy.sh` | Per-host heavy job admission, hardware calibration, and remote heavy job execution. |
| `script/usage-gate.py`, `script/usage-gate-hook.py` | Real provider quota check, `--publish` sync to runner hosts, `pick` ranking, and fail-closed `PreToolUse` hook. |
| `script/wrap-up.sh`, `script/worktree-idle.py` | Fleet-wide cleanup of finished worktrees, merged branches, ended terminals/panes and temp files. |

Full tool list across all stages: [Agent team reference](team-reference.md).
