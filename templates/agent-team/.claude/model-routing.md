# Model routing

Tiers, Orca worker flags, worker launch and supervision, fallback, and the commit, push and merge rule. They apply to every provider.

Engineering runtime: read `.agents/skills/orca-adapter/ORCA-ADAPTER.md` first for fullstack-dev, qa-sdet and release-manager work. Provider policy lives in this file; the adapter never overrides it, and its usage, effort, token, strike, independent-review and publication gates still apply.

User rule (2026-11-09, replaces the 2026-11-06 rule): implementation units run on Cursor `grok-4.7-xhigh`, the pstack default, then Claude (`--agent claude --model sonnet --effort medium`) only when that quota is out, no fleet wide lane limit (user 2026-11-04). Host caps count every worker and alone decide how many run at once; extra ready batches queue. Every other role, verifiers included, starts on Claude, Cursor or Antigravity per the table below. Antigravity and Cursor workers run without the Claude hooks and the `settings.json` deny list; the strike rule in `AGENTS.md` is their guard.

User rule (2026-11-09): units that change only docs, or one small script (about 100 changed lines or less, one script plus its test, nothing touching money, sign in, hooks, merge or deploy gates), run on the Light tier. Everything else keeps its tier.

## Coordinator effort (user 2026-11-03)

Claude (`--agent claude --model opus --effort medium`) is the default for the coordinator; Antigravity `gemini-4-argon-medium` (`--agent antigravity --model gemini-4-argon-medium`) is the fallback. Provider, host and usage caps still apply. Verify the effective model and effort of a running session separately from saved presets.

## Tiers

| Tier | Use it for | Roles |
| --- | --- | --- |
| Strong reasoning | Ambiguous decisions, specs, security, financial and PR review | elon (Claude Opus medium default; `gemini-4-argon-medium` fallback), architect-pm, secops-finops, qa-sdet |
| Workhorse | Implementation, coordination, QA, release, support, drafts | fullstack-dev, release-manager, sales-marketing, support-csm |
| Light | Clerical subtasks (formatting, extraction, changelog fragment lines), docs only units, and small scripts | none by default, chosen per task |

Strong tier roles (`elon`, `architect-pm`, `secops-finops`, `qa-sdet`) are never started with `~/dotfiles/script/start-cursor-worker.sh` or any Cursor model; run `python3 ~/dotfiles/script/usage-gate.py pick --role <role>` and pass its flags to `orca orchestration worker-start`. The helper is for `fullstack-dev`, `release-manager` and Light work only.
A session is plain Claude Code until the user calls the agent team with `/elon`, `/ceo` or the `team` launcher; the coordinator then follows `elon.md`.

Raise one assignment a tier, never the whole role, when it touches money, auth, tenancy or production, or after two failed attempts at a hard diagnosis (for example the qa-sdet review of a payment PR runs at Strong). Record the reason in the task; a higher tier grants no extra strike.

## Default provider by role

Fallback begins at the provider after the role's default.

| Role | Default provider | Flags |
| --- | --- | --- |
| elon | Claude, then Antigravity Argon | `--agent claude --model opus --effort medium` by default; fallback `--agent antigravity --model gemini-4-argon-medium` (`~/.orca/presets.json`). |
| fullstack-dev | Cursor `grok-4.7-xhigh`, then Claude Sonnet, then Antigravity Argon | `--agent cursor --model grok-4.7-xhigh` when Cursor is allowed; `--agent claude --model sonnet --effort medium` only when Cursor is blocked; then `--agent antigravity --model gemini-4-argon-medium` (before merge, audit the file list and the i18n keys). `usage-gate.py pick` enforces this order. The preset chain in `~/.orca/presets.json` matches it. |
| qa-sdet | Independent family on an available provider | Use a permitted model family different from the author, respecting provider and host caps. Opus is not mandatory for ordinary QA; extra Strong review follows the user rule below. |
| light (`fullstack-dev-small` and any role whose tier is light) | Cursor `grok-4.7-xhigh`, then Claude Haiku, then Antigravity Flash | `--agent cursor --model grok-4.7-xhigh` when Cursor is allowed; then `--agent claude --model haiku`; then `--agent antigravity --model gemini-3.8-flash`. |
| every other role | Claude | the Claude column for the role's tier. Strong roles never take a Cursor model. |

