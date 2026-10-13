---
name: crew
description: Run one objective through the project's agent team with the crew protocol (decompose, dispatch parallel workers, isolated execution, audit, integrate into one diff). Use with /crew <objective>, or when the owner states an objective in a lead session. Works in Claude Code, Cursor, Antigravity and Orca worktrees.
---

# Crew protocol

The objective is the text after `/crew` ($ARGUMENTS). If there is none, ask for it in one line and stop.

"Team facts" means the project's `docs/agents/team-facts.md` (repository, worker start flags, check commands, review checklist, extra reviewers, changelog folder). Read it before Step 1; if it is missing, stop and tell the owner.

Elon (`elon`) owns the objective, the task tree, dispatch and completion review. The Tech Lead (`lead`) integrates engineering work. Every teammate reports only to Elon, and follows both role files and their gates; a critical or suppressed concern may go to Elon and the owner. Elon contacts the owner only for a decision Elon cannot make, stating the decision, the options and a recommendation. Owner facing replies may use Taiwan Traditional Chinese or English without mirroring the owner.

## Step 0. Fast path

A bug fix, chore or small task touching 3 files or fewer skips the crew: work directly in the current workspace with the `tdd` skill (`diagnosing-bugs` first for a bug), run the fast checks from team facts (Checks), and finish. The crew is for multi domain features and large epics.

## Step 1. Scope and plan (Elon and BA)

1. Elon scans the workspace status, aligns the objective with Sales-Marketing and directs the BA (`architect-pm` / 需求分析師).
2. The BA breaks the spec into machine checkable ticket contracts with the `to-tickets` skill (GitHub issues with blocking edges): scope boundaries and exact allowed files, verification commands and criteria, blast radius and dependencies.
3. Size gate: handle small changes directly; parallelize only truly independent tasks. Each task has an owner, allowed files, dependencies and a done criterion.
4. The Tech Lead reviews the dependency DAG. Show the plan briefly and proceed.

## Step 2. Parallel dispatch (Elon, with Orca orchestration)

Load the `orchestration` skill (`orca skills get orchestration`) first. Never use a non Orca subagent tool.

- Do small reversible docs and lookups directly; delegate substantial implementation and independent review.
- One Run per objective: `orca orchestration run-create --objective "<objective>" --json`.
- Start the whole independent wave before waiting, at most 2 or 3 workers: `orca orchestration worker-start --spec "<task spec>" --worktree new-child <worker start flags from team facts> --agent <provider> --model <id> --effort <level> --json`, provider from the role's default, model and effort from its tier in `.claude/model-routing.md`. `--deps` only for real ordering, such as review after build.
- Task spec: Target (files in scope), Change (the result), Constraints, Ownership (allowed files), Observable acceptance (test command and done criterion), Skill (the one skill the job runs, named with its file so every provider loads it: "use `/tdd`: read `~/.agents/skills/tdd/SKILL.md` and follow it"; build `tdd`, a whole ticket `implement`, a hard bug `diagnosing-bugs`, review `code-review`, a merge conflict `resolving-merge-conflicts`; a `disable-model-invocation` skill such as `implement` loads only this way), rules 1 and 2 of "Commit, push and merge" in `.claude/model-routing.md`, and "read `.claude/agents/<role>.md` and the Token budget in `AGENTS.md` first and follow them". Workers do not inherit role frontmatter, so name the role. When team facts say a worker's worktree lacks `.claude/agents/`, give the absolute paths they list.
- Follow "Starting a worker" (usage gate, title, rename, panes, delivery check, close) and "Watching a worker" in `.claude/model-routing.md`.
- Let workers finish: one self-contained contract, then wait for `worker_done` or a real escalation. No tight polling, premature terminal restarts or mid flight model swaps unless the provider is demonstrably unavailable.
- Wait with `orca orchestration check --wait --types worker_done,escalation,question --timeout-ms 900000 --json`. Answer each question and validate each `worker_done`. If validation fails, send the fix to the same worker first. Then close every settled worker, succeeded or failed (`orca orchestration worker-release --dispatch <id>` is required: an open worker holds a terminal and a worktree).
- Provider failure (quota, auth, outage): rerun the Task on the next provider, `orca orchestration worker-start --task <task_id> --agent <next provider> ...` (Fallback in `.claude/model-routing.md`).
- Keep workers short. A Claude Code worker's prompt cache lasts about 5 minutes: put the full contract in the spec and never park a worker waiting on a reply.
- Orca creates worktrees (`--worktree new-child`). Never create loose worktrees in `/tmp` or `.claude/worktrees/`.

