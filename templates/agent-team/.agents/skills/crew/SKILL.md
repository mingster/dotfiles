---
name: crew
description: Run one objective through the project's agent team with the crew protocol (decompose, dispatch parallel workers, isolated execution, audit, integrate into one diff). Use with /crew <objective>, or when the owner states an objective in a lead session. Works in Claude Code, Cursor, Antigravity and Orca worktrees.
---

# Crew protocol

The objective is the text after `/crew` ($ARGUMENTS). If there is none, ask for it in one line and stop.

Product facts (repository, worker start flags, check commands, review checklist, extra reviewers, changelog folder) live in the project's `docs/agents/team-facts.md`. Read it before Step 1. Where this skill says "team facts", use the value from that file. If the file is missing, stop and tell the owner.

Elon (`elon`) is the session and the top-level orchestrator: Elon owns the objective, the task tree, dispatch and completion review. The Tech Lead (`lead`) is a teammate that integrates engineering work. Every teammate reports to Elon only, and Elon contacts the owner only for a decision Elon cannot make. Follow both role files and their gates. Critical or suppressed concerns may escalate to Elon and the owner. Owner-facing replies may use Taiwan Traditional Chinese or English without mirroring the owner. A message to the owner states the decision, the options and Elon's recommendation.

## Step 0. Fast-Path Check (Skip Crew)

If the objective is a bug fix, chore, or small task touching <= 3 files, **do NOT run the full crew**. Work directly in the current workspace with TDD, run the fast checks from team facts (Checks), and finish. Use the multi-agent crew below only for multi-domain features or large epics.

## Step 1. Scope and plan (Elon and BA)

1. Elon scans the workspace status, aligns the objective with Sales-Marketing and directs the BA (`architect-pm` / 需求分析師).
2. The BA breaks the spec into machine-checkable ticket contracts (`tickets.md`):
   - Scope boundaries and exact allowed files.
   - Verification commands and criteria.
   - Blast radius and dependencies.
3. Size gate: handle small changes directly. Parallelize only truly independent tasks. Each task has owner, exact files allowed, dependencies, and done criterion.
4. The Tech Lead reviews the dependency DAG. Show the proposed plan concisely and proceed.

## Step 2. Parallel dispatch (Elon to workers, with Orca orchestration)

Load the `orchestration` skill (`orca skills get orchestration`) before dispatching. Never use a non-Orca subagent tool for this.

- Handle small reversible docs and lookups directly; delegate substantial implementation and independent review.
- Open one Run for the objective: `orca orchestration run-create --objective "<objective>" --json`.
- Start the whole independent wave before waiting, at most 2 or 3 workers: `orca orchestration worker-start --spec "<task spec>" --worktree new-child <worker start flags from team facts> --agent <provider> --model <id> --effort <level> --json`. Choose the provider from the role's default and the model and effort from its tier in `.claude/model-routing.md`. Use `--deps` only for real ordering, such as review after build.
- Task spec: Target (files in scope), Change (the result), Constraints, Ownership (the allowed files), Observable acceptance (the test command and done criterion), and "read `.claude/agents/<role>.md` and the Token budget in `AGENTS.md` first and follow them". Workers do not inherit role frontmatter, so name the role. When team facts say a worker's worktree does not hold `.claude/agents/`, give the absolute paths it lists.
- **Anti-fluttering**: Do not flutter workers. Give each worker a self-contained contract, dispatch it, and wait for `worker_done` or legitimate escalation. Never poll in a tight loop, restart terminals prematurely, or swap models mid-flight unless the provider is demonstrably unavailable.
- Title every worker terminal "<role name> - <short description of the job>" (for example `fullstack-dev - fix RSVP late-pay rounding`): pass `--task-title` with the same text to `worker-start`, then, only after the worker reports "Setup succeeded" (agents overwrite the title at startup), run `orca terminal rename --terminal <handle> --title "<same text>"` using the terminal handle from the `--json` start receipt (or `worker-show`), and in the same step run `~/.claude/skills/orchestration/worker-panes.sh <run_id> <coordinator terminal handle> <dispatch_id>` so the worker opens as a colored pane in the coordinator's tab (the color comes from the role, so start the title with the role name). Always close a finished worker the moment you validate its `worker_done` (or it fails): `worker-release`, then `worker-pane-close.sh <dispatch_id>`, which closes the pane and every terminal of that dispatch still in `orca terminal list` (its agent, setup and shell terminals, including a pane whose split timed out and was never recorded; a pane also closes itself about 10 seconds after its dispatch ends), then remove its worktree (`git worktree remove`) and prune. Never leave a finished worker's terminal or pane open, and never close the owner's own sessions or other projects' terminals.
- Before and after every worker-start follow Starting a worker in `.claude/model-routing.md`.
- Wait with `orca orchestration check --wait --types worker_done,escalation,question --timeout-ms 900000 --json`. Reply to each question, validate each `worker_done`, then run `orca orchestration worker-release --dispatch <id>` for every settled worker, succeeded or failed. This is required: a worker that stays open after `worker_done` holds a terminal and a worktree. If validation fails, send the fix to the same worker first, then release it.
- Provider failure (quota, auth, outage): rerun the Task on the next provider with `orca orchestration worker-start --task <task_id> --agent <next provider> ...`. See Fallback in `.claude/model-routing.md`.
- Keep workers short. A Claude Code worker's prompt cache lasts about 5 minutes, so put the full contract in the spec and do not park a worker waiting on a reply.
- Worktrees: Orca creates them (`--worktree new-child`). Never create loose worktrees in `/tmp` or `.claude/worktrees/`.

