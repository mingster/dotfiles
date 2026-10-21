---
name: deploy
description: Move a commit (of one component, when the project has several) through local dev, staging and production. Use with /deploy local|staging|production [<component>] or /deploy status. Run by release-manager, reporting directly to Elon. Works in Claude Code, Cursor and Antigravity.
---

# Deploy

Arguments: the stage (`local`, `staging`, `production` or `status`) and, when the project has more than one component, the component. With no stage, run `status`; `status` without a component covers them all.

"Facts" means the project's `docs/agents/deploy-facts.md`: repository, components and folders, stage branch and status names, hosts, the command per stage, guards, production window, owner approval script, rollback. Read it first; if it is missing, stop and tell Elon. On a product detail the facts win; on the rules below this skill wins.

Placeholders: `<repo>` the repository, `<dev>` the development branch, `<staging branch>` and `<production branch>` the component's stage branches (for example `staging` or `web2/staging`), `<context>` the stage's commit status name (for example `deploy/staging` or `deploy/web2/staging`).

## Rules for every stage

1. **Who starts a stage.** local and staging: release-manager, any time. production: release-manager only, on the owner's explicit go for that exact commit, inside the production window when the facts name one.
2. **Promotion.** A stage deploys only a commit with a `success` status from the stage before: the local context for staging, the staging context for production. Production deploys exactly the commit `<staging branch>` points at, even when `<dev>` has moved on.
3. **Fast forward only.** release-manager pushes only `<staging branch>` and `<production branch>`; other branches go to the responsible coordinator, Elon for docs and the Tech Lead for code ("Commit, push and merge" in `.claude/model-routing.md`). Stage branches move with `git push origin <sha>:<stage branch>` and nothing else (the first push creates the branch). If the push is refused as non fast forward, stop and tell Elon; never add `--force`.
4. **One path to a server.** Deploy only with the facts' command for the stage. No host scripts or `ssh` around it, except the manual fallback steps the facts name for when the command cannot run (those ask for approval). When the command refuses, report the reason to Elon; never work around it.
5. **The record.** Set the stage's status on the commit when it passes, and `failure` when it fails:
   `gh api -X POST repos/<repo>/statuses/<sha> -f state=success -f context=<context> -f description="<one line>"`
6. **Smoke checks belong to the role the facts name** (qa-sdet unless they say otherwise). After staging or production, send `Ready for <role> smoke check: [<component>] <stage> <sha>` and set the status only after `Smoke passed: [<component>] <stage> <sha>`.
7. **One deploy at a time** when the facts say so (a lock or a shared host). Stop at the first failure: report the step, the command and the first error line to Elon. Do not retry a step that may have changed a database.
8. **Ten minute limit.** A single step (test suite, build, deploy command) running over 10 minutes is a failure, not a wait. Exception: the development pass full regression suite may run up to 20 minutes (owner decision 2026-10-10). A step silent for 5 minutes counts the same. Stop it, set nothing to success, and report to Elon at once: step, command, run time, last output line.
9. **Deploys test the deployment, not the code** (owner rule). A stage checks only that the build succeeds, the schema sync works and the site serves the candidate sha. Unit and regression suites run in development before any deploy; the local stage requires the facts' development pass (a commit status) instead of running them. A missing or failed pass stops the stage and is fixed in development.
10. **Prepare the candidate before the development pass** (owner rule). Run the facts' format script (for example `bun run format`) in every Bun package the facts name and set its package.json `"version"` to today as `YYYY.MM.DD` (for example `2026.10.09`). Commit it, formatting included, as `chore: format and version YYYY.MM.DD` on a branch and report it to the Tech Lead, who pushes, opens the PR to `<dev>` and merges; then run the development pass on that merged commit, so the commit that passed is the one that deploys. A second deploy the same day keeps the date and skips the version change. No package updates here (rule 11).
11. **Dependency update on its own cycle** (owner rule 2026-10-12). Right after a production deploy succeeds, and every Monday with no production deploy in the past 7 days, release-manager runs `bun upgrade && bun update` in every Bun package the facts name, updates every Bun version pin the facts name when Bun changed, runs the unit tests and the build, commits it on its own branch as `chore: dependency update YYYY-MM-DD` and reports it to the Tech Lead, who pushes, opens the PR to `<dev>` and merges. Exact pins in package.json stay; upgrading a pinned package is its own ticket. Revert a bad update for that package alone, never hold it into a release, so feature work runs on new packages for days before the next deploy.

