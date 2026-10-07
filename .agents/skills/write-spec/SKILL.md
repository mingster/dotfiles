---
name: write-spec
description: "Write spec.md for an accepted intent.md (Design stage of the AI-native SDLC): requirements and design for this codebase, conflicts with existing decisions, glossary terms and ADRs. Use when an intent is accepted, or the owner says \"write the spec\" or \"/write-spec\" for an intent folder."
---

# Write spec

The spec answers the intent: what exactly will be built in this codebase and why that way. It is committed next to its intent, and the pair is frozen once the spec is accepted. It records what was asked for and what was decided.

## Before writing

1. Read `docs/SDLC.md` if it exists; it overrides these defaults.
2. Read the intent. Its Status must include `Accepted`; if not, ask the owner to accept or edit it first.
3. Read `CONTEXT.md`, the ADRs that touch the area, the area's living design notes (`docs/<AREA>/_INDEX.md`) and the code paths involved. Find facts yourself.
4. Grill the owner on every decision the intent leaves open (use the `grilling` and `domain-modeling` skills, or `/grill-with-docs`): numbered rounds, each question with your recommended answer, until nothing is silently assumed. Record settled terms in `CONTEXT.md` and hard-to-reverse trade-offs as ADRs as they settle.

## spec.md template

```markdown
# <Intent title>: spec

Status: Proposed <YYYY-MM-DD>
Intent: [intent](intent.md)

## Summary
Two or three sentences: what changes for whom.

## Requirements
Numbered, testable statements in glossary terms. Each one says who can do what, and what happens on failure.

## Design
How it fits the current code: data model changes, where the logic lives, screens and routes, jobs, integrations, permissions. Name real files and modules.

## Decisions and conflicts
Which ADRs this relies on, amends or supersedes (link new ADRs). Any place where two policies cannot both be satisfied, and who must decide.

## Out of scope
What this spec deliberately leaves out.

## Verification
The tests and regression areas that prove each requirement. Every requirement maps to at least one check.

## Rollout
Migrations, backfills, flags, environments, anything the deploy needs.
```

## After writing

Show the draft, apply corrections, and when the owner accepts it set `Status: Proposed ... · Accepted <date>` in both files' history as appropriate, then commit (`docs: spec <slug>`). Next: break it into issues (`to-tickets`). If the plan changes during Build, record the change in the PR or a new ADR; do not edit the frozen pair.

## Writing rules

English, glossary terms from `CONTEXT.md`, no em dashes or spaced hyphens as punctuation.
