# Model routing

Role frontmatter in `.claude/agents/` is the source of truth for Claude Code. This file adds the tiers and the fallback rule that apply to every provider.

## Tiers

| Tier | Use it for | Roles | Claude flags (`--agent claude`) |
| --- | --- | --- | --- |
| Strong reasoning | Ambiguous decisions, specs, security and financial review | elon, architect-pm, secops-finops | `--model opus --effort high`. Elon's whole session runs on it, so raise to `max` for one hard decision only |
| Workhorse | Implementation, coordination, QA, release, support, drafts | lead, fullstack-dev, qa-sdet, release-manager, sales-marketing, support-csm | `--model sonnet --effort medium` |
| Light | Clerical subtasks: formatting, extraction, changelog lines | none by default, chosen per task | `--model haiku` |

The main session starts as Elon (`"agent": "elon"` in `.claude/settings.json`), which sets its own model and effort.

Raise one assignment a tier, never the whole role, when it touches money, auth, tenancy or production, or after two failed attempts at a hard diagnosis. For example, the qa-sdet review of a payment PR runs at Strong reasoning. Record the reason in the task. A higher tier does not grant another strike.

## Fallback when a provider is unavailable

Order: Claude, then Codex, then Cursor, then Antigravity. Under Orca orchestration the provider, model and effort are set on every worker: `orca orchestration worker-start --agent <provider> --model <id> --effort <level>`. For each tier choose that provider's strongest reasoning model (Strong), default mid-size model (Workhorse) or fastest model (Light). Check which ids the install accepts with `orca orchestration worker-start --help` and the tool's own selector.

1. **Unavailable means** quota exhausted, a rate limit that will outlast the task, an auth error, or an outage. Retry a single transient error once and stay put.
2. **Switch by rerunning the Task on the next provider:** `orca orchestration worker-start --task <task_id> --worktree <same worktree> --agent codex --model <id> --effort <level> --json`. Release the failed worker only after it is proven stopped. For an unsupervised transfer that you start yourself, use the `orca-cli` handoff instead.
3. **Never downgrade silently.** If no provider can run a Strong tier assignment, use the strongest model available, say so in the report, and have the independent reviewer (secops-finops for money or auth, otherwise qa-sdet) run at Strong before merge.
4. **Hooks do not run outside Claude Code.** The strike rule in `AGENTS.md` is then the only guard, so follow it as written.
5. **Finish the task where it landed.** The next task starts on the preferred provider again.
6. **Record the runner** (provider and model) in the PR description so the reviewer knows what produced the diff.

## Limits

A role file's `model:` line applies only to Claude Code subagents. A worker started with Orca takes its model and effort from `--model` and `--effort`, so set them on every `worker-start` and name the role file in the spec. A model named in documentation is not proof this account can run it, so check that the selector offers it. Do not change the customer facing AI model catalog or billing settings to route development agents.
