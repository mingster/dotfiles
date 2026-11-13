# Coordinator operations

Start remote workers through `bash script/start-remote-worker.sh` (or `bash script/worker-startup.sh`)
with the same arguments as `orca orchestration worker-start`, including `--on <environment>`
and `--agent claude|cursor|antigravity`. The helper first checks `script/usage-gate.py` for the
target provider and model (exiting 3 if refused), then probes the required CLI on the execution
environment's login-shell PATH in an Orca terminal and refreshes `~/dotfiles` and the `~/.orca/presets.json`
symlink (`script/setup-orca.sh`) on that host before dispatch. A missing CLI, failed probe, or
unconfirmed exit refuses dispatch and names the required CLI. Install missing tools on that
environment with `script/install-agent-clis.sh`; sign-in remains a user action. `script/usage-gate-hook.py`
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
with keyring or API-key authentication. User sign-in checks remain separate.

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

For an existing remote worktree, replace the creation flags with `--worktree-path <absolute-remote-path>`. If the base branch is omitted during remote creation, Orca uses the remote repository default branch. Without `--on`, local creation, trust and spawn follow the existing behavior.

## Fleet and load distribution

The team coordinates work across a fleet of Macs paired in Orca ADE (`orca environment list`). One host is the active coordinator (`agent-state/coordinator.conf`); the remaining hosts share PR owner, verifier, browser, release and heavy-check workloads.

### Host specialization and routing order

Host names, 1-minute load ceilings and roles live in the private fleet-watch config (`host_caps`, `host_load_ceilings`, `worker_placement.order` and `worker_placement.roles`). `~/.claude/state/fleet-load.sh` is the default load sensor.

**Automatic placement (`script/worker-startup.sh`):** when `--run` has no `--on`, `script/worker-placement.py` reads the sensor and config, walks `worker_placement.order`, skips hosts tagged `heavy`, `release` or `browser` for ordinary code work, skips hosts with no readable load, and picks the first host whose 1-minute load is under its ceiling. On the local host only, placement also treats the host as full when 1-minute load per core is at or above `0.7` (same bar as coordinator overload), even when load is still under the host ceiling. Remote picks require a `worker_placement.repos.<environment>` entry that maps the caller's repo id or path to that environment's Orca repo selector; hosts without a mapping are skipped. When every remote host is skipped for no repo mapping, the refusal line says `no host has a repo mapping` (it does not blame a missing load reading). Cursor placement passes that mapped selector to `start-cursor-worker.sh`. Browser workers are routed only when the brief contains a line `Host role: browser` (not from casual mentions of secrets or checkout). With no fleet config file, placement is skipped and the worker starts locally. It prints one line (`worker-placement: host=<name> load_1m=<value>`), sets `--on` for a remote choice, and refuses with one line listing each considered host's load when every candidate is at or over its ceiling. Explicit `--on` skips placement; the usage gate (#748) still applies to the named host. Dry check only: `worker-startup.sh --pick-host-only --spec <brief> [--repo <selector>]`.

**Manual reference order** (must match `worker_placement.order` in the live config):

1. **Primary code host (also hosts the coordinator):** first choice for code, test and review while 1-minute load < 12.
2. **First overflow host:** next choice while 1-minute load < 8.
3. **Second overflow host:** next choice while 1-minute load < 12.
4. **Browser host:** used when the kickoff includes `Host role: browser` (not for ordinary code that merely mentions secrets or checkouts in prose).
5. **Release-manager host:** runs only on a host named in the project's `docs/agents/deploy-facts.md`.
6. **Database and heavy host:** runs the dev database and remote Playwright or `head-checks.sh` jobs via `script/remote-heavy.sh`; never runs interactive agent workers. `head-checks.sh` may also run on the least loaded host that has the repository and `~/dotfiles`.

### Worker admission and load balancing

- **Admission rule (user 2026-11-04):** admit a new worker on a host when `(1-minute load / CPU cores) < 0.7` and `free memory >= 4 GB`, within the host's worker cap (`host_caps`).
- **Load band target:** host caps are a ceiling, never a target. Fill an idle host up to its cap before any host with queued work waits, and keep each active host between `0.4` and `0.7` load per core.
- **Counted slots:** count PR owners, verifiers, child dispatches and finished committers still holding a pending-push slot.
- **Heavy job gate (`script/heavy-gate.sh` and `script/heavy-gate.py`):** Playwright and production builds wait on slots (weight 2, at most 2 per host unless calibrated). Full `tsc` uses `--measure` with no slot. Unit tests and lint do not use the gate. Load and free memory rules unchanged; `HEAVY_GATE_CLASS=long` leaves 1 slot free.
- **Quota publication across hosts (`script/usage-gate.py --publish`):** the coordinator refreshes provider usage readings (`claude`, `cursor`, `antigravity`) and publishes `~/.claude/state/usage-gate.json` to runner hosts so local and remote hooks enforce the same per provider ceilings (`script/usage-gate.config.json`).

