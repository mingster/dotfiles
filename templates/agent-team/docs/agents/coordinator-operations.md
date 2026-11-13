# Coordinator operations

Read before reporting status or reviewing process performance.

## Status evidence

- Provider quota comes from the readings (`python3 ~/dotfiles/script/usage-gate.py show`), never the gate verdict alone; the daily cap paces, it does not block (`.claude/model-routing.md`, Starting a worker). Non engineering worker state comes from its screen or `worker-list`. Say "not checked" for anything you did not check.
- Each wake, drain every pending delivery. Ack and drop heartbeat deliveries (`--type heartbeat`, empty body); never treat one as a report or relay it. When `orca orchestration check --run <run>` returns `consumer_fenced`, run `orca orchestration run-use --id <run>` first, then wait with `check --run <run> --wait` and `--ack` each batch. Never scrape the shared `orca orchestration inbox`.

## Process improvement

- For any unit over 10 minutes from start to MERGED, find and log a reason or structural fix the same wake with `~/dotfiles/script/team-audit.sh --log "<finding>" "<evidence>"`. A finding logged twice prints a promote line: open its fix ticket.
- Weekly measures from GitHub and Orca, never estimated: errors (bug or hotfix issues tied to PRs merged in the last 7 days, reverts, user re-asks, hard stops); speed (median hours from `ready-for-agent` or hotfix to MERGED); throughput (PRs merged per working day that close an issue or ship a reviewed change).
- Apply changes inside your authority at once; protected files and user decisions go to the user with the diff.

## Worker run

Read before your first dispatch. Worker accounting follows pstack Orchestrate, Supervision.

- At start and each wake, settle every unreleased dispatch from `orca orchestration worker-list --run <your run> --json`; a stopped or failed one follows the lifecycle transition in the Orca orchestration guide, preserving unmerged work. A new coordinator session adopts every live worker before new work.
- Answer a worker only with `~/dotfiles/script/orca-reply.sh --to <handle> --id <msg id> --body "<text>"`; a bare `orca orchestration reply` does not wake an idle worker.
- **Cursor worker trust marker:** start Cursor workers with `~/dotfiles/script/start-cursor-worker.sh` (`.claude/model-routing.md`, Cursor start rule); it creates the worktree and writes `.workspace-trusted` first.
- **Small task method** (brief to MERGED under 3 minutes): exact edits in the brief, worktree pre-created at `~/orca/workspaces/{{PROJECT_NAME}}/<lane>`, one Cursor `grok-4.7-xhigh` worker, merge on checks.

## Independent inbox watchdog

`script/fleet-watch.py` from dotfiles (`docs/agents/fleet-watch.md`) watches the inbox each minute, independent of your waiter. Schedule it on the coordinators' host and repoint its private config at every new Run (and `leads` whenever a lead restarts); both are explicit activation steps.

The waiter script and its output live in `~/.local/state/agent-team/` (`elon-wait.sh`, `elon-waiter.json`), never `/tmp`. Briefs tell workers to write temp files only in their scratch dir or worktree.

## User asks

- Permission, not hands: once the user is signed in (Chrome Dev 9223, Keychain, `fileServer/secrets/`), the coordinator, RM or QA finish the step. Never hand the user a command an agent can run.
- Send no message that needs nothing from the user.
- Append each user ask and answer to `~/.claude/state/elon-owner-asks.md` the turn it arrives (ask, issue, state, next gate). An ask closes only on production or when the user drops it.

## Wake loop

Run on every wake. One waiter per delivery, `--timeout-ms 3600000`, re-armed only after it fires; re-arm an empty timeout wake once, then the next wake is whatever fleet-watch or a worker sends.

- After every `worker-start`, run `~/.claude/skills/orca-team/worker-start-check.sh <dispatch>`; exit 1 (failed, or not accepted in 2 minutes) means restart once from the same brief. Do not open worker panes.
- `~/dotfiles/script/fleet-pull.sh`; report skipped dirty checkouts.
- `usage-gate.py show`, `worker-list` on your run, the `ready-for-agent` count, open PRs per project, and the release-manager screen.
- **GitHub budget:** 5000 REST calls an hour for the whole fleet. Before any `gh` call, read `gh api rate_limit --jq .resources.core.remaining`; below 500, use local git, `.orca` state and files only, and start no regression round or status post until it recovers. A script reading commit statuses fetches each sha once per process.
- `gh pr list --label needs-redesign`: apply `team.md`, Redesign.
- `gh pr list --label needs-elon`: decide each this wake. `Review: FAIL` beside a PASS Verdict holds the merge until you read the defect and record fix or override on the PR.
- `worker-watch.sh` on your run and every run with a live worker; replace a stalled worker per pstack Orchestrate. A verifier at a usage limit or idle is a stalled gate: restart it on the next `usage-gate.py pick` provider this wake. fleet-watch covers stalled workers and backup freshness on the coordinator host.
- A user ask open over 4 hours with no Playground deploy carrying it is a bottleneck: name the blocker and its user in the ask's ledger row.
- Queue empty: start architect-pm and sales-marketing planning within the hour. Send pending user asks as one numbered batch before the user leaves; one answer holds at most one unit.
- A screen on a permission prompt is a hold: answer a read-only command at once, otherwise decide or escalate this wake.
- **Sweep finished workers** (PR merged, `worker_done` for a settled task, or over 8 hours): match agent processes on every fleet host (`ps`, `lsof` for the working folder) to dispatches and merged PRs. For each finished one, `worker-release` the dispatch, `kill <pid>` from `ps` (never `pkill`), and remove its worktree when nothing is uncommitted or unmerged. A process under 8 hours with no dispatch and no PR: report it and ask the user. Finished workers count against host caps (`.claude/model-routing.md`, Starting a worker, step 5).

## Production job order

Release-manager reads this before moving the production branch.

Only inside a matching user approval, run the project's SQL apply script (dry run first, then apply) and secret script from the deploy facts. Run every pending one time data step the deploy scripts print. When the facts name a schema rehearsal script (a schema only dump of production, then the data steps and schema push on a throwaway database at the exact sha), its pass at that sha gates promote.

## Taking over the coordinator

Only when the user says so; failover is never automatic. On the host taking over, run `bash script/take-over-coordinator.sh --yes` (`--dry-run` to look first, `--help` for the steps). It fences the old host through `coordinator.conf` in the private agent-state repo and is safe to rerun. Hand back by running it on the other host. Left for the user: pair Orca on the new host and start the coordinator agent there.

A host not named in `coordinator.conf` refuses `sync.sh push`; the user decides what to keep from its live files.

## Coordinator check

`script/elon-startup.sh` (`== 0 coordinator`) reports whether this host is the coordinator with current state. `NO DISPATCH` means start no worker and ask the user; only the user changes the coordinator.
