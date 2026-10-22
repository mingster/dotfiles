# Pstack in Orca

Read this adapter before `SKILL.md` and the selected playbook. This is the pinned vendored runtime for the Tech Lead and engineering workers, with local Orca integration. No plugin installation, upstream scripts, automatic updates or Cursor cloud execution is authorized. The pin and license are in `docs/agents/pstack-attribution.md`. The first pilot is ticket #3810 after #3770 merges; adoption alone does not start that pilot.

## Our gates win

Existing project instructions, the assigned brief, standing authority, token budget, strike rule and owner approval gates override every upstream autonomy instruction. Do not change their numbers or widen scope because a playbook says to continue. Elon is the owner's only contact; workers ask the tech-lead, and the tech-lead routes owner decisions through Elon. Workers commit locally; the tech-lead publishes reviewed work. Release-manager retains its existing staging and production promotion authority, and production requires the owner's explicit go relayed by Elon. Do not send external messages merely because an upstream playbook suggests it.

Read `.claude/model-routing.md` and run `~/dotfiles/script/usage-gate.py` as prescribed there before dispatch or changing providers. One gate governs every provider and the entire team. A depleted provider never authorizes on-demand spending or bypassing a gate. Keep existing review, security, money, tenancy, exact-head and release evidence requirements. A skipped or blocked check is not a pass.

Internally, read each cited principle's leaf skill and name the principle and the decision it changed in briefs, review findings and worker reports. Elon translates these into plain language for the owner. Principles guide decisions; they do not grant new authority.

## Runtime and worker dispatch

The tech-lead and engineering workers run on Claude (owner 2026-10-22: Codex is removed from the agent team). Cursor is reserved for jobs needing their own machine, including E2E and browser smoke checks, and cross-model second-opinion reviews. Cursor has no on-demand spending: when its quota is exhausted, fall back to Claude under the same usage gate. A fallback without the needed machine or independent model family must report that gate blocked; it cannot claim equivalent verification. Source tests never stand in for a browser, device, provider, host or deployment check.

Map upstream model slugs, strong/fast tiers, `high` and `xhigh` through `.claude/model-routing.md` and available presets. Unsupported names are not literal CLI arguments. Provider policy lives in that routing document; this adapter never overrides it.

| Upstream concept | Orca execution |
| --- | --- |
| Subagent, Task tool, cloud subagent, `poteto-agent` | A supervised Orca worker with a complete local brief; no cloud worker. |
| Agent prompt | Include role, ticket, exact worktree and cwd, file allowlist, acceptance criteria, exact checks, full-suite permission, budget and escalation gates, verbatim role Standing authority, and absolute paths to this adapter, poteto-mode and selected leaf skills. |
| Start or fan out | Read `docs/agents/team.md` and the `orchestration` skill; create the supervised Run/tasks, start workers in plain terminals per `.claude/model-routing.md`, use `worker-panes.sh` according to its help and team facts, and respect capacity. |
| Agent result | Require `worker_done` with matching task and dispatch IDs, evidence, local commit and remaining gates. A terminal message alone does not settle a dispatch. |
| Review/fix iteration | Use a fresh worker for every fix round and an independent reviewer for the resulting head. Keep the existing strike rule; no iteration floor or broad fan-out overrides the brief or budget. |

Do not guess helper flags or run absent upstream scripts. Follow local helper documentation. Preserve role-specific restrictions: a reviewer cannot become a production-code fixer without an appropriate new assignment.

## Lead loop and handoff

**Orchestrate** maps to the tech-lead's existing run loop: classify scope, dispatch bounded work, answer within standing authority, inspect evidence, obtain required independent review of the full current head, integrate and report to Elon. Use `crew` for dispatch and delivery. Apply the existing review-by-risk rule; upstream fixed review lanes do not replace it. The tech-lead delegates code and reviews.

**Session pickup** and **Pause safely** use a worktree `.scratch/` handoff with ticket, branch and head, worker/dispatch IDs, rulings, completed and pending checks, baseline failures, next action and gates. At the existing rotation boundary ask Elon for rotation. Do not kill unknown processes, delete worktrees with unmerged commits or silently abandon active workers. Resume only after reading the handoff and reconciling current Git and dispatch state.

