# Shared team skills and usage caps

Status: Accepted  
Date: 2026-10-06

The agent team skills (`elon`, `ceo`, `crew`, `tl`, `deploy`) were copied by hand into each project and drifted apart. The usage gate (a cap on AI usage per provider) was only a written rule in the role files, so nothing stopped a worker from starting when a provider was out of quota.

## Decision

1. **Three tiers of skills.**
   - General skills (for example `orchestration`) live only in `~/dotfiles/.agents/skills` and are linked into `~/.claude/skills` and `~/.agents/skills`. A project does not copy them.
   - Team skills `elon`, `ceo`, `crew`, `tl` and `deploy` have one source, `templates/agent-team/.agents/skills`, product neutral. `script/setup-agent-skills.sh` links them on each machine to the dotfiles checkout, `script/agent-team.sh sync` removes any older copy from a project, and `agent-team.sh check` reports a Tier 2 copy or link left in a project as drift. Project facts live in the project: `docs/agents/team-facts.md` and `docs/agents/deploy-facts.md`.
   - Project skills stay in the project's `.agents/skills`, with links from `.claude/skills` and `.cursor/skills`.
2. **Machine links, not project copies, for team skills.** A project holds no copy of a Tier 2 skill, so a copy cannot go stale. A machine without `~/dotfiles` does not have the skills. `agent-team.sh check` flags a copy that reappears in a project.
3. **The usage gate is enforced by a hook.** `script/usage-gate-hook.py` (PreToolUse on Bash) runs `usage-gate.py check` for every `orca orchestration worker-start` of a claude or codex worker, and denies it when the provider has used its daily cap (see point 4) in a day or 95% of the week. The check also holds back a reserve of 1% of the week for each worker already running on that provider (`orca orchestration worker-list`), so a start is refused a little before the cap and running workers keep room to finish. A missing or stale reading (exit 4) and other agents are allowed with a warning. Elon and the Tech Lead then pick the next provider in the fallback order.
4. **The thresholds are owner reserved.** The weekly ceiling is 95%. The daily cap was a fixed 12% of the week; since 2026-10-09 it is what is left under the ceiling at the start of the day, divided by the days left until the weekly reset (a partial last day counts as a fraction), so a light day leaves more for the rest of the week and a heavy one less. `--cap N` still fixes it. Agents do not change them.

## Consequences

A fix to a team skill is made once here and reaches every machine through its link into the dotfiles checkout. A copy placed in a project is flagged by `agent-team.sh check` and removed by `agent-team.sh sync`, so project specific facts go in the facts files. The gate fails open when a provider has no reading, and a stale reading counts as no reading, so a provider can run past the ceiling unnoticed until a fresh reading exists. The gate reads Antigravity per model pool from its local language server and applies the 95% ceiling; Cursor reads its billing cycle usage. The hook lives in `~/dotfiles`, so a machine without dotfiles is not gated. The gate checks only at `worker-start`; a running worker is never stopped. "Used today" is the whole account's weekly percentage now minus its value at the start of the local day (codex: the last session event before midnight, claude: the first statusline reading of the day), so a provider's own app sessions outside Orca count against the cap.
