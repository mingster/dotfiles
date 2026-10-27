---
name: team-grill-backlog
description: Team backlog sweep. Elon sends architect-pm and sales-marketing through every open issue that is not agent ready (blocked, owner-action, ready-for-human, needs-triage), they turn what they can into ready-for-agent work and propose A/B decisions, Elon decides and dispatches. The owner is asked only for Owner-Reserved calls and his own hands. Use with /team-grill-backlog, "review open issues", or when Elon has no work to dispatch.
---

# Team grill the backlog

Run by Elon. Goal: refill the agent-ready queue without the owner. `grill-backlog` grills the owner; this one has the team grill itself first.

## When

- The owner asks ("review open issues", "get issues agent ready").
- Elon has no work: the ready-for-agent queue is under 3 and no lane is waiting on a brief. Skip it when the last sweep was under 2 hours ago and no issue in scope changed since (`gh issue list --search "updated:>=<last sweep>"`).

## 1. Collect and split

From the repo root, with the tracker in `docs/agents/issue-tracker.md`, list every open issue that is not `ready-for-agent`. Split them in two lists by area:

- architect-pm: product, engineering, ops, data, deploy, integrations.
- sales-marketing: marketing, channels, social, messaging providers, payments providers, tax and legal.

## 2. Dispatch

Every ready-for-agent ticket has `## Acceptance criteria` (observable cases and exact proving command), `Requirement owner: <requester and reason>` and `Deleted: <removed requirement or nothing, because ...>` in one body or comment. A second Done condition repeats acceptance criteria and is unnecessary.

Start one read-only worker per role with Orca orchestration (the `orchestration` skill), light load, no browser. Brief, in English, for each:

```
Role: <role> (read .claude/agents/<role>.md). Backlog sweep, no code. Elon decides; you propose and prepare.
Your issues: <numbers>
For each issue read the body, the last comments and any linked spec or ADR, then sort it with the kinds in the grill-backlog skill, section 2:
1. Fact the repo or a read-only query answers: answer it on the issue.
2. Production step by procedure: rewrite as release-manager steps for the next release; relabel ready-for-agent if nothing else blocks.
3. Product, scope or copy call: comment "Proposed decision (Elon to confirm)" with A (recommended, one line why) and B.
4. Needs the owner's own hands: make sure the exact steps are on the issue, paste ready.
5. Blocked: check the blocker is still real. If a slice can be built now, file it as a new ready-for-agent issue with acceptance criteria and the proving test (search first, docs/agents/issue-budget.md).
On a non-Owner-Reserved ask timeout, proceed with recommended A and label "Elon decision pending"; report it to Elon. Owner-Reserved work remains blocked.
Never change a priority or close an issue. Never touch Owner-Reserved items (pricing rulings, prod data, credentials). Never read secrets.
Finish within 30 minutes. worker_done: one line per issue (number, kind, action), new ready-for-agent numbers, proposed decisions as a numbered A/B list.
```

## 3. Decide

For each proposal, Elon picks A or B, comments "Elon decision <date>: <choice>. <one line>" on the issue, and relabels it ready-for-agent when nothing else blocks. An Owner-Reserved call goes to the owner in one numbered round, each with the recommendation.

## 4. Hand over

- New ready-for-agent issues go to the tech-lead in one message.
- Kind 2 steps join the next release brief through `deploy`.
- Kind 4 items: tell the owner only the ones new since the last sweep, with the exact steps.

## Done when

Both worker_done reports are in, every proposal has an Elon decision on its issue, and the new ready-for-agent issues are with the tech-lead. Report to the owner in one short message: how many issues became agent ready, and anything only he can do.
