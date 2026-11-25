# Agent team architecture

Overview of the AI agent team across **<project-a>**, **<project-b>** and future adoptions. The current rules live in the root [README](../../README.md), each project's `docs/agents/team.md` and `.claude/model-routing.md`; when this file disagrees with them, they win.

## 1. Organization

Mingster talks only to **The coordinator (`elon`)**, the shared CEO and single front door of <project-a> and <project-b>. The coordinator delegates to teammates, every teammate reports to the coordinator, and the coordinator reports to Mingster. Each project has eight shared roles (the coordinator and seven specialists); a project may add its own roles in its `.claude/agents/`.

```mermaid
flowchart TD
    Board["Mingster (Human Owner / Board)\nOwner pauses: Money rules and prices, Spending, Customer messages, Data deletion, Prod Go once a real store is live, one look before production"]
    CEO["Elon (shared CEO)\nSingle front door for <project-a> and <project-b>, dispatches with Orca orchestration"]

    subgraph Direct_Reports["Product, Commercial & Customer Specialists"]
        Sales["Sales & Marketing\n(sales-marketing)\nSelf-serve acquisition, positioning, UI grill & unit economics"]
        BA["BA & Product Architect\n(architect-pm / 需求分析師)\nIntake, one-doc feature design (intent, spec, tickets), triage, audits"]
        Support["Support & CSM\n(support-csm)\nTicket triage, customer reply drafts & recurring pain points"]
    end

    subgraph Tech_Specialists["Technical Execution Specialists (report to Elon with worker_done)"]
        Dev["Fullstack-Dev\n(fullstack-dev)\nTDD implementation in isolated worktrees"]
        QA["QA-SDET\n(qa-sdet)\nCross-family PR review, Playwright proofs & daily staging review"]
        SecOps["SecOps-FinOps\n(secops-finops)\nSecurity, auth, tenancy & money reconciliation audits"]
        RM["Release-Manager\n(release-manager)\nDaily 19:00 staging deploy & production after Playground regression, owner's go once a real store is live"]
    end

    Board --> CEO
    CEO --> Sales
    CEO --> BA
    CEO --> Support

    BA -- "Machine-Checkable Ticket Contracts (GitHub issues)" --> CEO
    CEO --> Dev
    CEO --> QA
    CEO --> SecOps
    CEO --> RM
```

## 2. Responsibilities and decision boundaries

- **Mingster (user / board).** Talks to the coordinator (`/elon` or `/ceo`) as executive peer. Decides only money rules and prices, spending and contracts, sending customer replies, irreversible data deletion, production deploy once a real store is live, and a look at each new feature or page before production (owner, coordinator chat 2026-11-13). Nothing else interrupts the user.
- **The coordinator.** Critical, program driven partner without flattery. The user's window and only contact, off the main line (`README.md` section 3). Turns vision into commercial experiments (Sales), requirements (BA) and delivery (workers), sets priorities weekly, handles `needs-elon` exceptions, dispatches ready issues within `usage-gate.py` and `heavy-gate.py`, and contacts the user only for a user decision. Never uses Claude subagents. Commands: `/elon <goal>` or `/ceo <goal>`. Unprompted messages carry a decision, options, a recommendation and any exact command; routine progress, merges, reviews and staging deploys are not reported. On `/elon status` ("what now") the format is **Now**, **Needs user**, **Running**; on "recap" it reports merged, deployed, problems and numbers.
- **Sales and Marketing (`sales-marketing`).** Owns self-serve acquisition, positioning, conversion experiments and metric definitions (MRR, LTV, CAC, churn, 14 day activation), and joins the pre-build grill for new UI pages and wording. Delegates market research, competitor price comparison and Taiwan merchant lookups to a Gemini worker on Antigravity (requiring a source URL for every number and merchant fact, spot-checked before use). Never plans manual outbound sales, sends unapproved emails, touches production tables or alters live pricing.
- **BA (`architect-pm` / 需求分析師).** Runs intake, writes one design document per feature (intent, spec and units; the owner approves only money rules and prices, and looks at a new feature or page before production), slices specs into machine-checkable GitHub issues with `to-tickets`, maintains the weekly list of non-blocker findings, and runs full `/team-audit` reviews on the user's word. Never writes application code.
- **Support tickets (`support-csm`, user rule 2026-10-12).** When a ticket or support email arrives, the underlying problem is resolved first when it needs a fix, `support-csm` drafts the reply in the customer's language, and the coordinator notifies Mingster the same day with the ticket, what was done and the draft. Nothing is sent or closed before the user approves.

