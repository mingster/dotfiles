# Orca fleet automations

Dotfiles ships `script/install-fleet-automations.sh` to register recurring jobs as Orca automations. Each job runs only a precheck shell command; the automation prompt is a placeholder and the precheck always exits with status 1 so no agent session starts. On the host named in private `agent-state/coordinator.conf`, automations install **enabled**; on every other fleet host they install **disabled** (paused) so the same script is idempotent everywhere. Headless hosts without Orca in a login shell are not a failure for this installer.

Private paths and timezone live in `~/.config/fleet-watch/automations.env` (see `script/fleet-watch.automations.env.example`). Project roots for drift and audit checks come from the untracked `script/team-audit.local.conf` on the coordinator, one absolute path per line. The installer resolves the dotfiles checkout to a canonical path for Orca `--repo` (symlinked `~/dotfiles` included).

## Commands

```bash
~/dotfiles/script/install-fleet-automations.sh --status
~/dotfiles/script/install-fleet-automations.sh --install
~/dotfiles/script/install-fleet-automations.sh --uninstall
```

Dry run: `~/dotfiles/script/install-fleet-automations.sh --dry-run --install`.

Pause on the coordinator: `orca automations edit <id> --disabled` (or reinstall from a non coordinator host, then enable only what you need by hand). Resume: `orca automations edit <id> --enabled`.

## Installed automations

| Name | Schedule (cron) | What the precheck does | Who reads the result | Pause |
|------|-----------------|------------------------|----------------------|-------|
| `fleet-watch` | `*/5 * * * *` | Runs `script/fleet-watch.py` once with private config and state; appends to `FLEET_WATCH_PRECHECK_LOG` | Elon and backup operators via `~/.orca/logs/fleet-watch.log` and orchestration digests configured in private fleet watch json | `install-fleet-automations.sh --uninstall` or `orca automations edit` on non coordinators leave it disabled |
| `wrap-up-scheduled` | `0 */2 * * *` | Runs `script/wrap-up.sh --scheduled` one locked round on this host | Operators via `~/.orca/logs/wrap-up-scheduled.log` and optional GitHub issue from `WRAP_UP_ISSUE_REPO` | Same as other rows |
| `sync-team-skills-drift` | `0 6 * * *` | `script/sync-team-skills.sh --check` for each root in `team-audit.local.conf`; appends to `SYNC_DRIFT_LOG` | Architect and Elon before skill edits; drift lines in the log | Same |
| `team-audit-weekly` | `0 7 * * 1` | `script/team-audit.sh` plus `bin/team-audit-metrics.ts` when bun and the script exist; appends to `TEAM_AUDIT_WEEKLY_LOG` | Architect on the weekly line; full `/team-audit` skill still runs only when the owner asks | Same |
| `weekly-update` | `0 8 * * 1` | `script/weekly-update.sh` via `automation-precheck-weekly-update.sh`; appends to `WEEKLY_UPDATE_LOG` | Owner reviews open upstream refresh PRs; script never merges or deploys | Same |

Precheck logs default under `~/.local/state/agent-team/` unless overridden in `automations.env`.

## Automation scan (scripts in agent team docs and orca-team)

| Script | Automate | Reason |
|--------|----------|--------|
| `script/fleet-watch.py` | Yes (as `fleet-watch`) | Five minute watchdog; append-only private state and logs; coordinator already enabled elsewhere |
| `script/wrap-up.sh --scheduled` | Yes (as `wrap-up-scheduled`) | Bounded cleanup round; no merge; writes logs and optional issue body |
| `script/sync-team-skills.sh --check` | Yes (as `sync-team-skills-drift`) | Read-only drift; daily log for architect |
| `script/team-audit.sh`, `bin/team-audit-metrics.ts` | Yes (as `team-audit-weekly`) | Report-only weekly line; metrics optional |
| `script/weekly-update.sh` | Yes (as `weekly-update`) | Monday precheck opens tested upstream PRs and a summary; no merge; owner reviews |
| `script/fleet-pull.sh` | No | Coordinator wake; fast-forwards checkouts |
| `script/secrets-sync.sh`, `script/secrets-pack.sh`, `script/secrets-unpack.sh` | No | Secrets mutation or owner transfer |
| `script/elon-startup.sh`, `script/fleet-toolchain-check.sh` | No | Wake-only health reports |
| `script/coordinator-drain.sh`, `script/worker-watch.sh` | No | Tied to Elon session and fleet-watch, not a cron |
| `script/worker-startup.sh --host-check` | No | Runs before each worker launch |
| `script/head-checks.sh`, `script/pr-review.sh` | No | PR CI (`Checks`) and GitHub Actions `Review` workflow after `Checks` pass |
| `script/ship.sh`, `script/lead-merge.sh`, `script/coordinator-publication.sh` | No | Shipping run squash merge, legacy merge gate, push, and owner-reserved publication |
| `script/new-coordinator.sh`, `script/take-over-coordinator.sh` | No | Owner provisioning and failover |
| `script/agent-project-autoinit.sh` | No | IDE SessionStart hook |
| `script/bun-pin-check.sh`, `script/count-agents.sh` | No | On-demand checks from startup or fleet-watch |
| `script/weekly-skill-impact.sh`, `script/prepend-recent-change.ts` | No | Draft or changelog helpers on request |
| `script/remote-heavy.sh`, `script/remote-shot.sh` | No | Per-job remote runs with admission gates |
| `~/.claude/skills/orca-team/worker-pane-close.sh` | No | Wrap-up and coordinator wake sweep |
| `script/shellcheck-dotfiles.sh` | No | CI and pre push |
| Legacy `templates/launchd/life.example.wrap-up.plist` | No | Superseded on Orca hosts by `wrap-up-scheduled` |
| Host backup pull scripts under `arch/bin/` | No | Production data paths and host-specific config |

Fleet watchdog behavior (alerts, issue_scan, worker_stall) is documented in [Fleet watch](fleet-watch.md). This file covers only Orca automation registration from dotfiles.
