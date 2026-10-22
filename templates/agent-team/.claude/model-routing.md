# Model routing

Tiers, Orca worker flags, worker launch and supervision, fallback, and the commit, push and merge rule. They apply to every provider.

Engineering runtime: read `.agents/skills/poteto-mode/ORCA-ADAPTER.md` first for tech-lead, fullstack-dev, qa-sdet and release-manager work. Its Codex-first routing, Cursor job restrictions and quota fallback supersede older engineering provider defaults below; existing usage, effort, token, strike, independent-review and publication gates still apply.

## Tiers

| Tier | Use it for | Roles |
| --- | --- | --- |
| Strong reasoning | Ambiguous decisions, specs, security, financial and PR review | elon, architect-pm, secops-finops, qa-sdet |
| Workhorse | Implementation, coordination, QA, release, support, drafts | tech-lead, fullstack-dev, release-manager, sales-marketing, support-csm |
| Light | Clerical subtasks: formatting, extraction, changelog fragment lines | none by default, chosen per task |

A session is plain Claude Code until the owner calls the agent team with `/elon`, `/ceo`, `/crew`, `/tl` or the `team` launcher; Elon then follows `elon.md`.

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
| Strong | `--agent claude --model opus --effort high` | `--agent codex --model gpt-6.1-sol --effort medium` | `--agent cursor --model claude-opus-5-5-high` | `--agent antigravity --model claude-opus-5-5-high` |
| Workhorse | `--agent claude --model sonnet --effort medium` | `--agent codex --model gpt-6.1-sol --effort medium` | `--agent cursor --model claude-sonnet-5-5-medium` | `--agent antigravity --model claude-sonnet-5-5-medium` |
| Light | `--agent claude --model haiku` | `--agent codex --model gpt-6.1-sol --effort low` | `--agent cursor --model gemini-3.8-flash-low` | `--agent antigravity --model gemini-3.8-flash-low` |

- Owner rule (2026-10-13), Codex use: QA smoke checks, dev pass runs, deploys and browser walkthroughs never run on Codex; route them to Antigravity or Cursor (the Docs and deploys line under Saving quota). Fixes above the 3 file small fix limit start on `gpt-6.1-sol` (smaller ones keep the `fullstack-dev-small` route below). Give a fix one complete contract in its spec (failing check, files allowed, the command that proves it done) and run one round: a miss goes back to Elon, never into a second or third Codex fix pass.
- Owner rule (2026-10-22, supersedes the 2026-10-07 Strong rule and the astra clause of 2026-10-13): every Codex worker, Strong tier included, runs `gpt-6.1-sol` at `--effort medium` (Light at `--effort low`; luna returns 400 on this account since 2026-10-21), never high. `gpt-6-astra` runs only with the owner's yes for that specific use, recorded on the issue; no brief, role file or preset grants it, and `start-codex-worker.sh` refuses it without `OWNER_ASTRA_YES`. Evidence: on 2026-10-22 one astra worker took about 620 calls and moved the weekly Codex reading from 65% to 95% in under 3 hours. Raise a Codex model or effort only with the owner.
- Provisional, not in force (owner direction 2026-10-21): from 2026-11-01, after a trial, DeepSeek V4 through the `opencode` agent replaces Codex for Codex routed work. The owner still decides the account and budget; until then Codex rows stay. Elon stays on Claude; Antigravity stays for docs, translation, walkthrough and research workers.
- Cursor and Antigravity put the effort in the model id: pass no `--effort`.
- Cursor and Antigravity default to Claude models, so they do not give a different family when the author ran on Claude. Non Claude reviewer when Codex is blocked: `--agent cursor --model gpt-5.6-sol-high` or `--agent antigravity --model gemini-4-argon-high` (Cursor checked 2026-10-07; Antigravity checked 2026-10-17).
- Cursor quota runs out per model family (2026-10-07: Gemini exhausted until 10/25, Opus spend limit hit earlier). A Cursor usage limit is a provider stop: fall back, never retry the same Cursor model.
- After each start, compare `launch.requested` with `launch.effective` in the receipt and report the effective model.

## Saving quota (owner 2026-10-09)