## Test noise

Release-manager applies this rule to development and release tests: a failing test counts as noise only with evidence that it passes on one isolated rerun, or fails the same on the last released SHA. Record the test, candidate and released SHAs, commands and matching failure evidence. More than 3 failures in one area blocks the release, even if individually classified as noise. Unproven failures block; never label them noise from an `origin/main` failure alone. This classification does not waive required success statuses or permit retrying a guarded or mutating deploy step.

## status

`git fetch origin --quiet`, then for each component: the commits and dates of `origin/<dev>`, `origin/<staging branch>` and `origin/<production branch>`, how far each is behind the stage before (`git rev-list --count <a>..<b>`, limited to the component folder with `-- <folder>/` when the facts give one), the deploy statuses of the staging commit:

```bash
gh api repos/<repo>/commits/<sha>/statuses --jq '.[] | select(.context|startswith("deploy/")) | "\(.context) \(.state) \(.created_at)"'
```

and, when the facts name a host status command, what the hosts actually run (a host running something other than its branch is a finding for release-manager to diagnose and report to Elon). Reply one line per component and stage: commit, date, statuses, commits behind the stage before.

## local

The commit is the tip of `<dev>` unless Elon names another.

1. Prepare a throwaway worktree at the candidate commit in the location named by the facts. In Orca, use the `orca-cli` skill for creation and cleanup. Outside Orca, use Git worktrees. Preserve an existing worktree with unshipped changes.
2. Copy the env file the facts name into the worktree with `cp`.
3. **Database guard.** Every database URL in that env file must point where the facts allow for local (a local host or a `_test` database). Check with the facts' masking tool or check command; never print the file or its credentials. Anything else stops the stage.
4. A port the stage needs must be free. If the owner's dev server holds it, stop and ask Elon; never kill it.
5. **Development pass.** The commit must carry the facts' development pass status (for example `dev/<component>`) as `success` before any step; otherwise stop promotion: release-manager runs or diagnoses the development pass in development, first running the facts' dev schema sync preflight when they name one, and reports the result to Elon. Never run the unit or regression suites here. Then run the facts' local steps for the component, in order, in the worktree. A step the facts mark advisory fails the gate only as the facts describe.
6. All passed: set the local context to `success` with what ran (build, development pass) in the description. Clean up the throwaway worktree through the same tool that created it.

## staging

0. **Compile changelog fragments first** (by whoever runs this stage). On an up to date `<dev>`, run `bin/changelog-compile.sh`. If a `CHANGELOG.md` changed, commit `chore: compile changelog fragments` on a branch and report it to Elon, who publishes and merges through the docs-only mechanical lane; continue once Elon reports the merge sha. The compile commit touches only `CHANGELOG.md` and `changelog.d/`, so it needs no fresh local run: for each component deployed, confirm `git diff --name-only <parent>..<compile merge sha>` lists only those paths and the parent (the previous `<dev>` head) has local `success`, then set local `success` on the compile merge commit with the description `changelog compile only, inherits <parent sha>`. Step 1 then picks it. If the parent has no local success, run `/deploy local` on the compile commit instead.
1. Pick the commit: the newest commit on `<dev>` with the local context `success`. Check the status before anything else.
2. `git push origin <sha>:<staging branch>`, then run the staging deploy command from the facts.
3. Follow the facts' staging steps: waiting for the build, the guards, applying staging migrations, the app page that must answer 200. A failed build or deploy leaves staging on the previous commit: set the staging context to `failure` and report.
4. Send the smoke check message. On `Smoke passed`, set the staging context to `success`, then send Elon `Ready for owner to approve production: [<component>] <sha>, <N> PRs` with the summary below.

