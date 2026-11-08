# Orca fleet automations

Dotfiles ships `script/install-fleet-automations.sh` to register recurring jobs as Orca automations. Each job runs only a precheck shell command; the automation prompt is a placeholder and the precheck always exits with status 1 so no agent session starts. `wrap-up-scheduled` installs **enabled** (`*/10 * * * *`) on every host that runs Orca, while `fleet-watch` and the other coordinator jobs install **enabled** only on the host named in private `agent-state/coordinator.conf` and **disabled** (paused) on other Orca hosts. Re-running `--install` fixes a stale `wrap-up-scheduled` schedule (such as `0 */2 * * *`) or a disabled entry. Hosts without the Orca app (such as the headless database host) are skipped with a clear message and exit 0, and wrap-up there stays manual.

Private paths, timezone, and optional `WRAP_UP_ISSUE_REPO` live in `~/.config/fleet-watch/automations.env` (see `script/fleet-watch.automations.env.example`). When `WRAP_UP_ISSUE_REPO` is set in `automations.env`, the installer passes it to `wrap-up-scheduled`. Project roots for drift and audit checks come from the untracked `script/team-audit.local.conf` on the coordinator, one absolute path per line. The installer resolves the dotfiles checkout to a canonical path for Orca `--repo` (symlinked `~/dotfiles` included).

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
| `sync-team-skills-drift` | `0 6 * * *` | Coordinator only | Wrapper runs `script/automation-precheck-sync-drift.sh` | `SYNC_DRIFT_LOG` (default `~/.local/state/agent-team/sync-team-skills-drift.log`) | Same |
| `team-audit-weekly` | `0 7 * * 1` | Coordinator only | Wrapper runs `script/automation-precheck-team-audit-weekly.sh` | `TEAM_AUDIT_WEEKLY_LOG` (report only; the full `/team-audit` skill still runs only when the owner asks) | Same |
| `weekly-update` | `0 8 * * 1` | Coordinator only | Wrapper runs `script/automation-precheck-weekly-update.sh` | `WEEKLY_UPDATE_LOG` | Same |
| `fleet-toolchain` | `0 5 * * *` | Coordinator only | Wrapper runs `script/fleet-pull.sh` then `script/fleet-toolchain-check.sh --apply` | `FLEET_TOOLCHAIN_LOG` (default `~/.local/state/agent-team/fleet-toolchain.log`) | Same |

## Traceable precheck lines

Every registered job runs its shell body through `script/automation-precheck-wrapper.sh`. The wrapper traps `EXIT`, `TERM`, and `INT`, stops the child process group on `TERM`, and appends exactly one **start** and one **end** line to that job's log path on every run (including `exit=143` on `TERM` and `exit=130` on `INT`, or when the inner script skips, the lock is held, or the command fails before the main script starts). Format:

```text
YYYY-MM-DDTHH:MM:SS±ZZZZ host=<short hostname> automation=<name> run=<pid> phase=start exit=- duration=0s summary=starting
YYYY-MM-DDTHH:MM:SS±ZZZZ host=<short hostname> automation=<name> run=<pid> phase=end exit=<inner rc> duration=<seconds>s summary=<one line>
```

`hostname -s` is read at runtime. `summary` is `no change` when nothing set, `failed inner exit N` on failure, the last `wrap-up-scheduled` round line for wrap-up, or `AUTOMATION_TRACE_SUMMARY` when the inner script exports it. Test: `bash script/tests/automation-precheck-wrapper.test.sh`.

Precheck logs default under `~/.orca/logs/` or `~/.local/state/agent-team/` unless overridden in `automations.env`.

## Automation scan (scripts in agent team docs and orca-team)

| Script | Automate | Reason |
|--------|----------|--------|
| `script/fleet-watch.py` | Yes (as `fleet-watch`) | Five minute watchdog; append-only private state and logs; coordinator already enabled elsewhere |
| `script/wrap-up.sh --scheduled` | Yes (as `wrap-up-scheduled`) | Enabled on every Orca host (headless host stays manual); bounded cleanup round inside `WRAP_UP_PRECHECK_TIMEOUT`, logs skipped repos and optional issue body |
| `script/sync-team-skills.sh --check` | Yes (as `sync-team-skills-drift`) | Read-only drift; daily log for architect |
| `script/team-audit.sh`, `bin/team-audit-metrics.ts` | Yes (as `team-audit-weekly`) | Report-only weekly line; metrics optional |
| `script/weekly-update.sh` | Yes (as `weekly-update`) | Monday precheck opens tested upstream PRs and a summary; no merge; owner reviews |
| `script/fleet-pull.sh`, `script/fleet-toolchain-check.sh` | Yes (as `fleet-toolchain`) | Daily coordinator pull and toolchain check and upgrade |
| `script/secrets-sync.sh`, `script/secrets-pack.sh`, `script/secrets-unpack.sh` | No | Secrets mutation or owner transfer |
| `script/elon-startup.sh` | No | Wake-only health report |
| `script/coordinator-drain.sh`, `script/worker-watch.sh` | No | Tied to Elon session and fleet-watch, not a cron |
| `script/worker-startup.sh --host-check` | No | Runs before each worker launch |
| `script/head-checks.sh`, `script/pr-review.sh` | No | PR CI (`Checks`) and GitHub Actions `Review` workflow after `Checks` pass |
| `script/ship.sh`, `script/lead-merge.sh`, `script/coordinator-publication.sh` | No | Shipping run squash merge, legacy merge gate, push, and owner-reserved publication |
| `script/new-coordinator.sh`, `script/take-over-coordinator.sh` | No | Owner provisioning and failover |
| `script/agent-project-autoinit.sh` | No | IDE SessionStart hook |
| `script/bun-pin-check.sh`, `script/count-agents.sh` | No | On-demand checks from startup or fleet-watch |
| `script/weekly-skill-impact.sh`, `script/prepend-recent-change.ts` | No | Draft or changelog helpers on request |
| `script/remote-heavy.sh` | No | Per-job remote runs with admission gates |
| `~/.claude/skills/orca-team/worker-pane-close.sh` | No | Wrap-up and coordinator wake sweep |
| `script/shellcheck-dotfiles.sh` | No | CI and pre push |
| Legacy `templates/launchd/life.example.wrap-up.plist` | No | Superseded on Orca hosts by `wrap-up-scheduled` |
| Host backup pull scripts under `arch/bin/` | No | Production data paths and host-specific config |

Fleet watchdog behavior (alerts, issue_scan, worker_stall) is documented in [Fleet watch](fleet-watch.md). This file covers only Orca automation registration from dotfiles.
