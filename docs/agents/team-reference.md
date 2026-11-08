# Agent team reference

Long reference moved out of the root [README](../../README.md). Read it when you need the full role list, the project file map, the per stage command table, the fleet and load distribution rules, the full tool reference, or the skill sharing rules.

## Agent team template

Use `script/agent-team.sh` for machine setup, new projects and safe reset previews. See [Agent team setup](agent-team-setup.md) for commands, backups and owner steps.

The team files give agents their jobs, working rules and repeatable steps. Elon is the owner's window and only contact, off the main line: he sets priorities weekly, handles `needs-elon` exceptions, dispatches ready issues within the usage and load gates, and contacts the owner only on Owner-Reserved decisions. See [Agent team architecture](agent-team-architecture.md) for the full design.

`script/adopt-agent-team.sh [--project-name <name>] <dir>` installs from [templates/agent-team](../../templates/agent-team/): roles, generated team skills, facts file skeletons, role reference docs, settings, hooks, model routing and a Token budget block for `AGENTS.md`. Review the project copies and fill in their facts before using the team.

Role instructions live at `<project>/.claude/agents/<role>.md`. Give workers their role file path in the task prompt (using the main checkout's absolute path so a branch worktree never reads a stale copy), including workers on other providers. Every role edit requires human review and an `Owner-approved: <owner> <date> (<where approved>)` commit trailer.

| Role | Owns |
| --- | --- |
| `elon` | Owner's window and only contact, weekly priorities, `needs-elon` exceptions, ready issue dispatch, and Owner-Reserved decisions. |
| `architect-pm` | Intake, one design document per feature (intent, spec and tickets), issue triage, the weekly non-blocker list and full `/team-audit` runs. |
| `fullstack-dev` | Features and fixes built with tests first by TDD (Cursor `composer-2.5` first, then Claude when quota is out), running touched checks locally before pushing once and opening its PR. |
| `qa-sdet` | Cross-family verifier Verdict (`script/post-verdict.sh`, running parent against head as a user would), Playwright proving runs and daily/weekly `/staging-review`. |
| `release-manager` | Daily 19:00 Taiwan time staging deploy, production deploy on the owner's explicit go, release evidence and rollback plans. |
| `sales-marketing` | Self-serve acquisition, positioning, conversion experiments, weekly metrics (MRR, LTV, CAC, churn) and the pre-build grill for new UI pages and wording. Delegates market research and merchant lookups to a Gemini worker on Antigravity with source URLs. |
| `secops-finops` | Security, auth, tenant isolation, money PR reviews (part of Strong review and the money pre-build grill) and weekly financial reconciliation. |
| `support-csm` | Customer ticket triage, reply drafts (sent only after owner approval), recurring pain points and support grill input. |

The adoption script installs every role in the template, including support.

Team skills come from [templates/agent-team/.agents/skills](../../templates/agent-team/.agents/skills/): `elon` is the entry point, `ceo` is its alias, `crew` coordinates delivery, `deploy` promotes releases, `staging-review` audits daily and weekly staging, `grill-backlog` and `team-grill-backlog` clear pre-build and owner decisions, `wrap-up` prunes finished worktrees and branches, `team-audit` checks team files and metrics, and `poteto-mode` (with `ORCA-ADAPTER.md`, `ketchup`, `recall`, `show-me-your-work`, `correct`, `unslop` and the `principle-*` skills) supplies the vendored pstack playbooks and decision cues. Adoption runs `script/sync-team-skills.sh` to generate project `.agents/skills/` copies with links from `.claude/skills/` and `.cursor/skills/`. Edit the template source and sync again; do not edit generated copies.

Team skills add project policy and call Orca and Matt Pocock skills for shared procedures. See [Skills inventory](skills-inventory.md) for the three-tier layout and upstream sync rules.

Other project files tell the team how this repo works:

| File | What to set or read |
| --- | --- |
| `.claude/model-routing.md` | Provider and model choices, worker launch rules, fail-closed usage gate and publication/merge authority. |
| `.claude/settings.json`, `.claude/hooks/` | Claude session setup, Bash safeguards (`guard-bash.py`), fail-closed usage gate (`usage-gate-hook.py`), repeated test failure limits (`strikes.py`) and turn budget (`worker-budget.py`). |
| `docs/agents/team.md` | Team roles, 2026-11-06 process, human approval for role changes, orchestration, delivery contract, handoffs, hotfix loop, rules and gated actions. |
| `docs/agents/team-facts.md` | Repository, check commands, review rules and project shortcuts. |
| `docs/agents/deploy-facts.md` | Components, hosts, stage commands, production approval and rollback steps. |
| `docs/agents/coordinator-operations.md`, `elon-dispatch.md`, `engineering-integration.md` | Coordinator wake loop, failover, fleet placement, review tiers and merge rules. |
| `docs/agents/architect-pm-work.md`, `qa-sdet-execution.md`, `release-manager-work.md` | Role-specific work references loaded on demand to keep `.claude/agents/*.md` under the 800-word budget. |
| `docs/agents/issue-tracker.md` | Where specs and tickets go and how to read or update them (including sub-issues and native blocking dependencies). |
| `docs/agents/triage-labels.md` | The project's issue labels and what each means. |
| `docs/agents/domain.md` | Where agents read domain terms (`CONTEXT.md`) and design decisions (`docs/adr/`). |

Adoption creates `team.md`, `team-facts.md`, `deploy-facts.md` and the role reference docs. Create the tracker, label and domain files with `~/dotfiles/script/init-agent-project.sh --labels <dir>` (automatically run by `script/agent-team.sh project`). Configure `docs/agents/daily-run.md` in the project before asking for a daily run. Decisions belong in `docs/adr/`.

Use slash commands below in Claude Code, Cursor and Antigravity. A worker prompt can instead name the skill's `SKILL.md` path and ask it to follow the file.

| Stage | What happens | Skill or command | Example prompt |
| --- | --- | --- | --- |
| Adopt the team | Install the files, then fill in project facts and tracker setup. | `script/agent-team.sh project <dir> --project-name <name>` | Adopt the team into `~/projects/acme` and show me the facts I need to fill in. |
| Start a session | Talk to Elon, who routes the work and runs `recall` and `ketchup`. | `/elon` or `/ceo` | `/elon Help me choose the next objective.` |
| Intake and Design | For a new feature, produce one design document (intent, spec and tickets) for one owner approval. Attach phone screenshots for any new UI page. | `/capture-intent`, `/write-spec`, `/to-spec`, `/to-tickets` | `/capture-intent New users cannot tell whether setup is complete.` |
| Pre-build grill | Run a multi-role grill only for money (`secops-finops`, `architect-pm`, Elon) or new UI pages (`sales-marketing`, Elon); owner approves before build. Elon decides all other work on the issue. | `/grill-with-docs`, `/grilling`, `/team-grill-backlog` | `/team-grill-backlog Run the pre-build grill on the pending money and UI issues.` |
| Dispatch and build | Elon assigns ready tickets (`Acceptance criteria`, `Requirement owner`, `Deleted`) under the usage and host gates; workers build by TDD on touched tests in child worktrees and report `worker_done`. | `/elon <objective>`, `/crew`, `script/worker-startup.sh`, `/tdd` | `/elon Deliver the ready setup tickets.` |
| Checks and review | Actions `Checks` (`head-checks.sh`) run on push; Actions `Review` (`script/pr-review.sh`) runs the read only bot review, and a cross-family `qa-sdet` verifier runs parent against head as a user would and posts the `Verdict` via `script/post-verdict.sh`. | `script/head-checks.sh`, `script/pr-review.sh`, `script/post-verdict.sh`, `/code-review` | `/code-review Check this branch against main and its ticket.` |
| Babysit, ship and wrap-up | The 5 minute pass (`fleet-watch.py`) starts one fix worker or a Shipping run (`script/ship.sh`) that squash merges and reads back as merged; `wrap-up.sh` runs every 10 minutes. | `script/ship.sh`, `script/wrap-up.sh`, `/wrap-up` | Run a Shipping pass on the verified PR and wrap up finished worktrees. |
| Deploy and staging review | Staging deploys daily at 19:00 Taiwan time, followed by `/staging-review` and full regression; a green review leads to a one-line summary and same-day owner go for production. | `/deploy local`, `/deploy staging`, `/staging-review`, `/deploy production` | `/deploy staging Promote main and start the daily staging review.` |
| Status and daily run | Get company status (**Now**, **Needs owner**, **Running**) or a recap, or run the project's daily checklist. | `/elon status`, `/elon daily run` | `/elon status Show Now, Needs owner and Running.` |
| Audit and weekly update | Orca runs `team-audit.sh` and `team-audit-metrics.ts` weekly for one line; `architect-pm` runs `/team-audit` on the owner's word; `weekly-update.sh` opens three upstream PRs for owner review. | `/team-audit`, `script/weekly-update.sh` | `/team-audit Check this repo's team files, metrics and observations.` |
| Support | Elon routes fixes and `support-csm` drafts the customer reply in the customer's language; the owner approves before sending or closing. | Ask Elon to assign `support-csm` | Elon, resolve this support ticket and bring me the reply draft for approval. |

## Fleet and load distribution

The team runs across a fleet of Macs paired in Orca ADE (`orca environment list`) and coordinated from a single active coordinator host named in `agent-state/coordinator.conf`.

1. **Coordinator and host sync:** `script/elon-startup.sh` checks that the current machine is the named coordinator, `agent-state` is fresh (`.sync-ok` under 30 minutes), and every fleet host has fast-forwarded `main` checkouts (`script/fleet-pull.sh`) and synced secrets (`script/secrets-sync.sh`). Backup hosts watch the coordinator via `script/fleet-watch.py` (`coordinator_watch`) and take over only when the owner runs `script/take-over-coordinator.sh --yes`.
2. **Host placement order (`~/.claude/state/fleet-load.sh`):**
   - **Primary code host (also hosts the coordinator):** first choice for code, test and review while 1-minute load < 12.
   - **First overflow host:** next choice while 1-minute load < 8.
   - **Second overflow host:** next choice while 1-minute load < 12.
   - **Browser and secrets host:** always used for browser work, secrets and main-checkout operations.
   - **Release-manager host:** runs only on a host named in the project's `docs/agents/deploy-facts.md`.
   - **Database and heavy host:** runs the dev database and remote Playwright or `head-checks.sh` jobs via `script/remote-heavy.sh`; never runs interactive agent workers.
3. **Worker admission and load targets (owner 2026-11-04):** admit a new worker on a host when `(1-minute load / CPU cores) < 0.7` and `free memory >= 4 GB`, within the host's worker cap (`host_caps`). Caps are a ceiling, never a target: fill an idle host up to its cap before any host with queued work waits, and keep each active host between `0.4` and `0.7` load per core. Count builders, reviewers, child dispatches and finished committers still holding a pending-push slot.
4. **Per-host heavy job admission (`script/heavy-gate.sh` and `script/heavy-gate.py`):** Playwright and production builds are heavy: at most 2 per host (unless calibrated higher), waiting until 1-minute load is below the host limit (default 12) and free RAM is at least 20%. They use `--weight 2`; `HEAVY_GATE_CLASS=long` leaves 1 slot free. Full `tsc` uses `--measure` (no slot, logs metrics for the owner trial week). Unit tests and lint skip the gate.
5. **Provider quota distribution (`script/usage-gate.py` and `script/usage-gate-hook.py`):** every worker launch checks real weekly quota across Claude, Cursor and Antigravity, reserving 2% per running worker on that provider and refusing dispatch at the 95% weekly ceiling (exit 3) or when readings are stale beyond 5 minutes and cannot refresh (exit 4).

See [Agent team architecture](agent-team-architecture.md) and [Coordinator operations](coordinator-operations.md) for full details.

## Tools

All team tools live under `script/`, `.agents/skills/orca-team/`, and `bin/`.

### Setup, adoption and skill sync

| Tool | Purpose |
| --- | --- |
| `script/agent-team.sh` | Single entry point for `machine` setup, `project` adoption, safe `reset` (diff and backup before `--yes`) and `all`. |
| `script/adopt-agent-team.sh` | Copies the agent team template (`.claude/agents/`, hooks, `model-routing.md`, `team.md`, facts skeletons) into a project and syncs team skills. |
| `script/init-agent-project.sh` | Seeds `docs/agents/{issue-tracker,triage-labels,domain}.md`, appends `## Agent skills` to `AGENTS.md`, and with `--labels` creates the five triage labels on GitHub. |
| `script/agent-project-autoinit.sh` | Claude Code `SessionStart` hook that auto-runs `init-agent-project.sh --labels` for unseeded `mingster/*` repos. |
| `script/sync-team-skills.sh` | Generates committed copies of Tier 2 skills from `templates/agent-team/.agents/skills/` into a project; `--check` fails on drift. |
| `script/sync-mattpocock-skills.sh` | Refreshes the 22 vendored Matt Pocock skills from upstream and reapplies `CONTEXT.md` naming and `.mattpocock-local.patch`. |
| `script/check-skill-collisions.sh` | Checks for project skills that shadow shared or Orca-bundled skills, broken symlinks, or missing `SKILL.md` files. |
| `script/bootstrap-asdf-tools.sh` | Installs and pins `python` and `nodejs` from `.tool-versions` via `asdf`. |
| `script/bun-pin-check.sh` | Warns when a local or remote host's `bun` version is older than the repo's `package.json` pin (`packageManager` or `engines.bun`). |
| `script/switch-login-shell-zsh.sh` | Links zsh dotfiles and switches the host's login shell to `zsh` so remote Orca probes and hooks share one PATH. |
| `script/agent-settings-check.py` | Read-only coverage check classifying local agent settings against public templates and `AGENT_PRIVATE_BACKUP_MANIFEST`. |
| `script/backup-claude-desktop.sh` | Copies sanitized live Claude Desktop settings into `init/claude_desktop_config.json`. |
| `script/contribute-to-agents.sh` | Appends a dated reusable lesson to `.agents/claude/notes/<topic>.md`. |

### Coordinator, fleet and state sync

| Tool | Purpose |
| --- | --- |
| `script/elon-startup.sh` | Coordinator session-start check: verifies `coordinator.conf` and `.sync-ok` freshness in `agent-state`, then runs `fleet-pull.sh` and reports host status. |
| `script/new-coordinator.sh` | Bootstraps a new Mac as the coordinator from `agent-state` (Homebrew bundle, repo clones, state restore, LaunchAgents, Orca data restore and health checks). |
| `script/take-over-coordinator.sh` | Manual coordinator failover and handback using `coordinator.conf` in `agent-state` (`--dry-run` first, `--yes` to execute). |
| `script/orca-reply.sh` | Sends `orca orchestration reply` to a worker and nudges its terminal so an idle session wakes up immediately. |
| `script/fleet-pull.sh` | Fast-forwards clean `main` checkouts across configured fleet hosts and triggers `secrets-sync.sh`. |
| `script/fleet-watch.py` | Independent 5-minute watchdog: monitors inbox waiters, host caps, lead panes, stalled workers (`worker_stall`), backup freshness (`backup`), failed PR checks (`pr_watch`), `heavy_gate` wait medians, `wrap_up` freshness, `coordinator_watch` on backup hosts, and opt-in `issue_scan` auto-dispatch. |
| `script/fleet-workers.py` | Lists active Orca workers and dispatches across local and remote fleet environments. |
| `script/count-agents.sh` | Counts active coding agent CLI processes (`claude`, `agent`/`cursor-agent`, `agy`, `codex`, `gemini`) from a process snapshot. |
| `script/secrets-pack.sh` | Packs local secrets into an AES-256 encrypted `hdiutil` disk image for transfer between Macs. |
| `script/secrets-unpack.sh` | Unpacks an AES-256 secrets disk image onto a host. |
| `script/secrets-sync.sh` | Syncs the shared secrets directory across reachable fleet hosts. |

### Worker launch, usage gate and heavy gate

| Tool | Purpose |
| --- | --- |
| `script/worker-startup.sh` | Unified worker launcher and daily `--host-check`: aligns `~/dotfiles`, Orca presets, repo `main`, Node `.tool-versions` via `asdf` and Bun pins, checks `usage-gate.py`, and delegates to the provider starter. |
| `script/start-remote-worker.sh` | Checks `usage-gate.py`, probes the remote CLI in an Orca terminal, refreshes remote `~/dotfiles` and `~/.orca/presets.json`, and calls `orca orchestration worker-start --on`. |
| `script/start-cursor-worker.sh` | Creates a local or remote `--on` worktree, writes `.workspace-trusted` via Python 3 in an Orca terminal, checks `usage-gate.py`, and starts a Cursor worker. |
| `script/worktree-setup.sh` | Orca worktree setup hook: fetches and fast-forwards `origin/main` and runs `bun install --frozen-lockfile` when `node_modules` is missing. |
| `script/usage-gate.py` | Reads real Claude, Cursor and Antigravity quota, publishes readings to runner hosts (`--publish`), checks the 95% weekly ceiling (`check`), and ranks candidates (`pick`). |
| `script/usage-gate-hook.py` | Fail-closed Claude `PreToolUse` hook blocking any `worker-start` that bypasses `usage-gate.py`, lacks fresh readings, or calls `--on` directly. |
| `script/heavy-gate.sh` | Shell wrapper around `heavy-gate.py` for Playwright and production builds (`--weight 2`), plus `--measure` type checks without a slot. |
| `script/heavy-gate.py` | Enforces per-host slot limits, load ceiling, free memory floor, and `HEAVY_GATE_CLASS=long` reservation; logs slot waits and measure runs. |
| `script/hw-probe.sh` | Probes host CPU cores and RAM and calibrates per-host `heavy-gate` slots and load limits into `~/.config/heavy-gate/slots.conf`. |
| `script/remote-heavy.sh` | Syncs a commit to a remote fleet host, runs a heavy command there under that host's `heavy-gate.sh`, and copies artifacts back. |
| `script/run-scoped-tests.py` | Selects and runs unit tests scoped to changed files and their direct importers. |

### Checks, review and merge

| Tool | Purpose |
| --- | --- |
| `script/pr-review.sh` | Runs the read only cold PR review on the self hosted `Review` runner after GitHub Actions `Checks` pass (replacing `script/on-worker-done.sh`; uses `script/review-prompt.sh`, `script/review-prompt.txt`, `script/review-model.sh`, `script/review-run.sh`, `script/pr-review-author-family.py`). |
| `script/coordinator-publication.sh` | Pushes an explicit engineering branch (`--branch <branch> --worktree <path>`) and opens or updates its PR after validating `Closes #<n>`, `## Verification` bullets, and zero `.env` secrets. |
| `script/head-checks.sh` | Runs a repo's `.agents/head-checks.conf` checklist once on a trial merge of the PR head with `main` in a throwaway worktree; only Playwright and build steps wait on `heavy-gate.sh`. |
| `script/head-checks-tsc.sh` | TypeScript check helper invoked by `head-checks.sh` profiles. |
| `script/post-verdict.sh` | Validates and posts a canonical `Verdict: PASS|PASS+NOTES|FAIL head=<sha> verifier=<id> author=<id>` comment and `review` status on a PR, refusing self-review. |
| `script/ship.sh` | Shipping run (replacing `script/lead-merge.sh`): verifies required checks and matching `git patch-id` Verdict, merges with `gh pr merge --squash`, and reads the PR back as `MERGED`. |

### Cleanup, audits and weekly maintenance

| Tool | Purpose |
| --- | --- |
| `script/wrap-up.sh` | Previews and prunes finished worktrees, merged branches (protecting `archive/*` tags), ended Orca terminals/panes (25s budget), stale temp browsers, Chrome clones and agent temp files (`--fleet`, `--scheduled`). |
| `script/worktree-idle.py` | Exits 0 only when `orca terminal list` positively confirms a worktree has zero active terminals. |
| `script/team-audit.sh` | Deterministic audit of skill sync, 800-word role budget, banned wording, skill frontmatter/locks, helpers, SDLC rules, Matt Pocock upstream drift, ready-brief fields, `Owner-approved:` trailers, and `script-list`. |
| `bin/team-audit-metrics.ts` | Computes the five weekly delivery metrics from GitHub PRs and issues (`median_ticket_start_to_merge_minutes`, `first_pass_checks_fail_rate`, `p0_filed_this_month`, `p1_filed_this_month`, `reopened_or_hotfix_rate`). |
| `script/weekly-update.sh` | Weekly maintenance runner that updates Matt Pocock skills, pstack template skills, Bun and Node LTS across three tested PRs and one owner summary. |
| `script/prepend-recent-change.ts` | Prepends dated change summaries to project changelog or recent-change files. |
| `script/shellcheck-dotfiles.sh` | Runs `shellcheck --severity=error` on the repository's shell entrypoints. |

### Orca-team pane and watch helpers (`.agents/skills/orca-team/`)

| Tool | Purpose |
| --- | --- |
| `worker-start-check.sh` | Runs `usage-gate.py check` for the chosen `--agent` and `--model`, then calls `orca orchestration worker-start`. |
| `worker-watch.sh` | Polls active Orca workers and detects stalled sessions so the coordinator can nudge, retry or respawn them. |
| `worker-panes.sh`, `worker-pane.sh` | Opens and colors supervised worker panes in Orca by role (`role-colors.tsv`). |
| `worker-pane-close.sh` | Closes ended worker panes/terminals (`--ended` or `--release <dispatch_id>`) and kills leftover process groups. |
| `worker-pane-retry.sh` | Retries or respawns a failed or stalled worker pane cleanly. |

## Skills

Reusable skills live in `.agents/skills/<name>/` and are visible to Claude Code, Cursor and Antigravity through individual links in `~/.agents/skills` and `~/.claude/skills` (also read by Cursor), and the Antigravity `skills.json`. A project skill with the same name as a central one silently wins, so keep the two sets apart:

| Kind | Lives in |
| --- | --- |
| Reusable across projects | here, `.agents/skills/<name>/`, and nowhere else |
| Project specific | `<project>/.agents/skills/<name>/`, with symlinks from `<project>/.claude/skills/` and `<project>/.cursor/skills/` |

Run `bash script/setup-agent-skills.sh` to migrate legacy tree links to real directories. It retains tool-installed skills and their lock data, leaves the old source intact, links only tracked dotfiles skills, runs `orca skills install --all` when `orca` is on `PATH`, and prints its actions. Existing tool folders and foreign links are preserved, including same-name conflicts. `DOTFILES_SKIP_SYSTEM_SETUP=1 bash install.sh` also performs this migration without installing software. The skill inventory requires a Git checkout.

Run `script/check-skill-collisions.sh` to find a project skill that shadows a central or Orca-bundled one, a broken symlink, or a missing `SKILL.md`. MCP secrets go in `~/.claude/settings.local.json` (gitignored). Paths reference: [AGENTS.md](../../AGENTS.md).

## Context, notes and backups

Project instructions (`AGENTS.md`) load always. Short cross-project rules live in `~/.claude/notes/` (`.agents/claude/notes/`) and the Obsidian vault holds deep docs. Add a lesson from any project:

```bash
~/dotfiles/script/contribute-to-agents.sh nextjs "Nested route-group layouts cause dev 404s"
```

```bash
bash script/backup-claude-desktop.sh   # Claude Desktop settings into init/
```