## Taking over the coordinator

Do this only when the user says so. Failover is never automatic and nothing schedules it. Roles live in the private agent-state repo, in `coordinator.conf`: one `coordinator <name>` line and ordered `backup <name>` lines, where each name is what `hostname -s` prints on that host.

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

Left for the user afterwards: pair Orca on the new host and start the coordinator agent there.

### When the old host comes back

Every `sync.sh push` first fetches origin and reads the `coordinator` line. If this host is not named, it refuses with `coordinator refused: this host is not <name>`, writes `.sync-refused`, alerts the fleet terminals and exits 1, before copying, committing or pushing anything. A failed fetch refuses too. The old host's live files stay as they were and origin is unchanged. The user decides what to keep from them.

### Handing back

Run the same command on the other host: `bash script/take-over-coordinator.sh --yes`. The current coordinator is stopped and fenced the same way, and the host handing back becomes a backup again.

## Coordinator check

`script/elon-startup.sh` opens with `== 0 coordinator`, before the pull. It only reports and never blocks or changes anything. It fetches the private state repo (`${AGENT_STATE_DIR:-$HOME/agent-state}`, 10 second limit), reads `coordinator` from `origin/main:coordinator.conf`, and runs three checks:

1. This host is the coordinator (`hostname -s`, compared without case).
2. The local state repo is not behind `origin/main`.
3. `.sync-ok` in the state repo is under 30 minutes old (three sync periods). A missing file counts as stale.

Each failure prints a `PROBLEM` line and a `NO DISPATCH: <reason>` line. A missing state repo, a missing `coordinator` line and a failed fetch also print `NO DISPATCH`. When all pass it prints `ok coordinator <name>, state fresh`.

`NO DISPATCH` means start no worker and ask the user. Failover is never automatic: only the user changes the coordinator.

## Board status

A card is Done (`workspaceStatus=completed`) when any one holds: its pull request is merged or closed, its linked issue is closed, its worker is released and the worktree has no pull request, or its worker failed or stopped. A worker that is still live stays, unless a pull request or issue rule already applies. An open pull request stays In review when a worker on that worktree was released, even if another worker there failed or stopped. A card whose workers only failed or stopped goes to Done. A worker with a pull request sets `in-review` before `worker_done`. A worker with no pull request sets `completed`.

`script/board-done.py` does the check. Dry run is the default and lists each card it would move and why. `--apply` sets the status. `--fleet` visits this Orca and every paired host with `--environment`. A host that cannot be reached is skipped and tried again on the next round. It is not treated as gone.