## Step 3. Isolated execution (workers)

- Send `worker_done` once when finished (three sentence summary, `--outcome succeeded` or `failed`) with the Task and Dispatch IDs from your preamble, then stop. Ask blocking questions with the preamble's `ask` command, not a local prompt.
- **Run ledger:** for a ticket with more than one slice, keep `active_run.md` (git ignored) in your worktree root. Write it at the start (allowed files, verify command, current step) and again only when blocked (strike count, blockers). See `docs/agents/persistent-memory-protocol.md`.
- Edit only allowlisted files. For another file, ask Elon with `ask` and wait.
- Follow `AGENTS.md`. App changes: run the team facts checks for the component you touched. Documentation only: check links, role and branch references and `git diff --check`; no app build.
- Follow the Token budget in `AGENTS.md`, including two strikes on a failing test. Pipe long output (`tail -40`, `git diff --stat`); run only relevant tests while coding.
- Finish with: branch, commits, `git diff <default branch>...HEAD --stat`, tests run with pass and fail counts (failing output only), anything left open. Not the full diff.

## Step 4. Quality gate (reviewers)

- **Dual-Axis review** with the `code-review` skill (fixed point the default branch, spec the ticket). Standards: `AGENTS.md` conventions, the team facts standards checklist, Fowler smells. Spec: the diff against the ticket contract (only allowlisted files, every acceptance criterion met, no scope creep).
- `qa-sdet` audits every worker diff; `secops-finops` too when it touches auth, tenancy, entitlement, rate limits, money or payments. Team facts may name more reviewers by area.
- The reviewer verifies the ticket's test command passes cleanly.
- Verdict per task: `PASSING AUDIT` or `FAILED AUDIT` with concrete remediation. At most 2 remediation rounds per task; a task that fails both gets a `retro` (`~/.agents/skills/retro/SKILL.md`) on the worker's session, its top finding filed as an issue.

## Step 5. Integration (Tech Lead integrates, Elon ships)

1. When every task passed, the Tech Lead creates `crew/<slug>` from an up to date default branch in its own worktree (the Orca worktree when run from Orca).
2. It merges each passing branch locally in dependency order. No force push, no history rewriting. Each worker branch carries its own changelog fragment (folder in team facts, `<issue>-<slug>.md`), so entries never conflict; any other conflict goes back to the owning worker. Never edit `CHANGELOG.md` here; the release step compiles fragments.
3. It runs the full team facts checks on an integrated app change, documentation checks on a documentation only change. If integration changed code, qa-sdet audits again.
4. It reports to Elon with `worker_done`: the `crew/<slug>` branch, worktree path, `git diff <default branch>...HEAD --stat`, audit verdict and test results. It never pushes, opens a PR or merges.
5. Elon alone pushes `crew/<slug>`, opens one PR for the objective in the team facts repository (spec traceability, review checklists, validation fitting the changed files) and merges it, per "Commit, push and merge" in `.claude/model-routing.md`. Worker branches stay local.
6. After the merge, remove child worktrees (`git worktree remove <path>`).
7. Elon takes the next open issue in the queue and starts the next cycle, until no open tasks remain.

## Orca terminal layout

Each worker shows as a colored pane in the coordinator's tab: after "Setup succeeded", run `~/.claude/skills/orca-team/worker-panes.sh <run_id> <coordinator terminal handle> <dispatch_id>` (colors per role in `role-colors.tsv`, read from the `<role> - <job>` task title), and close it with `worker-pane-close.sh <dispatch_id>` on release ("Starting a worker" in `.claude/model-routing.md`). Never nest tmux inside Orca for supervised work: nested panes escape Orca's lifecycle control.