Different family review: qa-sdet never uses the model family fullstack-dev used on the same PR. Select an available permitted independent family; a Cursor GPT author does not by itself require Claude Opus. User rule 2026-10-31: extra Strong / Claude Opus cross review is required only for issues involving money transactions (including payments, wallet movements and ledger postings), or when the coordinator or the human user explicitly requests it for that issue. Record an explicit request and its reason on the issue or PR. Auth, schema, tenant isolation, gate scripts, diff size, uncertainty and a model fallback do not automatically require this extra review. Ordinary independent QA and exact-head Checks remain required; when both pass, the lead proceeds without waiting for an extra Strong review outside those two cases. Independent review: a Claude author gets a `gemini-4-argon-high` verifier, and a Gemini author gets a Claude verifier. The families left are Claude and Gemini; GPT is reachable only through Cursor. Role fallback chains: `~/.orca/presets.json`.

## Worker flags by provider

Cursor workers may run locally or on a saved Orca environment. Use `start-cursor-worker.sh --on <environment>` for remote Cursor so trust is written on the execution host before dispatch. Antigravity workers still require the local host until remote attach works.

The user's standing choice: pass these on every `worker-start`. Ids checked 2026-10-25 (Claude `claude --help`, Cursor `cursor-agent --list-models`, Antigravity `agy models`); re-check when they drift.

| Tier | Claude | Cursor | Antigravity |
| --- | --- | --- | --- |
| Strong | `--agent claude --model opus --effort high` | `--agent cursor --model grok-4.7-xhigh` | `--agent antigravity --model gemini-4-argon-high` |
| Workhorse | `--agent claude --model sonnet --effort medium` | `--agent cursor --model grok-4.7-xhigh` | `--agent antigravity --model gemini-4-argon-medium` |
| Light | `--agent claude --model haiku` | `--agent cursor --model grok-4.7-xhigh` | `--agent antigravity --model gemini-3.8-flash-medium` |

Light order: Cursor `grok-4.7-xhigh`, then Claude `haiku`, then Antigravity `gemini-3.8-flash`.

- Cursor and Antigravity put the effort in the model id: pass no `--effort`.
- Cursor and Antigravity default to Claude models, so they do not give a different family when the author ran on Claude. Non Claude verifier: `--agent antigravity --model gemini-4-argon-high` or `--agent cursor --model grok-4.7-high` (Cursor checked 2026-10-07; Antigravity checked 2026-10-17). Cursor verifiers never run tests or heavy-gate jobs (the coordinator 2026-10-26): they review code only, and the lead runs the tests.
- Cursor quota runs out per model family (2026-10-07: Gemini exhausted until 10/25, Opus spend limit hit earlier). A Cursor usage limit is a provider stop: fall back, never retry the same Cursor model.
- After each start, compare `launch.requested` with `launch.effective` in the receipt and report the effective model.

## Argon builds, Claude debugs (user 2026-11-01)

- Gemini 4 Argon (`--agent antigravity --model gemini-4-argon-high` or `-medium`) takes broad, multi step Worktree jobs: high throughput work, multimodal input (video, images, large documents), and wide generation of base code and unit tests.
- Claude (Opus 5.5 for hard cases, Sonnet 5.5 otherwise) takes fine terminal debugging. When Argon has pushed code but the project stalls at `bun run build` or a CLI deploy step with hard environment or type errors, hand that same worktree to a Claude worker to fix it.
- Handoff: Argon commits and reports the failing command and its output; the Claude worker starts in the same worktree, fixes only what blocks the build or deploy, and does not rewrite Argon's feature code.
- Proven combo (user 2026-11-01, 24 hour run): the coordinator on `--agent antigravity --model gemini-4-argon-medium` with Cursor `grok-4.7-xhigh` workers for small, mechanical or bounded units (three files or fewer, no `"use server"`, auth, payment or schema change). The coordinator may run this way when Claude quota is tight. Escalate a unit to Claude when it fails twice or touches the excluded areas.
- The Cursor "Trust this workspace" stall is handled under the coordinator's supervision: read the screen after each Cursor start and accept the prompt.
- Debug handoff preset: `fullstack-dev-debug` (Claude `sonnet` high, then `opus` high).
- Verifier: never the author's family. Use the first provider whose model family differs from the author (Argon author: Claude; Claude author: Argon; Grok author: always Claude). Argon is the Gemini family, so it counts as cross family for a Claude author. Cursor reviews only on `grok-4.7-high`. If none is available, report gate blocked.
- Claude authored PRs (user 2026-11-06, replaces the 2026-11-05 Composer exception): when Argon is out, Cursor `grok-4.7-high` reviews and its Verdict counts for merge. Grok authored PRs always go to a Claude verifier (`usage-gate.py pick --avoid-family grok` offers only Claude).
- Cursor runs only `grok-4.7-xhigh` to build and `grok-4.7-high` to review (user 2026-11-09). Use `grok-4.7-xhigh-fast` only when urgent: CI or trunk is red, or a person is blocked on the result right now. Composer is no longer used. xhigh spends more Cursor quota per unit than Composer did, and the fast variant spends more again, so the usage gate reaches its cap sooner. Never pass another Cursor model (`claude-*`, `gpt-*`, `gemini-*`); `usage-gate.py pick` skips them and `~/.orca/presets.json` lists none.
- Argon workers still get the file list and i18n key audit before merge (see below).

