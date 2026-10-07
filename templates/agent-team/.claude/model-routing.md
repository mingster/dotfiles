# Model routing

Role frontmatter in `.claude/agents/` sets the model and effort for a role that runs as a Claude Code subagent. This file adds the tiers, the exact Orca worker flags and the fallback rule that apply to every provider.

## Tiers

| Tier | Use it for | Roles |
| --- | --- | --- |
| Strong reasoning | Ambiguous decisions, specs, security and financial review | elon, architect-pm, secops-finops |
| Workhorse | Implementation, coordination, QA, release, support, drafts | lead, fullstack-dev, qa-sdet, release-manager, sales-marketing, support-csm |
| Light | Clerical subtasks: formatting, extraction, changelog fragment lines | none by default, chosen per task |

The main session starts as Elon (`"agent": "elon"` in `.claude/settings.json`), which sets its own model and effort.

Raise one assignment a tier, never the whole role, when it touches money, auth, tenancy or production, or after two failed attempts at a hard diagnosis. For example, the qa-sdet review of a payment PR runs at Strong reasoning. Record the reason in the task. A higher tier does not grant another strike.

## Default provider by role

Each role starts on its default provider. Fallback begins at the next provider after it.

| Role | Default provider | Flags |
| --- | --- | --- |
| fullstack-dev | Codex | `--agent codex --model gpt-6.1-sol --effort medium` (owner rule, see below) |
| qa-sdet | Claude / Cursor | `--agent claude --model opus --effort high` (or Cursor `claude-opus-5-5-high`) |
| every other role | Claude | the Claude column for the role's tier |

Dual-model separation: qa-sdet must never use the same model family as fullstack-dev on the same PR to prevent shared blind spots. When fullstack-dev implements on Codex (GPT), qa-sdet audits on Claude (Opus) or Cursor (Claude Opus). Consult `~/.orca/presets.json` for role fallback chains.

Codex workers run without the Claude hooks (`guard-bash.py`, `strikes.py`) and the `settings.json` deny list. Their hard stops are the `forbidden` rules in `~/.codex/rules/default.rules` (migrations, `prisma db push`, ssh, deploy scripts, merges, pushes to default branches). Check that those rules exist before starting a Codex worker. Read only and release roles stay on Claude.

## Worker flags by provider

This table is the owner's standing model choice, so pass these flags on every `worker-start`. Ids were checked on 2026-10-05 on this machine: Claude aliases from `claude --help`, Codex from `~/.codex/models_cache.json`, Cursor from `cursor-agent --list-models`, Antigravity from `agy models`. Re-check them when they drift.

| Tier | Claude | Codex | Cursor | Antigravity |
| --- | --- | --- | --- | --- |
| Strong | `--agent claude --model opus --effort high` | `--agent codex --model gpt-6-astra --effort medium` | `--agent cursor --model claude-opus-5-5-high` | `--agent antigravity --model claude-opus-5-5-high` |
| Workhorse | `--agent claude --model sonnet --effort medium` | `--agent codex --model gpt-6.1-sol --effort medium` | `--agent cursor --model claude-sonnet-5-5-medium` | `--agent antigravity --model claude-sonnet-5-5-medium` |
| Light | `--agent claude --model haiku` | `--agent codex --model gpt-6-luna --effort low` | `--agent cursor --model gemini-3.8-flash-low` | `--agent antigravity --model gemini-3.8-flash-low` |

- Codex's own descriptions: `gpt-6-astra` is "frontier intelligence for the most demanding work", `gpt-6.1-sol` is the "latest workhorse model for coding and everyday work", `gpt-6-luna` is "fast and affordable".
- Owner rule (2026-10-07): Codex workhorse workers (fullstack-dev and every Workhorse role) run `gpt-6.1-sol` at `--effort medium`; Light work runs `gpt-6-luna` at `--effort low`. Strong tier work on Codex (elon, architect-pm, secops-finops, and money or security reviews) runs `gpt-6-astra` at `--effort medium`, never high effort. Do not raise a Codex worker's model or effort without the owner.
- Cursor and Antigravity put the effort in the model id, so pass no `--effort` there.
- Cursor and Antigravity default to Claude models, so they do not satisfy the different family review rule when the author ran on Claude. For a non-Claude reviewer when Codex is blocked, use `--agent cursor --model gpt-5.6-sol-high` or `--agent antigravity --model gemini-3.1-pro-high` (ids checked 2026-10-07).
- Cursor's model quota can run out per model family (2026-10-07: Gemini exhausted until 10/25, Opus spend limit hit earlier). If a Cursor start reports a usage limit, treat it like any provider stop and fall back to the next provider; do not retry the same Cursor model.
- Elon's own session runs on `opus` at `high`, set by `elon.md`.
- After each start, compare `launch.requested` with `launch.effective` in the receipt, and report the effective model, not the requested one.

