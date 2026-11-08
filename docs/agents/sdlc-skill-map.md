# SDLC skill map

Which role owns each SDLC stage and recurring job, which Matt Pocock or team skill it runs, and how the 2026-11-06 team guideline applies them. Read it before changing a role file, the crew or elon skill, `model-routing.md`, a project `daily-run.md` or the Engineering workflow table in `.agents/claude/CLAUDE.md`.

## Two rules for invoking skills in Orca workers

1. **A `disable-model-invocation` skill runs only when named.** `grill-me`, `grill-with-docs`, `handoff`, `implement`, `improve-codebase-architecture`, `retro`, `to-spec`, `to-tickets`, `triage` and `wayfinder` carry the flag. Claude Code skips them in a role's `skills:` list and refuses them through the Skill tool; Antigravity hides them until the prompt names them. Because an Orca worker spec is not a typed slash command, the spec names the file path: "read `~/.agents/skills/<name>/SKILL.md` and follow it".
2. **`skills:` preloads the whole skill on every start.** Only `claude --agent <role>` reads frontmatter `skills:`; default Orca workers read the role body. Keep `skills:` limited to a role's primary skills (`qa-sdet` preloads `[tdd, code-review]`; `secops-finops` preloads `[code-review]`) and name on-demand skills in the role body with when to load them.

## Stage and job map

| Job | Owner | Skill or tool | Current rule |
| --- | --- | --- | --- |
| Intake and triage of an issue | `architect-pm`, Elon as maintainer | `triage` (agent brief per `AGENT-BRIEF.md`) | Each `ready-for-agent` issue carries `## Acceptance criteria`, `Requirement owner` and `Deleted` in one text (enforced by `script/team-audit.sh`). |
| Intent, Grill and Spec (Design) | `architect-pm` with Elon; `sales-marketing` for UI/wording; `secops-finops` for money | `capture-intent`, `grill-with-docs` (`grilling` and `domain-modeling`), `write-spec` (or `to-spec`) | One design document per feature (intent, spec and tickets) with one owner approval (`docs/agents/team.md`, Process 2026-11-06). Every spec committed since 2026-10-21 has a sibling `intent.md` and a `## Test plan` section. |
| Tickets | `architect-pm` | `to-tickets` (GitHub issues with blocking edges) | Invoked by file path; slices accepted specs into GitHub issues with test cases from `## Test plan` and native GitHub sub-issue / dependency links. |
| Implement | `fullstack-dev` | `implement` per ticket (drives `tdd`, ends with `code-review`); `tdd` on the fast path | Runs only the ticket's listed test cases and touched unit tests (red on `main`, green after) via `script/run-scoped-tests.py`; commits locally on its own branch and reports `worker_done`. |
| Bug diagnosis | `qa-sdet` reproduces, `fullstack-dev` fixes | `diagnosing-bugs`, then `tdd` | `qa-sdet` records a failing reproduction test; `fullstack-dev` makes it pass. |
| Head checks | GitHub Actions `Checks`, `fleet-watch.py` `issue_scan`, publication | `script/head-checks.sh` | Runs the repo's `.agents/head-checks.conf` checklist once on a trial merge of the PR head with `main` in a throwaway worktree under `script/heavy-gate.sh`, posting the `Checks` receipt. |
| Review | GitHub Actions `Review` workflow | `script/pr-review.sh`, `usage-gate.py pick --role reviewer` | After `Checks` pass on the PR head, a self hosted runner checks out `main` and runs a read only cold review with a cross family model; posts the `review` status and one `Review:` comment. Live proof stays with `qa-sdet` on app repos. |
| Merge conflicts | `fullstack-dev` | `resolving-merge-conflicts` | Used when rebasing or merging `origin/main` into a worker branch. |
| Publish and merge | Elon dispatches | `script/coordinator-publication.sh`, `script/lead-merge.sh` | Publication and merge workers; one `lead-merge.sh` batch per wake after `Checks: PASS` and `Verdict: PASS` (`verdict_carry` across clean `main` merges). |
| Architecture review and prototyping | `architect-pm` | `improve-codebase-architecture`, `codebase-design`, `prototype` | Loaded on demand; competing prototypes (Exhaust the Design Space) require owner approval via Elon. |
| Retro | Elon / `architect-pm` | `retro` | Runs on about one session in five (failures first) and after a task fails both rework rounds. |
| Session handoff and startup | Worker at budget or Elon at session start | `handoff`, `recall`, `ketchup` | Workers at 80% context or 120 turns write a `handoff` artifact; Elon runs `recall` then `ketchup` at session start. |
| Deploy and staging review | `release-manager`, `qa-sdet` | `deploy`, `staging-review` | Staging deploys daily at 19:00 Taiwan time, followed immediately by `/staging-review` and full regression; page-by-page review runs weekly; production deploys on the owner's explicit go. |
| Wrap-up | Elon / host schedule | `wrap-up` (`script/wrap-up.sh`) | Scheduled every 10 minutes on each host (`--scheduled`) and run after merges to clear finished worktrees, branches, terminals and temp files. |
| Team audit and weekly update | Orca schedule / `architect-pm` | `team-audit` (`script/team-audit.sh`, `bin/team-audit-metrics.ts`), `script/weekly-update.sh` | Orca runs the audit script and five metrics weekly for one line; `architect-pm` runs the full `/team-audit` skill on the owner's word; `weekly-update.sh` opens three upstream update PRs for owner review. |

## Pre-build grill gate (owner rule 2026-11-06)

A multi-role pre-build grill runs only for two categories:

* **Money** (payments, billing, refunds, ledger, credits, pricing or entitlements): `secops-finops`, `architect-pm` and Elon.
* **New UI pages:** `sales-marketing` and Elon, with phone screenshots of the design or prototype attached to the spec (`~/.claude/state/screenshots/<repo>/<issue>/`).
* **Owner approval:** the owner approves the grill result before build starts.
* **All other work:** no multi-role grill; Elon decides and records the decision on the issue.
