# Orca fleet automations

Dotfiles ships `script/install-fleet-automations.sh` to register recurring jobs as Orca automations. Each scheduled job runs only a precheck shell command, which never exits 0, so no agent session starts. The automation prompt tells an agent to run the same job once, so a manual "Run now" (which skips the precheck) still does the job and replies with its result line. The prompt's command is the precheck command with its ending changed, so it exits 0 for an ok job (wrapper exit 1) and non zero for a failed one; the scheduled precheck still never exits 0. Run `--install` again to update the stored prompts. `wrap-up-daily` (`0 10,22 * * *`) installs **enabled** on every host that runs Orca (wrap-up runs twice a day, owner 2026-11-26; the 10 minute `wrap-up-scheduled` round is gone, owner decision 2026-11-23, #1533), while `fleet-watch`, `board-sweep` and the other coordinator jobs install **enabled** only on the host named in private `agent-state/coordinator.conf` and **disabled** (paused) on other Orca hosts. Re-running `--install` removes a leftover `wrap-up-scheduled` entry and fixes a stale `wrap-up-daily` schedule (such as `0 */2 * * *`) or a disabled entry. `sync-team-skills-drift`, `team-audit-weekly` and `weekly-update` keep whatever enabled state the owner set (a new entry starts disabled), so a reinstall never turns them off or on. Hosts without the Orca app (such as the headless database host) are skipped with a clear message and exit 0, and worktree cleanup there stays manual.

Private paths, timezone, and optional `WRAP_UP_ISSUE_REPO` live in `~/.config/fleet-watch/automations.env` (see `script/fleet-watch.automations.env.example`). The installer passes `WRAP_UP_ISSUE_REPO` to `wrap-up-daily`. It defaults to the private `mingster/agent-state`, and `automations.env` can override it. The `fleet-watch` precheck passes `--config` for `~/.claude/state/fleet-watch-elon.json` unless `FLEET_WATCH_CONFIG` is set. That file holds the hand-kept keys (`repo_roots`, `host_caps`, and the per-host monitor paths). The host-caps file `~/.config/fleet-watch/config.json` is not the scheduled config. wrap-up opens no issue on a public repo. Project roots for drift and audit checks come from the untracked `script/team-audit.local.conf` on the coordinator, one absolute path per line. The installer resolves the dotfiles checkout to a canonical path for Orca `--repo` (symlinked `~/dotfiles` included).

Orca's own listings are slow under load (terminals and worktrees can take minutes), so a scheduled wrap-up round lists terminals once. The first repo's child reuses the listing its terminal close step already made for the worktree check and the idle worktree sweep, and saves it (without the terminals it closed) as `wrap-up-scheduled.terminals` in the state directory; later repos read that file. The first repo reads the whole worktree list once and reuses it in the sweep (it lists again only when the run removed worktrees in between). Each later repo asks only for its own worktrees (`orca worktree list --repo path:<repo>`), falls back to the whole list when that fails, and does not fall back when it timed out. Refs #1314.

The per worktree loop of a scheduled child has its own budget (`WRAP_UP_SCHEDULED_WORKTREE_BUDGET`, default 120 s) so slow per worktree git, gh and process checks cannot spend the repo's 300 s before branch cleanup and the cache step run (#1535, the `exit 124` rounds on blueDevil). A worktree reached after the budget is kept with `worktree step budget spent, next round` and checked again by the next round. The child prints `step worktrees seconds=<n>` when the loop ends.

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

Pause on the coordinator: `orca automations edit <id> --disabled` (or reinstall from a non coordinator host, then enable only what you need by hand). Resume: `orca automations edit <id> --enabled`. A re-install keeps a paused `fleet-watch` paused: the installer creates it enabled on the coordinator, then keeps the owner's choice (#1838).

## Installed automations