## production

Before asking for go, build the summary for Elon to put in the owner decision message:

- The commit (`origin/<staging branch>`) and its local and staging statuses. Both must be `success`.
- `git log --oneline origin/<production branch>..<sha>` (limited to the component folder when the facts give one) and the merged PRs in it.
- The schema or migration change, using the diff command in the facts. Name any column that would be dropped or retyped, and any migration the owner must apply first.
- What the deploy interrupts, from the facts.
- Checks on the commit are green (`gh api repos/<repo>/commits/<sha>/check-runs`).
- Prerequisites: anything a PR in the range needs before or with the deploy (an env value, a secret, a cron line, a server setting). Read each PR's description and deploy notes.

**Owner go.** Production always needs the owner's explicit go for that release; no earlier go, rule or passing check replaces it. Send `Ready for owner to approve production: [<component>] <sha>, <N> PRs` and deploy only after Elon relays the go for that exact commit. When the facts name an owner approval script, also give Elon the exact command for the owner, component and commit filled in, and deploy only after it ran. A rollback needs the owner's go too.

**Production prerequisites.** When the facts name a production SQL apply script or secret script and the owner's approval covers them (scope in the facts), release-manager runs them itself before moving `<production branch>`: the SQL script dry run first, then without it, one database at a time; the secret script per required key. Only these scripts: never raw SQL or `ssh`, never `owner-approve` or the approval file. The owner never runs SQL. Stop on the first failure; never retry a file or write that may have applied. If a guard denies a command, report the deny message to Elon; never work around it.

Then:

1. Run the production deploy command from the facts, including the `git push origin <sha>:<production branch>` when the facts list it (some commands push the branch themselves, some check that it already points at the commit). Set only the overrides the facts allow, and only when the owner said so.
2. Confirm the host runs the commit with the check in the facts.
3. Send the smoke check message. On `Smoke passed`, set the production context to `success` and tell Elon: component, commit, PRs shipped, deploy time.

## Release evidence
- Raw gate logs go only in gitignored `.claude/release-reports/<release-id>/` (they can hold host or environment details); delete the folder once the release reaches production or is superseded. The durable result (summary, gate outcomes, owner prerequisites) goes in the release PR or its issue.

## Release brief rules
Elon copies these into every release dispatch brief, and release-manager follows them over any other wording:

- Never invoke `bin/owner-approve.sh` in any form (`status`, `help`, `--help`, `version`, dry run) and never write the approval file. Read only approval evidence comes from the Read tool on the approval file, or from Elon.
- A guard or approval hook denial is a terminal stop-and-report. Preserve the exact denied command and message, notify Elon, and do not reformulate or retry. Valid owner scope does not grant discretion to override it.
- Guarded commands keep the literal component and full SHA. No shell variables such as `$S`.
- Backup and `RESTORE VERIFYONLY` before SQL, the once-only ledger, approval file integrity (record its content hash first) and the exact host SHA with HTTP and mobile evidence all stay required.

## A deploy run by hand

The host deploy script is the last step of this pipeline, not a way around it; a commit the owner deploys directly may have skipped stages. On a hand deploy (the owner names the sha, or the host's recorded sha differs from `origin/<production branch>`), release-manager tells Elon, records the sha as the production context only after the smoke check passes, and asks the owner to approve fast forwarding `<production branch>` to it (the push asks for approval). Until then every smoke check targets the sha that actually runs.

## When production fails

- **Normal:** revert the change on `<dev>` and take the revert through local, staging and production.
- **Emergency, owner approval required:** follow the rollback section of the facts (usually: move `<production branch>` back to the previous commit with a force push, which asks for approval, and redeploy). Blocked when the failed deploy changed the schema in a way the facts say does not reverse: that case goes to Elon, who asks the owner, with the schema diff.

Report every failure to Elon at once with the step, the error and your recommendation.