## Role files and worker launch

A role file's `model:` and `effort:` apply only when the role runs as a Claude Code subagent or as `claude --agent <role>`. An Orca worker started with `worker-start --agent ... --model ...` does not read them.

1. **Default, every provider:** use the flags above, and the spec says "read `<repo root>/.claude/agents/<role>.md` first and follow it". Use the absolute path, so the worker reads the role file on the main checkout, not a stale copy in its own branch. The role's `tools:` line is then not enforced, so a read only role (secops-finops, support-csm, stream-health) is held only by its Never section. Check the diff it leaves.
2. **Claude with the role enforced (optional, not tested here):** `orca terminal create --worktree <worktree> --command "claude --agent <role>" --json`, then `orca orchestration worker-start --terminal <handle> --spec "<task spec>" --worktree <worktree> --json`. The role's model, effort, tools and skills then come from its frontmatter. `--model` and `--effort` cannot be combined with `--terminal`.

Keep each role file's `model:` and `effort:` equal to the Claude row for its tier, because mode 2 and Claude Code subagents use them.

Every worker spec must say: commit only on your own branch in your own worktree; never `git push`, `gh pr create` or merge; report the branch, worktree path, `git diff main...HEAD --stat` and test counts in `worker_done`. A reviewer's spec says: read the worker's worktree locally and put findings in `worker_done`, not in PR comments. Elon alone pushes (with the push script) and opens PRs; the release manager pushes only `staging` and `production`.

## Starting a worker

1. Start every worker with `--worktree new-child --name <role>-<short-job> --base-branch origin/main`, so it shows under the coordinator's worktree in Orca's sidebar. Do not pre-create worker worktrees with `--no-parent`, because their terminals then sit under a separate sidebar entry the owner cannot find.
2. Delivery check: within 2 minutes of `worker-start`, run `orca terminal read --terminal <handle> --screen`. It must show the agent working on the spec. An empty prompt, a startup notice (usage limit, model retirement, update), any dialog or an error in the agent output (for example Cursor answering "spendLimitHit: true" for Opus) means the start failed and the spec was not delivered. Such a dispatch has not settled, so `worker-release` refuses it. Run `orca orchestration worker-stop --dispatch <id>`; if it returns `stop_unknown` and the screen positively shows the provider error with no `worker_done` sent, run `orca orchestration worker-abandon --dispatch <id>` (a retry on a `stop_unknown` dispatch fails with `task_not_startable`). Then `orca orchestration worker-start --task <task_id> --retry-of <dispatch_id> --worktree <same worktree> --agent <next provider that passes the usage gate> ...`, and run the delivery check again. Never wait on an undelivered worker.
3. Start Codex workers with `~/dotfiles/script/start-codex-worker.sh --run <run_id> --spec <file> --title "<role - job>" (--worktree-path <path> | --name <lane> --repo <path>) [--model <id>] [--effort <level>]`. Orca marks a Codex terminal ready only after Codex has finished one turn, so the script opens the Codex terminal, sends the warm-up line "Say ready and wait for your task.", waits for that turn, then runs `worker-start --terminal <handle> --worktree path:<wt>`. It prints `<dispatch> <terminal> <state>` and exits 1 when the dispatch is not running. Fallback only if the script is unavailable: let a plain `worker-start` fail, send the warm-up line to the terminal, wait about 25 seconds, then `worker-start --task <task_id> --retry-of <dispatch_id> --terminal <handle> --worktree path:<same worktree>`; only a `dispatched` state counts as started.
4. Cursor shows "Workspace Trust Required" in every new worktree and `worker-start` fails at `agent_readiness`. `cursor-agent --trust` trusts the workspace without prompting, so launch with it when the start command lets you pass flags. Otherwise run `orca terminal send --terminal <handle> --text a`, confirm the prompt bar shows, then `worker-start --task <task_id> --retry-of <failed dispatch> --terminal <handle> --worktree path:<same worktree>`.
5. Before picking a provider, read its startup notice: Codex prints "weekly limit: only N% left", and at 5% or less treat Codex as unavailable for a new worker. Record each unavailable provider's reset time in the status report.
6. Rename the terminal after the delivery check passes, because agents overwrite the title at startup, then confirm with `orca terminal list`. Then run `~/.claude/skills/orchestration/worker-panes.sh <run_id> <coordinator terminal handle> <dispatch_id>` so the worker appears as a colored pane in the coordinator's tab (pane color comes from the role in the task title, so always start the title with the role name); find the coordinator handle with `orca terminal list --json` (the terminal titled with the coordinator role in the main checkout).
7. In status reports, name each running worker's worktree (under `~/orca/workspaces/<project>`) so the owner can find it.
8. The moment the coordinator validates a worker's report (or the worker fails), it closes everything that worker left open: `worker-release`, then `~/.claude/skills/orchestration/worker-pane-close.sh <dispatch_id>` (closes the pane and every terminal of that dispatch still in `orca terminal list`: its agent, setup and shell terminals, and a pane whose split timed out and was never recorded; no arguments closes every recorded pane whose dispatch has ended), then removes the worker's worktree and prunes. A finished worker's terminal or pane never stays open, and the owner's own sessions and other projects' terminals are never closed. Each pane also closes itself about 10 seconds after its dispatch ends (`worker-pane.sh`), as a backstop.

