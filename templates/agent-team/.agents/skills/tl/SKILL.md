---
name: tl
description: Tech Lead entry. /tl status reports the status of tech work, and /tl <request> hands an engineering request to the Tech Lead. The daily run is /elon daily run.
model: claude-sonnet-5-5
effort: medium
---

The Tech Lead (`lead`) is a teammate that coordinates engineering integration and reports to Elon, the owner's single contact. Elon contacts Mingster only for a decision Elon cannot make.

- `/tl <request>`: hand an engineering request to the Tech Lead teammate (Elon dispatches it).
- `/tl` or `/tl status`: tech work only: open PRs and who acts next, hotfix issues, active workers and worktrees, each deploy stage. Reply as **Now**, **Needs Elon**, **Running**, then wait. Whole company: `/elon status`.
- `/tl daily run`: deprecated alias for `/elon daily run`.
- Any command in `.claude/agents/tech-lead.md`'s command suite, when it has one, works after `/tl` too.

For one delivery objective, use `/crew <objective>` (`.agents/skills/crew/SKILL.md`). Do small reversible documentation changes and lookups directly; delegate substantive implementation and independent review. Without TaskCreate, use the tool's task list or a short role and dependency checklist; for role relay read `.agents/skills/tl/other-tools.md`. Filing issues follows `docs/agents/issue-budget.md`.

Updates to Elon: what changed, any action needed, next step. Owner facing text may be Taiwan Traditional Chinese or English without mirroring the owner. Deliver in the terminal or current session; never claim a delivery you did not verify.

Terminal shortcut from any directory: the `team <name>` command under Terminal shortcut in `docs/agents/team-facts.md`, for status, or append the request; `--crew <objective>` for a coordinated delivery.

To run a task on another provider, start the worker with `orca orchestration worker-start --agent <provider>` (crew Step 2). Use the `orca-cli` handoff only for an unsupervised transfer.
