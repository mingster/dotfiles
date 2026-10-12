---
name: team-audit
description: Monthly audit of the agent team files (role files, team skills, model-routing.md, team docs) for drift, contradictions and unused skills. Use with /team-audit, on the first Monday of the month in the daily run, or after a large team file change.
---

# Team audit

Run by architect-pm (or Elon). Edits only on a branch in your own worktree; Elon pushes and merges.

## 1. Deterministic checks

Run `~/dotfiles/script/team-audit.sh` (default projects `~/projects/riben.life` and `~/pstv`; pass project roots to override). Each `FINDING <check>` line names the file. Fix every finding or explain why it is a false positive (a line may opt out with the comment `team-audit: allow`). For a `sync` finding, edit the dotfiles source and run `~/dotfiles/script/sync-team-skills.sh <project>`; never edit a generated copy. For an `mp-upstream` finding (the vendored Matt Pocock skills are behind upstream, or a role names one that is missing), run `~/dotfiles/script/sync-mattpocock-skills.sh`, review `git diff` of `.agents/skills`, and commit it on the team-audit branch in dotfiles. A `WARN mp-upstream` line means the network check was skipped; rerun later. Never run `skills update`.

## 2. Judgement review

Read, in each project: `.claude/agents/*.md`, `.claude/model-routing.md`, `docs/agents/team.md`, `docs/agents/daily-run.md`, and the team skills in `.agents/skills/`. Then report:

- **Contradictions:** two files that give a different owner, order, model, provider or gate for the same thing. Owner rules (dated "owner rule" lines and `docs/agents/team.md`) win, then `.claude/model-routing.md` for models and the commit, push and merge rule, then the role file. Name both lines.
- **Duplication:** a rule restated in full outside its single source; replace it with a pointer.
- **Unused skills:** skills named in role frontmatter or `~/.agents/skills` with no use in the last 30 days of `~/.claude/projects/*/*.jsonl` logs (grep for `"skill":"<name>"` and `/<name>`). Propose removal; do not remove.
- **Drift between projects:** the same role file differs between riben.life, PSTV and the dotfiles template in a way that is not a product fact.

## 3. Output

A `worker_done` (or a reply to Elon) with: the script result, each finding with file and line, and the proposed change. Make agreed edits on `mingster/team-audit-<date>` in all three places (dotfiles template, riben.life, PSTV), keep `team-audit.sh` clean and `sync-team-skills.sh --check` passing, and commit only on that branch.