- A fix or chore touching 3 files or fewer runs as `fullstack-dev-small`, a Light role in `~/.orca/presets.json` (Codex `gpt-6.1-sol` at `--effort low` first), titled `fullstack-dev-small - <job>` so the usage gate picks from the Light tier. Features, schema changes, money and security stay on `fullstack-dev`.
- Docs, translation, deploys and Playground walkthroughs start on `--agent antigravity --model gemini-4-argon-high` (the usage gate reads Antigravity per model pool, Claude and Gemini: check with `--provider antigravity --model <id>`), which keeps Claude and Codex for code. Before merge, audit a Gemini worker's file list and new i18n keys: it reformats files and copies English into tw and jp.
- Sales (owner 2026-10-15): sales-marketing stays on Claude Sonnet for Traditional Chinese copy, outreach, pricing strategy and data analysis. Market research, competitor price comparison and Taiwan merchant lookups go to `--agent antigravity --model gemini-4-argon-high` (Google search grounding; spares Claude and Codex quota). Gemini must give a source URL for every number and merchant fact; sales-marketing spot checks them before any decision, and a fact without a source is not used.
- Antigravity's Claude models and Cursor's Opus have their own quotas that can run out for days. On a quota message in the startup screen, fall back to the next provider; do not retry.

## Role files and worker launch

A role file's `model:` and `effort:` apply only to a Claude Code subagent or `claude --agent <role>`. An Orca worker started with `worker-start --agent ... --model ...` does not read them; set `--model` and `--effort` on every `worker-start`. Keep each role file's `model:` and `effort:` equal to the Claude row for its tier.

1. **Default, every provider:** pass the flags above; the spec says "read `<repo root>/.claude/agents/<role>.md` first and follow it", with the absolute path, so the worker reads the main checkout's role file, not a stale copy in its branch. `tools:` is then not enforced, so a read only role (secops-finops, support-csm, stream-health) is held only by its Never section: check the diff it leaves.
2. **Claude with the role enforced (optional, untested):** `orca terminal create --worktree <worktree> --command "claude --agent <role>" --json`, then `orca orchestration worker-start --terminal <handle> --spec "<task spec>" --worktree <worktree> --json`. Model, effort, tools and skills then come from the frontmatter. `--model` and `--effort` cannot be combined with `--terminal`.

A model named in documentation is not proof this account can run it: check the selector offers it. Never change the customer facing AI model catalog or billing settings to route development agents.

## Commit, push and merge (owner rule)

Publication authority (owner 2026-10-20). The Tech Lead owns engineering integration; Elon owns PM, sales and docs integration under `docs/agents/team.md`, Orchestration rule 3. Enforced by instruction until the worker hook (blocks `git push`, `gh pr create` and `gh pr merge` in worker terminals) and the push script are built. Every worker spec states rules 1 and 2.

1. An implementation worker edits and commits only on its own branch in its own worktree, at each green checkpoint. It never runs `git push`, `gh pr create` or merges. Its `worker_done` reports the branch, worktree path, `git diff main...HEAD --stat` and test counts.
2. A reviewer reads the worker's worktree locally and puts findings in its `worker_done`, never in PR comments.
3. The responsible coordinator under `docs/agents/team.md`, Orchestration rule 3, pushes the branch and opens the PR, with the push script: it refuses `main`, `staging`, `production` and `.env` files, tries at most 3 times then reports, and writes a PR body with no Test plan and no tool credit (no "Generated with Claude Code" line, no Co-Authored-By trailer, also on `gh pr edit`; the owner's rule overrides the tool's attribution reminder). The responsible coordinator merges with `--match-head-commit`, never force pushes, never uses `--admin`. Elon publishes and merges docs-only PRs through the mechanical lane; this is not writing code. Intent/spec acceptance and changes to `.claude/hooks/`, `.claude/settings.json` or `bin/owner-approve.sh` wait for owner approval through Elon. A worktree is removed only after its push succeeded and its PR merged.
4. The release manager pushes only `staging` and `production`, production only with the owner's approval.
5. Merge on completion (owner standard, 2026-10-12): once a worker's `worker_done` and required reviews/checks are validated, the responsible coordinator merges its branch and fast forwards the owner's local main checkout (`git pull --ff-only`, only when it is on `main` and clean). Never hold a finished branch for another review round: release that reviewer first (the merge removes the worktree), then run one post-merge review on `main` and file its findings as follow-up issues.