## 3. Delivery lifecycle

GitHub issues and PRs are the state of record (`README.md` section 3). After each push, GitHub Actions `Checks` run first; when they pass, Actions `Review` (`script/pr-review.sh`) and the verifier (`qa-sdet` via `script/post-verdict.sh`) run. The 5 minute babysit pass (`fleet-watch.py`) starts one verifier when head-checks passed, the head has a cold `Review: PASS` (or the repo has no online review runner) and no Verdict. The existing fix worker and a Shipping run (`script/ship.sh`) still run for a failing head and for a passing Verdict that matches the head. `wrap-up.sh --daily` cleans up once a day at 04:00 on every Orca host. Docs and changelog only PRs, and tier 0 PRs, need no verifier: a cold `Review: PASS` at the head is enough for `ship.sh`.

```mermaid
sequenceDiagram
    autonumber
    actor Owner as Owner
    participant CEO as Elon (CEO)
    participant BA as architect-pm / sales-marketing
    participant Dev as Fullstack-Dev
    participant QA as Actions Review & QA-SDET Verifier
    participant Ship as Shipping Run (script/ship.sh)
    participant RM as Release-Manager

    Owner->>CEO: Product Vision / Feature Goal
    CEO->>BA: Intake, pre-build grill (money or new UI page), one design doc (intent, spec, tickets)
    BA->>Owner: Approval only for a price or money rule; a new feature or UI page builds and gets one look before production
    BA->>CEO: Ready GitHub issue tickets (Machine-checkable contracts)

    CEO->>Dev: 5 minute run starts scoped ticket in isolated worktree
    Dev->>Dev: Bug fixes start with a failing test, features, scripts and refactors require tests and proof on the real artifact (refactors prove behavior unchanged), local checks, push once and open PR
    Dev->>QA: Actions Checks pass; Actions Review (pr-review.sh) and verifier Verdict (post-verdict.sh)
    QA->>Ship: 5 minute babysit pass starts a verifier; a fix worker or a Shipping run still runs for the other groups
    Ship->>Ship: Squash merge (gh pr merge --squash), read back as MERGED; 10m wrap-up cleans worktree

    RM->>RM: Daily 19:00 Taiwan time staging deploy
    RM->>QA: swarm staging review (full regression, smoke, changed pages on phone viewport; all pages weekly)
    RM->>RM: Playground regression on the staging SHA while production holds only test data
    Owner->>RM: Owner's go for the exact production SHA, only once a real store is live
    RM->>RM: Production backup, deploy and live smoke check (auto code rollback on smoke fail)
```

## 4. Unit and review contracts

Each ready GitHub issue carries in one text (body or a single comment) these three fields:

1. **`## Acceptance criteria`:** observable cases, allowed files, and the exact proving command (the unit's listed test cases from the spec's `## Test plan` plus touched unit tests, never the full regression suite).
2. **`Requirement owner:`** the requester and reason (per The Algorithm: question the requirement first).
3. **`Deleted:`** what requirement or step was removed, or `nothing, because ...`.

Pre-build grill gate (user rule 2026-11-06): a multi-role grill runs only for **money** (payments, billing, refunds, ledger, credits, pricing or entitlements) with `secops-finops`, `architect-pm` and the coordinator, and for **new UI pages** with `sales-marketing` and the coordinator. The coordinator approves the result; for money rules and prices the build runs while the owner reviews it, and only the merge waits. All other work has no grill: the coordinator decides and records it on the issue. Exact user-facing copy in `tw`, `en` (fluent American English, written natively) and `jp` (natural Japanese, written natively) is reviewed with the spec by the team, and the owner sees it in the look before production (Owner pauses); nobody asks him again at merge.

