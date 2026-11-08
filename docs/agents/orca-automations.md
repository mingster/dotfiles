# Orca fleet automations

Dotfiles ships `script/install-fleet-automations.sh` to register recurring jobs as Orca automations. Each job runs only a precheck shell command; the automation prompt is a placeholder and the precheck always exits with status 1 so no agent session starts. On the host named in private `agent-state/coordinator.conf`, automations install **enabled**; on every other fleet host they install **disabled** (paused) so the same script is idempotent everywhere.

Private paths and timezone live in `~/.config/fleet-watch/automations.env` (see `script/fleet-watch.automations.env.example`). Project roots for drift and audit checks come from the untracked `script/team-audit.local.conf` on the coordinator, one absolute path per line.

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

Precheck logs default under `~/.local/state/agent-team/` unless overridden in `automations.env`.

## Not registered here

These stay manual, wake driven, or project CI:

| Job | Verdict | Reason |
|-----|---------|--------|
| `script/weekly-update.sh` | Skip | Opens branches, commits, pushes upstream refresh PRs; needs owner merge |
| `script/fleet-pull.sh`, `script/secrets-sync.sh`, `script/elon-startup.sh` | Skip | Run on coordinator wake; mutates checkouts or secrets |
| `script/coordinator-drain.sh`, `script/worker-watch.sh` | Skip | Tied to Elon wake and fleet watch, not a standalone schedule |
| `script/worker-startup.sh --host-check` | Skip | Precedes each worker launch |
| Legacy `templates/launchd/life.example.wrap-up.plist` (10 min) | Skip | Superseded on Orca hosts by `wrap-up-scheduled`; keep launchd only where Orca automations are not used |
| Host backup pull scripts under `arch/bin/` | Skip | Production data paths and host specific config |
| `script/shellcheck-dotfiles.sh` | Skip | CI and pre push, not fleet schedule |

Fleet watchdog behavior (alerts, issue_scan, worker_stall) is documented in [Fleet watch](fleet-watch.md). This file covers only Orca automation registration from dotfiles.
