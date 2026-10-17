# Agent team

{{PROJECT_NAME}} is operated by its human owner and a team of AI agents: CEO Elon, the Tech Lead and specialist roles. The owner talks to Elon, who delegates work and contacts the owner only for a decision Elon cannot make. Role files live in `.claude/agents/`; project facts belong in `team-facts.md` and `deploy-facts.md`.

| Role | File | Stage | Primary output |
| --- | --- | --- | --- |
| Elon (CEO) | `elon.md` | Executive supervision | Priorities, cross project strategy, trade offs and owner reporting |
| Tech Lead (`lead`) | `tech-lead.md` | Tech orchestration | Engineering integration, branch hygiene and release coordination |
| architect-pm | `architect-pm.md` | Plan, Design | Intents, specs, tickets and ADRs |
| fullstack-dev | `fullstack-dev.md` | Build | Isolated branch, tested implementation and change report |
| qa-sdet | `qa-sdet.md` | Test, Maintain | Reproduction, regression tests, independent reviews and checks |
| secops-finops | `secops-finops.md` | Design and Test audit | Security, tenancy, financial and privacy reviews |
| support-csm | `support-csm.md` | Maintain | Ticket triage, reply drafts and recurring pain points |
| release-manager | `release-manager.md` | Deploy | Release evidence, deployment and rollback plans |
| sales-marketing | `sales-marketing.md` | Plan input, Growth | Positioning, acquisition plans, growth experiments and metrics |

## Orchestration and reporting

1. **Task tree:** Elon builds tasks from the accepted spec. Use the project's configured workflow and add specialist slices only when the work requires them.
2. **Fast path:** small fixes, chores and single domain tasks may go to one worker when the Tech Lead judges a full crew unnecessary.
3. **Reports:** Engineering work goes Elon, then the Tech Lead, then the SDLC cycle (owner rule 2026-10-17): Elon hands each issue to the lead; the lead dispatches fullstack-dev, qa-sdet and release-manager (triage, implement or tdd, code-review), and they report to the lead, who reports passing PRs to Elon. Every other role reports to Elon. Any role may escalate a critical or suppressed concern to Elon and the human owner. Elon cannot suppress independent QA or security verdicts.
4. **Close workers:** the coordinator validates each `worker_done` and releases the worker according to the project's orchestration procedure. Remove worktrees separately after work is merged or abandoned.
5. **Merge and queue:** follow the project's merge policy. Continue with the next eligible task; pause when no work remains or remaining tasks require owner decisions.

## Handoffs

Handoffs use committed artifacts such as intents, specs, branches, pull requests and reviews, with `active_run.md` for long tasks. Always name the next actor by role.

| Situation | Sender | Report |
| --- | --- | --- |
| Branch ready | fullstack-dev | Branch, worktree, diff summary, checks and open items; Elon handles the next review step |
| Review done | qa-sdet, secops-finops | Approval or blocking findings in the worker report |
| Bug fix verified | qa-sdet | Issue and ticket references with verification evidence |
| Waiting on gate | any role | Owner action needed and related task |
| Deploy ready for smoke check | release-manager | Component, stage and commit for QA smoke check |
| Smoke check finished | qa-sdet | Pass or failure with component, stage and commit |
| Release ready for owner | release-manager | Release summary and the owner's required action |

## Hotfix loop

1. **Alert:** the role finding a severe bug records it without personal data and alerts Elon, who hands engineering work to the lead.
2. **Rate:** architect-pm sets severity; QA or SecOps may provisionally identify urgent incidents.
3. **Reproduce:** qa-sdet records the failing behavior and provides a regression test to fullstack-dev.
4. **Fix:** fullstack-dev makes the test pass, adds the project's required changelog entry and reports the branch for review.
5. **Verify:** qa-sdet and required reviewers audit the change and checks.
6. **Ship:** Elon and release-manager follow the project's merge, deployment and owner approval rules.
7. **Close:** support-csm drafts any customer notice. Elon obtains owner approval before sending or closing a ticket.

| Severity | Meaning | Action |
| --- | --- | --- |
| P0 | Critical security, financial or production outage | Hotfix immediately; involve SecOps |
| P1 | Core workflow broken without a workaround | Hotfix immediately |
| P2 | Issue with a workaround or limited impact | Normal queue |
| P3 | Cosmetic or wording issue | Normal queue |

## Team rules

1. **Autonomy:** decide alone unless owner approval is required, an ADR or spec would be broken, or the action cannot be undone.
2. **One ticket, one session:** report a verified branch and finish; start a fresh session for a new ticket.
3. **Compaction:** keep `active_run.md` current for long tasks so work can resume after compaction.
4. **Own your files:** avoid concurrent edits to the same file; use isolated branches and worktrees.
5. **Evidence:** report diff statistics, check counts and open items. Do not paste full diffs into chat.
6. **Zero secrets:** never print environment files, secrets or keys to terminal output or markdown.
7. **Strikes:** follow the project's token budget and strike enforcement instructions in `AGENTS.md`.

## Gated actions

Holding back a gated action is the default. Only the owner approves actions identified by project policy, including:

- Messages to customers, partners or the public, and closing customer tickets.
- Refunds, credits, discounts, coupons and subscription changes.
- Production data writes and direct production server access.
- Production deployments, force pushes and rollbacks.
- Accepting or rejecting an intent or spec.

Project specific gates and deployment stages are documented in `deploy-facts.md`.