Every code change passes `script/head-checks.sh` once per head and an independent cross-family review before merge. The verifier never runs unit tests, `tsc` or lint; it reads the diff and the `head-checks.sh` Checks receipt, proves load-bearing behaviour live (browser at phone viewport for UI, real API call or script run), answers the three review questions (does the diff meet each acceptance line, is there a real bug, would the new test go red without the fix), and posts `Verdict: PASS|PASS+NOTES|FAIL head=<full sha> verifier=<dispatch id> author=<dispatch id>` with `Command: <exact test command run>`. Extra Strong (Claude Opus) cross review is required only for money transactions or when the coordinator or the user explicitly requests it on the issue or PR. A PASS Verdict and Checks PASS carry across a clean merge of `main` (`verdict_carry`).

## 5. Persistent memory (`active_run.md`)

A worker on a unit with more than one slice keeps one git-ignored ledger, `active_run.md`, in its worktree root, so a compaction or restart restores state in one turn. It is written once before code changes (program, allowed files, verification command, steps) and updated only when blocked or at a handoff (strike count, `[Blockers]`). It does not replace the coordinator's child ledger (`docs/agents/team.md`, rule Child ledger).

Template and examples: [Persistent memory protocol](persistent-memory-protocol.md).

## 6. Token efficiency and FinOps

1. **Model and effort:** pick the tier by task (Strong for ambiguous decisions, specs, security or financial review; Workhorse for implementation, coordination, QA, release, sales and support; Light for clerical subtasks and `fullstack-dev-small` fixes touching 3 files or fewer). Flags: `.claude/model-routing.md`.
2. **Usage gate (fail closed, user 2026-11-06, reworked 2026-11-13):** every provider (`claude`, `antigravity`, `grok`, and `cursor`, which is still gated though no longer routed) and every way of starting a worker passes `script/usage-gate.py` and `script/usage-gate-hook.py`. The hook denies any `worker-start` when usage plus the running-worker reserve (2 points per strong model, 1 per other) reaches the provider's ceiling in `script/usage-gate.config.json` (Claude 95, Cursor included pool 100, each Antigravity pool 95; exit 3; Grok has no usage API, so its gate is at most one live grok worker per host), when no fresh reading is available and the last good reading is over 2 hours old or within 10 points of the ceiling (exit 4; Antigravity is the exception: `check` and `pick` both allow it with a note and the worker stops at its first quota or sign-in error), when `--agent` is missing or unknown, or when `--on` is called directly instead of through `script/start-remote-worker.sh`, `script/start-cursor-worker.sh` or `script/worker-startup.sh`. The daily cap blocks automatic starts only (`--auto`, passed by fleet-watch for the issue scan and babysit); a manual or coordinator start past it gets a note. Claude has no daily cap: its headroom is the weekly percent left over the time to the weekly reset, summed over every managed Orca account (owner 2026-11-21). `fleet-watch.py` logs every refusal and tells the coordinator once after 30 minutes of refusals with over 20 points of headroom. `usage-gate.py show` prints sources, ages and reset times. Decision record: `docs/adr/0001-shared-team-skills-and-usage-caps.md`.
3. **Heavy gate:** Playwright and production builds run through `~/dotfiles/script/heavy-gate.sh --weight 2` (at most 2 per host). Full `tsc` uses `--measure` without a slot. Unit tests and lint skip the gate. Wait in the foreground under the tool timeout, never via background shell polling.
4. **Strikes and Attack the Premise:** at the second failure of the same check, write down and directly test the shared premise before a third attempt. Three behavioural failures of the same command after production edits trigger a hard stop (`.claude/hooks/strikes.py`); tooling or setup failures (missing dependencies, Prisma generation, typegen) do not count toward the three strikes.
5. **On demand memory:** never load `learned.md` or `experiences/` at session start; grep them only when a domain gotcha comes up.
6. **Worktrees and worktree cleanup:** child worktrees go in `~/orca/workspaces/<project>/<lane>`, never `/tmp` or `.claude/worktrees`. When a job merges or settles, release the worker with `worker-pane-close.sh --release <dispatch_id>` and let `script/wrap-up.sh` prune finished branches, worktrees, terminals and temp browsers.
7. **Team audit:** Orca runs `script/team-audit.sh` and `script/team-audit-metrics.ts` weekly for a one-line result. When the user says "team-audit", `architect-pm` runs the full `/team-audit` skill: six deterministic checks (sync, 800-word role budget, banned wording, skills, ready-for-agent label conflicts, and `Owner-approved:` role commit trailers), mistake classes found by `workflow-from-chats` over the last 7 days of transcripts and the observation log `~/agent-state/team-observations.tsv`, each fixed through `/correct`, the Orca stage times, and the six delivery metrics (`median_ticket_start_to_merge_minutes`, `first_pass_checks_fail_rate`, `first_pass_verdict_rate`, `p0_filed_this_month`, `p1_filed_this_month`, `reopened_or_hotfix_rate`).
8. **Context hygiene:** one unit per session (a worker exits once its branch is committed, verified and reported). Keep `active_run.md` current on multi-slice work so `/compact` loses no state. The coordinator delegates heavy reading and test sweeps to Orca workers and reads only diff stats and exit codes.