## Saving quota (user 2026-10-09)

- A fix or chore touching 3 files or fewer runs as `fullstack-dev-small`, a Light role in `~/.orca/presets.json`, titled `fullstack-dev-small - <job>` so the usage gate picks from the Light tier. Features, schema changes, money and security stay on `fullstack-dev`.
- Small and mechanical units (copy, text substitutions, one-file fixes) route to a Cursor worker (`--agent cursor --model grok-4.7-xhigh`; user 2026-11-09). Start it with `~/dotfiles/script/start-cursor-worker.sh` (Cursor start rule below); the worker then sends `worker_done` like any other.
- Docs, translation, deploys and Playground walkthroughs start on `--agent antigravity --model gemini-4-argon-high` (the usage gate reads Antigravity per model pool, Claude and Gemini: check with `--provider antigravity --model <id>`), which keeps Claude for code. Before merge, audit a Gemini worker's file list and new i18n keys: it reformats files and copies English into tw and jp.
- Sales (user 2026-10-15): sales-marketing stays on Claude Sonnet for Traditional Chinese copy, outreach, pricing strategy and data analysis. Market research, competitor price comparison and Taiwan merchant lookups go to `--agent antigravity --model gemini-4-argon-high` (Google search grounding; spares Claude quota). Gemini must give a source URL for every number and merchant fact; sales-marketing spot checks them before any decision, and a fact without a source is not used.
- Antigravity's Claude models have their own quota that can run out for days. On a quota message in the startup screen, fall back to the next provider; do not retry.

## Role files and worker launch

A role file's `model:` and `effort:` apply only to a Claude Code subagent or `claude --agent <role>`. An Orca worker started with `worker-start --agent ... --model ...` does not read them; set `--model` and `--effort` on every `worker-start`. Keep each role file's `model:` and `effort:` equal to the Claude row for its tier.

1. **Default, every provider:** pass the flags above; the spec says "read `<repo root>/.claude/agents/<role>.md` first and follow it", with the absolute path, so the worker reads the main checkout's role file, not a stale copy in its branch. `tools:` is then not enforced, so a read only role (secops-finops, support-csm) is held only by its Never section: check the diff it leaves.
2. **Claude with the role enforced (optional, untested):** `orca terminal create --worktree <worktree> --command "claude --agent <role>" --json`, then `orca orchestration worker-start --terminal <handle> --spec "<task spec>" --worktree <worktree> --json`. Model, effort, tools and skills then come from the frontmatter. `--model` and `--effort` cannot be combined with `--terminal`.

A model named in documentation is not proof this account can run it: check the selector offers it. Never change the customer facing AI model catalog or billing settings to route development agents.

## Commit, push and merge (user rule)

Publication authority (user 2026-10-20). The coordinator owns all integration under `~/dotfiles/templates/agent-team/docs/agents/team.md`, rule Publication. Every worker terminal must not run raw `git push`, `gh pr create` or `gh pr merge`; coordinators publish through `~/dotfiles/script/coordinator-publication.sh`. Only the coordinator lands a PR, and only through `~/dotfiles/script/ship.sh` (rule 6). Every worker spec states rules 1, 2 and 6.

