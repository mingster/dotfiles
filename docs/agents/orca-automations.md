# Orca fleet automations

Dotfiles ships `script/install-fleet-automations.sh` to register recurring jobs as Orca automations. Each scheduled job runs only a precheck shell command, which never exits 0, so no agent session starts. The automation prompt tells an agent to run that same command once, so a manual "Run now" (which skips the precheck) still does the job and replies with its result line. `wrap-up-scheduled` (`*/10 * * * *`) and `wrap-up-daily` (`0 4 * * *`) install **enabled** on every host that runs Orca, while `fleet-watch` and the other coordinator jobs install **enabled** only on the host named in private `agent-state/coordinator.conf` and **disabled** (paused) on other Orca hosts. Re-running `--install` fixes a stale `wrap-up-scheduled` or `wrap-up-daily` schedule (such as `0 */2 * * *`) or a disabled entry. `sync-team-skills-drift`, `team-audit-weekly` and `weekly-update` keep whatever enabled state the owner set (a new entry starts disabled), so a reinstall never turns them off or on. Hosts without the Orca app (such as the headless database host) are skipped with a clear message and exit 0, and worktree cleanup there stays manual.

Private paths, timezone, and optional `WRAP_UP_ISSUE_REPO` live in `~/.config/fleet-watch/automations.env` (see `script/fleet-watch.automations.env.example`). The installer passes `WRAP_UP_ISSUE_REPO` to `wrap-up-scheduled`. It defaults to the private `mingster/agent-state`, and `automations.env` can override it. The `fleet-watch` precheck passes `--config` for `~/.claude/state/fleet-watch-elon.json` unless `FLEET_WATCH_CONFIG` is set. That file holds the hand-kept keys (`repo_roots`, `host_caps`, and the per-host monitor paths). The host-caps file `~/.config/fleet-watch/config.json` is not the scheduled config. wrap-up opens no issue on a public repo. Project roots for drift and audit checks come from the untracked `script/team-audit.local.conf` on the coordinator, one absolute path per line. The installer resolves the dotfiles checkout to a canonical path for Orca `--repo` (symlinked `~/dotfiles` included).

Orca's own listings are slow under load (terminals and worktrees can take minutes), so a scheduled wrap-up round lists terminals once. The first repo's child reuses the listing its terminal close step already made for the worktree check and the idle worktree sweep, and saves it (without the terminals it closed) as `wrap-up-scheduled.terminals` in the state directory; later repos read that file. The first repo reads the whole worktree list once and reuses it in the sweep (it lists again only when the run removed worktrees in between). Each later repo asks only for its own worktrees (`orca worktree list --repo path:<repo>`), falls back to the whole list when that fails, and does not fall back when it timed out. Refs #1314.

## Why Orca shows every run as an error

Orca has no script only automation. An automation is an agent prompt, and its precheck is the only place to run a shell command without an agent. Orca (1.4.x) starts the agent only on precheck exit 0, and records any other exit as `skipped_precheck` with the error text `Precheck exited with code N.` There is no exit code Orca treats as a normal skip. So an ok round and a failed round both look like errors in the run history, and a change to the exit codes cannot fix that.

What to read instead: the precheck stdout on the run record starts with `ok <name>` (wrapper exit 1) or `FAILED <name>` (wrapper exit 2), and the log named on that line has the round. A real failure is exit 2. Exit 1 only means the job ran fine.

A scheduled wrap-up round asks Orca once about a never settled dispatch that Orca cannot show (`dispatch_not_found`). The first `--apply` logs the warning and records the id in `wrap-up-gone-dispatches` in the state directory, and later runs skip it. A dry run reads that file but never creates or changes it.

## Commands

```bash
~/dotfiles/script/install-fleet-automations.sh --status
~/dotfiles/script/install-fleet-automations.sh --install
~/dotfiles/script/install-fleet-automations.sh --uninstall
```

Dry run: `~/dotfiles/script/install-fleet-automations.sh --dry-run --install`.

Pause on the coordinator: `orca automations edit <id> --disabled` (or reinstall from a non coordinator host, then enable only what you need by hand). Resume: `orca automations edit <id> --enabled`.

## Installed automations

