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
