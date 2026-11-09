# Agent team

{{PROJECT_NAME}} is operated by its human user and a team of AI agents: the coordinator (CEO) and specialist roles. The user talks to the coordinator, who delegates work and contacts the user only for a decision the coordinator cannot make. Role files live in `.claude/agents/`; this file lives once in `~/dotfiles/templates/agent-team/docs/agents/team.md`, and project differences go in `docs/agents/team-facts.md` only (deploy facts in `docs/agents/deploy-facts.md`).

Every role works through pstack `poteto-mode` and `.agents/skills/orca-adapter/ORCA-ADAPTER.md`. This file holds only facts and the rule table; it never restates a pstack principle or playbook. GitHub issues and PRs are the state of record.

| Role | File | Primary output |
| --- | --- | --- |
| The coordinator (CEO) | `elon.md` | Priorities, user contact, dispatch |
| architect-pm | `architect-pm.md` | One document per feature (intent, spec and units), issue triage, weekly list |
| fullstack-dev | `fullstack-dev.md` | Isolated branch with its own tests. Cursor `grok-4.7-xhigh`; Claude only when that quota is out |
| qa-sdet | `qa-sdet.md` | Verifier Verdict (`script/post-verdict.sh`), Playwright runs, weekly swarm live lanes |
| secops-finops | `secops-finops.md` | Money and auth PR reviews, weekly reconciliation |
| support-csm | `support-csm.md` | Ticket triage, reply drafts and recurring pain points |
| release-manager | `release-manager.md` | Staging on the daily schedule, production on the user's go, rollback plan (a rollback still needs the user) |
| sales-marketing | `sales-marketing.md` | Positioning, acquisition plans, growth experiments, weekly numbers |

| Severity | Meaning | Action |
| --- | --- | --- |
| P0 | Critical security, financial or production outage | Hotfix immediately; involve SecOps |
| P1 | Core workflow broken without a workaround | Hotfix immediately |
| P2 | Issue with a workaround or limited impact | Normal queue |
| P3 | Cosmetic or wording issue | Normal queue |

Usage gate by coordinator host: `usage-gate-hook.py` gates every worker start from Claude Code (`.claude/settings.json`), Cursor (`~/.cursor/hooks.json`) and Antigravity (`~/.gemini/config/hooks.json`). The Cursor and Antigravity entries come from `~/dotfiles/script/setup-cursor.sh` and `setup-antigravity.sh`; a coordinator that starts workers from either IDE first confirms its entry is installed, and otherwise runs in Claude Code.

Before judging engineering reviews or tests, the coordinator reads `~/dotfiles/templates/agent-team/docs/agents/engineering-integration.md`. Release failure classification follows `.agents/skills/deploy/SKILL.md`, Test noise.

## Rule table

Each rule names what enforces it. "none" means only the agent's reading holds it; those rows are follow up work. Before adding a rule, step or check, apply The Algorithm (row below).

