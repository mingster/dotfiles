# Coordinator operations

Read before reporting status or reviewing process performance.

## Status evidence

- **Status sources** (user rule 2026-10-17; pstack Orchestrate, Supervision, covers live state checks). Provider quota comes from the real readings (`python3 ~/dotfiles/script/usage-gate.py show`), never the gate verdict alone, and the daily cap is a pacing estimate, not a block (`.claude/model-routing.md`, Starting a worker). Non engineering worker state comes from its screen or `worker-list`. If you did not check, say "not checked". On every wake drain every pending delivery. Heartbeat deliveries (`--type heartbeat`, an empty body with only task, dispatch and phase) come from the Orca runtime: ack and drop them, never treat one as a report or relay it (user 2026-11-02). If `orca orchestration check --run <run>` returns `consumer_fenced` (session restarted or compacted), run `orca orchestration run-use --id <run>` first; then wait with `check --run <run> --wait` and `--ack` each batch. Never scrape the shared `orca orchestration inbox` for your own messages.

## Process improvement (user 2026-10-19)

- Any unit over 10 minutes from start to MERGED gets a reason or structural fix logged with `~/dotfiles/script/team-audit.sh --log "<finding>" "<evidence>"` the same wake; finding it is the coordinator's job.
- Measures, read weekly from GitHub and Orca, never estimated:
  1. Errors: post-merge defects (a bug or hotfix issue tied to a PR merged in the last 7 days), reverts, user re-asks, hard stops.
  2. Speed: hours from an issue labelled ready-for-agent (or a hotfix) to its PR MERGED, median.
  3. Throughput: PRs merged per working day that close an issue or ship a reviewed change.
- Log each finding the same way; a finding seen twice prints a promote line, so open its fix ticket. Apply changes inside the coordinator's authority at once; protected files and user decisions go to the user with the diff.

## Worker run

Read this before your first dispatch. Accounting for every worker follows pstack Orchestrate, Supervision; these are the Orca gates.

- At start and on every wake, settle each unreleased dispatch from `orca orchestration worker-list --run <your run> --json`; a stopped or failed one follows the lifecycle transition in the official Orca orchestration guide, preserving unmerged work. A new coordinator session adopts every live worker before new work.
- Answer a worker only with `~/dotfiles/script/orca-reply.sh --to <handle> --id <msg id> --body "<text>"`. Never a bare `orca orchestration reply`: it does not wake an idle worker (approvals sat 10+ minutes). `orca-reply.sh` replies, nudges the terminal and refuses an empty `--to`.
- Never hand-dispatch a verifier: `fleet-watch.py` starts one once the PR checks are green at the head. A builder hands off only on green checks (its Finish waits for them), so a red or pending head goes back to the builder, not to a verifier.
- **Cursor worker trust marker:** use `~/dotfiles/script/start-cursor-worker.sh` as described in `.claude/model-routing.md`, Cursor start rule. It creates the worktree and writes `.workspace-trusted` before spawning the worker.

- **Small task method** (brief to MERGED under 3 minutes): exact edits in the brief, worktree pre-created at `~/orca/workspaces/{{PROJECT_NAME}}/<lane>`, one Cursor `grok-4.7-xhigh` worker, merge on checks.

## Independent inbox watchdog

Configure `script/fleet-watch.py` from dotfiles with this run, coordinator terminal and unique waiter pattern in a private config. An independent minute scheduler runs it; the coordinator waiter cannot supervise itself. It warns after ten minutes of unacked deliveries without a waiter, on failed dispatches, on host caps including children, and once when a lead pane listed under `leads` (name and terminal handle) is gone; update `leads` whenever a lead restarts. List each lead Run in `runs` too (`terminal` the lead, `waiter_pattern` its `check --run <run> --wait`), so a lead with unread deliveries and no waiter gets the terminal wake. Schedule it on the host that runs the coordinators and repoint it at every new Run: a config naming an old Run watches nothing. See dotfiles `docs/agents/fleet-watch.md`; scheduling and terminal selection are explicit activation steps.

The inbox waiter script and its output file live in `~/.local/state/agent-team/` (`elon-wait.sh`, `elon-waiter.json`), never in `/tmp`, where worktree cleanup cleans agent temp files. Briefs tell workers to write temp files only inside their scratch dir or worktree.

## User asks

- Permission, not hands: once the user is signed in (Chrome Dev 9223, Keychain, `fileServer/secrets/`), the coordinator, RM or QA finish the step (agent-browser, `orca computer`, scripts). Never hand the user a command an agent can run.
- A message that needs nothing from the user is not sent.
- Ledger: append each user ask and each answer to `~/.claude/state/elon-owner-asks.md` the turn it arrives (ask, issue, state, next gate). An ask is closed only when it is on production or the user drops it.

## Wake loop

