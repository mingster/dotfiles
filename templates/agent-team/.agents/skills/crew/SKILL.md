---
name: crew
description: Run one objective through the {{PROJECT_NAME}} agent team with the crew protocol (decompose, dispatch parallel workers, isolated execution, audit, integrate into one diff). Use with /crew <objective>, or when the owner states an objective in a lead session. Works in Claude Code, Cursor, Antigravity and Orca worktrees.
---

# Crew protocol

The objective is the text after `/crew` ($ARGUMENTS). If there is none, ask for it in one line and stop.

Elon (`elon`) is the session and the top-level orchestrator: Elon owns the objective, the task tree, dispatch and completion review. The Tech Lead (`lead`) is a teammate that integrates engineering work. Every teammate reports to Elon only, and Elon reports to the owner. Follow both role files and their gates. Critical or suppressed concerns may escalate to Elon and the owner. Owner-facing replies may use Taiwan Traditional Chinese or English without mirroring the owner. Every message to the owner uses **Now**, **Needs owner**, **Running**.

## Step 0. Fast-Path Check (Skip Crew)

If the objective is a bug fix, chore, or small task touching <= 3 files, **do NOT run the full crew**. Work directly in the current workspace with TDD, verify with `bun run lint` and `bun test --isolate <file>`, and finish. Use the multi-agent crew below only for multi-domain features or large epics.

## Step 1. Orchestration and decomposition (Elon)

1. CEO / Lead scan: scan workspace status and define tasks. Keep tasks lean.
2. Size gate: handle small changes directly. Parallelize only truly independent tasks.
3. Build the task tree: each task has owner, exact files allowed, dependencies, and done criterion.
4. Show proposed plan concisely and proceed.

## Step 2. Parallel dispatch (Elon to workers, with Orca orchestration)

Load the `orchestration` skill (`orca skills get orchestration`) before dispatching. Never use a non-Orca subagent tool for this.

- Handle small reversible docs and lookups directly; delegate substantial implementation and independent review.
- Open one Run for the objective: `orca orchestration run-create --objective "<objective>" --json`.
- Start the whole independent wave before waiting, at most 2 or 3 workers: `orca orchestration worker-start --spec "<task spec>" --worktree new-child --agent <provider> --model <id> --effort <level> --json`. Choose provider, model and effort from the tier in `.claude/model-routing.md`. Use `--deps` only for real ordering, such as review after build.
- Task spec: Target (files in scope), Change (the result), Constraints, Ownership (the allowed files), Observable acceptance (the test command and done criterion), and "read `.claude/agents/<role>.md` first and follow it". Workers do not inherit role frontmatter, so name the role.
- **Anti-fluttering**: Do not flutter workers. Give each worker a self-contained contract, dispatch it, and wait for `worker_done` or legitimate escalation. Never poll in a tight loop, restart terminals prematurely, or swap models mid-flight unless the provider is demonstrably unavailable.
- Wait with `orca orchestration check --wait --types worker_done,escalation,question --timeout-ms 900000 --json`. Reply to each question, validate each `worker_done`, then run `orca orchestration worker-release --dispatch <id>` for every settled worker, succeeded or failed. This is required: a worker that stays open after `worker_done` holds a terminal and a worktree. If validation fails, send the fix to the same worker first, then release it.
- Provider failure (quota, auth, outage): rerun the Task on the next provider with `orca orchestration worker-start --task <task_id> --agent <next provider> ...`. See Fallback in `.claude/model-routing.md`.
- Keep workers short. A Claude Code worker's prompt cache lasts about 5 minutes, so put the full contract in the spec and do not park a worker waiting on a reply.
- Worktrees: Orca creates them (`--worktree new-child`). Never create loose worktrees in `/tmp` or `.claude/worktrees/`.

## Step 3. Isolated execution (workers)

- When finished, send `worker_done` once (three sentence summary, `--outcome succeeded` or `failed`) with the Task and Dispatch IDs from your preamble, then stop. Ask a blocking question with the preamble's `ask` command, not a local prompt.
- **Run ledger**: for a ticket with more than one slice, keep `active_run.md` (git ignored) in your worktree root. Write it once at the start (allowed files, verify command) and again only when blocked. Task list, git and your final report hold everything else.
- Edit only files on your allow list. If you need another file, ask Elon with the preamble's `ask` command and wait; do not edit it.
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

## Step 5. Integration (Tech Lead teammate)

1. When every task has passed, create `crew/<slug>` from an up to date `main` in the current worktree (the Orca worktree when run from Orca).
2. Merge each passing branch in dependency order. No force push, no history rewriting. `CHANGELOG.md` merges as a union on its own (`merge=union` in `.gitattributes`); any other conflict goes back to the owning worker.
3. Run `bun run lint` and `bun run test` on an integrated app change; use documentation checks for documentation-only changes. If integration changed code, qa-sdet audits again.
4. Push the branch and open one PR for the objective, with validation appropriate to the changed files. Worker branches stay local.
5. **Prune worktrees**: Immediately remove child worktrees (`git worktree remove <path>`) once integrated so orphaned directories never accumulate.
6. Present to the owner: `git diff main...HEAD --stat`, the PR link, audit verdict, and test results.
7. Merge the PR under the Merging rules once review and checks pass.
8. **Continuous queue draining**: Immediately query for the next open issue in the queue and begin the next cycle, repeating until no open tasks remain.

## Orca terminal layout

For visible teammate terminals, open the CEO session in an Orca terminal and run `orca claude-teams`. Orca creates native split panes for the teammates and preserves their lifecycle and worktree visibility. Use clear role titles such as `CEO`, `Tech Lead`, `QA-SDET` and `Release-Manager`; Orca currently provides a global color scheme, not a per-pane color flag. Do not nest tmux inside Orca for supervised work, because nested panes are outside Orca's lifecycle control.