## Watching a worker

1. Heartbeats and a live terminal do not prove progress: a provider can stop an agent on quota while Orca still shows the terminal alive. Wait in slices of at most 15 minutes (`orca orchestration check --wait --timeout-ms 900000`), and after every slice without a report run `~/.claude/skills/orchestration/worker-watch.sh <run_id>`. Exit 4 means a worker is STOPPED (provider limit, or "Context limit reached"), BLOCKED_DIALOG (Cursor "Workspace Trust Required") or LOW_CONTEXT (Claude status line at ctx 80% or more), and the line names the dispatch and the matched screen line. Heartbeats and "Setup succeeded" status messages need only an ack, no report to the owner: report only `worker_done`, an escalation, a question or a stopped worker. A completed dispatch can no longer receive messages (`dispatch_inactive`), so send follow-up work as a new dispatch.
2. On STOPPED, keep the worktree as it is, uncommitted work included. Run the usage gate (`usage-gate.py check --provider <next>`) for the next provider in the fallback order, then `orca orchestration worker-stop --dispatch <id>` (if it returns `stop_unknown`, `worker-abandon --dispatch <id>`), then `orca orchestration worker-start --task <task_id> --retry-of <dispatch_id> --worktree <same worktree> --agent <next provider> ...`. A retry reuses the original spec, so send the continuation (what the previous attempt left in the worktree, decisions already answered) with `orca orchestration send --to dispatch:<new id> --priority high`, add a one line `orca terminal send --enter` nudge to read it, and run the delivery check.
3. Every worker spec says: commit to your branch at each green checkpoint, so a provider stop loses little. At about 80% context, or at the worker-budget warning (120 turns), commit (never push) and send `worker_done --outcome failed` saying "context exhausted" plus a short "what is left" list. Never start a big new step past that point.
4. On LOW_CONTEXT or a "context exhausted" report, start a fresh worker on the same task in the same worktree (`worker-start --task <task_id> --retry-of <dispatch_id> --worktree <same worktree>`), send the "what is left" list as the continuation message, add the one line terminal nudge, and run the delivery check. Do not ask the old worker to `/compact`.
5. When the provider that would give the reviewer a different model family is out, wait for its reset if it lands before the deadline. Never review with the same family as the author.

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