The coordinator's `wrap-up.sh --scheduled` round runs that check after the round's own cleanup, so the same round does not delete a card that just became Done. Only the host named in `agent-state/coordinator.conf` runs it. Fleet-watch does not: that pass is frozen and only alerts, while this round is already the one that reads the board. `script/ship.sh` still sets `completed` after a merge, on the environment that holds the worktree (`--environment`, or the dispatch record's host). A record that names no remote host sets the card on the local Orca.

Once a card has been Done for 30 minutes, `script/board-clean.py` removes its worktree, local branch, remote branch, terminals and session on the host named by the dispatch record (`--environment`). Dry run is the default and names every Done card it would clean or keep. A host that cannot be reached is skipped and tried again next round. It is not treated as gone. A card that stays gets a board comment with the reason: unsaved changes, commits that are not on main and not on any remote, an unreleased worker, the coordinator's own worktree, a `lead-*` worktree, an `rm-*` worktree, the main checkout, a protected branch, or an `archive/` branch. After the worker is released, `verify-*`, `qa-*` and `rm-*` branches are deleted even when they have local commits. A failed or stopped card is cleaned under those same guards.

## Tools

| Tool | Role in coordinator and fleet operations |
| --- | --- |
| `script/elon-startup.sh` | Verifies coordinator identity and `.sync-ok` freshness in `agent-state`, runs `fleet-pull.sh`, and reports host health. |
| `script/new-coordinator.sh` | Sets up a new Mac as the coordinator from `agent-state` (`--dry-run` first). |
| `script/take-over-coordinator.sh` | Manual coordinator failover and handback using `coordinator.conf` (`--yes`). |
| `script/orca-reply.sh` | Replies to a worker's orchestration message and nudges its terminal so an idle session wakes up. |
| `script/fleet-pull.sh` | Fast-forwards clean `main` checkouts across fleet hosts (for hosts in `agent_hosts`, resets configured repositories to `origin/main` and cleans untracked files while keeping ignored files and fast-forwarding `~/agent-state` only) and runs `secrets-sync.sh`. |
| `script/fleet-watch.py` | 5-minute watchdog checking inbox waiters, host caps, stalled workers, backup freshness, PR checks, `heavy-gate` wait times, `wrap-up` freshness and `coordinator_watch` (see [Fleet watch](fleet-watch.md)). |
| `script/fleet-workers.py` | Lists active Orca workers across local and remote fleet environments. |
| `script/worker-startup.sh` | Daily `--host-check` and unified worker launcher (aligns `~/dotfiles`, Orca presets, repo `main`, Node and Bun pins, checks `usage-gate.py`, and starts the worker). |
| `script/start-remote-worker.sh` | Checks `usage-gate.py`, probes the remote CLI in an Orca terminal, refreshes `~/dotfiles` and presets, and calls `worker-start --on`. |
| `script/start-cursor-worker.sh` | Creates the worktree, writes `.workspace-trusted` via Python 3, checks `usage-gate.py`, and starts a Cursor worker. |
| `script/pr-review.sh` | Cold PR review on the self hosted `Review` runner after GitHub Actions `Checks` pass; picks a cross family model via `usage-gate.py`. |
| `script/post-verdict.sh` | Posts the canonical `Verdict:` comment and `review` status. |
| `script/doc-fact-check.sh` | Lists removed markdown lines that do not appear anywhere under `docs/` or `README.md` at head (exit 1 when any). Coordinators and verifier briefs run it on doc rewrites. |
| `script/ship.sh` | Shipping run: verifies required checks and matching `git patch-id` Verdict, squash merges, reads back `MERGED`, and sets the board card to Done on the host that holds the worktree. |
| `script/board-done.py` | Moves finished board cards to Done. Dry run by default. `--fleet` reaches every paired host; an unreachable host is skipped until the next round. |
| `script/board-clean.py` | After 30 minutes in Done, removes the worktree, branches, terminals and session on the dispatch host. Dry run names every card it would clean or keep. A kept card gets a board comment. |
| `script/heavy-gate.sh`, `script/heavy-gate.py`, `script/hw-probe.sh`, `script/remote-heavy.sh` | Per-host heavy job admission, hardware calibration, and remote heavy job execution. |
| `script/usage-gate.py`, `script/usage-gate-hook.py` | Real provider quota check, `--publish` sync to runner hosts, `pick` ranking, and fail-closed `PreToolUse` hook. |
| `script/wrap-up.sh`, `script/worktree-idle.py` | Fleet-wide cleanup of finished worktrees, merged branches, ended terminals/panes and temp files. |

Fleet watch restarts only workers it started (verifiers, rework and scanned issues) and reports every other stalled worker once; the coordinator recovers those with `worker-watch.sh`.

Full tool list across all stages: [Agent team reference](team-reference.md).

## Review rules (issue #760)

1. **No fact lost.** On PRs that rewrite or move docs, run `script/doc-fact-check.sh` against the merge base and explain every flagged line in the Verdict notes.
2. **Verifier differs from PR owner.** The builder puts a `Builder: agent=<agent> model=<model>` line in the PR body. The verifier posts its Verdict through `script/post-verdict.sh` with `--agent` and `--model`, which land on the Verdict line. `script/ship.sh` reads both from those two lines (no Orca lookup) and refuses when the verifier matches the builder on both. When no other provider has quota, review waits instead of reusing the builder model.
3. **Coordinator Verdicts.** `post-verdict.sh` accepts a configured coordinator id (`coordinator_ids` in `script/ship.local.json`) as `verifier=` or `author=`. A worker can still paste `verifier=<coordinator id>` in a PR comment without proving they hold that terminal. Known limit: the gate cannot authenticate a coordinator id in a Verdict, because every comment comes from the same GitHub account.
4. **Verdict carry.** There is no Self-review section to write. `script/ship.sh` carries an older Verdict sha by `git patch-id`, but refuses the carry when a commit it carries over (after that sha, or the whole branch after a rebase) is empty or changes only whitespace, since those leave the patch-id unchanged. Plain-text steps: [self-review-checklist.md](self-review-checklist.md) (Cursor and Antigravity run it as-is).
5. **No coordinator Verdict, no duplicate QA pass.** The coordinator never posts a `Verdict:` or `Review:` line on a PR head, because that makes the cold `Review` skip the head. `script/ship.sh` merges a PR that touches more than markdown and `changelog.d/` on a `Verdict: PASS` from a verifier other than the builder; a cold `Review: PASS` alone does not satisfy it (only `Review: FAIL` blocks). A code or script PR gets one verifier (`qa-sdet`) that runs the change as a user would, parent against head (for a script, it runs the changed script in a temp environment). It never re-reads the diff for style and never re-runs the tests `Checks` already ran. A PR of markdown and `changelog.d/` files only lands on a cold `Review: PASS`. The PR owner runs `ship.sh` on its own PR; the coordinator does not merge by hand (`templates/agent-team/docs/agents/team.md`, Publication).
