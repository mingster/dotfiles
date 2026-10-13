# Model routing

Tiers, Orca worker flags, worker launch and supervision, fallback, and the commit, push and merge rule. They apply to every provider.

## Tiers

| Tier | Use it for | Roles |
| --- | --- | --- |
| Strong reasoning | Ambiguous decisions, specs, security, financial and PR review | elon, architect-pm, secops-finops, qa-sdet |
| Workhorse | Implementation, coordination, QA, release, support, drafts | lead, fullstack-dev, release-manager, sales-marketing, support-csm |
| Light | Clerical subtasks: formatting, extraction, changelog fragment lines | none by default, chosen per task |

The main session starts as Elon (`"agent": "elon"` in `.claude/settings.json`), on `opus` at `high` from `elon.md`.

Raise one assignment a tier, never the whole role, when it touches money, auth, tenancy or production, or after two failed attempts at a hard diagnosis (for example the qa-sdet review of a payment PR runs at Strong). Record the reason in the task. A higher tier grants no extra strike.

## Default provider by role

Fallback begins at the provider after the role's default.

| Role | Default provider | Flags |
| --- | --- | --- |
| fullstack-dev | Codex | `--agent codex --model gpt-6.1-sol --effort medium` (owner rule below) |
| qa-sdet | Claude / Cursor | the Strong row: `--agent claude --model opus --effort high` (or Cursor `claude-opus-5-5-high`) |
| every other role | Claude | the Claude column for the role's tier |

Different family review: qa-sdet never uses the model family fullstack-dev used on the same PR. When fullstack-dev ran on Codex (GPT), qa-sdet audits on Claude Opus or Cursor Claude Opus. Role fallback chains: `~/.orca/presets.json`.

Codex workers run without the Claude hooks (`guard-bash.py`, `strikes.py`) and the `settings.json` deny list. Their hard stops are the `forbidden` rules in `~/.codex/rules/default.rules` (migrations, `prisma db push`, ssh, deploy scripts, merges, pushes to default branches); check those rules exist before starting a Codex worker. Read only and release roles never run on Codex: Claude, or Antigravity where Saving quota below says so.

## Worker flags by provider

The owner's standing choice: pass these on every `worker-start`. Ids checked 2026-10-05 (Claude `claude --help`, Codex `~/.codex/models_cache.json`, Cursor `cursor-agent --list-models`, Antigravity `agy models`); re-check when they drift.

| Tier | Claude | Codex | Cursor | Antigravity |
| --- | --- | --- | --- | --- |
| Strong | `--agent claude --model opus --effort high` | `--agent codex --model gpt-6-astra --effort medium` | `--agent cursor --model claude-opus-5-5-high` | `--agent antigravity --model claude-opus-5-5-high` |
| Workhorse | `--agent claude --model sonnet --effort medium` | `--agent codex --model gpt-6.1-sol --effort medium` | `--agent cursor --model claude-sonnet-5-5-medium` | `--agent antigravity --model claude-sonnet-5-5-medium` |
| Light | `--agent claude --model haiku` | `--agent codex --model gpt-6-luna --effort low` | `--agent cursor --model gemini-3.8-flash-low` | `--agent antigravity --model gemini-3.8-flash-low` |

- Owner rule (2026-10-07): Codex Workhorse runs `gpt-6.1-sol` at `--effort medium`, Light `gpt-6-luna` at `--effort low`, Strong (elon, architect-pm, secops-finops, money or security reviews) `gpt-6-astra` at `--effort medium`, never high. Raise a Codex model or effort only with the owner.
- Cursor and Antigravity put the effort in the model id: pass no `--effort`.
- Cursor and Antigravity default to Claude models, so they do not give a different family when the author ran on Claude. Non Claude reviewer when Codex is blocked: `--agent cursor --model gpt-5.6-sol-high` or `--agent antigravity --model gemini-3.1-pro-high` (checked 2026-10-07).
- Cursor quota runs out per model family (2026-10-07: Gemini exhausted until 10/25, Opus spend limit hit earlier). A Cursor usage limit is a provider stop: fall back, never retry the same Cursor model.
- After each start, compare `launch.requested` with `launch.effective` in the receipt and report the effective model.

## Saving quota (owner 2026-10-09)

