# Team facts

Product facts read by the generated team skills (`crew`), which hold none themselves. This project owns this file, and project differences from `~/dotfiles/templates/agent-team/docs/agents/team.md` go in `docs/agents/team-facts.md` only. Keep the headings: the skills look values up by heading.

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
* Extra verifiers: none.

## Changelog

* Fragments: `changelog.d/<issue>-<slug>.md` at the repo root.

## Role facts

Project specific schemas, wrapper scripts, and domain rules per role. Keep the `### <role>` headings so roles and `agent-team.sh` find them.

### sales-marketing

* Read only data access: `<read only database variable or wrapper script, plus order and subscription tables>`.

### secops-finops

* Read only reconciliation access: `<read only database variable or wrapper script, plus ledger, order, and fee tables>`.

### support-csm

* Support thread reader and intake wrappers: `<wrapper commands, queue reader, and intake or draft contracts>`.

## Terminal shortcut

* `team {{PROJECT_NAME}}`.
