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
4. Use the `grill-with-docs` skill for unresolved decisions and domain records: read `~/.agents/skills/grill-with-docs/SKILL.md` and follow it.

## spec.md template

```markdown
# <Intent title>: spec

Status: Proposed <YYYY-MM-DD>
Intent: [intent](intent.md)

## Summary
Two or three sentences: what changes for whom.

Deleted: the flag, step, layer or requirement this removes, or "nothing, because ...".

## Requirements
Numbered, testable statements in glossary terms. Each one says who can do what, what happens on failure, and who asked for it and why (a person, never "the ticket", "the reviewer", "the linter" or "the old code").

## Design
When the spec touches a shared module (wallet or ledger, notifications, auth or permissions, any lib others call), open with the caller's usage, then types and signatures, then the module map. Settle any open question that running code can answer with a throwaway spike in a scratch dir and paste the result here; only product trade-offs go to the owner.

How it fits the current code: data model changes, where the logic lives, screens and routes, jobs, integrations, permissions. Name real files and modules.

## Decisions and conflicts
Which ADRs this relies on, amends or supersedes (link new ADRs). Any place where two policies cannot both be satisfied, and who must decide.

## Out of scope
What this spec deliberately leaves out.

## Risk checklist
One line each: tenancy, money, auth, data deletion. Security and cross-family review run on the first built slice, not on this spec.

## Test plan
The Functional tests that prove each requirement (owner rule 2026-10-21): numbered test cases, each naming the requirement it proves, the test file or command, and the observable result (command output, screenshot, DB row), never only "tests pass". Every requirement maps to at least one case. Each ticket later lists the cases it owns; passing them is the ticket's definition of done. Do not list Regression (the full suite) here: it runs only in the development pass before staging, or for a very large update with owner approval.

## Rollout
Migrations, backfills, flags, environments, anything the deploy needs.
```

## After writing

Show the draft, apply corrections, and when the owner accepts it set `Status: Proposed ... · Accepted <date>` in both files' history as appropriate, then commit (`docs: spec <slug>`). Next: break it into issues (`to-tickets`); each ticket copies the Test plan cases it owns. If the plan changes during Build, record the change in the PR or a new ADR; do not edit the frozen pair.

## Writing rules

English, glossary terms from `CONTEXT.md`, no em dashes or spaced hyphens as punctuation.