## Starting a worker

Host ssh work routes to a Claude worker. The Codex exec layer blocks ssh and remote shells by design; do not change those rules. Codex keeps the local parts of the same ticket.

**Usage gate (never run out of AI usage).** Before every `worker-start`:

- Pick: `~/dotfiles/script/usage-gate.py pick --role <role>` ranks providers by headroom and respects role pins; pass its flags. A reviewer adds `--avoid-family <author family>`.
- Check: `python3 ~/dotfiles/script/usage-gate.py check --provider <claude|codex|cursor|antigravity>`. Exit 0 allows; the daily spread is only a pacing hint (`pacing: prefer a lighter model`). Exit 3 blocks only when fresh real provider usage plus the running-worker reserve reaches the 95% weekly ceiling (Cursor billing cycle or Antigravity model pool). Take the next provider that passes; only the usage gate on real readings may stop dispatching.
- Missing, expired or stale readings (older than five minutes) trigger a new provider read: Codex account rate limits, Claude OAuth usage, Cursor usage summary or Antigravity quota. If that fails, exit 4 reports `unknown`, its reason and the exact source; continue and report the uncertainty without inventing usage. A provider stop message requires checking fresh usage and recovering the queue on a provider with headroom.
- `usage-gate.py show` lists every provider with its reading source, age and reset time. The gate checks at `worker-start` and never stops a running worker. Never raise the 95% ceiling without Mingster.
- The `usage-gate-hook.py` PreToolUse hook denies only a start blocked by the real usage ceiling, and warns on unknown readings. Provider routing recommendations are advisory; `USAGE_GATE_OVERRIDE='<reason>'` records a deliberate routing choice and never bypasses the usage ceiling. Daily cap overrides remain pacing hints and are unnecessary to dispatch with weekly headroom.
- Read each provider's startup notice: at Codex "weekly limit: only N% left" of 5% or less, treat Codex as unavailable. Record each unavailable provider's reset time in the status report.

**Start.**

