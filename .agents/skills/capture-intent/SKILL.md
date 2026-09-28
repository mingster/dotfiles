---
name: capture-intent
description: Turn a product idea, pain point or incident into a committed intent.md (Plan stage of the AI-native SDLC). Use when the owner describes something the product should do differently, says "capture intent" or "/capture-intent", or an incident needs a product change.
---

# Capture intent

An intent is the first artifact of a change: the problem and the wanted outcome, in the owner's own words, before anyone designs a solution. It is committed so the next stage (Design, `write-spec`) starts from it.

## When to use it

Only for new features and changes to how the product behaves. Bugs, refactors, chores and dependency updates go straight to an issue; say so and stop.

## Steps

1. If the repo has `docs/SDLC.md`, read it first: it gives the folder, the approver and any repo rules. Otherwise use `docs/intent/<YYYY-MM-DD>-<slug>/intent.md`.
2. Let the owner describe the problem. Ask questions one round at a time, numbered, each with your suggested answer, until you can state: who hurts, when, how often, and what "better" looks like. Look up facts yourself (code, docs, issues); only ask about things the owner decides.
3. Stay on the problem. Do not choose a design, name tables or pick libraries; that is `write-spec`. If the owner proposes a solution, record it under Proposed outcome as their preference, not as a decision.
4. Write the file in the owner's language and wording (Chinese is fine). Use the template below.
5. Show the draft, apply corrections, then commit it on its own (`docs: intent <slug>`), unless the owner says otherwise.

## Template

```markdown
# <Title in the owner's words>

Status: Proposed <YYYY-MM-DD>
Author: <owner>

## Problem
What happens today, to whom, and why it matters. Evidence if there is any (numbers, issues, messages).

## Proposed outcome
What is true when this is done, from the user's side. Not how it is built.

## Affected users and systems
Roles (customer, Store operator, platform admin...) and the product areas or integrations touched.

## Constraints
Deadlines, budgets, laws, platform limits, things that must not change.

## Open questions
What the owner does not know yet. The riskiest assumption goes first.
```

## Status

The header keeps the history on one line: `Status: Proposed 2026-09-28 · Accepted 2026-09-30 · Shipped 2026-10-12 (#1234)`. The owner is the only approver. Rejected intents stay in place as the record. After the spec is accepted, the intent is frozen.

## Writing rules

No em dashes or spaced hyphens as punctuation. Short sentences. No solution design.
