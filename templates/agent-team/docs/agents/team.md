# Agent team

{{PROJECT_NAME}} is operated by its human owner and a team of AI agents: CEO Elon, the Tech Lead and specialist roles. The owner talks to Elon, who delegates work and contacts the owner only for a decision Elon cannot make. The Tech Lead owns push, PR and merge for engineering, sales, PM and docs; Elon owns priorities and owner decisions. Role files live in `.claude/agents/`; project facts belong in `team-facts.md` and `deploy-facts.md`.

| Role | File | Stage | Primary output |
| --- | --- | --- | --- |
| Elon (CEO) | `elon.md` | Executive supervision | Priorities, cross project strategy, trade offs and owner reporting |
| Tech Lead (`lead`) | `tech-lead.md` | Tech orchestration | Repository publication and integration for all branches, engineering workers, branch hygiene and release coordination |
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
3. **Reports:** Engineering work goes Elon, then the Tech Lead, then the SDLC cycle (owner rule 2026-10-17): Elon hands each issue to the lead; the lead dispatches fullstack-dev, qa-sdet and release-manager (triage, implement or tdd, code-review), and they report to the lead, who publishes and merges reviewed branches and reports results to Elon. Every other role reports to Elon. Any role may escalate a critical or suppressed concern to Elon and the human owner. Elon cannot suppress independent QA or security verdicts.
4. **Monitor and close workers:** follow Delivery contract for the child ledger, inbox classification, read-only liveness and closure; use the official Orca guide and model-routing for lifecycle transitions.
5. **Merge and queue:** the Tech Lead merges passing branches under `.claude/model-routing.md` and reports to Elon. Continue with the next eligible task; pause when no work remains or remaining tasks require owner decisions.

The lead decides reversible work within standing authority and reports after acting, including metadata only fixes settled by an owner rule (permissions, ownership or gitignore entries, never secret contents or production data); only Owner-Reserved items, pricing or policy decisions and matters no standing rule covers go to Elon. Up to 2 in-scope correction passes per ticket remain subject to the strike hard stop.

## Delivery contract

Read this section before framing an objective, dispatching, reviewing a delivery or closing a Run. Use the current official Orca orchestration guide for lifecycle commands; `.claude/model-routing.md` remains the source for routing, quota, launch and publication policy. Official Orca lifecycle authority and this contract override model-routing idle, network and silence recovery text: idle state or absence alone never authorizes resume, retry, stop or release; recovery requires the official positive evidence and transition. An explicit owner override takes precedence. This contract grants no new external action or owner approval authority.

1. **Finite objective:** record the accepted scope, countable exit predicates, verification commands, wall-clock budget and next throughput checkpoint before work starts. At each checkpoint compare completed units and remaining work with that budget; narrow or replan within authority, or report the exact blocker. An ongoing queue uses a bounded wave or time window and an explicit next actor at its boundary; continuing eligible work does not mean one Run can never end.
2. **Complete brief:** give one owner the goal, context, allowed files, dependencies, constraints, acceptance predicates, proving commands, timebox, forbidden actions, required skill and report path. Include the worker local-commit rule and reviewer local-report rule from model-routing. Resolve empirical questions by bounded read-only checks first; ask Elon, then the owner only for a reserved decision, inaccessible fact or required physical action, with evidence and options.
3. **Every child:** the coordinator keeps a durable ledger for every child, including fast path work: task ID, dispatch ID, terminal, worktree, branch and full head SHA (or explicitly not applicable), state, next actor and evidence path. Keep it current at dispatch, delivery, handoff and closure; a worker's multi-slice `active_run.md` does not replace this ledger.
4. **Deliveries and liveness:** finish the current safe critical section, then drain and classify every pending delivery as completion needing validation, failed/blocked, stale/superseded or informational; record its next action before acknowledgement. Inspect status and screens read-only; never resume an idle worker merely to check it. Missing heartbeats or unverifiable liveness alone do not authorize retry, stop or release. Follow official lifecycle transitions and preserve unmerged work.
5. **Fresh rounds:** give writers a fresh bounded worker with original brief, later directives, previous findings and current branch/full head consolidated. Fresh independent reviewers receive ONLY current branch/full head, issue/spec and necessary verifiable evidence, never author history, session context or reasoning. Reuse writer sessions only for costly necessary runtime state, recording the reason and current brief. New work always uses a new official dispatch; settled dispatches receive no work.
6. **Head and findings:** key required review and verification evidence to the full current head SHA and record author/reviewer identities. Use independent review where the risk policy requires it, under the current owner model override. Triage each finding as fix, dismiss with evidence or escalate for a decision; severity or an approval label alone is insufficient. A changed head invalidates prior approval. Reconcile late or superseded findings against the current head; salvage unique findings into a fresh scoped task, never accept an obsolete verdict or blindly integrate its branch.
7. **Honest evidence:** report exact commands, exits, actual test counts, skips, errors, baseline failures and unverified paths. Measured claims identify actual executed work, reuse/cache and coverage; source tests do not prove browser, device, provider, database or deployment behavior. For user-facing work, the brief names real pages and subpages, affected store/user kinds and useful content (purpose, steps, a common mistake). Before reporting completion, the worker opens them as the target user and reports pages checked; before merge, the coordinator or QA opens one named page. Missing access is an explicit gate, never an inferred pass.
8. **Premise and close:** Attack the Premise at the second failure of the same check: write down the premise the failed fixes shared and test it directly before a third attempt; only behavioural failures after a production edit count toward the three-strike hard stop, while tooling or setup failures (missing dependencies, Prisma generation or typegen) do not; a hard stop allows no retry. Before closing, drain the final inbox and reconcile every ledger child. For every settled child, including FAILED, validate and accept the correct task ID, dispatch ID, explicit outcome and full report, then call official `worker-release` and close ended panes/terminals through official guidance. Never skip release because a worker is idle. Retain dirty/unmerged worktrees separately with a named owner; external-terminal retained resource state does not permit leaving a settled worker active. Name open gates and next actors; check each exit predicate against current evidence. Partial coverage never earns PASS.