1. An PR owner edits and commits only on its own branch in its own worktree, at each green checkpoint. It never runs `git push`, `gh pr create` or merges except under rule 6. Its `worker_done` reports the branch, worktree path, `git diff main...HEAD --stat` and test counts.
2. A verifier reads the worker's worktree locally and puts findings in its `worker_done`, never in PR comments.
3. The responsible coordinator under `~/dotfiles/templates/agent-team/docs/agents/team.md`, rule Publication, pushes the branch and opens the PR with `~/dotfiles/script/coordinator-publication.sh --repo owner/name --branch <engineering-branch> --body-file <path>` (and optional `--title`, `--worktree`). The helper refuses `main`, `staging`, `production`, force pushes and tracked secret `.env` files, never derives the branch from upstream, validates exactly three `## Verification` bullets with no Test plan or tool credit and one `Closes` issue per line, tries at most 3 times then reports, and writes a receipt so a push without a PR can resume. The coordinator never merges. The coordinator dispatches merge workers under rule 6, including docs-only PRs through the mechanical lane; this is not writing code. Intent/spec acceptance and changes to `.claude/hooks/`, `.claude/settings.json` or `bin/owner-approve.sh` wait for user approval through the coordinator. A worktree is removed only after its push succeeded and its PR merged.
4. The release manager pushes only `staging` and `production`, production only with the user's approval.
5. Merge on completion (user standard, 2026-10-12): once a worker's `worker_done` and required reviews/checks are validated, the coordinator dispatches a merge worker under rule 6. Never hold a finished branch for another review round: release that verifier first (the merge removes the worktree), then run one post-merge review on `main` and file its findings as follow-up issues.
6. **Coordinator lands PRs (owner 2026-11-11):** the coordinator runs `~/dotfiles/script/ship.sh --repo owner/name --pr N` itself, one PR at a time. No merge worker is dispatched. Raw `gh pr merge` stays forbidden.

## Starting a worker

Host ssh work routes to a Claude worker.

**Usage gate (never run out of AI usage).** Before every `worker-start`:

- Pick: `~/dotfiles/script/usage-gate.py pick --role <role>` ranks providers by headroom and respects role pins, except `fullstack-dev` and light-tier roles, which take the first allowed of Cursor `grok-4.7-xhigh`, then that role's Claude entry, then Antigravity. Strong roles never receive Cursor. Pass its flags. A verifier adds `--avoid-family <author family>`.
- Check: `python3 ~/dotfiles/script/usage-gate.py check --provider <claude|cursor|antigravity>`. Exit 0 allows; the daily spread is only a pacing hint (`pacing: prefer a lighter model`). Exit 3 blocks only when fresh real provider usage plus the running-worker reserve reaches the 95% weekly ceiling (Cursor billing cycle or Antigravity model pool). Take the next provider that passes; only the usage gate on real readings may stop spawning.
- Missing, expired or stale readings (older than five minutes) trigger a new provider read: Claude OAuth usage, Cursor usage summary or Antigravity quota. If that fails, exit 4 reports `unknown`, its reason and the exact source; continue and report the uncertainty without inventing usage. A provider stop message requires checking fresh usage and recovering the queue on a provider with headroom.
- `usage-gate.py show` lists every provider with its reading source, age and reset time. The gate checks at `worker-start` and never stops a running worker. Never raise the 95% ceiling without Mingster.
- The `usage-gate-hook.py` PreToolUse hook denies only a start blocked by the real usage ceiling, and warns on unknown readings. Provider routing recommendations are advisory; `USAGE_GATE_OVERRIDE='<reason>'` records a deliberate routing choice and never bypasses the usage ceiling. Daily cap overrides remain pacing hints and are unnecessary to spawn with weekly headroom.
- Read each provider's startup notice and record each unavailable provider's reset time in the status report.
- Write a brief in its own Bash call, then spawn in the next one. `guard-bash.py` reads the whole command, so a brief and a `worker-start` in one call can be denied on the wrong issue number, and the denial means the brief is never written.
- Host routing: browser tests and browser walks start only on a host that has the browser installed. Pass `--on <host>` to `orca orchestration worker-start` yourself, and report lane counts from the fleet load output, never from dispatch notes.
- Bun drift: when the worker runs on another host, run `~/dotfiles/script/bun-pin-check.sh <host> <repo>` first. It prints one warning if the host's bun is older than the repo's pin (never blocks). A mass of init-time `ReferenceError` failures on one host is usually an old bun, not a regression.

**Start.**

- **Not already done:** before a PR owner start, `git fetch origin main` and `git log origin/main --oneline --grep '#<N>'` must be empty and `gh pr list --search <N> --state all` must show no open or merged PR for the unit. A stale `ready-for-agent` label and a missing `Closes` line caused four duplicate builds in two days.
- **Remote host (`--on <host>`):** that host's local trunk can be hours behind and a `new-top-level` worktree has no dependencies. Pass `--base-branch origin/main --setup run`. Orca does not fetch, so set the repo's setup hook (Orca repo settings or `orca.yaml`) to `~/dotfiles/script/worktree-setup.sh`: it fetches, fast-forwards the new worktree to origin/main and runs `bun install` when `node_modules` is missing. With `wait-for-setup` the worker starts only after it succeeds. Do not repeat these steps in the brief.