The coordinator runs this on every wake. One waiter per delivery, `--timeout-ms 3600000`, re-armed only after it fires; an empty timeout wake is re-armed once, then the next wake is whatever fleet-watch or a worker sends (owner decision 2026-11-13, #970).

- After every `worker-start`, run `~/.claude/skills/orca-team/worker-start-check.sh <dispatch>`: exit 1 (failed or not accepted in 2 minutes) means restart once from the same brief. A silent start failure (`agent_not_in_foreground`) once sat unnoticed. Do not open worker panes.
- `~/dotfiles/script/fleet-pull.sh` on every wake: a host whose dotfiles or main checkout lags breaks the fleet scripts (a lagging `wrap-up.sh` failed on jq). Report skipped dirty checkouts.
- `usage-gate.py show`, `worker-list` on your run, the ready-for-agent count, the open PR count per project, and a read of the release-manager screen.
- **GitHub budget (audit 2026-11-05):** the REST limit is 5000 calls an hour for the whole fleet, shared by every host. Before any `gh` call in a wake, read `gh api rate_limit --jq .resources.core.remaining`; below 500, use local git, `.orca` state and files only, and do not start a regression round or a status post until it recovers (`reset` is the epoch second). A script that reads commit statuses must fetch each sha once per process (memoize), never once per area.
- `gh pr list --label needs-redesign`: each PR whose Verdict or Review failed twice. Close it with a comment naming what both failures showed, then dispatch a redesign (a fresh worker, a new brief that restates the goal from first principles and names those two lessons). Never send a third patch. Tell the user only if the redesign also dead ends.
- `gh pr list --label needs-elon`: decide each one this wake. `Review: FAIL` beside a PASS Verdict holds the merge until the coordinator reads the defect and records fix or override on the PR.
- `worker-watch.sh` on your run and on every run with a live worker (it already includes remote workers); replacing a stalled worker follows pstack Orchestrate. A verifier at a usage limit or idle is a stalled gate: restart it on the next `usage-gate.py pick` provider in the same wake. Stalled workers and backup freshness are covered by `fleet-watch.py` on the coordinator host (`docs/agents/fleet-watch.md`), not a separate script.
- User ask open over 4 hours with no Playground deploy carrying it is a bottleneck: name the blocker and its user in the ask's ledger row this wake.
- Queue empty: start architect-pm and sales-marketing planning within the hour. Send pending user asks as one numbered batch before he leaves; one answer holds at most one unit.
- A screen sitting on a permission prompt is a hold: answer a read-only command at once, otherwise decide or escalate in the same wake.
- **Sweep finished workers (user 2026-11-04).** A worker is finished when its PR is merged, when it has sent `worker_done` for a settled task, or when it has run over 8 hours. Each wake, list the agent processes on every fleet host (`ps`, and `lsof` for the working folder) and match them to dispatches and merged PRs. For each finished one, in the same wake: `worker-release` the dispatch, `kill <pid>` read from `ps` (never `pkill`), and remove its worktree when nothing is uncommitted and nothing is unmerged. A process with no dispatch and no PR that is under 8 hours is not finished: report it and ask the user. This checks `.claude/model-routing.md`, Starting a worker, step 5 (close a worker right after its report); finished workers left running count against the host caps.

## Production job order

Release-manager reads this before moving the production branch.

Only inside a matching user approval, before moving the production branch, run the project's SQL apply script (dry run first, then apply) and secret script from the list above. When the deploy scripts check one time data steps before the schema push and print a line per pending step with its apply command, run those lines; never skip them. Before promote, when the facts name a schema rehearsal script (a schema only dump of production, then the data steps and the schema push on a throwaway database at the exact sha), its pass at that sha is required.

## Taking over the coordinator

Do this only when the user says so. Failover is never automatic and nothing schedules it. Roles live in the private agent-state repo, in `coordinator.conf`: one `coordinator <name>` line and ordered `backup <name>` lines, where each name is what `hostname -s` prints on that host.

On the host that is taking over, run:

```sh
bash script/take-over-coordinator.sh --yes            # --dry-run to look first
```

It prints its plan and refuses without `--yes`. In order, it:

1. fetches and fast-forwards the agent-state checkout (`~/agent-state`, or `--state-dir`). It stops if there are unpushed commits or uncommitted changes, and lists them.
2. checks this host is a `backup` line. If an earlier backup answers ssh it stops and names that host; run the command there, or pass `--skip-order` to continue anyway.
3. sets `coordinator <this host>` in `coordinator.conf`, commits only that file and pushes. A rejected push is retried once after a fresh fetch. The old coordinator takes this host's place in the backup list, so it can hand back later.
4. stops the old host's sync over ssh (6 second timeout). It reports `old host sync stopped` or `old host unreachable, fenced by coordinator.conf`. Unreachable is a pass, because step 3 already holds it.
5. restores live state with `sync.sh pull`, keeping this host's own `~/.zshenv.local`.
6. installs and loads only the sync LaunchAgent, then touches `.sync-ok`.
7. runs one `sync.sh push` and prints the result.

Any failure stops at that step and prints the state and the next command. Running it again is safe. On a host that is already the coordinator it only repeats the restore, the LaunchAgent and the push.

Left for the user afterwards: pair Orca on the new host and start the coordinator agent there.

### When the old host comes back

Every `sync.sh push` first fetches origin and reads the `coordinator` line. If this host is not named, it refuses with `coordinator refused: this host is not <name>`, writes `.sync-refused`, alerts the fleet terminals and exits 1, before copying, committing or pushing anything. A failed fetch refuses too. The old host's live files stay as they were and origin is unchanged. The user decides what to keep from them.

### Handing back

Run the same command on the other host: `bash script/take-over-coordinator.sh --yes`. The current coordinator is stopped and fenced the same way, and the host handing back becomes a backup again.

## Coordinator check

`script/elon-startup.sh` opens with `== 0 coordinator`, before the pull. It only reports and never blocks or changes anything. It fetches the private state repo (`${AGENT_STATE_DIR:-$HOME/agent-state}`, 10 second limit), reads `coordinator` from `origin/main:coordinator.conf`, and runs three checks:

1. This host is the coordinator (`hostname -s`, compared without case).
2. The local state repo is not behind `origin/main`.
3. `.sync-ok` in the state repo is under 30 minutes old (three sync periods). A missing file counts as stale.

Each failure prints a `PROBLEM` line and a `NO DISPATCH: <reason>` line. A missing state repo, a missing `coordinator` line and a failed fetch also print `NO DISPATCH`. When all pass it prints `ok coordinator <name>, state fresh`.

`NO DISPATCH` means start no worker and ask the user. Failover is never automatic: only the user changes the coordinator.
