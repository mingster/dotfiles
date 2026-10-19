---
name: team-audit
description: Audit agent roles, team skills, model-routing.md and team docs when the owner says "team-audit". Produce structural fixes and report delivery and post-merge metrics.
---

# Team audit

Run only when the owner says "team-audit", by architect-pm (or Elon). Edits only on a branch in your own worktree; the Tech Lead publishes and merges reviewed branches under `.claude/model-routing.md`; Elon owns priorities and owner decisions.

## 1. Deterministic checks

Run `~/dotfiles/script/team-audit.sh` (default projects `~/projects/riben.life` and `~/pstv`; pass project roots to override). Each `FINDING <check>` line names the file. Fix every finding or explain why it is a false positive (a line may opt out with the comment `team-audit: allow`). For a `sync` finding, edit the dotfiles source and run `~/dotfiles/script/sync-team-skills.sh <project>`; never edit a generated copy. For an `mp-upstream` finding (the vendored Matt Pocock skills are behind upstream, or a role names one that is missing), run `~/dotfiles/script/sync-mattpocock-skills.sh`, review `git diff` of `.agents/skills`, and commit it on the team-audit branch in dotfiles. A `WARN mp-upstream` line means the network check was skipped; rerun later. Never run `skills update`.

## 2. Judgement review

Use the `writing-for-agents` skill to assess duplication, pointer quality, relevance and instruction structure in each project's roles, model routing, team docs, daily run and skills. For a failure tied to a particular session, use the `retro` skill on that session instead of recreating its process here.

Add these team checks:

- **Authority conflicts:** owner rules and `docs/agents/team.md` win, then `.claude/model-routing.md` for provider and shipping policy, then the role file. Name both file lines when rules disagree. Orca's `orchestration` skill owns runtime lifecycle authority.
- **Unused skills:** check the last 30 days of available session logs for skill invocations and file loads. A harness may read `SKILL.md` directly; no slash command match alone does not prove disuse. Propose removal with the evidence and log coverage; do not remove.
- **Project drift:** compare role and skill copies with the dotfiles template. Product facts may differ; team policy should have one source.

## 3. Role performance

**Encode Lessons in Structure:** review every role defined in each project's `.claude/agents/`, including roles with no activity, and turn evidenced failures into a lint, check, script or role-file rule rather than advice.

Elon appends observations as work happens to `~/.claude/state/team-observations.md`, one line per observation with date, project, role, evidence reference and proposed change. This log is private. Never copy it verbatim into a repository or put it in `~/.claude/notes`, which is public.

1. Read the unconsumed observations and the available Orca escalations and `worker_done` reports since the last audit, using the official `orchestration` guide to inspect the records. State the date range and report coverage. If a source is missing or unavailable, report that gap without treating it as a clean performance record.
2. For each role, give evidence of its decisions and outcomes, then produce a concrete structural fix (lint, check, script or role-file rule) for an evidenced recurring failure. Use sanitized evidence references rather than private log text. For an inactive role, record no activity and the evidence gap; mark a proposal provisional when there is insufficient evidence to justify adoption. Apply fixes within standing authority; route policy and reserved changes through Elon, preserving owner gates.
3. After recording the review, mark each consumed observation in the private log with `audited: YYYY-MM-DD` using the audit date. Preserve the observation and leave unreviewed entries unmarked.

Completion requires one performance entry for every role, with evidence or an explicit evidence gap, justified structural fixes and their verification (or a named approval gate), plus the consumed markers in the private log.

Every audit also removes at least one rule, check, hook or brief step, and reports what it removed (or why nothing qualified).

## 4. Metrics since the last audit

Record the previous audit date and current cutoff, with source references and coverage. Report ticket-start-to-merge time from the first recorded work start to confirmed merge, per ticket and as a median with sample count; list unmerged tickets separately. Report post-merge problems as counts of reopens and hotfixes, linked to the affected merged tickets, and distinguish overlapping incidents. Missing audit dates, timestamps or sources mean unknown, never zero.

Report lead escalations to Elon since the last audit: count the tagged lines in each project's lead `.scratch/escalations.md` by tag (`rule-covered`, `owner-decision`, `hard-stop`, `cross-project`). Every `rule-covered` escalation is a failure of the lead's standing authority: name it and fix the rule or the brief so the lead decides it next time. Untagged or missing logs mean unknown.

## 5. Output

A `worker_done` (or a reply to Elon) with: the script result, each finding with file and line, and the structural fix with verification or its approval gate, plus every role's performance entry, both metrics and the evidence coverage. Make agreed edits on `mingster/team-audit-<date>` in all three places (dotfiles template, riben.life, PSTV), keep `team-audit.sh` clean and `sync-team-skills.sh --check` passing, and commit only on that branch.