1. Title the task `<role> - <job>` (for example `qa-sdet - review the RSVP batch`) with `--task-title`; routing enforcement and pane color read the role from it. Start with `--worktree new-child --name <role>-<short-job> --base-branch origin/main`, so the worktree shows under the coordinator's in Orca's sidebar. Never pre-create worker worktrees with `--no-parent` (their terminals land under a separate entry the user cannot find). Agents are project level: a worker's terminal starts from a worktree of a project that has `.claude/agents`, so cross-project work (a dotfiles edit) starts in a project worktree and names the other worktree in the spec; `--agent` fails in a worktree without them. After start, read its status bar and confirm it matches the pick flags. Then set the terminal title to the same `<role> - <job>` text with both `orca terminal rename` and `orca terminal set-pane-title` (user 2026-10-24); agent title updates are off (`CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`), so the title stays.
2. **Cursor start:** use `~/dotfiles/script/start-cursor-worker.sh --run <run_id> --spec <brief-file> --title "<role> - <job>" --name <worktree-name> --repo <repo-path> --base-branch origin/main --model <model-id> --from <coordinator-handle>`. It creates the worktree, writes Cursor's `.workspace-trusted` marker for its absolute path, then dispatches into that existing worktree with `--agent cursor`. For an existing worktree, replace `--name`, `--repo` and `--base-branch` with `--worktree-path <absolute-path>`. For remote Cursor, add `--on <environment>` and use repository or worktree paths from that environment. The helper writes trust in the remote user HOME through an Orca command terminal and waits for a successful exit before dispatch. Both environments need Python 3. Without `--base-branch`, remote creation uses the remote repository default branch.
3. **Delivery check** within 2 minutes: run `~/.claude/skills/orca-team/worker-start-check.sh <dispatch>` (exit 1 means the start failed or was not accepted; user 2026-11-03: no worker panes), then use `worker-show` and `worker-read --source auto` (or the exact terminal screen) to confirm task acceptance and task-specific work. Compare requested/effective model and record the Dispatch ID, host and evidence. On failed or `outcome_unknown` start, inspect `failedStage`, `residualResources`, native liveness and recovery commands; load Orca's `orchestration` recovery-and-cleanup reference. Unknown is not failed or exited. Diagnose trust, runtime, quota or routing before another attempt; stop, abandon or retry only with positive process-state evidence and the supported lifecycle transition. Recheck actual task work after recovery.
4. Status reports name each running worker's worktree (under `~/orca/workspaces/<project>`).
5. **Close:** close finished worker and inactive Setup/pane terminals immediately after validating a settled worker's report (`~/.claude/skills/orca-team/worker-pane-close.sh --release <dispatch_id>`). Record the supported reuse, retention or native `worker-release` decision and verify that the worker terminal, recorded split pane and inactive Setup terminal disappear from `orca terminal list`. Shared worktree paths, task completion and shell exit status alone do not authorize closing terminals or deleting source. Preserve unknown/live resources and unmerged work; remove a worktree only after confirmed publication and merge, with current ownership and idle evidence. Follow the installed Orca recovery-and-cleanup reference for uncertain release. Keep the current coordinator and user sessions, and listen/communicate with active workers (`check --run <run> --wait`, `orca-reply.sh`).

## Watching a worker

