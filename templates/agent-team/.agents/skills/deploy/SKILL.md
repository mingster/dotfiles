---
name: deploy
description: Move a commit (of one component, when the project has several) through local dev, staging and production. Use with /deploy local|staging|production [<component>] or /deploy status. Run by release-manager, reporting directly to the coordinator. Works in Claude Code, Cursor and Antigravity.
---

# Deploy

Arguments: the stage (`local`, `staging`, `production` or `status`) and, when the project has more than one component, the component. With no stage, run `status`; `status` without a component covers them all.

"Facts" means the project's `docs/agents/deploy-facts.md`: repository, components and folders, stage branch and status names, hosts, the command per stage, guards, production window, user approval script, rollback. Read it first; if it is missing, stop and tell the coordinator. On a product detail the facts win; on the rules below this skill wins.

Placeholders: `<repo>` the repository, `<dev>` the development branch, `<staging branch>` and `<production branch>` the component's stage branches (for example `staging` or `web2/staging`), `<context>` the stage's commit status name (for example `deploy/staging` or `deploy/web2/staging`).

Steps follow pstack `shipping` (with `.agents/skills/orca-adapter/playbooks/shipping.md`), and a failure is diagnosed with `runtime-forensics`. This skill holds only the gates; they win over any playbook step.

## Gates for every stage

1. **Who starts a stage.** local and staging: release-manager, any time; promote trunk to staging after merges, without waiting for the queue to drain or a user word. production: release-manager only, on the user's explicit go for that exact commit, inside the production window when the facts name one.
2. **Promotion.** A stage deploys only a commit with a `success` status from the stage before: the local context for staging, the staging context for production. Production deploys exactly the commit `<staging branch>` points at, even when `<dev>` has moved on.
3. **Fast forward only.** release-manager pushes only `<staging branch>` and `<production branch>`; other branches go to the coordinator ("Commit, push and merge" in `.claude/model-routing.md`). Stage branches move with `git push origin <sha>:<stage branch>` and nothing else (the first push creates the branch). If the push is refused as non fast forward, stop and tell the coordinator; never add `--force`.
4. **One path to a server.** Deploy only with the facts' command for the stage. No host scripts or `ssh` around it, except the manual fallback steps the facts name for when the command cannot run (those ask for approval). When the command refuses, report the reason to the coordinator; never work around it.
5. **The record.** Set the stage's status on the commit when it passes, and `failure` when it fails (except a failed mandatory gate the facts name, which leaves the status unset). The staging context is set `pending` when the staging deploy succeeds, and `success` only after the regression run and the swarm live lanes on that sha both pass (staging gates):
   `gh api -X POST repos/<repo>/statuses/<sha> -f state=success -f context=<context> -f description="<one line>"`
6. **Smoke checks belong to the role the facts name** (qa-sdet unless they say otherwise). After staging or production, send `Ready for <role> smoke check: [<component>] <stage> <sha>` and set the status only after `Smoke passed: [<component>] <stage> <sha>`.
7. **One deploy at a time** when the facts say so (a lock or a shared host). Stop at the first failure: report the step, the command and the first error line to the coordinator. Do not retry a step that may have changed a database.
8. **Ten minute limit.** A single step (test suite, build, deploy command) running over 10 minutes is a failure, not a wait. Exception: the full regression run, started through the heavy gate with `HEAVY_GATE_CLASS=long`, may take up to 20 minutes (user decision 2026-10-10); it runs beside the staging deploy and never holds it (rule 9). A step silent for 5 minutes counts the same. Stop it, set nothing to success, and report to the coordinator at once: step, command, run time, last output line.
9. **Deploys test the deployment, not the code** (user rule). A stage checks only that the build succeeds, the schema sync works, the site serves the candidate sha and any mandatory gate the facts name passes. The gate before staging is the type check, the unit tests, the build, and the app answering 200 with `/api/build` serving the sha (the facts name the commands and the development pass status for it); the local stage requires that pass instead of running the suites. A missing or failed pass stops the stage and is fixed in development. The full regression suite is not part of that gate: it runs in development on the same sha, in parallel with the staging deploy (staging gates), and blocks production of that sha only (staging stays on a red sha).
10. **Prepare the candidate before the development pass** (user rule). Run the facts' format script (for example `bun run format`) in every Bun package the facts name and set its package.json `"version"` to today as `YYYY.MM.DD` (for example `2026.10.09`). Commit it, formatting included, as `chore: format and version YYYY.MM.DD` on a branch and report it to the coordinator, who pushes, opens the PR to `<dev>` and merges; then run the development pass on that merged commit, so the commit that passed is the one that deploys. A second deploy the same day keeps the date and skips the version change. No package updates here (rule 11).
11. **Dependency update on its own cycle** (user rule 2026-10-12). Right after a production deploy succeeds, and every Monday with no production deploy in the past 7 days, release-manager runs `bun upgrade && bun update` in every Bun package the facts name, updates every Bun version pin the facts name when Bun changed, runs the unit tests and the build, commits it on its own branch as `chore: dependency update YYYY-MM-DD` and reports it to the coordinator, who pushes, opens the PR to `<dev>` and merges. Exact pins in package.json stay; upgrading a pinned package is its own unit. Revert a bad update for that package alone, never hold it into a release, so feature work runs on new packages for days before the next deploy.
12. **Align the toolchain first.** Before the build on staging and before the build or switch on production, the deploy reads the runtime pins from the repo at the deploy sha, installs or switches the target host toolchain with its version manager, reads the versions again, logs the aligned versions, and stops before touching the live app when a version still does not match.