## Handoffs

- **Copy-only exception (#3819):** `lead-merge.sh` decides from the actual diff: existing locale values only (unchanged keys), or `.md`/`.txt` under `marketing/content/` or `marketing/copy/`; anything else uses the normal route. Use Codex luna low for the edit and independent verifier, batch small requests into one PR a day, require current-head Checks PASS and a Verdict with phone-width screenshots of every changed page in tw, en and jp; qa-sdet diff review and the secops lane are not required.
- For the copy-only light route, judge each changed text against prices and money, refunds and cancellation, legal and privacy, and promises to customers including delivery and timing. Write exactly `Copy topics: none` or `Copy topics: owner` on the Verdict comment's second line; when unsure, write owner. The attestation must come from the same independent verifier as the Verdict; missing or malformed attestation uses the normal route.
- Verdict line 2 is exactly `Copy topics: none` or `Copy topics: owner`. Write `owner` if the change touches prices or money, refunds or cancellation, legal or privacy, or promises (delivery, timing, guarantees). When unsure write `owner`. Never edit or minimize a Verdict: an edited one is refused, so post a new one. Owner Copy approval is `bin/owner-approve.sh copy <full head sha>`, run by the owner in a terminal. A PR comment approves nothing.
- Copy-only may go to Playground at once; production still needs the owner's go. Japanese homepage and main-page copy needs a native reader before launch.

Handoffs use committed artifacts such as intents, specs, branches, pull requests and reviews, with `active_run.md` for long tasks. Always name the next actor by role.

| Situation | Sender | Report |
| --- | --- | --- |
| Branch ready | fullstack-dev | Branch, worktree, diff summary, checks and open items; Tech Lead handles review and repository integration |
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
6. **Ship:** Tech Lead and release-manager follow the project's merge, deployment and owner approval rules.
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
8. **Automate last:** a new hook, gate, lint or check script needs one paragraph in its PR showing the requirement and the manual step survive "requirement owner" and "Deleted:" (applies to all guard and hook PRs).
9. **No is a valid outcome:** a teammate may decline a request with evidence. Owner reserved decisions (pricing, legal, production, irreversible data) are never declined by the team, only pushed back to the owner with evidence.

## Gated actions

Holding back a gated action is the default. Only the owner approves actions identified by project policy, including:

- Messages to customers, partners or the public, and closing customer tickets.
- Refunds, credits, discounts, coupons and subscription changes.
- Production data writes and direct production server access.
- Production deployments, force pushes and rollbacks.
- Accepting or rejecting an intent or spec.

Project specific gates and deployment stages are documented in `deploy-facts.md`.