## Step 3. Isolated execution (workers)

- When finished, send `worker_done` once (three sentence summary, `--outcome succeeded` or `failed`) with the Task and Dispatch IDs from your preamble, then stop. Ask a blocking question with the preamble's `ask` command, not a local prompt.
- **Run ledger**: for a ticket with more than one slice, keep `active_run.md` (git ignored) in your worktree root. Write it once at the start (allowed files, verify command, current step) and again only when blocked (strike count, blockers). Task list, git and your final report hold everything else. See `docs/agents/persistent-memory-protocol.md`.
- Edit only files on your allow list. If you need another file, ask Elon with the preamble's `ask` command and wait; do not edit it.
- Follow `AGENTS.md`. For app changes, run the checks from team facts for the component you touched. For documentation-only changes, check links, role/branch references and `git diff --check`; do not run an app build.
- Follow the Token budget section of `AGENTS.md`, including two strikes on a failing test. Pipe long output (`tail -40`, `git diff --stat`) and run only the relevant tests while coding.
- Finish with: branch name, commits, `git diff <default branch>...HEAD --stat`, tests run with pass and fail counts (failing output only), and anything left open. Not the full diff: the reviewer reads it from the branch.

## Step 4. Quality gate (reviewers)

- **Dual-Axis Review (Standards & Spec)**:
  - **Standards Axis**: Conventions (`AGENTS.md`), the standards checklist in team facts, Fowler smells.
  - **Spec Axis**: Check diff against the machine-checkable ticket contract (exact allowlisted files touched, all acceptance criteria satisfied, no scope creep).
- `qa-sdet` audits every worker diff. `secops-finops` audits too when the diff touches auth, tenancy, entitlement, rate limits, money or payments. Team facts may name more reviewers by area.
- Reviewer verifies the test command from the ticket contract passes cleanly.
- Verdict per task: `PASSING AUDIT` or `FAILED AUDIT` with concrete remediation items. At most 2 remediation rounds per task.

## Step 5. Integration (Tech Lead teammate)

1. When every task has passed, create `crew/<slug>` from an up to date default branch in the current worktree (the Orca worktree when run from Orca).
2. Merge each passing branch in dependency order. No force push, no history rewriting. Each worker branch adds its own changelog fragment (folder in team facts, named `<issue>-<slug>.md`), so changelog entries never conflict; any other conflict goes back to the owning worker. Do not edit `CHANGELOG.md` here, the release step compiles the fragments.
3. Run the full checks from team facts on an integrated app change; use documentation checks for documentation-only changes. If integration changed code, qa-sdet audits again.
4. Push the branch and open one PR for the objective in the repository from team facts, with spec traceability, review checklists and validation appropriate to the changed files. Worker branches stay local.
5. **Prune worktrees**: Immediately remove child worktrees (`git worktree remove <path>`) once integrated so orphaned directories never accumulate.
6. Report to Elon: `git diff <default branch>...HEAD --stat`, the PR link, audit verdict, and test results.
7. Merge the PR under the Merging rules once review and checks pass.
8. **Continuous queue draining**: Immediately query for the next open issue in the queue and begin the next cycle, repeating until no open tasks remain.

## Orca terminal layout

For visible teammate terminals, open the CEO session in an Orca terminal and run `orca claude-teams`. Orca creates native split panes for the teammates and preserves their lifecycle and worktree visibility. Use clear role titles such as `CEO`, `Tech Lead`, `QA-SDET` and `Release-Manager`; Orca currently provides a global color scheme, not a per-pane color flag. Do not nest tmux inside Orca for supervised work, because nested panes are outside Orca's lifecycle control.