## 7. Fleet and load distribution

The team operates across a fleet of Macs paired in Orca ADE (`orca environment list`) so PR owners, verifiers and heavy check jobs run in parallel without overloading a single machine.

```mermaid
flowchart LR
    Coord["Active Coordinator Host\n(Elon, coordinator.conf, 10m state sync)"]
    Primary["Primary Code Host\n(load < 12, code/test/review first choice)"]
    Overflow1["Overflow Host 1\n(load < 8, next choice)"]
    Overflow2["Overflow Host 2\n(load < 12, third choice)"]
    Browser["Browser & Secrets Host\n(browser tasks, secrets, main checkouts)"]
    Heavy["Database & Heavy Host\n(dev DB, remote-heavy.sh, no workers)"]

    Coord --> Primary
    Coord --> Overflow1
    Coord --> Overflow2
    Coord --> Browser
    Coord --> Heavy
```

### Coordinator authority and fleet synchronization

- **Single active coordinator:** `agent-state/coordinator.conf` names one `coordinator <host>` and ordered `backup <host>` entries. `script/elon-startup.sh` verifies that the current host matches `coordinator.conf` and `.sync-ok` is under 30 minutes old before any dispatch.
- **State and checkout sync:** the active coordinator pushes state every 10 minutes (`sync.sh push`), while backup hosts run `script/fleet-watch.py` (`coordinator_watch`) to alert if the coordinator goes unreachable or stale. `script/fleet-pull.sh` fast-forwards clean `main` checkouts across fleet hosts (for hosts in `agent_hosts`, resets configured repositories to `origin/main` and cleans untracked files while keeping ignored files and fast-forwarding `~/agent-state` only) and runs `script/secrets-sync.sh`. Before launching any worker, `script/worker-startup.sh` aligns `~/dotfiles`, `~/.orca/presets.json`, repo `main`, Node (`.tool-versions` via `asdf`) and Bun (`package.json`) on the target host.
- **Manual failover only:** failover is never automatic. On the user's instruction, `script/take-over-coordinator.sh --yes` fences the old host via `coordinator.conf`, restores state on the backup host, and starts the sync LaunchAgent there.

### Host placement and routing order

The coordinator picks the target host for each task using `~/.claude/state/fleet-load.sh`:

1. **Primary code host (also hosts the coordinator):** first choice for code, test and review while 1-minute load < 12.
2. **First overflow host:** next choice while 1-minute load < 8.
3. **Second overflow host:** next choice while 1-minute load < 12.
4. **Browser and secrets host:** always used for browser work, secrets and main-checkout operations.
5. **Release-manager host:** runs only on a host named in the project's `docs/agents/deploy-facts.md`.
6. **Database and heavy host:** hosts the dev database and runs the `head-checks.sh` steps that need Postgres, via `script/remote-heavy.sh`; never runs interactive agent workers or Playwright.

### Worker admission and load balancing

- **Admission formula (user 2026-11-04):** admit a new worker on a host when `(1-minute load / CPU cores) < 0.7` and `free memory >= 4 GB`, within that host's worker cap (`host_caps`).
- **Load band target:** host caps are a ceiling, never a target. Fill an idle host up to its cap before any host with queued work waits, and aim to keep each active host between `0.4` and `0.7` load per core.
- **Counting active slots:** count PR owners, verifiers, child dispatches and finished committers still holding a pending-push slot.
- **Per-host heavy job admission (`script/heavy-gate.sh`):** Playwright and builds use weight 2 slots; full `tsc` uses measure mode. `script/fleet-watch.py` alerts when a host's 24-hour median slot wait exceeds 2 minutes.

