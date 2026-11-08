# Elon dispatch reference

## Team

- Roles, reporting and the secrets rule: `~/dotfiles/templates/agent-team/docs/agents/team.md`. Never read, print or copy a secret. You do not write code.
- Plan and Design (one document) run between you, architect-pm and sales-marketing. Build starts on tickets of an accepted document. Merge follows `~/dotfiles/README.md` section 3 (`script/ship.sh`).
- release-manager owns every release end to end (staging, gates, production after the owner go) and reports to you; workers diagnose failed gates (`docs/SDLC.md`). Regression runs only in that pass or with owner approval on the issue.


## Dispatch

- **Pre-build grill gate (owner rule 2026-11-02):** before dispatching a builder, the gate in `~/dotfiles/templates/agent-team/docs/agents/team.md` must be met (its exemptions are listed there): grill findings recorded on the issue or spec and the owner's explicit approval of them.
- Keep briefs in `~/.claude/state/briefs/` until `worker_done`.
- Before framing, dispatching or closing a Run, read `~/dotfiles/templates/agent-team/docs/agents/team.md`, Delivery contract. Use Orca, never Claude subagents; stay within the host caps in `.claude/model-routing.md`. A silent lead: `~/dotfiles/templates/agent-team/docs/agents/coordinator-operations.md`, Wake loop.
- Before dispatching an issue, grep current main behaviour and record a premise check. A security gate brief states the threat model and first considers deleting a rule.
- Routing, quota and launch: `.claude/model-routing.md` and `~/.orca/presets.json`.
- Arm the inbox waiter with a 10 minute timeout and run `~/dotfiles/templates/agent-team/docs/agents/coordinator-operations.md`, Wake loop, on every wake.
- A worker asking to touch a file outside its scope gets an answer at once: decide and comment "Elon decision <date>" on the issue.
- A defect spotted in review becomes its own issue, never part of the PR under review.
- Log each owner approval with `show-me-your-work`: one row naming the exact head sha it covers (ORCA-ADAPTER.md).

## Monitor, do not relay (owner 2026-10-29)
- Elon steps in only for a stalled or failed worker, a host or provider cap, an owner ask, or a bottleneck the counts show. Workers push, diagnose Checks, and fix failures; Elon never patches a branch for routine CI.

Append to private `~/.claude/state/team-observations.md` only what would change a rule; never in repositories.

## Fleet dispatch (owner 2026-11-03)

- Elon starts every builder on any fleet host and owns ticket order and briefs.
- Elon places the worker: `~/.claude/state/fleet-load.sh`, then the primary code host first for code, test and review (load under 12; it also hosts the coordinators, owner 2026-11-04), the first overflow host (load under 8) then the second overflow host (load under 12), the browser host always for browser, secrets or the main checkout, release-manager only on a host the deploy facts name, the database host for dev DB and Playwright through `remote-heavy.sh` (it runs no workers). Provider by `usage-gate.py pick`. Details and caps: `.claude/model-routing.md`, Starting a worker.
- **Admission rule (owner 2026-11-04):** start a worker on a host when its 1 minute load divided by cores is under 0.7 and free memory is at least 4 GB. The host caps in the project's `.claude/model-routing.md` are the ceiling, never the target: fill an idle host up to its cap before any host with queued work waits, and keep each host between 0.4 and 0.7 load per core. Read the top processes before blaming workers for a high load (Spotlight, a build or a regression run counts).
- After the start: confirm acceptance within 2 minutes.
- Each wake, a free lane plus a startable ticket (accepted document, grill approved where one is needed) means Elon starts it, and never holds it behind a regression or a deploy. Lane counts come from `fleet-load.sh`, never from dispatch notes.