## Test noise

Release-manager applies this rule to development and release tests: a failing test counts as noise only with evidence that it passes on one isolated rerun, or fails the same on the last released SHA. Record the test, candidate and released SHAs, commands and matching failure evidence. More than 3 failures in one area blocks the release, even if individually classified as noise. Unproven failures block; never label them noise from an `origin/main` failure alone. This classification does not waive required success statuses or permit retrying a guarded or mutating deploy step.

## Stage gates

**status** is read only: per component, the commits of `origin/<dev>`, `origin/<staging branch>` and `origin/<production branch>`, their `deploy/` statuses, how far each is behind the stage before, and what the hosts run when the facts name a host status command. A host running something other than its branch is a finding for the coordinator.

**local**
- **Database guard.** Every database URL in the facts' env file must point where the facts allow for local (a local host or a `_test` database). Check with the facts' masking tool or check command; never print the file or its credentials. Anything else stops the stage.
- A port the stage needs must be free. If the user's dev server holds it, stop and ask the coordinator; never kill it. Preserve an existing worktree with unshipped changes.
- **Development pass.** The commit carries the facts' development pass status (for example `dev/<component>`) as `success` before any step; otherwise promotion stops and release-manager runs or diagnoses the pass in development (rule 9), first running the facts' dev schema sync preflight when they name one. Never run the unit or regression suites here. A step the facts mark advisory fails the gate only as the facts describe.
- Local `success` only when every facts local step passed, with what ran in the description.

**staging**
- **Changelog first.** Fragments are compiled with `bin/changelog-compile.sh` on an up to date `<dev>`; a changed `CHANGELOG.md` is committed as `chore: compile changelog fragments` and goes through the coordinator on the docs-only mechanical lane. The compile merge commit inherits local `success` (description `changelog compile only, inherits <parent sha>`) only when `git diff --name-only <parent>..<compile merge sha>` lists only `CHANGELOG.md` and `changelog.d/` and the parent has local `success`; otherwise run `/deploy local` on it.
- The candidate is the newest commit on `<dev>` with local `success`.
- A failed build or deploy leaves staging on the previous commit and sets the staging context to `failure`. A successful deploy sets it to `pending` ("deployed, regression and swarm live lanes running") and starts the full regression run in development on the same sha (the facts name the host and database); it never holds the deploy.
- Every mandatory staging gate the facts name passes first; a failed gate leaves the staging context unset.
- Staging `success` only when all of these hold on the same sha: `Smoke passed`, the regression run passed, and the swarm live lanes (pstack `swarm` with `.agents/skills/orca-adapter/playbooks/swarm.md`) have no open P0 or P1 finding (the coordinator reports it). A failed regression or a P0/P1 finding sets `failure` with the failing spec names or issue numbers; it blocks production of that sha only, staging stays on the sha, and the fix lands on `<dev>` as a new candidate.
- On `success`, send the coordinator `Ready for owner to approve production: [<component>] <sha>, <N> PRs` with the production summary.