Operational details: [Coordinator operations](coordinator-operations.md) and [Fleet watch](fleet-watch.md).

## 8. Providers in Orca ADE

Every provider is driven through Orca orchestration (`orca orchestration worker-start --agent <provider> --model <id> [--effort <level>]`) and reports with `worker_done` to the coordinator. Model names, presets and fallback chains live in `.claude/model-routing.md` and `~/.orca/presets.json`. General fallback order (owner 2026-11-20): **Claude, Antigravity, Grok**, nothing after, starting from each role's default provider. Cursor is no longer a provider. When all three are blocked, `usage-gate.py pick` reports a queue result and the batch waits for the earliest reset:

- **The coordinator:** defaults to Claude Opus medium (`--agent claude --model opus --effort medium`), fallback Antigravity `gemini-4-argon-medium` (`--agent antigravity --model gemini-4-argon-medium`).
- **`fullstack-dev`:** runs on Claude Sonnet medium (`--agent claude --model sonnet --effort medium`) first, then Antigravity `gemini-4-argon-medium` (with file-list and i18n-key audit before merge), then Grok (`--agent grok --model grok-4.7`). `usage-gate.py pick` enforces this order. When Argon stalls on a build or CLI deploy error, hand the same worktree to a Claude worker (`fullstack-dev-debug`).
- **`qa-sdet` (independent family review):** never uses the author's model family; one verifier table in `usage-gate.py` decides (owner 2026-11-21, #1305). A Claude author is reviewed by Antigravity `gemini-4-argon-high` or Grok `grok-4.7`, whichever has more weekly percent left (a different Claude model, tagged `same-family-different-model`, when both are blocked). An Antigravity author is reviewed by Claude, and by Grok only when Claude is blocked. A Grok author is reviewed by Claude only.
- **`sales-marketing`:** runs on Claude Sonnet medium for Traditional Chinese copy, positioning, pricing strategy and SQL analysis; delegates market research, competitor pricing and Taiwan merchant lookups to Antigravity `gemini-4-argon-high` (or the next provider passing the usage gate) with mandatory source URLs.
- **Other specialists (`architect-pm`, `secops-finops`, `release-manager`, `support-csm`):** default to Claude for their tier (Strong Opus high or Workhorse Sonnet medium), falling back per `.claude/model-routing.md`.

| Provider | Role loading | Notes |
| :--- | :--- | :--- |
| **Claude** | Role files in `.claude/agents/*.md` | `model:` and `effort:` in role frontmatter apply only under `claude --agent <role>`. Hooks in `.claude/settings.json` run automatically. |
| **Antigravity** | Spec says read `<repo root>/.claude/agents/<role>.md` first, plus `AGENTS.md` and `.agents/skills/` | Effort is in the model id (`gemini-4-argon-high`, `gemini-4-argon-medium`, `gemini-3.8-flash`). Local host only until remote attach is supported. |
| **Grok** | Spec says read `<repo root>/.claude/agents/<role>.md` first | One model, `grok-4.7`. `elon`, `architect-pm` and `secops-finops` never take Grok. `script/worker-startup.sh --agent grok --on <environment>` starts only on a host listed under `grok_hosts` in the fleet config, and pre-trusts a new local worktree so Grok does not stop at its folder trust question. |

