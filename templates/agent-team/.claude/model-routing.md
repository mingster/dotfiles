# Model routing

Role frontmatter in `.claude/agents/` sets the model and effort for a role that runs as a Claude Code subagent. This file adds the tiers, the exact Orca worker flags and the fallback rule that apply to every provider.

## Tiers

| Tier | Use it for | Roles |
| --- | --- | --- |
| Strong reasoning | Ambiguous decisions, specs, security and financial review | elon, architect-pm, secops-finops |
| Workhorse | Implementation, coordination, QA, release, support, drafts | lead, fullstack-dev, qa-sdet, release-manager, sales-marketing, support-csm |
| Light | Clerical subtasks: formatting, extraction, changelog lines | none by default, chosen per task |

The main session starts as Elon (`"agent": "elon"` in `.claude/settings.json`), which sets its own model and effort.

Raise one assignment a tier, never the whole role, when it touches money, auth, tenancy or production, or after two failed attempts at a hard diagnosis. For example, the qa-sdet review of a payment PR runs at Strong reasoning. Record the reason in the task. A higher tier does not grant another strike.

## Default provider by role

Each role starts on its default provider. Fallback begins at the next provider after it.

| Role | Default provider | Flags |
| --- | --- | --- |
| fullstack-dev | Codex | `--agent codex --model gpt-5.5 --effort medium` (or `gpt-6.1-sol`) |
| qa-sdet | Claude / Cursor | `--agent claude --model opus --effort high` (or Cursor `claude-opus-5-5-high`) |
| every other role | Claude | the Claude column for the role's tier |

Dual-model separation: qa-sdet must never use the same model family as fullstack-dev on the same PR to prevent shared blind spots. When fullstack-dev implements on Codex (GPT), qa-sdet audits on Claude (Opus) or Cursor (Claude Opus). Consult `~/.orca/presets.json` for role fallback chains.

Codex workers run without the Claude hooks (`guard-bash.py`, `strikes.py`) and the `settings.json` deny list. Their hard stops are the `forbidden` rules in `~/.codex/rules/default.rules` (migrations, `prisma db push`, ssh, deploy scripts, merges, pushes to default branches). Check that those rules exist before starting a Codex worker. Read only and release roles stay on Claude.

## Worker flags by provider

This table is the owner's standing model choice, so pass these flags on every `worker-start`. Ids were checked on 2026-10-05 on this machine: Claude aliases from `claude --help`, Codex from `~/.codex/models_cache.json`, Cursor from `cursor-agent --list-models`, Antigravity from `agy models`. Re-check them when they drift.

| Tier | Claude | Codex | Cursor | Antigravity |
| --- | --- | --- | --- | --- |
| Strong | `--agent claude --model opus --effort high` | `--agent codex --model gpt-6-astra --effort high` | `--agent cursor --model claude-opus-5-5-high` | `--agent antigravity --model claude-opus-5-5-high` |
| Workhorse | `--agent claude --model sonnet --effort medium` | `--agent codex --model gpt-6.1-sol --effort medium` | `--agent cursor --model claude-sonnet-5-5-medium` | `--agent antigravity --model claude-sonnet-5-5-medium` |
| Light | `--agent claude --model haiku` | `--agent codex --model gpt-6-luna --effort low` | `--agent cursor --model gemini-3.8-flash-low` | `--agent antigravity --model gemini-3.8-flash-low` |

- Codex's own descriptions: `gpt-6-astra` is "frontier intelligence for the most demanding work", `gpt-6.1-sol` is the "latest workhorse model for coding and everyday work", `gpt-6-luna` is "fast and affordable".
- Cursor and Antigravity put the effort in the model id, so pass no `--effort` there.
- Elon's own session runs on `opus` at `high`, set by `elon.md`.
- After each start, compare `launch.requested` with `launch.effective` in the receipt, and report the effective model, not the requested one.

## Role files and worker launch

A role file's `model:` and `effort:` apply only when the role runs as a Claude Code subagent or as `claude --agent <role>`. An Orca worker started with `worker-start --agent ... --model ...` does not read them.

1. **Default, every provider:** use the flags above, and the spec says "read `.claude/agents/<role>.md` first and follow it". The role's `tools:` line is then not enforced, so a read only role (secops-finops, support-csm, stream-health) is held only by its Never section. Check the diff it leaves.
2. **Claude with the role enforced (optional, not tested here):** `orca terminal create --worktree <worktree> --command "claude --agent <role>" --json`, then `orca orchestration worker-start --terminal <handle> --spec "<task spec>" --worktree <worktree> --json`. The role's model, effort, tools and skills then come from its frontmatter. `--model` and `--effort` cannot be combined with `--terminal`.

Keep each role file's `model:` and `effort:` equal to the Claude row for its tier, because mode 2 and Claude Code subagents use them.

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