**production**
- **Production summary** for the user decision message: the commit (`origin/<staging branch>`) with local and staging both `success`; `git log --oneline origin/<production branch>..<sha>` (limited to the component folder when the facts give one) and its merged PRs; the schema diff from the facts' command, naming any column that would be dropped or retyped and any migration the user must apply first; what the deploy interrupts, from the facts; green checks (`gh api repos/<repo>/commits/<sha>/check-runs`); prerequisites any PR in the range needs (an env value, a secret, a cron line, a server setting), read from each PR's description and deploy notes.
- **User go.** Production always needs the user's explicit go for that release; no earlier go, rule or passing check replaces it. Send `Ready for owner to approve production: [<component>] <sha>, <N> PRs` and deploy only after the coordinator relays the go for that exact commit. When the facts name a user approval script, also give the coordinator the exact command for the user, component and commit filled in, and deploy only after it ran. A rollback needs the user's go too.
- **High risk release.** When the facts define a high risk release, follow their rule for it (for example: deploy it alone, user online, the named gates before and after).
- **Production prerequisites.** When the facts name a production SQL apply script or secret script and the user's approval covers them (scope in the facts), release-manager runs them itself before moving `<production branch>`: the SQL script dry run first, then without it, one database at a time; the secret script per required key. Only these scripts: never raw SQL or `ssh`, never `owner-approve` or the approval file. The user never runs SQL. Stop on the first failure; never retry a file or write that may have applied. If a guard denies a command, report the deny message to the coordinator; never work around it.
- **Host approval preflight.** Before any production host job, when the facts name a user approval, check that it has the scope of the job (`host` for host jobs, `promote` for a promotion, `rollback` for a rollback) and is still valid for the expected job length (read only its scope and expiry, never other fields). If it is missing, expired, another scope or shorter than the job, stop before the first ssh and ask the coordinator for a fresh user approval of that scope. The expiry itself stays as the facts set it.
- **Deploy.** Only the facts' production command (with the `git push origin <sha>:<production branch>` when the facts list it) and only the overrides the facts allow, when the user said so. Confirm the host runs the commit with the facts' check. Every mandatory production gate the facts name passes before the smoke check; set the production context to `success` only on `Smoke passed`, then tell the coordinator: component, commit, PRs shipped, deploy time.

## Release evidence
- Raw gate logs go only in gitignored `.claude/release-reports/<release-id>/` (they can hold host or environment details); delete the folder once the release reaches production or is superseded. The durable result (summary, gate outcomes, user prerequisites) goes in the release PR or its issue.

## Release brief rules
Elon copies these into every release dispatch brief, and release-manager follows them over any other wording:

- Never invoke `bin/owner-approve.sh` in any form (`status`, `help`, `--help`, `version`, dry run) and never write the approval file. Read only approval evidence comes from the Read tool on the approval file, or from the coordinator.
- A guard or approval hook denial is a terminal stop-and-report. Preserve the exact denied command and message, notify the coordinator, and do not reformulate or retry. Valid user scope does not grant discretion to override it.
- Guarded commands keep the literal component and full SHA. No shell variables such as `$S`.
- Backup and `RESTORE VERIFYONLY` before SQL, the once-only ledger, approval file integrity (record its content hash first) and the exact host SHA with HTTP and mobile evidence all stay required.

## Hand deploy and rollback

- **Hand deploy.** When the user names the sha, or the host's recorded sha differs from `origin/<production branch>`, a stage may have been skipped: tell the coordinator, record the sha as the production context only after the smoke check passes, and ask the user to approve fast forwarding `<production branch>` to it (the push asks for approval). Until then every smoke check targets the sha that actually runs.
- **Rollback.** Normally a revert on `<dev>` taken through every stage. An emergency rollback follows the facts' rollback section and needs the user's approval; it is blocked when the failed deploy changed the schema in a way the facts say does not reverse, and that case goes to the coordinator, who asks the user, with the schema diff.
- Report every failure to the coordinator at once with the step, the error and your recommendation.