Sources of truth: `AGENTS.md` for conventions; `.claude/agents/` for role boundaries on every provider (a role change merges on a passing non-author Verdict with the coordinator's approval and an `Owner-approved:` commit trailer; the owner approves only a change that loosens a safety limit). Skills come in three tiers: Tier 1 general skills from `~/dotfiles/.agents/skills/`, Tier 2 team skills from `~/dotfiles/templates/agent-team/.agents/skills/` linked on each machine by `script/setup-agent-skills.sh`, and Tier 3 project-specific skills. Details: [Skills inventory](skills-inventory.md).

## 9. Tools

Every repeatable team step is backed by a script under `script/`, `.agents/skills/orca-team/`, or `bin/`:

- **Setup, adoption and skill sync:** `agent-team.sh`, `sync-mattpocock-skills.sh`, `check-skill-collisions.sh`, `bootstrap-asdf-tools.sh`, `bun-pin-check.sh`, `switch-login-shell-zsh.sh`, `agent-settings-check.py`, `backup-claude-desktop.sh`, `contribute-to-agents.sh`.
- **Coordinator, fleet and state sync:** `elon-startup.sh`, `new-coordinator.sh`, `take-over-coordinator.sh`, `orca-reply.sh`, `fleet-pull.sh`, `fleet-watch.py`, `fleet-workers.py`, `count-agents.sh`, `secrets-pack.sh`, `secrets-unpack.sh`, `secrets-sync.sh`.
- **Worker launch, usage gate and heavy gate:** `worker-startup.sh`, `start-remote-worker.sh`, `start-cursor-worker.sh`, `worktree-setup.sh`, `usage-gate.py`, `usage-gate-hook.py`, `heavy-gate.sh`, `heavy-gate.py`, `hw-probe.sh`, `remote-heavy.sh`, `run-scoped-tests.py`, and the `orca-team` helpers (`worker-start-check.sh`, `worker-watch.sh`, `worker-panes.sh`, `worker-pane.sh`, `worker-pane-close.sh`, and `worker-pane-retry.sh`, the sourced close and verify loop the two pane scripts share).
- **Checks, review and merge:** `coordinator-publication.sh`, `head-checks.sh`, `head-checks-tsc.sh`, `live-check-server.sh`, `pr-review.sh`, `post-verdict.sh`, `ship.sh`.
- **Cleanup, audits and weekly maintenance:** `wrap-up.sh`, `worktree-idle.py`, `team-audit.sh`, `script/team-audit-metrics.ts`, `weekly-update.sh`, `prepend-recent-change.ts`, `shellcheck-dotfiles.sh`.

Full per-tool reference table: [Agent team reference](team-reference.md).

## 10. Shared and per project

The generic source is `~/dotfiles/templates/agent-team/`. Each project holds filled-in copies (`docs/agents/team.md`, `docs/agents/team-facts.md`, `docs/agents/deploy-facts.md`, `.claude/agents/`, `.claude/model-routing.md`), and its agents follow those. Team skills are not copied into a project: edit `templates/agent-team/.agents/skills/`, and machines read them through links from `script/setup-agent-skills.sh`. `agent-team.sh sync <project>` removes any older copy, and `agent-team.sh check` reports one as drift. `script/weekly-update.sh` keeps upstream Matt Pocock skills, pstack skills, Bun and Node LTS pins current across three tested PRs that merge on green checks and a Verdict.

### Template pin

A merged template change must never turn open project PRs red. `agent-team.sh sync` writes `.claude/agent-team-pin`, the dotfiles commit it rendered from. `head-checks.sh` runs `agent-team.sh check --pinned`, which extracts dotfiles at that commit and checks the project against it, so a PR's result depends only on the PR. A project without a pin gets the plain check against current dotfiles. A pin that is not in the dotfiles history counts as drift.

Moving a project to a newer template is its own PR. When `ship.sh` merges a dotfiles PR that touched `templates/agent-team/` or `script/agent-team.sh`, it starts `script/template-sync-pr.sh` in the background (log in `~/.claude/state/template-sync-after-ship.log`; a failure never undoes the merge). For each project in the fleet-pull config whose repo is in `verdict_from_repos`, that script syncs a worktree off `origin/main` and, on a diff, opens or reuses a PR from branch `team-sync/<last template commit sha>`, one run per project at a time (a lock under `~/.claude/state/template-sync.lock.d`, a second run prints `busy`). On green checks it lands the PR with `ship.sh --verdict-from <owner>/dotfiles#N`. `ship.sh` checks the copies against the render at the PR head's pin, and refuses a pin that is not an ancestor of dotfiles `origin/main` or that moves backwards. That one run can fail or be missed (a merge outside `ship.sh`), so each `fleet-watch` pass also runs `agent-team.sh check --project-only` on a throwaway worktree of each pinned `repo_roots` checkout's `origin/main` and, on drift, starts `template-sync-pr.sh --project <checkout>` for it (log `~/.claude/state/template-sync-reconcile.log`). A project is retried after a new template commit on dotfiles `origin/main` or after 6 hours. `fleet-watch` reports a pin that lags a template change for more than 24 hours, and a bump PR left red (`~/.claude/state/template-sync.json`).
