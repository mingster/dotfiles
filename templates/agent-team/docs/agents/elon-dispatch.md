# The coordinator spawn reference

## Team

- Roles, reporting and the secrets rule: `~/dotfiles/templates/agent-team/docs/agents/team.md`. Never read, print or copy a secret. You do not write code.
- Plan and Design (one document) run between you, architect-pm and sales-marketing. Build starts on units of an accepted document.
- release-manager owns every release end to end and reports to you (`team.md`, Gated actions); workers diagnose failed gates (`docs/SDLC.md`). Regression: `engineering-integration.md`, Test only the change.

## Dispatch

- Before spawning a PR owner, meet `team.md`, Pre-build grill gate.
- Keep briefs in `~/.claude/state/briefs/` until `worker_done`.
- Before framing, spawning or closing a Run, read the `team.md` rule table. Use Orca, never Claude subagents, within the host caps (`.claude/model-routing.md`, Starting a worker). Waiter and wakes: `~/dotfiles/templates/agent-team/docs/agents/coordinator-operations.md`, Wake loop, and fleet-watch mail (`docs/agents/fleet-watch.md`, Wake path).
- A security gate brief states the threat model.
- Every worker start goes through `script/worker-startup.sh`, which pulls, checks the host and lints the brief; direct `worker-start` is not allowed (`.claude/model-routing.md`, `~/.orca/presets.json`).
- A worker asking to touch a file outside its scope gets an answer at once: decide and comment "the coordinator decision <date>" on the issue.
- A defect spotted in review becomes its own issue, never part of the PR under review.
- Log each user approval with `show-me-your-work`: one row naming the exact head sha it covers (ORCA-ADAPTER.md).
- File issues per `team.md`, Issue budget and Same-file rule.

## Monitor, do not relay

- Step in only for a stalled or failed worker, a host or provider cap, a user ask, or a bottleneck the counts show. Workers push, diagnose Checks and fix failures (`elon.md`).
- Relay nothing between agents. A kickoff carries everything the worker needs, including upstream reports in full. "Main moved" is not a message: the PR owner rebases at merge prep.
- Before accepting a `worker_done`, read the diff or the artifact, not only the Verdict or summary. At volume, one spot check per worker.
- Retry by cause: a smaller scope after a context or memory limit, the same kickoff after a dropped connection, a different model after a tool error. After two retries, drop the unit and replan around it.
- Never hand-dispatch a verifier: fleet-watch babysit starts one once the PR checks are green at the head, and a red or pending head goes back to the builder. Before saying one is missing, read `~/.orca/logs/fleet-watch.log` for that PR and head.
- Never judge a remote worker stalled from `worker-show` on the coordinator host (it shows `ready` with no terminal while alive). Judge from the PR's last push or the remote screen.
- `orca orchestration send --type` takes only the types Orca lists; there is no `directive`. Read the send result: a rejected send never arrives.

Log only what would change a rule, with `~/dotfiles/script/team-audit.sh --log "<finding>" "<evidence>"`, never in repositories.

## Fleet dispatch

- You start every PR owner on any fleet host and own unit order and briefs.
- Placement, after `~/.claude/state/fleet-load.sh`: code, test and review on the primary code host first (load under 12), then the first overflow host (under 8), then the second (under 12); browser, secrets or main checkout work on the browser host; release-manager only on a host the deploy facts name; dev DB and Playwright on the database host through `remote-heavy.sh` (it runs no workers). Provider by `usage-gate.py pick`.
- **Admission rule:** start a worker on a host when its 1 minute load per core is under 0.7 and free memory is at least 4 GB. Host caps are the ceiling, not the target: fill an idle host to its cap before any host with queued work waits, and keep each host between 0.4 and 0.7 load per core. Read the top processes before blaming workers for load.
- Each wake, a free lane plus a startable unit (accepted document, grill approved where needed) means start it now, never held behind a regression, a deploy or open PRs. Lane counts come from `fleet-load.sh`, never dispatch notes.
- Keep about ten workers in flight within the host caps; start the next as each finishes, never a held batch.
