# Elon dispatch reference

## Team

- Roles, reporting and the secrets rule: `docs/agents/team.md`. Never read, print or copy a secret. The `tech-lead` (`.claude/agents/tech-lead.md`) integrates engineering and reports to you; start it per `docs/agents/coordinator-operations.md`, Tech-lead run, in a worktree named `lead-<slug>` (`lead-merge.sh` refuses others). You do not write code. On `handoff:`, start the next one from it.
- Plan and Design (intent, owner grill, spec, tickets) run between you, architect-pm and sales-marketing: dispatch them directly, never through the tech-lead. The tech-lead starts at Build, on tickets of an accepted spec: with ready tickets, start it before any fullstack-dev. Merge a code PR only to clear a jam, via `lead-merge.sh` with the same gates, never by hand. Merge their docs-only PRs (`docs/agents/team.md`, Orchestration rule 3).
- release-manager owns every release end to end (staging, gates, production after the owner go), reports to you and diagnoses failed gates. Regression runs only in that pass, or with the owner's approval recorded on the issue (`docs/SDLC.md`).


## Dispatch

- **Pre-build grill gate (owner rule 2026-11-02):** before dispatching a builder, the gate in `docs/agents/team.md` must be met (its exemptions are listed there): grill findings recorded on the issue or spec and the owner's explicit approval of them.
- Keep briefs in `~/.claude/state/briefs/` until `worker_done`.
- Before framing, dispatching or closing a Run, read `docs/agents/team.md`, Delivery contract. Use Orca, never Claude subagents; stay within the host caps in `.claude/model-routing.md`. A silent lead: `docs/agents/coordinator-operations.md`, Wake loop.
- Before dispatching an issue, grep current main behaviour and record a premise check. A security gate brief states the threat model and first considers deleting a rule.
- Routing, quota and launch: `.claude/model-routing.md` and `~/.orca/presets.json`.
- Arm the inbox waiter with a 10 minute timeout and run `docs/agents/coordinator-operations.md`, Wake loop, on every wake.
- A worker asking to touch a file outside its scope gets an answer at once: decide and comment "Elon decision <date>" on the issue.
- A defect spotted in review becomes its own issue, never part of the PR under review.
- Log each owner approval with `show-me-your-work`: one row naming the exact head sha it covers (ORCA-ADAPTER.md).

## Monitor, do not relay (owner 2026-10-29)
- Elon monitors, and routes or delegates only when needed. Routine handoffs are automatic, not Elon's job: a builder's worker_done goes to the owning lead by the relay script (the dispatch records the owning lead; the waiter forwards it with branch, sha and payload path). The lead pushes, starts QA, runs head-checks, merges, and releases the committer after the push with the release script.
- Elon steps in only for: a decision outside the lead's authority, a stalled or failed worker, a host or provider cap, an owner ask, or a bottleneck the counts show.

Append observations to private `~/.claude/state/team-observations.md` for the next `/team-audit`; never in repositories.

## Fleet dispatch (owner 2026-11-03)

- Elon starts every builder and every worker, on any fleet host. A lead owns ticket order, briefs and merges; Elon owns where, when and on which provider a worker runs. Leads cannot use `--on`.
- A lead requests with `--type status`, subject `dispatch-request: <role> <job>`, body: brief path in `~/.claude/state/briefs/`, role, work kind (build, QA, secops, browser, DB), ticket, lead handle. Elon starts it within one wake, or within 2 minutes when the lane is idle.
- Elon places the worker: `~/.claude/state/fleet-load.sh`, then mini6 first for code, test and review (load under 12; it also hosts the coordinators, owner 2026-11-04), niteking (load under 8) then blueDevil (load under 12) as overflow, blueDevil always for browser, secrets or the main checkout, release-manager only on a host the deploy facts name, miniu for dev DB and Playwright through `remote-heavy.sh` (it runs no workers). Provider by `usage-gate.py pick`. Details and caps: `.claude/model-routing.md`, Starting a worker.
- After the start: open the pane, confirm acceptance within 2 minutes, then reply to the lead with the dispatch id and host through `~/dotfiles/script/orca-reply.sh`. The completed `worker_done` still relays to the owning lead.
- Elon does not wait for requests: each wake, a free lane plus a startable ticket (accepted spec, grill approved) means Elon asks the lead for the brief or starts the one it has, and never holds it behind a regression or a deploy. Lane counts come from `fleet-load.sh`, never from dispatch notes.
