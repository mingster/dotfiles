# Fleet watch

Orca registration for scheduled fleet jobs (including this pass) lives in [Orca automations](orca-automations.md).

Fleet watch is a bounded precheck script in `script/fleet-watch.py`. It is meant to run every five minutes on each fleet host through an Orca automation. The automation runs only the precheck command (no agent turn). Each pass writes one summary line to the fleet watch log and updates a private JSON state file. Handles, host names, and repo paths belong in private config only, never in this repository.

## What it is and how it runs

Install scheduling with `script/install-fleet-automations.sh` (see below). That script registers five Orca automations: `fleet-watch` on `*/5 * * * *`, `wrap-up-scheduled` on `0 */2 * * *`, `sync-team-skills-drift` on `0 6 * * *`, `team-audit-weekly` on `0 7 * * 1`, and `weekly-update` on `0 8 * * 1`. On the coordinator host, `--install` enables all five (including the daily drift check and the two Monday jobs). The fleet watch precheck runs `python3 script/fleet-watch.py --config <private-json> --state <private-state>`, appends stderr/stdout to the precheck log, and exits with code 1 so the automation does not spawn an agent.

You invoke the same command manually for debugging. Pass duration and feature outcomes land in `~/.orca/logs/fleet-watch.log` unless `FLEET_WATCH_LOG_PATH` is set. The state file holds waiter timers, notice queues, issue scan progress, and similar data across passes. Notices queue there, then deliver to configured run terminals through `orchestration send` (digest at most every 600 seconds, urgent items at once). A run may set `"typed": true` to use legacy `terminal send` instead.

Without a five minute schedule the script is an inert guard, not liveness coverage.

## Pass order

Each numbered step is one slice of a single pass, in the same order as `main` in `script/fleet-watch.py`. The script reads Orca once per pass and reuses that inventory where noted.

1. **Coordinator watch.** When `coordinator_watch` is set: ssh probe and alerts on backup hosts only. Saves state immediately. When `runs` is empty, this step can end the pass before Orca inventory (host without Orca).
2. **Orca inventory and worker alerts.** `read_orca_inventory` then `alerts`: inbox messages, worker list, per run inbox waiter checks (`pgrep` on `waiter_pattern`), and lead `terminal show`. On failure, one latched skip notice is queued and worker alerts, issue scan, and worker stall skip for that pass. When inventory succeeds: unacked inbox with no waiter for ten minutes yields one urgent notice per run; failed dispatches (after the first pass baseline), host cap exceeded (children count toward the cap), and dead lead panes yield urgent notices.
3. **Terminal list.** Fetches terminal last output times for worker stall. A list failure sets `terminal_list_failed` on the summary line and worker stall does not run actions that pass.
4. **PR watch.** When `pr_watch.repos` is set: merges, Verdict and Review receipts, and stuck failing open PRs (`stuck_minutes`).
5. **Usage publish.** When `usage_hosts` is set: runs `usage-gate.py publish` for each host; failures become digest notices.
6. **Workflow watch.** When `pr_watch.repos` is set: reruns each failed workflow once, then may open a `needs-elon` issue after two failures (optional `pr_watch.workflows` filter).
7. **Backup.** When `backup.stamp` is set, logs stamp age and opens at most one open GitHub issue when the stamp is older than thirty minutes.
8. **Heavy gate.** Reads recent `wait_s=` lines from per host wait logs, logs medians, and may open an issue when median wait exceeds two minutes (configurable).
9. **Wrap up age.** Reads the last timestamp in per host wrap up round logs, logs ages, and may open an issue when the last round is older than twenty minutes (configurable).
10. **Issue scan.** When `enabled: true` and Orca inventory succeeded: usage gate check, host admission under `host_caps`, detached head Checks workers, detached reviewer workers after push, rework workers on failing heads (cap two rounds), then at most one eligible `ready-for-agent` issue start. With no candidate issue and no other scan bits recorded yet, logs `issue_scan_none`. When inventory failed earlier in the pass, appends `issue_scan_inventory_failed` and returns without starting workers; the summary line still carries the bit. Team backlog sweep is not implemented on main; it is planned in open PR #699.
11. **Worker stall.** When enabled and inventory and terminal list succeeded: live workers with no terminal progress for thirty minutes get `worker-stop` then `worker-start --retry-of`; repeated silence after label cooldown adds `needs-elon` on the PR or opens a fixed title issue.

