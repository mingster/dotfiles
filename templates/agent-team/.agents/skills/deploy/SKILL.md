---
name: deploy
description: Move a commit (of one component, when the project has several) through local dev, staging and production. Use with /deploy local|staging|production [<component>] or /deploy status. Run by release-manager, or by the Tech Lead when release-manager is not running. Works in Claude Code, Cursor and Antigravity.
---

# Deploy

Arguments: the stage (`local`, `staging`, `production` or `status`) and, when the project has more than one component, the component. With no stage, run `status`; `status` without a component covers them all.

Every product fact lives in the project's `docs/agents/deploy-facts.md`: the repository, the components and their folders, the stage branch and status names, hosts, the command for each stage, guards, the production window, the standing go and the rollback. Read it first. Where this skill says "facts", use that file. If it is missing, stop and tell the lead. When the facts and this skill disagree on a product detail, the facts win; on the rules below, this skill wins.

In the commands below, `<repo>` is the repository from the facts, `<dev>` the development branch, `<staging branch>` and `<production branch>` the stage branch names for the component (for example `staging`, or `web2/staging`), and `<context>` the commit status name for the stage (for example `deploy/staging`, or `deploy/web2/staging`).

## Rules for every stage

1. **Who starts a stage.** local and staging: release-manager or the Tech Lead, any time. production: release-manager, under the standing go in the facts or on the owner's go for that exact commit, and only inside the production window when the facts name one.
2. **Promotion.** A stage deploys only a commit with a `success` status from the stage before: the local context for staging, the staging context for production. Production deploys exactly the commit `<staging branch>` points at, even when `<dev>` has moved on.
3. **Fast forward only.** Stage branches move with `git push origin <sha>:<stage branch>` and nothing else (the first push creates the branch). If the push is refused as non fast forward, stop and tell the lead; never add `--force`.
4. **One path to a server.** Deploy only with the command the facts name for the stage. Never run host scripts or `ssh` around it, except the manual fallback steps the facts name for when the command cannot run (those ask for approval). When the command refuses, report the reason to Elon; do not work around it.
5. **The record.** Set the stage's status on the commit when it passes, and `failure` when it fails:
   `gh api -X POST repos/<repo>/statuses/<sha> -f state=success -f context=<context> -f description="<one line>"`
6. **Smoke checks belong to the role the facts name** (qa-sdet unless they say otherwise). After staging or production, send `Ready for <role> smoke check: [<component>] <stage> <sha>` and set the status only after `Smoke passed: [<component>] <stage> <sha>`.
7. **One deploy at a time** when the facts say so (a lock or a shared host). Stop at the first failure: report the step, the command and the first error line to Elon. Do not retry a step that may have changed a database.

## status

`git fetch origin --quiet`, then for each component: the commits and dates of `origin/<dev>`, `origin/<staging branch>` and `origin/<production branch>`, how far each is behind the stage before (`git rev-list --count <a>..<b>`, limited to the component folder with `-- <folder>/` when the facts give one), the deploy statuses of the staging commit:

```bash
gh api repos/<repo>/commits/<sha>/statuses --jq '.[] | select(.context|startswith("deploy/")) | "\(.context) \(.state) \(.created_at)"'
```

and, when the facts name a host status command, what the hosts actually run. A host that runs something other than its branch is a finding for the lead. Reply with one line per component and stage: commit, date, statuses, and how many commits it is behind the stage before.

## local

The commit is the tip of `<dev>` unless the lead names another.

1. Make a throwaway worktree at the commit where the facts say (never a loose one in `/tmp`): `git fetch origin && git worktree add --detach <path> <sha>`. Remove an old one at that path first with `git worktree remove --force <path>`.
2. Copy the env file the facts name into the worktree with `cp`.
3. **Database guard.** Every database URL in that env file must point where the facts allow for local (a local host, or a `_test` database). Check with the masking tool or check command the facts name, never print the file or its credentials. Anything else stops the stage.
4. A port the stage needs must be free. If the owner's dev server holds it, stop and ask the lead; never kill it.
5. Run the local steps from the facts for the component, in order, inside the worktree. A step the facts mark advisory fails the gate only as the facts describe.
6. All passed: set the local context to `success` with what ran (test counts) in the description. Remove the worktree.

