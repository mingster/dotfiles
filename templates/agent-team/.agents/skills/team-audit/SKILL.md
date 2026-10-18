---
name: team-audit
description: Monthly audit of the agent team files (role files, team skills, model-routing.md, team docs) for drift, contradictions and unused skills. Use with /team-audit, on the first Monday of the month in the daily run, or after a large team file change.
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

## 3. Output

A `worker_done` (or a reply to Elon) with: the script result, each finding with file and line, and the proposed change. Make agreed edits on `mingster/team-audit-<date>` in all three places (dotfiles template, riben.life, PSTV), keep `team-audit.sh` clean and `sync-team-skills.sh --check` passing, and commit only on that branch.