| Name | Schedule (cron) | Enabled where | What the precheck does | Who reads the result | Pause |
|------|-----------------|---------------|------------------------|----------------------|-------|
| `fleet-watch` | `*/5 * * * *` | Coordinator only | `script/automation-precheck-wrapper.sh` runs `script/fleet-watch.py` once | `~/.orca/logs/fleet-watch.log` (override `FLEET_WATCH_AUTOMATION_LOG`) | Same |
| `board-sweep` | `20 * * * *` | Coordinator only | Wrapper runs `script/board-sweep.py`: `board-done.py --fleet --apply` (240 s limit, `BOARD_SWEEP_DONE_TIMEOUT`), then `board-clean.py --fleet --apply` (300 s limit, `BOARD_SWEEP_CLEAN_TIMEOUT`). The lifecycle table is in `templates/agent-team/docs/agents/team.md`, Board status | `~/.local/state/agent-team/board-sweep.log` (override `BOARD_SWEEP_LOG`) | Same |
| `wrap-up-daily` | `0 10,22 * * *` | Every Orca host | Wrapper runs `script/wrap-up.sh --daily`: the prune per repo (#1853), build caches, old logs, `brew cleanup -s`, `bun pm cache rm`, free space before and after (see "Daily disk cleanup") | `~/.orca/logs/wrap-up-daily.log` (override `WRAP_UP_DAILY_LOG`); detail in `wrap-up-daily-detail.log` | Same |
| `sync-team-skills-drift` | `0 6 * * *` | Coordinator only | Wrapper runs `script/automation-precheck-sync-drift.sh`, which runs `script/agent-team.sh check <project>` for each project root | `SYNC_DRIFT_LOG` (default `~/.local/state/agent-team/sync-team-skills-drift.log`) | Same |
| `team-audit-weekly` | `0 7 * * 1` | Coordinator only | Wrapper runs `script/automation-precheck-team-audit-weekly.sh`: `script/team-audit.sh` (which calls `agent-team.sh check` per project) with `TEAM_AUDIT_RUN_METRICS=1`, so `script/team-audit-metrics.ts --repo <owner/name>` runs for each project's origin repo | `TEAM_AUDIT_WEEKLY_LOG` (report only; the full `/team-audit` skill still runs only when the user asks) | Same |
| `weekly-update` | `0 8 * * 1` | Coordinator only | Wrapper runs `script/automation-precheck-weekly-update.sh` | `WEEKLY_UPDATE_LOG` | Same |
| `fleet-toolchain` | `0 5 * * *` | Coordinator only | Wrapper runs `script/fleet-pull.sh` (which also runs `agent-team.sh machine` on each host to render role files and `session-start.md`) then `script/fleet-toolchain-check.sh --apply` (which also runs `orca skills install --all` on each host) | `FLEET_TOOLCHAIN_LOG` (default `~/.local/state/agent-team/fleet-toolchain.log`) | Same |
| `daily-program-1900` | `0 19 * * *` (`Asia/Taipei`) | Coordinator only | Wrapper runs `script/automation-precheck-staging-daily.sh`, which always wakes the coordinator to run the standing program from `templates/agent-team/docs/agents/daily-run.md`. Only the staging deploy step is skipped when staging equals `origin/main`; otherwise the wake asks for `release-manager` staging deploy and the pstack `swarm` live lanes. Production runs after the Playground regression while production holds only test data, and on user approval once a real store is live. Re-install removes the entry under its pre #834 name | `STAGING_DAILY_LOG` (default `~/.local/state/agent-team/staging-daily.log`) | Same |

## Scheduled worktree cleanup round (not installed)

The installer no longer registers this 10 minute round. `wrap-up.sh --scheduled` still works for a manual run, and its description below is kept for that. On the coordinator, the daily job now also runs the board steps (`board-done.py --fleet`, then `board-clean.py --fleet`) after the repo cleanup, so cards move to Done and old Done cards go. The hourly `board-sweep` job runs the same two steps.

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

`script/wrap-up.sh --daily [--dry-run|--apply]` is one round of the same machinery, twice a day at 10:00 and 22:00 on every Orca host (issue #1533; owner 2026-11-26). It takes its own lock, log, detail log and failure streak (`wrap-up-daily.*`), so it never blocks or counts against the 10 minute round. A dry run prints everything it would delete and removes nothing: run `~/dotfiles/script/wrap-up.sh --daily --dry-run` on any host. The default with no flag is `--apply`, like `--scheduled`.

What a round does, in order:

1. Logs the free space of the home volume before.
2. For each Orca git repo, runs `wrap-up.sh --apply`, as the prune in each `prune-repo` listed repo (issue #1853, see "Daily prune" below): every worktree, local branch and (on the coordinator host only) origin branch goes unless it is `main`, `production`, `staging` or active work.
   Each repo run also cleans an automation "Run now" leftover (#1946), whatever its board status: an `auto-*-run-*` worktree on its `auto-*-run-*` branch that is clean, has no commit beyond `origin/main`, and whose terminals have exited or been silent for 30 minutes (with no terminal at all, the checkout must be 30 minutes old). Its terminals are stopped, the worktree and branch removed, and one `Cleaned automation run` line logged.
3. Deletes `.next` and `node_modules/.cache` (top level and one level down) in every worktree it kept, unless a process uses it.
4. Deletes logs: files older than 7 days (`WRAP_UP_DAILY_LOG_DAYS`) among `~/Library/Logs` (`*.log`, `*.log.*`, `*.ips`), rotated `~/.orca/logs/*.log.N`, and untracked `*.log` under agent-state; and any `*.log` over 100 MB (`WRAP_UP_DAILY_BIG_LOG_KB`) under `~/orca/workspaces` that nothing wrote in the last 3 hours. A live Orca log, a tracked file and a symlink are never touched.
5. Runs `brew cleanup -s` and `bun pm cache rm` when the tool is installed (each at most 120 s).
6. Logs the free space after. The round line reads `round ok: repos=2 seconds=40 logs=3 (1.2G) freed 10.0G (disk free 152.0G -> 162.0G)`. A disk that did not get emptier reads `freed 0.0G`.

A worktree whose PR was squash merged used to stay for ever: its head is on no remote branch and not an ancestor of main, so the last copy guard kept it. A merged PR that ended at exactly the worktree's head (and has no open PR on that branch) now counts as published. This applies to the 10 minute round too. Commits made after the merge still keep the worktree, and so does a closed PR that was never merged.

### Daily prune

The owner's rule (#1853): keep only `main`, `production`, `staging` and active work; everything else goes, on every host, in the repos the private `agent-state/coordinator.conf` lists as `prune-repo <path>` (absolute, or under `$HOME`), one line each. A repo with no such line (or no `coordinator.conf`) gets the strict cleanup only, and the detail log says `prune off in <repo>`. The listed repos stay out of this public repo. The daily child of a listed repo gets `WRAP_UP_DAILY_PRUNE` (`remote` on the coordinator host named in `coordinator.conf`, `local` elsewhere).

Kept, with the reason printed on a `Kept` line:

- Named: `main`, `production`, `staging`, any `<component>/staging` and `<component>/production` (per component deploy branches, local and origin), plus the default branch, GitHub protected branches and the Pages branch (GitHub refuses those deletes).
- Active work: the head of an open PR (by name or head commit), a worktree with a live or unknown Orca worker or terminal, the main checkout, and a worktree with uncommitted changes (never deleted, always listed).
- Too new: a branch (local or origin) whose tip commit is younger than 1 day (`WRAP_UP_PRUNE_MIN_AGE`, seconds, default 86400). Worktrees keep their own 3 hour rule.
- Not yet safe, retried the next day: a locked worktree, a `_` script owned worktree, one a process holds open, or one changed in the last 3 hours.
- Origin only: a branch checked out in an Orca worktree on this host or any paired host.

Each round makes durable progress. Branches go oldest first, each delete is logged first, and the local branch step stops at its time limit (`WRAP_UP_PRUNE_STEP` seconds, default what is left of the repo's budget less 60 s). The rest waits for the next round, and that is not a failure. A host with hundreds of old branches therefore clears them over a few rounds instead of being killed with nothing done. The host name in the restore log and the coordinator match fall back to `uname -n` when the `hostname` command is missing.

Dropped for the prune: the merged proof, the last copy and unpushed commit guards, `archive/*`, `master`, `lead-*`, Orca pins and open board cards.

Fail closed: a failed fetch, open PR list (also one that reaches its 1000 row limit), Orca worker or terminal inventory, branch protection lookup, or an unwritable restore log stops every delete in that repo for the day. An unreadable worktree list on any paired host stops origin deletes only, and so does a host the local list omits that is not one of this host's environments. The hosts a paired host omits are its own peers and are ignored, since this host reads each of its environments directly. Each stop is a failure in the round log.

Before each delete the restore log `~/agent-state/branch-prune/<date>.tsv` gets a line (time, host, repo, scope `worktree`, `local` or `remote`, name or path, commit), synced to disk. Restore a branch with `git branch <name> <sha>` (origin: `git push origin <sha>:refs/heads/<name>`). This works only while the commit is still in that host's git store: a local only commit lasts until `git gc` prunes it, about 2 weeks. A delete that fails is listed in the summary, the run goes on, and the round ends non-zero.

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

A run that shows "dispatching" in Orca is a precheck still running, not a stuck run. On the coordinator the wrap-up round gives `board-done` and `board-clean` each at most `WRAP_UP_SCHEDULED_BOARD_TIMEOUT` (120 s), never more than what is left of `WRAP_UP_PRECHECK_TIMEOUT` less the kill grace, and skips a step with `skip: <step> (round budget spent)` when under 10 s are left. The coordinator's repos and cleaners get the round limit less `WRAP_UP_SCHEDULED_BOARD_RESERVE` (90 s), so a slow repo cannot leave `board-clean` the last few seconds (#1726). `board-clean` is given `BOARD_CLEAN_BUDGET_S`, 5 s under its step limit, so it normally stops itself with its budget line and exits 0; both steps run unbuffered, so their output reaches the detail log (#1922). A board step that is still killed is logged as `<step> exit 124` and named in the round line (`board-clean timed out`); it does not fail the round, and the next round retries it. A failed `wrap-up --daily` round ends non zero, so the wrapper's `phase=end exit=` is no longer 0 for it.

Precheck logs default under `~/.orca/logs/` or `~/.local/state/agent-team/` unless overridden in `automations.env`. The wrapper and the four prechecks (`automation-precheck-sync-drift.sh`, `-team-audit-weekly.sh`, `-weekly-update.sh`, `-staging-daily.sh`) print one usage line for `-h` or `--help` and exit 0 without running the job or writing its log. Any other argument exits 2 and runs nothing. No arguments is the scheduled run. Test: `bash script/tests/automation-precheck-args.test.sh`.

## Automation scan (scripts in agent team docs and orca-team)

| Script | Automate | Reason |
|--------|----------|--------|
| `script/fleet-watch.py` | Yes (as `fleet-watch`) | Five minute watchdog and its one scheduler (#1838); append-only private state and logs; a pass ends new work at 250 s, inside the 280 s timeout |
| `script/wrap-up.sh --scheduled` | No (dropped 2026-11-23, #1533) | Manual runs only; the installer removes a leftover `wrap-up-scheduled` entry |
| `script/board-sweep.py` | Yes (as `board-sweep`) | Enabled on the coordinator; hourly catch-all for board cards (#1937) |
| `script/wrap-up.sh --daily` | Yes (as `wrap-up-daily`) | Enabled on every Orca host; twice a day it frees disk the 10 minute round leaves alone (#1533) |
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
| Legacy `templates/launchd/life.example.wrap-up.plist` | No | Superseded on Orca hosts by `wrap-up-daily` |
| Host backup pull scripts under `arch/bin/` | No | Production data paths and host-specific config |

Fleet watchdog behavior (alerts, issue_scan, worker_stall) is documented in [Fleet watch](fleet-watch.md). This file covers only Orca automation registration from dotfiles.

## Why the daily round ran out of time on niteking (#1533, #1535)

The repo run for one project took 569 s and exited 124. The cause was `lsof -t +D <worktree>`, the check that no process uses a worktree. It walks the whole tree, `node_modules` included, and took 9 to 13 s per worktree (measured on niteking with 28 project worktrees). It runs for each worktree in the sweep, before each delete, and for each build cache, so it used the whole 540 s round. The daily round now sets `WRAP_UP_LSOF_SNAPSHOT=1`, which makes the check read one `lsof -nP -Fn` listing of every open file (about 1 s) and match it by path prefix. Other modes keep `+D`. Fleet-watch's `wrap_up.hosts` log check (`docs/agents/fleet-watch.md`) must point at `wrap-up-daily.log` with `stale_limit_seconds` of 93600, or it opens a stale issue after 20 minutes.

A package cache cleaner (`brew cleanup -s`, `bun pm cache rm`) that only runs out of its time (exit 124) does not fail the daily round or add to its failure streak. The round line names it (`bun pm cache rm timed out`), the cache stays, and the next day's run retries it. Any other nonzero exit still fails the round (niteking, 2026-11-23, #1533).