- A fix or chore touching 3 files or fewer runs as `fullstack-dev-small`, a Light role in `~/.orca/presets.json` (Codex `gpt-6-luna` at `--effort low` first), titled `fullstack-dev-small - <job>` so the usage gate picks from the Light tier. Features, schema changes, money and security stay on `fullstack-dev`.
- Docs, translation, marketing copy, deploys and Playground walkthroughs start on `--agent antigravity --model gemini-3.1-pro-high` (the usage gate does not meter Antigravity and the hook lets it through), which keeps Claude and Codex for code. Before merge, audit a Gemini worker's file list and new i18n keys: it reformats files and copies English into tw and jp.
- Antigravity's Claude models and Cursor's Opus have their own quotas that can run out for days. On a quota message in the startup screen, fall back to the next provider; do not retry.

## Role files and worker launch

A role file's `model:` and `effort:` apply only to a Claude Code subagent or `claude --agent <role>`. An Orca worker started with `worker-start --agent ... --model ...` does not read them; set `--model` and `--effort` on every `worker-start`. Keep each role file's `model:` and `effort:` equal to the Claude row for its tier.

1. **Default, every provider:** pass the flags above; the spec says "read `<repo root>/.claude/agents/<role>.md` first and follow it", with the absolute path, so the worker reads the main checkout's role file, not a stale copy in its branch. `tools:` is then not enforced, so a read only role (secops-finops, support-csm, stream-health) is held only by its Never section: check the diff it leaves.
2. **Claude with the role enforced (optional, untested):** `orca terminal create --worktree <worktree> --command "claude --agent <role>" --json`, then `orca orchestration worker-start --terminal <handle> --spec "<task spec>" --worktree <worktree> --json`. Model, effort, tools and skills then come from the frontmatter. `--model` and `--effort` cannot be combined with `--terminal`.

A model named in documentation is not proof this account can run it: check the selector offers it. Never change the customer facing AI model catalog or billing settings to route development agents.

## Commit, push and merge (owner rule)

The single source for this rule. Enforced by instruction until the worker hook (blocks `git push`, `gh pr create` and `gh pr merge` in worker terminals) and the push script are built. Every worker spec states rules 1 and 2.

1. A worker (the lead included) edits and commits only on its own branch in its own worktree, at each green checkpoint. It never runs `git push`, `gh pr create` or merges. Its `worker_done` reports the branch, worktree path, `git diff main...HEAD --stat` and test counts.
2. A reviewer reads the worker's worktree locally and puts findings in its `worker_done`, never in PR comments.
3. Elon alone pushes the branch and opens the PR, with the push script: it refuses `main`, `staging`, `production` and `.env` files, tries at most 3 times then reports, and writes a PR body with no Test plan and no tool credit (no "Generated with Claude Code" line, no Co-Authored-By trailer, also on `gh pr edit`; the owner's rule overrides the tool's attribution reminder). Elon merges with `--match-head-commit`, never force pushes, never uses `--admin`. A worktree is removed only after its push succeeded.
4. The release manager pushes only `staging` and `production`, production only with the owner's approval.
5. Merge on completion (owner standard, 2026-10-12): once a worker's `worker_done` is validated, Elon merges its branch and fast forwards the owner's local main checkout (`git pull --ff-only`, only when it is on `main` and clean). Never hold a finished branch for another review round: release that reviewer first (the merge removes the worktree), then run one post-merge review on `main` and file its findings as follow-up issues.

## Starting a worker

**Usage gate (never run out of AI usage).** Before every `worker-start`:

