# Team facts

Product facts read by the generated team skills (`crew`, `tl`), which hold none themselves. This project owns this file. Keep the headings: the skills look values up by heading.

## Repository

* GitHub: `<owner>/{{PROJECT_NAME}}`, default branch `main`.
* PRs open in: `<owner>/{{PROJECT_NAME}}`.

## Worker start

* Extra `orca orchestration worker-start` flags: none.
* Role files: worker worktrees hold `.claude/agents/` and `AGENTS.md`, so relative paths work.

## Checks

* Fast (crew Step 0): `<lint command>` and `<single test command> <file>`.
* App change (workers and integration): `<lint command>` and `<test command>`, run in `<app folder>`.
* Documentation only: links, role and branch references, `git diff --check`.

## Review

* Standards checklist: `<project rules the Standards axis checks, beyond AGENTS.md>`.
* Extra reviewers: none.

## Changelog

* Fragments: `changelog.d/<issue>-<slug>.md` at the repo root.

## Terminal shortcut

* `team {{PROJECT_NAME}}`.