1. Title the task `<role> - <job>` (for example `tech-lead - merge the RSVP batch`) with `--task-title`; routing enforcement and pane color read the role from it. Start with `--worktree new-child --name <role>-<short-job> --base-branch origin/main`, so the worktree shows under the coordinator's in Orca's sidebar. Never pre-create worker worktrees with `--no-parent` (their terminals land under a separate entry the owner cannot find). Agents are project level: a worker's terminal starts from a worktree of a project that has `.claude/agents`, so cross-project work (a dotfiles edit) starts in a project worktree and names the other worktree in the spec; `--agent` fails in a worktree without them. A tech-lead starts with `orca orchestration worker-start --task <id> --worktree <wt> --agent tech-lead`.
2. Codex: `~/dotfiles/script/start-codex-worker.sh --run <run_id> --spec <file> --title "<role - job>" (--worktree-path <path> | --name <lane> --repo <path>) [--model <id>] [--effort <level>]`. Orca marks a Codex terminal ready only after one finished turn, so the script sends the warm-up line "Say ready and wait for your task.", waits for it, then runs `worker-start --terminal <handle> --worktree path:<wt>`. It prints `<dispatch> <terminal> <state>` and exits 1 when the dispatch is not running. Without the script: let a plain `worker-start` fail, send the warm-up line, wait about 25 seconds, then `worker-start --task <task_id> --retry-of <dispatch_id> --terminal <handle> --worktree path:<same worktree>`; only `dispatched` counts as started.
3. Cursor shows "Workspace Trust Required" in every new worktree and `worker-start` fails at `agent_readiness`. Launch with `cursor-agent --trust` when you can pass flags; otherwise `orca terminal send --terminal <handle> --text a`, confirm the prompt bar shows, then retry exactly: `orca orchestration worker-start --task <task_id> --retry-of <failed dispatch> --terminal <handle> --worktree path:<same worktree> --json`. Add no `--agent`, `--model` or `--effort`: a retry with `--terminal` rejects them and keeps the first dispatch's settings.
4. **Delivery check** within 2 minutes: `orca terminal read --terminal <handle> --screen` must show the agent working on the spec. An empty prompt, a startup notice (usage limit, model retirement, update), a dialog or an agent error (for example Cursor "spendLimitHit: true") means the spec was not delivered; `worker-release` refuses such a dispatch. Run `orca orchestration worker-stop --dispatch <id>`; on `stop_unknown`, when the screen shows the provider error and no `worker_done` was sent, `orca orchestration worker-abandon --dispatch <id>` (retrying a `stop_unknown` dispatch fails with `task_not_startable`). Then `orca orchestration worker-start --task <task_id> --retry-of <dispatch_id> --worktree <same worktree> --agent <next provider that passes the usage gate> ...` and check again. Never wait on an undelivered worker.
5. **Pane.** Right after a `worker-start` that returns `dispatched`, run `~/.claude/skills/orca-team/worker-panes.sh <run_id> <coordinator terminal handle> <dispatch_id>` so the worker shows as a colored pane in the coordinator's tab. The coordinator handle is the terminal titled with the coordinator role in the main checkout (`orca terminal list --json`). A coordinator with no Orca terminal (Elon in Orca chat) first creates the anchor once: `orca terminal create --worktree path:<main checkout> --title elon --json`. Once the worker reports "Setup succeeded" (agents overwrite the title at startup), `orca terminal rename --terminal <handle> --title "<same text>"` and confirm with `orca terminal list`.
6. Status reports name each running worker's worktree (under `~/orca/workspaces/<project>`).
7. **Close** the moment the coordinator validates a worker's `worker_done`, or the worker fails: `orca orchestration worker-release --dispatch <id>` (succeeded or failed), then `~/.claude/skills/orca-team/worker-pane-close.sh <dispatch_id>` (closes the pane and every terminal of that dispatch still in `orca terminal list`: agent and setup handles, shell terminals whose `worktreePath` matches the linked git worktree the worker created or reused (`.git` must be a file, so main checkouts are matched by worker handle only), and a pane whose split timed out unrecorded), then `git worktree remove` and prune. On every wake run `worker-pane-close.sh` with no arguments as the sweep: it closes every recorded pane whose dispatch ended, except a terminal that a dispatch not yet in a final state also uses, such as a retry's reused terminal. Never leave a finished worker's terminal or pane open; never close the owner's own sessions or other projects' terminals. As a backstop each pane closes itself about 10 seconds after its dispatch ends (`worker-pane.sh`). At the end of a session, after a batch of merges or before a release, the coordinator runs the `wrap-up` skill (`.agents/skills/wrap-up/SKILL.md`) for branches, worktrees and any pane left over.

## Watching a worker