| Rule | Enforcer |
| --- | --- |
| **The Algorithm:** apply `principle-the-algorithm` before any new rule, step or check. The PR names the requirement it questioned and what it deleted. | none |
| **User decisions:** pricing, legal, production and irreversible data are never declined by the team, only pushed back to the user with evidence. | none |
| **Plan approval (user 2026-11-06):** the user approves only new features, new UI pages, prices and money rules. The coordinator decides the rest and records it on the issue. | none |
| **Pre-build grill gate (user 2026-11-06):** a multi role grill runs only for money (payments, billing, refunds, ledger, credits, pricing or entitlements) with secops-finops, architect-pm and the coordinator, and for new UI pages with sales-marketing and the coordinator. The user approves the result before build. | `.claude/hooks/guard-bash.py` (grill check on build worker starts) |
| **Role changes (user 2026-10-31):** a change to a role definition (`.claude/agents/`, other provider role files, canonical role templates) needs the user's explicit approval of the concrete diff. The coordinator cannot approve for the user; silence, QA PASS or Checks PASS is not approval. Each commit carries `Owner-approved: <owner> <date> (<where approved>)`. | `script/team-audit.sh` (flags commits from 2026-11-03 without the trailer), `script/ship.sh` |
| **Gated actions:** only the user approves messages to customers, partners or the public, closing customer tickets, refunds, credits, discounts, coupons, subscription changes, production data writes, direct production server access, production deploys, force pushes, rollbacks, and accepting or rejecting an intent or spec. | `.claude/hooks/guard-bash.py` (production push, force push, approval scope); none for the rest |
| **Orca dispatch:** dispatch only through Orca orchestration; the in flight count comes from the fleet caps and the usage gate. | `script/usage-gate.py`, `usage-gate-hook.py` |
| **Allowed scripts:** "call no scripts" bans ad hoc coordination scripts only. The usage gate, `heavy-gate.sh`, `lead-merge.sh` and worker-watch stay. | `.claude/hooks/guard-bash.py` (un-gated heavy jobs) |
| **Publication:** the PR owner writes the branch; only the coordinator publishes and merges. | `script/lead-merge.sh`, `script/team-audit.sh` (merge wording) |
| **Stall detection:** stays on worker-watch. | `~/dotfiles/.agents/skills/orca-team/worker-watch.sh` |
| **Child ledger:** the coordinator keeps a ledger row for every child (task ID, dispatch ID, terminal, worktree, branch, full head SHA, state, next actor, evidence path). | none |
| **Background waits:** every wait runs in the background with a timeout; in Claude Code as its own Bash call with `run_in_background: true`, never a shell `&`. | `.claude/hooks/guard-bash.py` (trailing `&` on `check --wait`) |
| **No run-use for workers:** workers and child coordinators never run `orca orchestration run-use`. The coordinator rebinds with `run-use --id <run>` after a restart. | none |
| **Release settled workers:** every settled child, including FAILED, gets `worker-release` and its ended panes closed. | `script/wrap-up.sh` |
| **Reworks:** at most 2 reworks per PR, then the `needs-elon` label. | `script/pr-review.sh` |
| **Extra Strong review (user 2026-10-31):** extra Strong cross review only for money transactions, or when the coordinator or the user asks for it on that issue. | `script/pr-review.sh` (money paths) |
| **Verdict:** a PASS Verdict includes `Command: <exact test command run>`. Never edit or minimize a Verdict; post a new one. | `script/post-verdict.sh`, `script/ship.sh` |
| **Verdict carry (user 2026-10-23):** a PASS survives a rebase when the `git patch-id --stable` of `merge-base(origin/main, head)..head` matches the Verdict head. | `script/ship.sh` (`verdict_carry`) |
| **Head checks (user 2026-10-27):** proving commands include every `.agents/head-checks.conf` command for the changed files, with `shellcheck --severity=error` on each changed `.sh`, once, at the head. | `script/head-checks.sh` |
| **WIP cap (user 2026-10-23):** at most 6 open PRs per project; at 6, start no new feature unit. Test fix, hotfix and user UI look PRs are exempt. | none |
| **One PR per fix batch (user 2026-10-23):** fixes from one regression run or failing area go in one PR. | none |
| **Copy at the spec (user 2026-10-23):** the spec and each unit carry the exact new strings in tw, en and jp; the user's spec acceptance approves them. | none |
| **Native copy (user 2026-10-21):** `en` is fluent American English and `jp` natural Japanese, never word for word from `tw`. A menu or button name quotes the real label in that locale's file. | none |
| **New UI page (user 2026-10-26):** the user approves a new page at spec time from phone screenshots of the design or prototype. Screenshots go in `~/.claude/state/screenshots/<repo>/<issue>/`. | none |
| **Straight to staging (user 2026-10-23):** release-manager promotes trunk to staging after merges. Production needs the user's go per release. Japanese homepage copy needs a native reader before launch. | none |
| **Heavy jobs (user 2026-11-08):** Playwright and production builds run through `~/dotfiles/script/heavy-gate.sh --weight 2`; a long regression sets `HEAVY_GATE_CLASS=long`; full `tsc` uses `--measure`. Only the coordinator runs `hw-probe.sh --calibrate`. | `.claude/hooks/guard-bash.py`, `script/heavy-gate.sh` |
| **Strikes:** follow the project's token budget and strike rule in `AGENTS.md`. | `.claude/hooks/strikes.py` |
| **Zero secrets:** never print env files, secrets or keys to output or markdown; never open a secret file with a printing command. | `.claude/hooks/guard-bash.py` (secret readers, `.env` copies) |
| **Push an explicit branch (user 2026-10-23):** `git push origin HEAD:refs/heads/<branch>`, never a bare `git push`. | `.claude/hooks/guard-bash.py` (push to a protected branch) |
| **Close browsers (user 2026-10-28):** a worker that starts a browser with its own debugging port stops it by PID before `worker_done`. | `script/wrap-up.sh` |
| **No substitute tooling (user 2026-10-20):** never replace a standard team mechanism (Orca orchestration, GitHub Actions, hooks, gates, deploy scripts, worker lifecycle) with self built tooling without the user's approval. | none |
| **One unit, one session:** start a fresh session for a new unit; keep `active_run.md` current for long tasks. | none |
| **Own your files:** isolated branches and worktrees; no concurrent edits to one file. | none |
| **Issue budget:** search before filing (`gh issue list --search`); an issue names the change, an observable done condition, the requirement owner, a `Deleted:` line and the owner role; a bug carries its P label. A small PR finding is fixed in that PR, otherwise one follow up issue per PR. | none |
| **Labels:** `blocked` names what and who it waits on and never sits with `ready-for-agent`. | `script/team-audit.sh` (labels) |
| **Process findings:** log them with `~/dotfiles/script/team-audit.sh --log "<finding>" "<evidence>"`. | `script/team-audit.sh` |
