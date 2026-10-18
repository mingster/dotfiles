---
name: team-audit
description: Weekly audit of every agent role, team skills, model-routing.md and team docs for performance, drift, contradictions and unused skills. Use with /team-audit, every Monday in the daily run, or after a large team file change.
---

# Team audit

Run by architect-pm (or Elon). Edits only on a branch in your own worktree; the Tech Lead publishes and merges reviewed branches under `.claude/model-routing.md`; Elon owns priorities and owner decisions.

## 1. Deterministic checks

Run `~/dotfiles/script/team-audit.sh` (default projects `~/projects/riben.life` and `~/pstv`; pass project roots to override). Each `FINDING <check>` line names the file. Fix every finding or explain why it is a false positive (a line may opt out with the comment `team-audit: allow`). For a `sync` finding, edit the dotfiles source and run `~/dotfiles/script/sync-team-skills.sh <project>`; never edit a generated copy. For an `mp-upstream` finding (the vendored Matt Pocock skills are behind upstream, or a role names one that is missing), run `~/dotfiles/script/sync-mattpocock-skills.sh`, review `git diff` of `.agents/skills`, and commit it on the team-audit branch in dotfiles. A `WARN mp-upstream` line means the network check was skipped; rerun later. Never run `skills update`.

## 2. Judgement review

Use the `writing-for-agents` skill to assess duplication, pointer quality, relevance and instruction structure in each project's roles, model routing, team docs, daily run and skills. For a failure tied to a particular session, use the `retro` skill on that session instead of recreating its process here.

Add these team checks:

- **Authority conflicts:** owner rules and `docs/agents/team.md` win, then `.claude/model-routing.md` for provider and shipping policy, then the role file. Name both file lines when rules disagree. Orca's `orchestration` skill owns runtime lifecycle authority.
- **Unused skills:** check the last 30 days of available session logs for skill invocations and file loads. A harness may read `SKILL.md` directly; no slash command match alone does not prove disuse. Propose removal with the evidence and log coverage; do not remove.
- **Project drift:** compare role and skill copies with the dotfiles template. Product facts may differ; team policy should have one source.

## 3. Role performance

Every Monday, review every role defined in each project's `.claude/agents/`, including roles with no activity. Review behavior and outcomes, alongside the file review above.

Elon appends observations during the week to `~/.claude/state/team-observations.md`, one line per observation with date, project, role, evidence reference and proposed change. This log is private. Never copy it verbatim into a repository or put it in `~/.claude/notes`, which is public.

1. Read the unconsumed observations and the week's available Orca escalations and `worker_done` reports, using the official `orchestration` guide to inspect the records. State the date range and report coverage. If a source is missing or unavailable, report that gap without treating it as a clean performance record.
2. For each role, give evidence of its decisions and outcomes, then propose a concrete change to its role file, routing tier or dispatch brief template. Use sanitized evidence references rather than private log text. For an inactive role, record no activity and the evidence gap; mark a proposal provisional when there is insufficient evidence to justify adoption. Proposals remain proposals until agreed under existing authority and owner gates.
3. After recording the review, mark each consumed observation in the private log with `audited: YYYY-MM-DD` using the audit date. Preserve the observation and leave unreviewed entries unmarked.

Completion requires one performance entry for every role, with evidence or an explicit evidence gap, a proposal and its rationale, plus the consumed markers in the private log.

## 4. Output

A `worker_done` (or a reply to Elon) with: the script result, each finding with file and line, and the proposed change, plus every role's performance entry and the evidence coverage. Make agreed edits on `mingster/team-audit-<date>` in all three places (dotfiles template, riben.life, PSTV), keep `team-audit.sh` clean and `sync-team-skills.sh --check` passing, and commit only on that branch.