## staging

0. **Compile changelog fragments first** (run by the same person who runs this stage). On an up to date `<dev>`, run `bin/changelog-compile.sh`. If a `CHANGELOG.md` changed, commit `chore: compile changelog fragments` on a branch, open a PR and merge it (`gh pr merge --merge`). The compile commit touches only `CHANGELOG.md` and `changelog.d/` paths, so it is exempt from a fresh local run. For each component you are deploying: confirm `git diff --name-only <parent>..<compile merge sha>` lists only those paths and that the parent (the previous `<dev>` head) has the local context `success`, then set the local context to `success` on the compile merge commit with the description `changelog compile only, inherits <parent sha>`. Step 1 then picks the compile commit. If the parent has no local success, run `/deploy local` on the compile commit instead.
1. Pick the commit: the newest commit on `<dev>` with the local context `success`. Check the status before anything else.
2. `git push origin <sha>:<staging branch>`, then run the staging deploy command from the facts.
3. Follow the staging steps in the facts: how to wait for the build, the guards the command checks, how to apply staging migrations, and the app page that must answer 200. A failed build or deploy means staging still runs the previous commit: set the staging context to `failure` and report.
4. Send the smoke check message. On `Smoke passed`, set the staging context to `success`, then send the lead `Ready for owner to approve production: [<component>] <sha>, <N> PRs` with the summary below.

## production

Before asking for go, build the summary for the lead to put under **Needs owner**:

- The commit (`origin/<staging branch>`) and its local and staging statuses. Both must be `success`.
- `git log --oneline origin/<production branch>..<sha>` (limited to the component folder when the facts give one) and the merged PRs in it.
- The schema or migration change, using the diff command in the facts. Name any column that would be dropped or retyped, and any migration the owner must apply first.
- What the deploy interrupts, from the facts.
- Checks on the commit are green (`gh api repos/<repo>/commits/<sha>/check-runs`).
- Prerequisites: anything a PR in the range needs before or with the deploy (an env value, a secret, a cron line, a server setting). Read each PR's description and deploy notes.

**Standing go.** When every standing go condition in the facts holds, no approval of its own is needed: tell the lead `Standing go: [<component>] <sha>, <N> PRs, deploying` and go ahead (inside the window, when there is one). Otherwise send `Ready for owner to approve production: [<component>] <sha>, <N> PRs` and deploy only after the lead relays the owner's go for that exact commit. A rollback is never under the standing go.

Then:

1. Run the production deploy command from the facts, including the `git push origin <sha>:<production branch>` when the facts list it (some commands push the branch themselves, some check that it already points at the commit). Set only the overrides the facts allow, and only when the owner said so.
2. Confirm the host runs the commit with the check in the facts.
3. Send the smoke check message. On `Smoke passed`, set the production context to `success` and tell the lead: component, commit, PRs shipped, deploy time.

## A deploy run by hand

The host deploy script is the last step of this pipeline, not a way around it. If the owner runs it directly, the commit may not have passed the stages before it. When release-manager hears of a hand deploy (the owner names the sha, or the host's recorded sha differs from `origin/<production branch>`), it tells the lead, records the sha as the production context only after the smoke check passes, and asks the owner to approve moving `<production branch>` forward to that sha (a fast forward push, which asks for approval). Until then the branch and the statuses are behind what runs, and every smoke check targets the sha that actually runs.

## When production fails

- **Normal:** revert the change on `<dev>` and take the revert through local, staging and production.
- **Emergency, owner approval required:** follow the rollback section of the facts (usually: move `<production branch>` back to the previous commit with a force push, which asks for approval, and redeploy). Blocked when the failed deploy changed the schema in a way the facts say does not reverse: that case goes to the owner with the schema diff.

Report every failure to Elon at once with the step, the error and your recommendation.