| Name | Schedule (cron) | Enabled where | What the precheck does | Who reads the result | Pause |
|------|-----------------|---------------|------------------------|----------------------|-------|
| `fleet-watch` | `*/5 * * * *` | Coordinator only | `script/automation-precheck-wrapper.sh` runs `script/fleet-watch.py` once | `~/.orca/logs/fleet-watch.log` (override `FLEET_WATCH_AUTOMATION_LOG`) | Same |
| `wrap-up-scheduled` | `*/10 * * * *` | Every Orca host | Wrapper runs `script/wrap-up.sh --scheduled` (per repo and round budget inside `WRAP_UP_PRECHECK_TIMEOUT`, round lock, `WRAP_UP_ISSUE_REPO` when set) | `~/.orca/logs/wrap-up-scheduled.log`; detail in `wrap-up-scheduled-detail.log` | Same |
| `wrap-up-daily` | `0 4 * * *` | Every Orca host | Wrapper runs `script/wrap-up.sh --daily`: the strict worktree cleanup per repo, build caches, old logs, `brew cleanup -s`, `bun pm cache rm`, free space before and after (see "Daily disk cleanup") | `~/.orca/logs/wrap-up-daily.log` (override `WRAP_UP_DAILY_LOG`); detail in `wrap-up-daily-detail.log` | Same |
| `sync-team-skills-drift` | `0 6 * * *` | Coordinator only | Wrapper runs `script/automation-precheck-sync-drift.sh`, which runs `script/agent-team.sh check <project>` for each project root | `SYNC_DRIFT_LOG` (default `~/.local/state/agent-team/sync-team-skills-drift.log`) | Same |
| `team-audit-weekly` | `0 7 * * 1` | Coordinator only | Wrapper runs `script/automation-precheck-team-audit-weekly.sh`: `script/team-audit.sh` (which calls `agent-team.sh check` per project) with `TEAM_AUDIT_RUN_METRICS=1`, so `script/team-audit-metrics.ts --repo <owner/name>` runs for each project's origin repo | `TEAM_AUDIT_WEEKLY_LOG` (report only; the full `/team-audit` skill still runs only when the user asks) | Same |
| `weekly-update` | `0 8 * * 1` | Coordinator only | Wrapper runs `script/automation-precheck-weekly-update.sh` | `WEEKLY_UPDATE_LOG` | Same |
| `fleet-toolchain` | `0 5 * * *` | Coordinator only | Wrapper runs `script/fleet-pull.sh` (which also runs `agent-team.sh machine` on each host to render role files and `session-start.md`) then `script/fleet-toolchain-check.sh --apply` (which also runs `orca skills install --all` on each host) | `FLEET_TOOLCHAIN_LOG` (default `~/.local/state/agent-team/fleet-toolchain.log`) | Same |
| `daily-program-1900` | `0 19 * * *` (`Asia/Taipei`) | Coordinator only | Wrapper runs `script/automation-precheck-staging-daily.sh`, which always wakes the coordinator to run the standing program from `templates/agent-team/docs/agents/daily-run.md`. Only the staging deploy step is skipped when staging equals `origin/main`; otherwise the wake asks for `release-manager` staging deploy and the pstack `swarm` live lanes. Production runs after the Playground regression while production holds only test data, and on user approval once a real store is live. Re-install removes the entry under its pre #834 name | `STAGING_DAILY_LOG` (default `~/.local/state/agent-team/staging-daily.log`) | Same |

## Scheduled worktree cleanup round

`script/wrap-up.sh --scheduled` runs one worktree cleanup round on this host. On the coordinator host it then runs `script/board-done.py --fleet`, which moves finished cards to Done on every paired Orca and skips a host it cannot reach, and `script/board-clean.py --fleet`, which removes a card that has been Done for 30 minutes on the host named by its dispatch record. A round takes a lock (one per host,
under `~/.local/state/agent-team/`), finds the orca CLI, checks that `orca status --json` reports ready,
skips when the 1 minute load divided by the cores is 0.7 or more, then runs `wrap-up.sh --apply` for each
git repo in `orca repo list`. There is no config file. A manual worktree cleanup run does not take the lock;
worktree cleanup's own guards recheck before each delete.

The schedule shell is bare, so the round looks for orca itself: the Orca app first, then `PATH`,
`~/.local/bin`, Homebrew, and `~/.orca/cli/bin` last, because that copy can be a stale remote CLI.

Each round writes one line to `~/.orca/logs/wrap-up-scheduled.log`: `round ok`, `skip:` or `round failed:`.
Per repo output goes to `wrap-up-scheduled-detail.log` beside it. No CLI, an unreadable repo list or load,
a repo that fails, and a round over 4 minutes all count as failed. Repos not reached in time are not started.
Each log keeps one rotated copy (`.1`) once it passes 5 MB.

Two failed rounds in a row open one GitHub issue on the repo in `WRAP_UP_ISSUE_REPO`, titled
`wrap-up: scheduled rounds failing on <host>`, with home paths masked. While an issue with that title
is open, no second one is opened. With the variable unset, or a repo that is not private, the round
logs that and opens nothing, so host names stay out of public repos. A repo run hung past its budget
plus 30 seconds is stopped with its inner calls and counts as failed. A scheduled round closes a local
shell that no dispatch owns once it has had no output for 60 minutes. A shell with newer output stays
open, and so do the coordinator, a lead worktree, and any shell in a live dispatch's worktree. A
manual run keeps those shells too. Fetch, PR lookup, worker release, remote
branch checks, temp cleanup, the pane sweep, and the main update each have their own short time limit,
and terminal close runs before those steps.