1. A live terminal and heartbeats do not prove progress: a provider can stop an agent on quota while Orca shows it alive. Wait in slices of at most 15 minutes (`orca orchestration check --run <child> --wait --types worker_done,escalation,status,question,decision_gate --timeout-ms 900000`; never poll `worker-list`, `check --terminal`, grep or sleep loops); on every wake, and after every slice without a report, run `~/.claude/skills/orca-team/worker-watch.sh <run_id>`. Exit 4 names the dispatch and screen line of a worker that is STOPPED (provider limit, "Context limit reached" or network error), IDLE (empty input prompt without busy markers), BLOCKED_DIALOG (Cursor "Workspace Trust Required"), BLOCKED_APPROVAL (a pending tool approval prompt; approve or deny it at once) or LOW_CONTEXT (Claude status line at ctx 80% or more). On IDLE or network STOPPED, send the resume line from the `orca-team` skill (`orca terminal send --terminal <handle> --text "Resume the assigned task and report its outcome." --enter`) at once; never leave the worker waiting.
2. Heartbeats and "Setup succeeded" need only an ack. Report to the user only `worker_done`, an escalation, a question or a stopped worker. A completed dispatch rejects messages (`dispatch_inactive`): send follow-up work as a new dispatch.
3. On a provider-limit notice, preserve the worktree and inspect fresh usage, actual process state and the installed Orca recovery-and-cleanup reference. Choose a permitted provider with headroom only after positive exit evidence and a supported retry transition. Keep the original Task/retry chain and continuation; verify the replacement is actually working. An unreadable screen, provider notice or `stop_unknown` alone never authorizes abandon or duplicate launch.
4. Every worker spec says: at about 80% context, or at the worker budget warning (120 turns), commit (never push) and send `worker_done --outcome failed` with "context exhausted" and a short "what is left" list (written with the `handoff` skill, `~/.agents/skills/handoff/SKILL.md`, its path in the report); never start a big step past that point.
5. On LOW_CONTEXT, request the existing context-exhaustion handoff and preserve its work. Start a successor on the same Task/worktree only after accepted settlement or positively proven process exit and the native supported retry transition. Supply the continuation and verify task-specific progress; an old warning alone does not establish exit.
6. A deploy or release-manager worker gets 10 minute slices, and no step may run longer, except the development pass regression suite (up to 20 minutes; the Ten minute limit in the deploy skill). A slice with no new screen output means stuck: read the screen, stop the hung process, restart or report. Never keep waiting on a deploy.
7. **Superseded dispatch:** inspect the old and replacement Dispatches and their exact resources. Resolve the old attempt through the installed native lifecycle using positive process-state and settlement evidence; preserve shared terminals still used by the replacement. Record its explicit reuse, retention or release disposition before the next status report. A replacement shipping alone is not proof the old process exited.
8. When the provider that gives the verifier a different family is out, wait for its reset if it lands before the deadline. Never review with the author's family.
9. **Bounded runtime.** Every worker spec requires development servers and long test suites to run in the background, with their log path and owned PID or tool session recorded. Bound each command, readiness probe and completion wait with a timeout (`timeout 600` where available, or the tool timeout); use bounded log reads rather than bare `tail -f` or an unbounded wait loop. Check progress between waits and enforce the release step limits above (including the explicit 20 minute development regression exception). On timeout, inspect progress and stop only processes owned by that worker before restarting or reporting the blocker; never kill shared servers or another worker’s process.

10. **Reaching a running worker.** Answer its open question with `~/dotfiles/script/orca-reply.sh --to <handle> --id <msg id> --body "<text>"` (reply plus terminal nudge; `--subject "<s>"` in place of `--id` sends a new message with the same nudge; a bare `orca orchestration reply` leaves an idle session asleep), or send to `dispatch:<id>`; a plain `send` to a terminal handle can land in a mailbox nobody reads (a time-boxed go and a correction were both lost this way). Within 2 minutes `orca terminal read --terminal <handle> --screen` must show the worker acting on it; if not, resend with `orca terminal send --terminal <handle> --text "<message>" --enter`.

## Fallback when a provider is unavailable

Order: Claude, Cursor, Antigravity, except `fullstack-dev` and light-tier roles, which use Cursor, then Claude, then Antigravity (the role table). `worker-startup.sh` refuses `--agent claude` for those roles while pick still allows Cursor, unless `--route-override` gives a reason and the script logs it. Every worker gets its provider, model and effort on `orca orchestration worker-start --agent <provider> --model <id> --effort <level>`; per tier take that provider's strongest reasoning (Strong), default mid-size (Workhorse) or fastest (Light) model. Check accepted ids with `orca orchestration worker-start --help` and the tool's own selector.

1. **Unavailable** means quota exhausted, a rate limit that will outlast the task, an auth error, or an outage. Retry a single transient error once and stay put.
2. **Switch** by rerunning the Task on the next provider: `orca orchestration worker-start --task <task_id> --worktree <same worktree> --agent <next provider> --model <id> --effort <level> --json`. Release the failed worker only once it is proven stopped. For an unsupervised transfer you start yourself, use the `orca-cli` handoff.
3. **Never downgrade silently.** Report any model fallback. A fallback does not add a mandatory Strong verifier. Extra Strong review before merge follows the user rule above: money transactions or an explicit the coordinator / human request only.
4. **Hooks run only in Claude Code.** Elsewhere the strike rule in `AGENTS.md` is the only guard: follow it as written.
5. **Finish the task where it landed.** The next task starts on the preferred provider again.
6. **Record the runner** (provider and model) in the PR description.

