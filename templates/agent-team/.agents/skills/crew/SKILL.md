---
name: crew
description: Run one objective through the riben.life agent team with the crew protocol (decompose, dispatch parallel workers, isolated execution, audit, integrate into one diff). Use with /crew <objective>, or when the owner states an objective in a lead session. Works in Claude Code, Cursor, Antigravity and Orca worktrees.
---

# Crew protocol

The objective is the text after `/crew` ($ARGUMENTS). If there is none, ask for it in one line and stop.

In Orca, start with shared CEO Elon (`elon`) as the top-level orchestrator: Elon owns the cross-project objective, cross-role DAG, dispatch and completion review. The Tech Lead owns the riben.life engineering subtree beneath Elon. Outside Orca, the Tech Lead remains the lead session and reports to CEO. Follow both role files and their gates. Routine engineering, QA, release, product delivery and support reports go to the Tech Lead; Sales reports business outcomes and SecOps independent risk to Elon. Direct handoffs copy the lead; critical or suppressed concerns may escalate directly to Elon/owner. Owner-facing replies may use Taiwan Traditional Chinese or English without mirroring the owner. Every message to the owner uses **Now**, **Needs owner**, **Running**.

## Step 0. Fast-Path Check (Skip Crew)

If the objective is a bug fix, chore, or small task touching <= 3 files, **do NOT run the full crew**. Work directly in the current workspace with TDD, verify with `bun run lint` and `bun test --isolate <file>`, and finish. Use the multi-agent crew below only for multi-domain features or large epics.

## Step 1. Orchestration and decomposition (lead)

1. CEO / Lead scan: scan workspace status and define tasks. Keep tasks lean.
2. Size gate: handle small changes directly. Parallelize only truly independent tasks.
3. Build the task tree: each task has owner, exact files allowed, dependencies, and done criterion.
4. Show proposed plan concisely and proceed.

## Step 2. Parallel dispatch (lead to workers)

- Spawn one teammate per unblocked task (max 2-3 concurrent).
- Worktrees in Orca: create under `~/orca/workspaces/riben.life/<lane>`. Never create loose worktrees in `/tmp` or `.claude/worktrees/`.
- Prompt: objective, task number, allowed files, test command, and done criterion.

## Step 3. Isolated execution (workers)

- **Persistent Memory Layer**: Before modifying code, initialize `task_plan.md` in your worktree root (specifying target scope, allowlisted files, verification commands, and tracer bullet steps). After each step or test run, update `progress.md` (recording current step, test outcome, strike count, and findings). This prevents context amnesia across compaction rounds. See `docs/agents/persistent-memory-protocol.md`.
- Edit only files on your allow list. If you need another file, message the lead and wait; do not edit it.
- Follow `AGENTS.md`. For app changes, run `bun run lint` and the relevant `bun run test` in `web/`. For documentation-only changes, check links, role/branch references and `git diff --check`; do not run an app build.
- Follow the Token budget section of `AGENTS.md`, including two strikes on a failing test.
- Finish with: branch name, commits, `git diff main...HEAD --stat`, tests run with pass and fail counts (failing output only), and anything left open. Not the full diff: the reviewer reads it from the branch.

## Step 4. Quality gate (reviewer: qa-sdet & secops-finops)

- **Dual-Axis Review (Standards & Spec)**:
  - **Standards Axis**: Conventions (`AGENTS.md`), safe-actions only in `"use server"`, store scoping, mobile-first, BigInt epochs, Fowler smells.
  - **Spec Axis**: Check diff against the machine-checkable ticket contract (exact allowlisted files touched, all acceptance criteria satisfied, no scope creep).
- secops-finops audits too when the diff touches auth, tenancy, rate limits, money or payments.
- Reviewer verifies the test command from the ticket contract passes cleanly.
- Verdict per task: `PASSING AUDIT` or `FAILED AUDIT` with concrete remediation items. At most 2 remediation rounds per task.

## Step 5. Integration (lead)

1. When every task has passed, create `crew/<slug>` from an up to date `main` in the current worktree (the Orca worktree when run from Orca).
2. Merge each passing branch in dependency order. No force push, no history rewriting. `CHANGELOG.md` merges as a union on its own (`merge=union` in `.gitattributes`); any other conflict goes back to the owning worker.
3. Run `bun run lint` and `bun run test` on an integrated app change; use documentation checks for documentation-only changes. If integration changed code, qa-sdet audits again.
4. Push the branch and open one PR for the objective, with validation appropriate to the changed files. Worker branches stay local.
5. **Prune worktrees**: Immediately remove child worktrees (`git worktree remove <path>`) once integrated so orphaned directories never accumulate.
6. Present to the owner: `git diff main...HEAD --stat`, the PR link, audit verdict, and test results.
7. Merge the PR under the Merging rules once review and checks pass.

## Orca terminal layout

For visible teammate terminals, open the CEO session in an Orca terminal and run `orca claude-teams`. Orca creates native split panes for the teammates and preserves their lifecycle and worktree visibility. Use clear role titles such as `CEO`, `Tech Lead`, `QA-SDET` and `Release-Manager`; Orca currently provides a global color scheme, not a per-pane color flag. Do not nest tmux inside Orca for supervised work, because nested panes are outside Orca's lifecycle control.
