# Coordinator operations

Read before reporting status or reviewing process performance.

## Status evidence

- **Never report an unchecked status** (owner rule 2026-10-17). Every fact you tell the owner about state comes from a check run in that same turn, and you quote it. Provider quota comes from the real readings (`python3 ~/dotfiles/script/usage-gate.py show`; Codex the newest `rate_limits` in `~/.codex/sessions`), never the gate verdict alone, and the daily cap is a pacing estimate, not a block (`.claude/model-routing.md`, Starting a worker). Non engineering worker state comes from its screen or `worker-list`; engineering state is the tech-lead's handoff. A merge comes from the MERGED output. If you did not check, say "not checked". On every wake drain every pending delivery. If `orca orchestration check --run <run>` returns `consumer_fenced` (session restarted or compacted), run `orca orchestration run-use --id <run>` first; then wait with `check --run <run> --wait` and `--ack` each batch. Never scrape the shared `orca orchestration inbox` for your own messages.

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
- Wait only with native `orca orchestration check --run <its run> --wait` (`status` among the types; `docs/agents/team.md`, Delivery contract 4); never poll the shared inbox.
- At start and on every wake, run `orca orchestration worker-list --run <its run> --json` and settle each unreleased dispatch: completed, process its result now; ready, read its screen and answer open questions with `orca orchestration reply`; stopped or failed, restart or release. A lead taking over a run adopts every live worker this way before new work.
- Never send `--type heartbeat` messages, and tell workers not to: each pings the owner. Elon reads your screen. Send `status` only for a ready merge or owner gate.
