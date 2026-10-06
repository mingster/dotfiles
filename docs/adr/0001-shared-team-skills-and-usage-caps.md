# Shared team skills and usage caps

Status: Accepted  
Date: 2026-10-06

The agent team skills (`elon`, `ceo`, `crew`, `tl`, `deploy`) were copied by hand into each project and drifted apart. The usage gate (a cap on AI usage per provider) was only a written rule in the role files, so nothing stopped a worker from starting when a provider was out of quota.

## Decision

1. **Three tiers of skills.**
   - General skills (for example `orchestration`) live only in `~/dotfiles/.agents/skills` and are linked into `~/.claude/skills` and `~/.agents/skills`. A project does not copy them.
   - Team skills `elon`, `ceo`, `crew`, `tl` and `deploy` have one source, `templates/agent-team/.agents/skills`, product neutral. `script/sync-team-skills.sh` writes them into each project as committed copies with a stamp (source hash), and `--check` exits 1 on drift (hand edit, stale copy, missing link). Project facts live in the project: `docs/agents/team-facts.md` and `docs/agents/deploy-facts.md`.
   - Project skills stay in the project's `.agents/skills`, with links from `.claude/skills` and `.cursor/skills`.
2. **Committed copies, not symlinks, for team skills.** Cloud sessions and fresh clones have no `~/dotfiles`, so a link would point at nothing. A committed copy works anywhere. A project's SessionStart hook runs `sync-team-skills.sh --check` when the script exists and warns on drift, and the Tech Lead runs it before merging a PR that touches `.agents/skills`.
3. **The usage gate is enforced by a hook.** `script/usage-gate-hook.py` (PreToolUse on Bash) runs `usage-gate.py check` for every `orca orchestration worker-start` of a claude or codex worker, and denies it when the provider has used more than 12% of its weekly limit in a day or 95% of the week. A missing or stale reading (exit 4) and other agents are allowed with a warning. Elon and the Tech Lead then pick the next provider in the fallback order.
4. **The thresholds (12% daily, 95% weekly) are owner reserved.** Agents do not change them.

## Consequences

A fix to a team skill is made once here and reaches projects with `sync-team-skills.sh`, and an out of date copy is visible. A copy edited by hand in a project is overwritten or flagged, so project specific facts go in the facts files. The gate fails open when a provider has no reading, and a stale reading counts as no reading, so a provider can run past the ceiling unnoticed until a fresh reading exists. Providers without a reader (Cursor, Antigravity) are not gated. The hook lives in `~/dotfiles`, so a machine without dotfiles is not gated.