After checks, coordinator watch notices from step 1 are merged, drain counts from `script/coordinator-drain.sh` may append digest notices, the pass appends the log line, delivers notices, and saves state. Match `FLEET_WATCH_CONFIG` between fleet watch and coordinator drain when leads are configured.

## Config reference

Keep the live JSON beside machine private paths (for example under `~/.config/fleet-watch/`). Example shape: `script/fleet-watch.config.example.json`.

| Key | Meaning | Default |
|-----|---------|---------|
| `runs` | List of `{id, terminal, waiter_pattern}`; optional `typed: true` for legacy send | `[]` |
| `runs[].terminal` | Coordinator (or run) terminal handle for notices | required when runs nonempty |
| `host_caps` | Map host id to max concurrent dispatches (children included) | `{}` (issue scan admits with 4 when host missing) |
| `leads` | `{name, terminal}` panes that must stay alive | `[]` |
| `pr_watch.repos` | GitHub repos `owner/name` to watch | none |
| `pr_watch.stuck_minutes` | Minutes before a stuck failing open PR alerts | `30` |
| `pr_watch.workflows` | Workflow names to treat in rerun logic; empty means all failed runs in window | all in window |
| `worker_stall.label_repo` | Repo for stall issues and PR labels | none (feature off without it) |
| `worker_stall.needs_elon_label` | Label applied after cap | `needs-elon` |
| `worker_stall.label_cooldown_seconds` | Wait before labeling after restart | `120` |
| `worker_stall.stall_idle_seconds` | Silence before stall actions | `1800` (or `FLEET_WATCH_STALL_IDLE_SECONDS`) |
| `backup.stamp` | Path to coordinator sync stamp file | none |
| `backup.issue_repo` | Repo for backup stale issues | none |
| `heavy_gate.hosts` | Host id to wait log path | none |
| `heavy_gate.slot_roots` | Host id to heavy gate cache root | none |
| `heavy_gate.issue_repo` | Repo for median and stuck slot issues | none |
| `heavy_gate.median_limit_seconds` | Median wait threshold | `120` |
| `wrap_up.hosts` | Host id to wrap up scheduled log path | none |
| `wrap_up.issue_repo` | Repo for stale round issues | none |
| `wrap_up.stale_limit_seconds` | Age before opening issue | `1200` |
| `issue_scan.enabled` | Turn on automated issue and rework starts | `false` |
| `issue_scan.repos` | Repos to list `ready-for-agent` issues | `[]` |
| `issue_scan.repo_roots` | Repo to local checkout path | `{}` |
| `issue_scan.pr_repos` | Repos for PR rework and head checks | `repos` |
| `issue_scan.run` | Orca run id passed to worker startup | required when enabled |
| `issue_scan.from_terminal` | `--from` handle for worker starts | required when enabled |
| `issue_scan.host` | Host id for admission | `local` |
| `issue_scan.agent` / `model` | Provider and model for starts and gate | `cursor`, empty model |
| `issue_scan.startup` | Worker startup script path | `script/worker-startup.sh` |
| `issue_scan.role` | Default builder role name for issue starts | `builder` |
| `issue_scan.rework_agent` / `rework_model` | Overrides for rework starts | same as agent/model |
| `coordinator_watch.state_dir` | Git checkout of agent state | none |
| `coordinator_watch.offline_minutes` | Ssh failures before alert | `10` |
| `coordinator_watch.alert_command` | Shell command; alert text is the last argument | none |
| `usage_hosts` | Host ids passed to `usage-gate.py publish` | none |

## Install and uninstall

Use `script/install-fleet-automations.sh` from dotfiles on every host.

