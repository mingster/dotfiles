# SDLC skill map

Which role owns each SDLC stage and recurring job, which Matt Pocock or team skill it runs, and how the 2026-11-06 team guideline applies them. Read it before changing a role file, the elon skill, `model-routing.md`, a project `daily-run.md` or the Engineering workflow table in `.agents/claude/CLAUDE.md`.

## Two rules for invoking skills in Orca workers

1. **A `disable-model-invocation` skill runs only when named.** `grill-me`, `grill-with-docs`, `handoff`, `implement`, `improve-codebase-architecture`, `retro`, `to-spec`, `to-tickets`, `triage` and `wayfinder` carry the flag. Claude Code skips them in a role's `skills:` list and refuses them through the Skill tool; Antigravity hides them until the prompt names them. Because an Orca worker spec is not a typed slash command, the spec names the file path: "read `~/.agents/skills/<name>/SKILL.md` and follow it".
2. **`skills:` preloads the whole skill on every start.** Only `claude --agent <role>` reads frontmatter `skills:`; default Orca workers read the role body. Keep `skills:` limited to a role's primary skills (`qa-sdet` preloads `[tdd, code-review]`; `secops-finops` preloads `[code-review]`) and name on-demand skills in the role body with when to load them.

## Stage and job map

| Job | Owner | Skill or tool | Current rule |
| --- | --- | --- | --- |
| Intake and triage of an issue | `architect-pm`, the coordinator as maintainer | `triage` (agent brief per `AGENT-BRIEF.md`) | Each `ready-for-agent` issue carries `## Acceptance criteria`, `Requirement owner` and `Deleted` in one text. |
| Intent, Grill and Spec (Design) | `architect-pm` with the coordinator; `sales-marketing` for UI/wording; `secops-finops` for money | `capture-intent`, `grill-with-docs` (`grilling` and `domain-modeling`), `write-spec` (or `to-spec`) | One design document per feature (intent, spec and units) with one owner approval (`docs/agents/team.md`, Process 2026-11-06). Every spec committed since 2026-10-21 has a sibling `intent.md` and a `## Test plan` section. |
| Units | `architect-pm` | `to-tickets` (GitHub issues with blocking edges) | Invoked by file path; slices accepted specs into GitHub issues with test cases from `## Test plan` and native GitHub sub-issue / dependency links. |
| Implement | `fullstack-dev` | `implement` per unit (drives `tdd`, ends with `code-review`); `tdd` on the fast path | Runs only the unit's listed test cases and touched unit tests (red on `main`, green after) via `script/run-scoped-tests.py`; commits locally on its own branch and reports `worker_done`. |
| Bug diagnosis | `qa-sdet` reproduces, `fullstack-dev` fixes | `diagnosing-bugs`, then `tdd` | `qa-sdet` records a failing reproduction test; `fullstack-dev` makes it pass. |
| Head checks | GitHub Actions `Checks` | `script/head-checks.sh` | Runs the repo's `.agents/head-checks.conf` checklist once on a trial merge of the PR head with `main` in a throwaway worktree under `script/heavy-gate.sh`, posting the `Checks` receipt. |
| Review and Verdict | GitHub Actions `Review` and `qa-sdet` verifier (`secops-finops` for money) | `script/pr-review.sh`, `code-review`, `script/post-verdict.sh` | After `Checks` pass, `pr-review.sh` runs the read only bot review in Actions, and `qa-sdet` (another model family) runs the change as a user would (parent against head) and posts the `Verdict:` line via `post-verdict.sh`. |
| Merge conflicts | `fullstack-dev` | `resolving-merge-conflicts` | Used when rebasing or merging `origin/main` into a worker branch. |
| Babysit and ship | `fleet-watch.py` 5 minute pass | `script/ship.sh` (replaces `script/lead-merge.sh`) | One babysit pass per open PR in `check` mode starts one fix worker or a Shipping run (`ship.sh`), which checks `git patch-id` against the Verdict head, squash merges, and reads back as `MERGED`. |
| Architecture review and prototyping | `architect-pm` | `improve-codebase-architecture`, `codebase-design`, `prototype` | Loaded on demand; competing prototypes (Exhaust the Design Space) require user approval via the coordinator. |
| Retro | The coordinator / `architect-pm` | `retro` | Runs on about one session in five (failures first) and after a task fails both rework rounds. |
| Session handoff and startup | Worker at budget or the coordinator at session start | `handoff`, `recall`, `ketchup` | Workers at 80% context or 120 turns write a `handoff` artifact; the coordinator runs `recall` then `ketchup` at session start. |
| Deploy and swarm live lanes | `release-manager`, `qa-sdet` | `deploy`, `swarm` | Staging deploys daily at 19:00 Taiwan time, followed immediately by the pstack `swarm` live lanes and full regression; page-by-page review runs weekly; production deploys on the user's explicit go. |
| Worktree cleanup | The coordinator / host schedule | pstack `worktree-cleanup` (`script/wrap-up.sh`) | Scheduled every 10 minutes on each host (`--scheduled`) and run after merges to clear finished worktrees, branches, terminals and temp files. |
| Team audit and weekly update | Orca schedule / `architect-pm` | `team-audit` (`script/team-audit.sh`, `script/team-audit-metrics.ts`), `script/weekly-update.sh` | Orca runs the audit script and five metrics weekly for one line; `architect-pm` runs the full `/team-audit` skill on the user's word; `weekly-update.sh` opens three upstream update PRs for user review. |

## Pre-build grill gate (user rule 2026-11-06)

A multi-role pre-build grill runs only for two categories:

* **Money** (payments, billing, refunds, ledger, credits, pricing or entitlements): `secops-finops`, `architect-pm` and the coordinator.
* **New UI pages:** `sales-marketing` and the coordinator, with phone screenshots of the design or prototype attached to the spec (`~/.claude/state/screenshots/<repo>/<issue>/`).
* **Owner approval:** the owner approves the grill result before build starts.
* **All other work:** no multi-role grill; the coordinator decides and records the decision on the issue.