1. A live terminal and heartbeats do not prove progress: a provider can stop an agent on quota while Orca shows it alive. Wait in slices of at most 15 minutes (`orca orchestration check --run <child> --wait --types worker_done,escalation,status,question,decision_gate --timeout-ms 900000`; never poll `worker-list`, `check --terminal`, grep or sleep loops); on every wake, and after every slice without a report, run `~/.claude/skills/orca-team/worker-watch.sh <run_id>`. Exit 4 names the dispatch and screen line of a worker that is STOPPED (provider limit, "Context limit reached" or network error), IDLE (empty input prompt without busy markers), BLOCKED_DIALOG (Cursor "Workspace Trust Required"), BLOCKED_APPROVAL (a pending tool approval prompt; approve or deny it at once) or LOW_CONTEXT (Claude status line at ctx 80% or more). On IDLE or network STOPPED, send the resume line from the `orca-team` skill (`orca terminal send --terminal <handle> --text "Resume the assigned task and report its outcome." --enter`) at once; never leave the worker waiting. Your own handoff goes to `~/.claude/state/lead-handoffs/`, never a worktree `.scratch/`, so wrap-up cannot remove it.
2. Heartbeats and "Setup succeeded" need only an ack. Report to the owner only `worker_done`, an escalation, a question or a stopped worker. A completed dispatch rejects messages (`dispatch_inactive`): send follow-up work as a new dispatch.
3. On provider-limit STOPPED, keep the worktree as it is, uncommitted work included. Check the next provider in the fallback order (`usage-gate.py check --provider <next>`), `orca orchestration worker-stop --dispatch <id>` (on `stop_unknown`, `worker-abandon --dispatch <id>`), then `orca orchestration worker-start --task <task_id> --retry-of <dispatch_id> --worktree <same worktree> --agent <next provider> ...`. A retry reuses the original spec, so send the continuation (what the previous attempt left, decisions already answered) with `orca orchestration send --to dispatch:<new id> --priority high`, nudge it with one `orca terminal send --enter` line, and run the delivery check.
4. Every worker spec says: at about 80% context, or at the worker budget warning (120 turns), commit (never push) and send `worker_done --outcome failed` with "context exhausted" and a short "what is left" list (written with the `handoff` skill, `~/.agents/skills/handoff/SKILL.md`, its path in the report); never start a big step past that point.
5. On LOW_CONTEXT or "context exhausted", start a fresh worker on the same task and worktree (`worker-start --task <task_id> --retry-of <dispatch_id> --worktree <same worktree>`), send the "what is left" list as the continuation, nudge, and run the delivery check. Never ask the old worker to `/compact`.
6. A deploy or release-manager worker gets 10 minute slices, and no step may run longer, except the development pass regression suite (up to 20 minutes; the Ten minute limit in the deploy skill). A slice with no new screen output means stuck: read the screen, stop the hung process, restart or report. Never keep waiting on a deploy.
7. **Superseded dispatch.** The moment a replacement dispatch ships or a retry takes over the same work, close the one it replaced: `worker-stop --dispatch <old id>` (`worker-abandon` on `stop_unknown`), `worker-release`, then `worker-pane-close.sh <old id>`. Never leave it waiting; a stale release worker once waited 2 hours after its replacement shipped. Do it before the next status report.
8. When the provider that gives the reviewer a different family is out, wait for its reset if it lands before the deadline. Never review with the author's family.
9. **Bounded runtime.** Every worker spec requires development servers and long test suites to run in the background, with their log path and owned PID or tool session recorded. Bound each command, readiness probe and completion wait with a timeout (`timeout 600` where available, or the tool timeout); use bounded log reads rather than bare `tail -f` or an unbounded wait loop. Check progress between waits and enforce the release step limits above (including the explicit 20 minute development regression exception). On timeout, inspect progress and stop only processes owned by that worker before restarting or reporting the blocker; never kill shared servers or another worker’s process.

10. **Reaching a running worker.** Answer its open question with `orca orchestration reply`, or send to `dispatch:<id>`; a plain `send` to a terminal handle can land in a mailbox nobody reads (a time-boxed go and a Codex correction were both lost this way). Within 2 minutes `orca terminal read --terminal <handle> --screen` must show the worker acting on it; if not, resend with `orca terminal send --terminal <handle> --text "<message>" --enter`.

## Fallback when a provider is unavailable

Order: Claude, Codex, Cursor, Antigravity. Every worker gets its provider, model and effort on `orca orchestration worker-start --agent <provider> --model <id> --effort <level>`; per tier take that provider's strongest reasoning (Strong), default mid-size (Workhorse) or fastest (Light) model. Check accepted ids with `orca orchestration worker-start --help` and the tool's own selector.

1. **Unavailable** means quota exhausted, a rate limit that will outlast the task, an auth error, or an outage. Retry a single transient error once and stay put.
2. **Switch** by rerunning the Task on the next provider: `orca orchestration worker-start --task <task_id> --worktree <same worktree> --agent codex --model <id> --effort <level> --json`. Release the failed worker only once it is proven stopped. For an unsupervised transfer you start yourself, use the `orca-cli` handoff.
3. **Never downgrade silently.** If no provider can run a Strong assignment, use the strongest available, say so in the report, and have the independent reviewer (secops-finops for money or auth, otherwise qa-sdet) run at Strong before merge.
4. **Hooks run only in Claude Code.** Elsewhere the strike rule in `AGENTS.md` is the only guard: follow it as written.
5. **Finish the task where it landed.** The next task starts on the preferred provider again.
6. **Record the runner** (provider and model) in the PR description.