```bash
script/install-fleet-automations.sh --status
script/install-fleet-automations.sh --install
script/install-fleet-automations.sh --uninstall
```

Optional env file: `~/.config/fleet-watch/automations.env` (or `FLEET_AUTOMATIONS_ENV`). Common overrides: `DOTFILES_DIR`, `AGENT_STATE_DIR`, `FLEET_WATCH_CONFIG`, `FLEET_WATCH_STATE`, `FLEET_WATCH_PRECHECK_LOG`, `FLEET_WATCH_PRECHECK_TIMEOUT` (default 280), `ORCA_CLI_COMMAND`.

On install, the script compares `hostname -s` to the coordinator name in `agent-state/coordinator.conf`, or `mini6` when that file has no coordinator line. **Enabled** automations run only on that coordinator host. Other hosts get the same automation records **disabled** (precheck definition present, cron idle).

Coordinator watch alerts say failover is manual; there is no automatic promotion.

## Reading the log

Each line is UTC timestamp plus semicolon separated fields. Never contains terminal screen text.

| Bit | Meaning |
|-----|---------|
| `pass ok` / `pass failed` | Pass finished within or over four minute budget |
| `backup_age_s` / `backup_stale` | Stamp age; stale when over ten minutes |
| `heavy_gate_median_*` | Per host median wait seconds |
| `wrap_up_age_*` / `wrap_up_stale_*` | Last wrap up round age |
| `stall ...` | Worker stall actions taken this pass |
| `scan ...` | Issue scan summary (see below) |
| `terminal_list_failed` | Could not list terminals; worker stall skipped actions that pass |

Issue scan bits inside `scan ...`:

| Bit | Meaning |
|-----|---------|
| `issue_scan_off` | Feature disabled |
| `issue_scan_inventory_failed` | Orca inventory failed earlier this pass |
| `issue_scan_gate` | `usage-gate.py check` failed for configured agent/model |
| `issue_scan_load` | Host at cap under `host_caps` |
| `issue_start=N` | Started worker for issue number N |
| `issue_start_fail=N` | `worker-start` failed for issue N |
| `head_checks_start=abcdef12` | Detached Checks worker for PR head prefix |
| `reviewer_start=abcdef12` | Detached reviewer worker for PR head prefix |
| `rework_start` / `rework_fail` / `rework_cap` | Rework pipeline |
| `issue_scan_none` | No eligible ready issue and no other scan bits on that pass |

**First day checks:** Confirm one new log line every five minutes on the coordinator. Confirm `pass ok` and no repeated `Orca could not be read`. With issue scan enabled, expect occasional `issue_start` or explicit `issue_scan_none`, not endless `issue_start_fail`.

## Troubleshooting

**Stale coordinator terminal in config.** A wrong `issue_scan.from_terminal` or run `terminal` handle can make issue starts log `issue_start_fail` and rework starts log `rework_fail`. Detached head checks do not read `from_terminal`. Orca may return `no_active_sender_terminal` on a failed stall restart or on a failed `orchestration send` (stderr from `flush_queue`), which is the stale run terminal case. Fix: set the current coordinator terminal handle in the private JSON.

**Orca inventory errors.** One latched notice per outage; worker inbox alerts and issue scan skip until Orca responds. Backup, heavy gate, and wrap up still run.

**Inbox waiter false positive.** Confirm `waiter_pattern` matches only the coordinator inbox waiter for that run id.

**Host cap noise.** Count includes nested dispatches; raise the cap or reduce parallel work.

**Issue scan never starts.** Check `enabled`, repo roots on disk, usage gate, and `host_caps`. Read `issue_scan_gate` vs `issue_scan_load` in the log.

**Coordinator watch on the coordinator machine.** Should no op when this host is the named coordinator; configure only on backup hosts.

**Precheck log vs summary log.** Automation precheck appends full Python output to `FLEET_WATCH_PRECHECK_LOG`; the single line summary is always `fleet-watch.log`.

**Toolchain.** `script/fleet-toolchain-check.sh` (also from elon startup and wrap up) reports fleet hosts below current orca, bun, or node versus `mini6`.