## Daily disk cleanup

`script/wrap-up.sh --daily [--dry-run|--apply]` is one round of the same machinery, once a day at 04:00 on every Orca host (issue #1533). It takes its own lock, log, detail log and failure streak (`wrap-up-daily.*`), so it never blocks or counts against the 10 minute round. A dry run prints everything it would delete and removes nothing: run `~/dotfiles/script/wrap-up.sh --daily --dry-run` on any host. The default with no flag is `--apply`, like `--scheduled`.

What a round does, in order:

1. Logs the free space of the home volume before.
2. For each Orca git repo, runs `wrap-up.sh --apply` in a stricter mode. It reuses the existing guards, so a worktree stays when it has uncommitted work (other than screenshot dirt), commits no remote holds, an open PR, a live or unknown Orca terminal, a running process, a pin, an open board card, or any change in the last 3 hours (`WRAP_UP_DAILY_RECENT_MIN`, default 180; the 10 minute round uses 30 and archives a dirty worktree instead of keeping it). It removes finished worktrees (a merged branch, a PR merged at the worktree head, or a closed PR whose commits a remote still holds) and deletes merged or closed local branches.
3. Deletes `.next` and `node_modules/.cache` (top level and one level down) in every worktree it kept, unless a process uses it.
4. Deletes logs: files older than 7 days (`WRAP_UP_DAILY_LOG_DAYS`) among `~/Library/Logs` (`*.log`, `*.log.*`, `*.ips`), rotated `~/.orca/logs/*.log.N`, and untracked `*.log` under agent-state; and any `*.log` over 100 MB (`WRAP_UP_DAILY_BIG_LOG_KB`) under `~/orca/workspaces` that nothing wrote in the last 3 hours. A live Orca log, a tracked file and a symlink are never touched.
5. Runs `brew cleanup -s` and `bun pm cache rm` when the tool is installed (each at most 120 s).
6. Logs the free space after. The round line reads `round ok: repos=2 seconds=40 logs=3 (1.2G) free 152.0G->162.0G`.

A worktree whose PR was squash merged used to stay for ever: its head is on no remote branch and not an ancestor of main, so the last copy guard kept it. A merged PR that ended at exactly the worktree's head (and has no open PR on that branch) now counts as published. This applies to the 10 minute round too. Commits made after the merge still keep the worktree, and so does a closed PR that was never merged.

Install on a host:

1. Copy `templates/launchd/life.example.wrap-up.plist` to
   `~/Library/LaunchAgents/life.example.wrap-up.plist` and replace `__HOME__` with an absolute home path and `__ISSUE_REPO__` with a private `owner/repo`.
   Do not add `ORCA_CLI_COMMAND`: the round clears it, because worktree cleanup refuses `--apply` when it is set.
2. Load it: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/life.example.wrap-up.plist`.

Unload it: `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/life.example.wrap-up.plist`.

Proof: `launchctl print gui/$(id -u)/life.example.wrap-up` shows the job with `run interval = 600 seconds`.
To see a round without waiting, run `launchctl kickstart gui/$(id -u)/life.example.wrap-up`, then read
`~/.orca/logs/wrap-up-scheduled.log` for a `round ok` line.

## Traceable precheck lines

Every registered job runs its shell body through `script/automation-precheck-wrapper.sh`. The wrapper traps `EXIT`, `TERM`, and `INT`, stops the child process group on `TERM`, and appends exactly one **start** and one **end** line to that job's log path on every run (including `exit=143` on `TERM` and `exit=130` on `INT`, or when the inner script skips, the lock is held, or the command fails before the main script starts). Format:

```text
YYYY-MM-DDTHH:MM:SS±ZZZZ host=<short hostname> automation=<name> run=<pid> phase=start exit=- duration=0s summary=starting
YYYY-MM-DDTHH:MM:SS±ZZZZ host=<short hostname> automation=<name> run=<pid> phase=end exit=<inner rc> duration=<seconds>s summary=<one line>
```

`hostname -s` is read at runtime. `summary` is `no change` when nothing set, `failed inner exit N` on failure, this run's `wrap-up-scheduled` round line for worktree cleanup (never an older round's), or `AUTOMATION_TRACE_SUMMARY` when the inner script exports it. Test: `bash script/tests/automation-precheck-wrapper.test.sh`.

## Result in the Orca Automations view

Orca keeps the precheck's exit code and output on each run record, so `orca automations runs --id <id> --json` (and the Automations view) shows the result. The wrapper prints one line on stdout:

```text
ok <name>: <summary> (exit=<inner rc>, <seconds>s, log=<path>)
FAILED <name>: <summary> (exit=<inner rc>, <seconds>s, log=<path>)
```

A good run exits 1 ("Precheck exited with code 1"). A failed run exits 2 ("code 2") and puts the last 20 lines of that run's log section on stderr. The summary counts as failed when the inner command exits non zero or the summary starts with `round failed`, `failed`, `drift or check failure`, `team-audit findings`, `metrics failed` or `weekly-update failed`. 143 and 130 mean the wrapper was stopped (Orca's precheck timeout sends `TERM`).

A run that shows "dispatching" in Orca is a precheck still running, not a stuck run. On the coordinator the wrap-up round gives `board-done` and `board-clean` each at most `WRAP_UP_SCHEDULED_BOARD_TIMEOUT` (120 s), never more than what is left of `WRAP_UP_PRECHECK_TIMEOUT` less the kill grace, and skips a step with `skip: <step> (round budget spent)` when under 10 s are left.

Precheck logs default under `~/.orca/logs/` or `~/.local/state/agent-team/` unless overridden in `automations.env`.

## Automation scan (scripts in agent team docs and orca-team)

| Script | Automate | Reason |
|--------|----------|--------|
| `script/fleet-watch.py` | Yes (as `fleet-watch`) | Five minute watchdog; append-only private state and logs; coordinator already enabled elsewhere |
| `script/wrap-up.sh --scheduled` | Yes (as `wrap-up-scheduled`) | Enabled on every Orca host (headless host stays manual); bounded cleanup round inside `WRAP_UP_PRECHECK_TIMEOUT`, logs skipped repos and optional issue body |
| `script/wrap-up.sh --daily` | Yes (as `wrap-up-daily`) | Enabled on every Orca host; once a day it frees disk the 10 minute round leaves alone (#1533) |
| `script/agent-team.sh check` | Yes (as `sync-team-skills-drift`) | Read-only drift; daily log for architect |
| `script/team-audit.sh`, `script/team-audit-metrics.ts` | Yes (as `team-audit-weekly`) | Report-only weekly line; metrics skipped when `bun` is missing |
| `script/weekly-update.sh` | Yes (as `weekly-update`) | Monday precheck opens tested upstream PRs and a summary; they merge on green checks and a Verdict |
| `script/fleet-pull.sh`, `script/fleet-toolchain-check.sh` | Yes (as `fleet-toolchain`) | Daily coordinator pull, toolchain check and upgrade, and Orca bundled skills refresh |
| `script/automation-precheck-staging-daily.sh` | Yes (as `daily-program-1900`) | Daily `0 19 * * *` (`Asia/Taipei`) coordinator wake for the standing program; asks for the staging deploy and the pstack `swarm` live lanes only when `origin/main` is ahead of staging |
| `script/secrets-sync.sh`, `script/secrets-pack.sh`, `script/secrets-unpack.sh` | No | Secrets mutation or user transfer |
| `script/secrets-gate-setup.sh` | No | Owner only, runs sudo and makes the credential folder root owned |
| `script/elon-startup.sh` | No | Wake-only health report |
| `script/coordinator-drain.sh`, `.agents/skills/orca-team/worker-watch.sh` | No | Tied to the coordinator session and fleet-watch, not a cron |
| `script/worker-startup.sh --host-check` | No | Runs before each worker launch |
| `script/head-checks.sh`, `script/pr-review.sh` | No | PR CI (`Checks`) and GitHub Actions `Review` workflow after `Checks` pass |
| `script/ship.sh`, `script/coordinator-publication.sh` | No | Shipping run squash merge; push and PR opening by the PR owner |
| `script/new-coordinator.sh`, `script/take-over-coordinator.sh` | No | User provisioning and failover |
| `script/bun-pin-check.sh`, `script/count-agents.sh` | No | On-demand checks from startup or fleet-watch |
| `script/weekly-skill-impact.sh`, `script/prepend-recent-change.ts` | No | Draft or changelog helpers on request |
| `script/remote-heavy.sh` | No | Per-job remote runs with admission gates |
| `~/.claude/skills/orca-team/worker-pane-close.sh` | No | Worktree cleanup and coordinator wake sweep |
| `script/shellcheck-dotfiles.sh` | No | CI and pre push |
| Legacy `templates/launchd/life.example.wrap-up.plist` | No | Superseded on Orca hosts by `wrap-up-scheduled` |
| Host backup pull scripts under `arch/bin/` | No | Production data paths and host-specific config |

Fleet watchdog behavior (alerts, issue_scan, worker_stall) is documented in [Fleet watch](fleet-watch.md). This file covers only Orca automation registration from dotfiles.
