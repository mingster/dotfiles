# Coordinator operations

Read before reporting status or reviewing process performance.

## Status evidence

- **Never report an unchecked status** (owner rule 2026-10-17). Every fact you tell the owner about state comes from a check run in that same turn, and you quote it. Provider quota comes from the real readings (`python3 ~/dotfiles/script/usage-gate.py show`), never the gate verdict alone, and the daily cap is a pacing estimate, not a block (`.claude/model-routing.md`, Starting a worker). Non engineering worker state comes from its screen or `worker-list`; engineering state is the tech-lead's handoff. A merge comes from the MERGED output. If you did not check, say "not checked". On every wake drain every pending delivery. If `orca orchestration check --run <run>` returns `consumer_fenced` (session restarted or compacted), run `orca orchestration run-use --id <run>` first; then wait with `check --run <run> --wait` and `--ack` each batch. Never scrape the shared `orca orchestration inbox` for your own messages.

## Process improvement (owner 2026-10-19)

- Any ticket over 10 minutes from start to MERGED gets a reason or structural fix logged in `docs/agents/process-review.md` the same wake; finding it is Elon's job.
- Principle: The Algorithm (`docs/agents/team.md`, Team rules 8). Every change cites the requirement questioned, its owner, and what was deleted.
- Measures, read weekly from GitHub and Orca, never estimated:
  1. Errors: post-merge defects (a bug or hotfix issue tied to a PR merged in the last 7 days), reverts, owner re-asks, hard stops.
  2. Speed: hours from an issue labelled ready-for-agent (or a hotfix) to its PR MERGED, median.
  3. Throughput: PRs merged per working day that close an issue or ship a reviewed change.
- Log each finding in `docs/agents/process-review.md` (evidence, finding, proposal, step of the Algorithm). Apply changes inside Elon's authority at once; protected files and Owner-Reserved items go to the owner with the diff.

## Tech-lead run

The tech-lead reads this before its first dispatch.

- Elon messages the tech-lead only with native `orca orchestration send --to run:<tech-lead run>`, never on Elon's Run or to the lead's old dispatch (both go unread). The tech-lead names its Run in its first status; else `run-list --json` shows the Run whose `coordinator_handle` is the tech-lead's terminal.

- Create one Run per session (`run-create --from <your terminal>`); never rebind your dispatch to it. Name it (`run-current`) in your first status to `run:<Elon run>` from your brief; all reports go there.
- Wait only with native `orca orchestration check --run <its run> --wait` (`status` among the types; `docs/agents/team.md`, Delivery contract 4); never poll the shared inbox. Arm it with the Bash tool's `run_in_background: true`, never a trailing `&`, and re-arm after every `--ack`.
- At start and on every wake, run `orca orchestration worker-list --run <its run> --json` and settle each unreleased dispatch: completed, process its result now; ready, read its screen and answer open questions with `~/dotfiles/script/orca-reply.sh --to <handle> --id <msg id> --body "<text>"`; stopped or failed, inspect the native projection and follow the supported lifecycle transition in the official Orca orchestration guide (Delivery contract), preserving unmerged work. A lead taking over a run adopts every live worker this way before new work. A bare `orca orchestration reply` does not wake an idle worker session (approvals sat 10+ minutes), so never use it: `orca-reply.sh` replies and then nudges the terminal, and refuses an empty `--to`.
- **Cursor worker trust marker:** use `~/dotfiles/script/start-cursor-worker.sh` as described in `.claude/model-routing.md`, Cursor start rule. It creates the worktree and writes `.workspace-trusted` before dispatching the worker.
- Never send `--type heartbeat` messages, and tell workers not to: each pings the owner. Elon reads your screen. Send `status` only for a ready merge or a `handoff:`; anything needing Elon's decision goes as `--type escalation` with its tag (`tech-lead.md`, Authority).

- **Small task method** (brief to MERGED under 3 minutes): exact edits in the brief, worktree pre-created at `~/orca/workspaces/{{PROJECT_NAME}}/<lane>`, one Cursor `composer-2.5` worker, merge on checks.

## Independent inbox watchdog

Configure `script/fleet-watch.py` from dotfiles with this run, coordinator terminal and unique waiter pattern in a private config. An independent minute scheduler runs it; the coordinator waiter cannot supervise itself. It warns after ten minutes of unacked deliveries without a waiter, on failed dispatches, on host caps including children, and once when a lead pane listed under `leads` (name and terminal handle) is gone; update `leads` whenever a lead restarts. See dotfiles `docs/agents/fleet-watch.md`; scheduling and terminal selection are explicit activation steps.

The inbox waiter script and its output file live in `~/.local/state/agent-team/` (`elon-wait.sh`, `elon-waiter.json`), never in `/tmp`, where wrap-up cleans agent temp files. Briefs tell workers to write temp files only inside their scratch dir or worktree.

## Wake loop

Elon runs this on every wake, at least every 10 minutes (owner rule 2026-10-23).

- `usage-gate.py show`, `worker-list` on the tech-lead run, the ready-for-agent count, the open PR count per project, and a read of the tech-lead and release-manager screens.
- `worker-watch.sh` on your run; LONG_SESSION means act at once (tech-lead: order `handoff:`). Keep `worker-watchdog.sh` running on the tech-lead run.
- Fewer workers than the gate allows while startable tickets exist is a bottleneck: order the tech-lead to fill the lanes that turn.
- Queue empty: start architect-pm and sales-marketing planning within the hour. Send pending owner asks as one numbered batch before he leaves; one answer holds at most one ticket.
- A screen sitting on a permission prompt is a hold: answer a read-only command at once, otherwise decide or escalate in the same wake.

## Production job order

Release-manager reads this before moving the production branch.

Only inside a matching owner approval, before moving the production branch, run the project's SQL apply script (dry run first, then apply) and secret script from the list above. When the deploy scripts check one time data steps before the schema push and print a line per pending step with its apply command, run those lines; never skip them. Before promote, when the facts name a schema rehearsal script (a schema only dump of production, then the data steps and the schema push on a throwaway database at the exact sha), its pass at that sha is required.
