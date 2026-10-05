# Model routing

Role frontmatter in `.claude/agents/` is the source of truth for Claude Code. This file adds the tiers and the fallback rule that apply to every provider.

## Tiers

| Tier | Use it for | Roles | Claude Code |
| --- | --- | --- | --- |
| Strong reasoning | Ambiguous decisions, specs, security and financial review | elon, architect-pm, secops-finops | `opus`, effort `max` for elon, `high` for the others |
| Workhorse | Implementation, coordination, QA, release, support, drafts | lead, fullstack-dev, qa-sdet, release-manager, sales-marketing, support-csm | `sonnet`, effort `medium` |
| Light | Clerical subtasks: formatting, extraction, changelog lines | none by default, chosen per task | `haiku` |

The main session starts on `sonnet`, `medium` (`.claude/settings.json`). Leave `CLAUDE_CODE_SUBAGENT_MODEL` unset so the frontmatter defaults apply.

Raise one assignment a tier, never the whole role, when it touches money, auth, tenancy or production, or after two failed attempts at a hard diagnosis. For example, the qa-sdet review of a payment PR runs at Strong reasoning. Record the reason in the task. A higher tier does not grant another strike.

## Fallback when a provider is unavailable

Order: Claude, then Codex, then Cursor, then Antigravity. On each provider pick the model by tier: its strongest reasoning model for Strong, its default mid-size model for Workhorse, its fastest for Light. Choose it in that tool's own selector. Do not put another provider's model id in Claude frontmatter.

1. **Unavailable means** quota exhausted, a rate limit that will outlast the task, an auth error, or an outage. Retry a single transient error once and stay put.
2. **Switch with an Orca full handoff**, in the same worktree if the branch is already there: `orca worktree create --name <task> --no-parent --agent codex --prompt "<brief>" --json`, or `orca terminal create --worktree active --command "codex"` for an existing worktree. Check `orca worktree create --help` for the agent ids this install knows. The brief names the role file to read first (`.claude/agents/<role>.md`), the ticket contract, the branch and the verify command.
3. **Never downgrade silently.** If no provider can run a Strong tier assignment, use the strongest model available, say so in the report, and have the independent reviewer (secops-finops for money or auth, otherwise qa-sdet) run at Strong before merge.
4. **Hooks do not run outside Claude Code.** The strike rule in `AGENTS.md` is then the only guard, so follow it as written.
5. **Finish the task where it landed.** The next task starts on the preferred provider again.
6. **Record the runner** (provider and model) in the PR description so the reviewer knows what produced the diff.

## Limits

Only Claude models can be selected in frontmatter. A model named in documentation is not proof this account can run it, so check that the selector offers it. Do not change the customer facing AI model catalog or billing settings to route development agents.