**Babysit**, **Opening a PR** and **Shipping** use the existing delivery contract and `script/lead-merge.sh --repo <owner/name> --pr <N> --head <sha>`. Workers stop at local commits; the tech-lead owns push, PR and merge. There is no PR CI: use recorded local checks and required exact-head review rather than waiting for or inventing CI success. The merge helper enforces current-head and owner-file gates. Deployment remains `/deploy` with the project's facts and owner production approval. Worktree cleanup follows `wrap-up`, after publication and successful merge are verified.

## Session start, approvals and corrections

`ketchup`, `recall`, `show-me-your-work`, `correct` and `unslop` are vendored next to poteto-mode. The gates above still win: workers never push or merge, these skills never deploy, and owner gates stay.

- **ketchup and recall.** The tech-lead and Elon run `recall` and then `ketchup` at every session start and every handoff, instead of reading only the handoff note. `recall` rebuilds context from this project's own session history (Claude Code keeps it under `~/.claude/projects/<slug>/`), the `.scratch/` handoff, Orca run state and `git` and `gh`. Its `why` sweep maps to `gh` issue and PR search; skip a source we do not have and say so. `ketchup` then lists every item waiting on the owner. Both stay read only: no code change, dispatch or message during the catch up. `bro` is vendored only as ketchup's voice; `/visualize` is not, so use Mermaid for diagrams.
- **show-me-your-work.** Elon logs each owner approval as one row: phase `approval`, the decision, the owner's message reference as why, the exact head sha it covers as evidence, result `approved`. An approval covers only that sha, so a new head needs a new row before a gated merge, and the tech-lead checks the merge head against the latest row. Keep the log at `.scratch/decisions.tsv` outside git. Its cross model review needs another model family; when only Claude is available, report that review as blocked, never as self reviewed.
- **correct.** When the owner corrects the same agent mistake twice, the tech-lead (engineering) or architect-pm (team docs) turns it into a lint, test, hook or script in the skill's order, with a check proven to fail on the past mistake. Keep the rule table in `docs/agents/team.md`, never in `AGENTS.md`. A hook or protected path change needs the owner's read before merge.
- **unslop.** Run it over agent documents, briefs, reports and owner messages. It cuts wording, never a rule, gate or number. Our doc style overrides its rule 13: parentheses are allowed and dashes are never punctuation.

## Skill and tool translations

Read a local skill before using it and confirm it exists. A referenced upstream skill or script that is not vendored is not implicitly available.

| Upstream route | Local route |
| --- | --- |
| `architect`, `interrogate`, `why`, `how`, design exploration | `grilling`, `domain-modeling`, `codebase-design`; use the project's spec workflow only when assigned. |
| `tdd`, bug investigation, runtime/trace forensics | `tdd`, `diagnosing-bugs`, targeted local tools and project evidence. |
| `benchmark-checklist`, eval, hillclimb, performance | A scoped measurement plan through `diagnosing-bugs`; record baseline, workload, command, environment and repeatable result. Skip unavailable instrumentation and report the gap. |
| `arena`, `swarm`, autopilot, multi-phase plan | Supervised Orca dispatch and `crew`; no hidden workers or broadened authority. |
| `technical-writing`, `reflect` | Delivery-contract evidence, `writing-for-agents` for agent documents, and existing handoff/retrospective workflow when assigned. No automatic memory writes. |
| `deslop`, `no-comments`, `bugbot` | Local `code-review` with the required independent reviewer; retain useful comments and make only allowlisted fixes. |
| `control-ui`, `control-cli` | Local `agent-browser` or `computer-use` for authorized machine work; normal documented shell commands for CLI work. Apply the Cursor reservation and fallback policy above. |
| `create-skill` | Local `writing-for-agents` and `skill-creator` only for an assigned skill change; otherwise skip. |
| `in-cloud`, cloud-only tools | Skip; use local supervised workers for authorized equivalent work. |
| Short principle names | Resolve to the vendored `principle-<name>/SKILL.md`; read it before citing it. |
| Any other unavailable route or bundled script | Skip and state what was omitted and why; ask the tech-lead only if it blocks acceptance. |

The vendored upstream harness adapter applies only when running a Claude worker; this Orca adapter takes precedence. The vendored benchmark-checklist is a principle dependency; apply its measurement guidance through local tools. Do not fetch or install omitted dependencies to satisfy a playbook.
