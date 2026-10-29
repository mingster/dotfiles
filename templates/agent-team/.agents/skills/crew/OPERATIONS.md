# Completion and review contracts

Read before dispatch or completion handling. Project owner decisions and `docs/agents/team.md` retain authority; Orca's installed orchestration guide defines supported runtime commands. These contracts do not grant new quota, host capacity, protected-path access or publication authority.

## Elon: every inbox read ends with a waiter

Treat read, process, acknowledge, drain and rearm as one wake transaction. Record the Run, processed delivery IDs and new waiter receipt in private state. Acknowledge only processed messages; drain until empty, then arm the next waiter before returning to other work. An error or disconnected wait requires recovery and a fresh receipt, never an assumption that the old waiter survived. A timeout is not approval on an Owner-Reserved item.

## Lead and Elon: count occupied host slots

Before every launch, count each host's builders, reviewers, child dispatches and completed committers still holding a pending-push slot. Release a committer's slot only after the owning lead confirms the push and resource release. A task marked complete is insufficient. Apply existing host and provider caps together; do not raise either cap. Missing remote observations or unknown release state do not prove a free slot: refresh the host inventory before admitting another worker there.

## Reviewers and leads: append Verdicts

Preserve every prior Verdict, including malformed comments and FAILs superseded by later evidence. Append a correction referencing the original, exact head, author and verifier dispatch IDs. Neither a lead nor the original author deletes review history. The project's canonical Verdict format and supersession rules determine acceptance; a correction alone grants no merge authority.

## Builders: prove partial mocks before handing off

When touching a partial module mock, inventory the real exports used by the affected call sites and preserve them with the project's real-module helper. Use the established real-module helper and include the project's partial-module contract check alongside the touched tests in the scoped verification brief. A bare fake must not first reach the batch's head checks. Follow the project's test authority and heavy-gate admission; list unrun checks explicitly. Other projects use their established equivalent, without introducing a new mock framework for this rule.

## Lead: stop repeating a failed premise

Apply Delivery contract 8 in `docs/agents/team.md`, rather than inventing another remediation counter. On the second behavioral failure of the same premise, return to diagnosis/design with the concrete failing path, all sibling call sites and a state/case matrix; assign each case a proving check before another patch. For deletion code, include every deletion path and unknown inspection state. Tooling failures and tests that never ran are reported separately under the existing strike rule. Do not spend additional model quota or widen scope without the required authority.

## Lead and QA: remote and family provenance

A remote brief records host, saved environment selector, Run, dispatch, terminal, worktree, selected model and model family. Inspect that host through the supported Orca environment and paginate the inventory. A local-only worker watch is incomplete coverage, never remote health proof. Choose independent QA from the selected model family, not the provider label: a provider may serve several families. If a helper rejects an author family or cannot prove remote capability, retain the author identity and use an authorized route with those receipts; do not relabel the author as another provider to make the helper accept it. Unknown family cannot satisfy independent review.

A rule-covered integration or routing choice stays with the owning lead; report its decision and evidence rather than escalating the same standing-authority question to Elon. Escalate an actual owner boundary or unavailable required capability with the missing receipt.
