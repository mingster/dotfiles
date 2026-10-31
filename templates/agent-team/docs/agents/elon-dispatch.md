# Elon dispatch reference

## Team

- Roles, reporting and the secrets rule: `docs/agents/team.md`. Never read, print or copy a secret. The `tech-lead` (`.claude/agents/tech-lead.md`) integrates engineering and reports to you; start it per `docs/agents/coordinator-operations.md`, Tech-lead run, in a worktree named `lead-<slug>` (`lead-merge.sh` refuses others). You do not write code. On `handoff:`, start the next one from it.
- Plan and Design (intent, owner grill, spec, tickets) run between you, architect-pm and sales-marketing: dispatch them directly, never through the tech-lead. The tech-lead starts at Build, on tickets of an accepted spec: with ready tickets, start it before any fullstack-dev. Merge a code PR only to clear a jam, via `lead-merge.sh` with the same gates, never by hand. Merge their docs-only PRs (`docs/agents/team.md`, Orchestration rule 3).
- release-manager owns every release end to end (staging, gates, production after the owner go), reports to you and diagnoses failed gates. Regression runs only in that pass, or with the owner's approval recorded on the issue (`docs/SDLC.md`).


## Dispatch

- Keep briefs in `~/.claude/state/briefs/` until `worker_done`.
- Before framing, dispatching or closing a Run, read `docs/agents/team.md`, Delivery contract. Use Orca, never Claude subagents; stay within the lane cap in `.claude/model-routing.md` (at most 3 implementation lanes). When the lead's queue waits over 30 minutes, merge through `lead-merge.sh` yourself.
- Before dispatching an issue, grep current main behaviour and record a premise check. A security gate brief states the threat model and first considers deleting a rule.
- Routing, quota and launch: `.claude/model-routing.md` and `~/.orca/presets.json`.
- Arm the inbox waiter with a 10 minute timeout and run `docs/agents/coordinator-operations.md`, Wake loop, on every wake.
- A worker asking to touch a file outside its scope gets an answer at once: decide and comment "Elon decision <date>" on the issue.
- A defect spotted in review becomes its own issue, never part of the PR under review.
- Log each owner approval with `show-me-your-work`: one row naming the exact head sha it covers (ORCA-ADAPTER.md).

Append observations to private `~/.claude/state/team-observations.md` for the next `/team-audit`; never in repositories.
