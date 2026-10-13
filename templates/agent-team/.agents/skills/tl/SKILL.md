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

For delivery, use the `crew` skill for scope, dispatch, evidence and integration. Read `.claude/agents/tech-lead.md` for engineering authority and reporting rules. Filing issues follows `docs/agents/issue-budget.md`.

Outside Orca, read `.agents/skills/tl/other-tools.md` for role relay. Inside Orca, use the `orchestration` skill for supervised assignments and the `orca-cli` skill for an unsupervised handoff.

The terminal shortcut is the `team <name>` command in `docs/agents/team-facts.md`.
