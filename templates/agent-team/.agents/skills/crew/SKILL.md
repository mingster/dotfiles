---
name: crew
description: Apply the agent team's roles and delivery gates to one objective. Use with /crew <objective> or when Elon coordinates a feature or epic.
---

# Crew

The objective is the text after `/crew` ($ARGUMENTS). If it is missing, ask for it and stop. Read `docs/agents/team-facts.md` for checks, repository, worker placement and review rules; if it is missing, report that to Elon.

Elon owns the objective and dispatch. The Tech Lead integrates engineering work. Read `.claude/agents/elon.md` for the front door and owner decisions, and `.claude/model-routing.md` for provider selection, the usage gate and commit, push and merge authority.

## Step 0. Fast path

Bugs, chores and small tasks touching 3 files or fewer use `tdd` directly, with `diagnosing-bugs` first when diagnosis is needed. Run the fast checks in team facts. Small reversible documentation changes and lookups need no crew. Use the remaining steps for features across domains and large epics.

## Step 1. Scope and plan

Elon aligns the objective with Sales-Marketing and assigns architect-pm to use the `to-tickets` skill for ticket contracts and dependencies. Read `~/.agents/skills/to-tickets/SKILL.md` and follow it. The Tech Lead reviews the resulting plan for integration risks. Existing accepted tickets need no second breakdown.

## Step 2. Dispatch

Use the `orchestration` skill for task contracts, dispatch, supervision, questions, recovery and settlement. Load the installed guide with `orca skills get orchestration` and follow its conditional references. Use Orca for supervised work across every provider.

Team additions to its task contract:

- Name the role file by absolute path, the Token budget in `AGENTS.md`, and the skill file to read. Use `implement` for a whole ticket, `tdd` for a build slice, `diagnosing-bugs` for diagnosis, `code-review` for review and `resolving-merge-conflicts` for conflicts. Read the named `~/.agents/skills/<name>/SKILL.md` even when the harness hides it.
- State rules 1 and 2 of "Commit, push and merge" in `.claude/model-routing.md`: workers commit on their own branches and worktrees, never push, open PRs or merge PRs; reviewers report locally to Elon.
- Apply the usage gate before every launch and use the role's provider, model and effort from `.claude/model-routing.md`. Cap each independent wave at 3 workers. Use child worktrees and the placement flags in team facts.
- Use the `orca-team` skill for colored panes and worker watch helpers. Keep runtime lifecycle authority with `orchestration`; project routing supplies team policy, not permission to bypass Orca's recovery rules.

## Step 3. Worker evidence

Use the assigned implementation skill and the component checks in team facts. Documentation changes need link and reference checks plus `git diff --check`, with no app build. Follow the Token budget and strike rule in `AGENTS.md`.

For a ticket with several slices, use `docs/agents/persistent-memory-protocol.md` for the worktree's `active_run.md`. Edit only allowed files; a scope extension goes to Elon through orchestration.

Include the branch, commits, worktree path, `git diff <default branch>...HEAD --stat`, check counts and unresolved items in the completion evidence required by orchestration. Use the `handoff` skill if context runs out, and include its artifact path.

## Step 4. Review

Use the `code-review` skill against the default branch and ticket, with `AGENTS.md` and the team facts checklist as standards. Apply the review by risk rule in `.claude/agents/tech-lead.md`; add `secops-finops` for auth, tenancy, entitlement, rate limits, money or payments, and any reviewers named in team facts.

The reviewer verifies the ticket's check command passes. Report `PASSING AUDIT` or `FAILED AUDIT` with concrete remediation. Allow at most two remediation rounds; after both fail, use the `retro` skill on the worker session and file its top finding under the project's issue budget. Review timing follows "Merge on completion" in `.claude/model-routing.md`.

## Step 5. Integration and completion

The Tech Lead combines passing branches locally in dependency order on `crew/<slug>`, based on the current default branch in its own worktree. Keep local history intact. Worker branches carry separate changelog fragments in the team facts folder. Send conflicts to their owning worker to resolve with `resolving-merge-conflicts`.

Run the integrated checks from team facts and report the branch, worktree, diff stat, audit verdict and check results to Elon. The Tech Lead pushes, opens the PR and applies "Merge on completion" in `.claude/model-routing.md`, including the clean local main update and post merge review. Do not hold a validated completion for another review round.

Use `orchestration` for settled worker cleanup. After the successful push and merge, the Tech Lead runs the `wrap-up` skill (`.agents/skills/wrap-up/SKILL.md`) for finished branches, worktrees and ended panes, and `orca-cli` only for a worktree it keeps. Continue with the next open issue within the authorized objective until its queue is empty.