- Pick: `~/dotfiles/script/usage-gate.py pick --role <role>` ranks providers by headroom and respects role pins; pass its flags. A reviewer adds `--avoid-family <author family>`.
- Check: `python3 ~/dotfiles/script/usage-gate.py check --provider <claude|codex>`. Exit 0 allows. Exit 3 blocks: the provider used its daily cap (what is left of its week under the 95% ceiling at the start of today, divided by the days left to its weekly reset) or the week is 95% used, counting a reserve of 1% of the week per worker already running on it. Take the next provider in the fallback order that passes; if all are blocked, stop dispatching and report it (Elon tells Mingster, because it stops all work) and resume after the reset the gate prints in local time. Exit 4 means no reading: go ahead and say so in the report.
- Limit reached, check the real number (owner 2026-10-13). When the gate blocks a provider or a worker stops on a quota message, read the provider's own usage before deciding, not only the gate's estimate: Codex `/status` in a Codex terminal (or the newest `rate_limits` in `~/.codex/sessions`), Claude `/usage`, Cursor the spend or limit message on the worker screen, Antigravity the quota line and reset time on its screen. When the provider shows headroom the gate missed (a stale reading, a daily cap tighter than the week needs), adjust: write `~/.claude/state/usage-gate/<provider>.cap-override.json` as `{"until": <epoch>, "cap": <percent>, "by": "<reason>"}` sized to that headroom, and say so in the report. When the provider is truly out, record its real reset time and fall back. Never raise the 95% weekly ceiling without the owner.
- `usage-gate.py show` lists every provider with its reset time. The gate checks only at `worker-start` and never stops a running worker, so do not pile workers on a provider near its cap. "Today" counts the whole account, sessions outside Orca included. Never change the 95% ceiling or the formula without Mingster.
- The `usage-gate-hook.py` PreToolUse hook in `~/dotfiles/script` enforces this: it denies a claude or codex `worker-start` the gate blocks (naming the reset time) and lets other agents and exit 4 through with a warning. For a deliberate exception, prefix the start with `USAGE_GATE_OVERRIDE='<reason>'`; the hook logs it in `~/.claude/state/usage-gate/overrides.log` and still enforces the daily cap.
- Read each provider's startup notice: at Codex "weekly limit: only N% left" of 5% or less, treat Codex as unavailable. Record each unavailable provider's reset time in the status report.

**Start.**

1. Title the task `<role> - <job>` (for example `fullstack-dev - fix RSVP late-pay rounding`) with `--task-title`; routing enforcement and pane color read the role from it. Start with `--worktree new-child --name <role>-<short-job> --base-branch origin/main`, so the worktree shows under the coordinator's in Orca's sidebar. Never pre-create worker worktrees with `--no-parent` (their terminals land under a separate entry the owner cannot find).
2. Codex: `~/dotfiles/script/start-codex-worker.sh --run <run_id> --spec <file> --title "<role - job>" (--worktree-path <path> | --name <lane> --repo <path>) [--model <id>] [--effort <level>]`. Orca marks a Codex terminal ready only after one finished turn, so the script sends the warm-up line "Say ready and wait for your task.", waits for it, then runs `worker-start --terminal <handle> --worktree path:<wt>`. It prints `<dispatch> <terminal> <state>` and exits 1 when the dispatch is not running. Without the script: let a plain `worker-start` fail, send the warm-up line, wait about 25 seconds, then `worker-start --task <task_id> --retry-of <dispatch_id> --terminal <handle> --worktree path:<same worktree>`; only `dispatched` counts as started.
3. Cursor shows "Workspace Trust Required" in every new worktree and `worker-start` fails at `agent_readiness`. Launch with `cursor-agent --trust` when you can pass flags; otherwise `orca terminal send --terminal <handle> --text a`, confirm the prompt bar shows, then `worker-start --task <task_id> --retry-of <failed dispatch> --terminal <handle> --worktree path:<same worktree>`.
4. **Delivery check** within 2 minutes: `orca terminal read --terminal <handle> --screen` must show the agent working on the spec. An empty prompt, a startup notice (usage limit, model retirement, update), a dialog or an agent error (for example Cursor "spendLimitHit: true") means the spec was not delivered; `worker-release` refuses such a dispatch. Run `orca orchestration worker-stop --dispatch <id>`; on `stop_unknown`, when the screen shows the provider error and no `worker_done` was sent, `orca orchestration worker-abandon --dispatch <id>` (retrying a `stop_unknown` dispatch fails with `task_not_startable`). Then `orca orchestration worker-start --task <task_id> --retry-of <dispatch_id> --worktree <same worktree> --agent <next provider that passes the usage gate> ...` and check again. Never wait on an undelivered worker.
5. Once the check passes and the worker reports "Setup succeeded" (agents overwrite the title at startup), `orca terminal rename --terminal <handle> --title "<same text>"` with the handle from the `--json` receipt or `worker-show`, confirm with `orca terminal list`, and run `~/.claude/skills/orchestration/worker-panes.sh <run_id> <coordinator terminal handle> <dispatch_id>` so the worker shows as a colored pane in the coordinator's tab. The coordinator handle is the terminal titled with the coordinator role in the main checkout (`orca terminal list --json`).
6. Status reports name each running worker's worktree (under `~/orca/workspaces/<project>`).
7. **Close** the moment the coordinator validates a worker's report, or the worker fails: `orca orchestration worker-release --dispatch <id>` (succeeded or failed), then `~/.claude/skills/orchestration/worker-pane-close.sh <dispatch_id>` (closes the pane and every terminal of that dispatch still in `orca terminal list`: agent, setup and shell terminals, and a pane whose split timed out unrecorded; with no arguments it closes every recorded pane whose dispatch ended), then `git worktree remove` and prune. Never leave a finished worker's terminal or pane open; never close the owner's own sessions or other projects' terminals. As a backstop each pane closes itself about 10 seconds after its dispatch ends (`worker-pane.sh`).

## Watching a worker

1. A live terminal and heartbeats do not prove progress: a provider can stop an agent on quota while Orca shows it alive. Wait in slices of at most 15 minutes (`orca orchestration check --wait --timeout-ms 900000`); after every slice without a report run `~/.claude/skills/orchestration/worker-watch.sh <run_id>`. Exit 4 names the dispatch and screen line of a worker that is STOPPED (provider limit, "Context limit reached"), BLOCKED_DIALOG (Cursor "Workspace Trust Required") or LOW_CONTEXT (Claude status line at ctx 80% or more).
2. Heartbeats and "Setup succeeded" need only an ack. Report to the owner only `worker_done`, an escalation, a question or a stopped worker. A completed dispatch rejects messages (`dispatch_inactive`): send follow-up work as a new dispatch.
3. On STOPPED, keep the worktree as it is, uncommitted work included. Check the next provider in the fallback order (`usage-gate.py check --provider <next>`), `orca orchestration worker-stop --dispatch <id>` (on `stop_unknown`, `worker-abandon --dispatch <id>`), then `orca orchestration worker-start --task <task_id> --retry-of <dispatch_id> --worktree <same worktree> --agent <next provider> ...`. A retry reuses the original spec, so send the continuation (what the previous attempt left, decisions already answered) with `orca orchestration send --to dispatch:<new id> --priority high`, nudge it with one `orca terminal send --enter` line, and run the delivery check.
4. Every worker spec says: at about 80% context, or at the worker budget warning (120 turns), commit (never push) and send `worker_done --outcome failed` with "context exhausted" and a short "what is left" list (written with the `handoff` skill, `~/.agents/skills/handoff/SKILL.md`, its path in the report); never start a big step past that point.
5. On LOW_CONTEXT or "context exhausted", start a fresh worker on the same task and worktree (`worker-start --task <task_id> --retry-of <dispatch_id> --worktree <same worktree>`), send the "what is left" list as the continuation, nudge, and run the delivery check. Never ask the old worker to `/compact`.
6. A deploy or release-manager worker gets 10 minute slices, and no step may run longer, except the development pass regression suite (up to 20 minutes; the Ten minute limit in the deploy skill). A slice with no new screen output means stuck: read the screen, stop the hung process, restart or report. Never keep waiting on a deploy.
7. When the provider that gives the reviewer a different family is out, wait for its reset if it lands before the deadline. Never review with the author's family.

## Fallback when a provider is unavailable

Order: Claude, Codex, Cursor, Antigravity. Every worker gets its provider, model and effort on `orca orchestration worker-start --agent <provider> --model <id> --effort <level>`; per tier take that provider's strongest reasoning (Strong), default mid-size (Workhorse) or fastest (Light) model. Check accepted ids with `orca orchestration worker-start --help` and the tool's own selector.

1. **Unavailable** means quota exhausted, a rate limit that will outlast the task, an auth error, or an outage. Retry a single transient error once and stay put.
2. **Switch** by rerunning the Task on the next provider: `orca orchestration worker-start --task <task_id> --worktree <same worktree> --agent codex --model <id> --effort <level> --json`. Release the failed worker only once it is proven stopped. For an unsupervised transfer you start yourself, use the `orca-cli` handoff.
3. **Never downgrade silently.** If no provider can run a Strong assignment, use the strongest available, say so in the report, and have the independent reviewer (secops-finops for money or auth, otherwise qa-sdet) run at Strong before merge.
4. **Hooks run only in Claude Code.** Elsewhere the strike rule in `AGENTS.md` is the only guard: follow it as written.
5. **Finish the task where it landed.** The next task starts on the preferred provider again.
6. **Record the runner** (provider and model) in the PR description.
