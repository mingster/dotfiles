# Deploy facts

Product facts the shared `deploy` skill reads. The skill is generated from dotfiles and holds no hosts, branches or commands; this file is owned by this project. Keep the headings: the skill looks values up by heading.

## Repository

* GitHub: `<owner>/{{PROJECT_NAME}}`. Development branch: `main`.
* Decision record: `<ADR that set up this pipeline>`.

## Components

One row per deployable component. With one row, `/deploy` takes no component argument.

| Component | Folder | Stage branches | Status contexts | local | staging | production | Smoke check |
| --- | --- | --- | --- | --- | --- | --- | --- |
| app | repo root | `staging`, `production` | `deploy/local`, `deploy/staging`, `deploy/production` | worktree on the Mac | `<staging host>` | `<production host>` | qa-sdet |

## Production window

* `<for example 15:00 to 17:00 Asia/Taipei, or none>`.
* One deploy at a time: `<the lock or shared host, or none>`.

## local

* Worktree path: `.claude/worktrees/deploy-local`.
* Env file: `<path>`. Allowed databases: `<localhost only, or _test databases only>`. Masking tool: `<path, or none>`.
* Port that must be free: `<port>`.
* Steps, in order: `<install>`, `<schema sync>`, `<lint>`, `<test>`, `<regression>`.

## staging

* Deploy command: `<git push only, or a wrapper>`.
* Wait for the build: `<how, and for how long>`.
* App page that must answer 200: `<url>`.
* Migrations: `<how staging migrations are applied, or none>`.

## production

* Deploy command: `<command>`. Overrides allowed only on the owner's word: `<env flags, or none>`.
* Host check that it runs the commit: `<command>`.
* Schema diff for the summary: `<git diff command>`.
* What a deploy interrupts: `<downtime, restarts>`.

### Production prerequisites

Release-manager applies production SQL and secrets itself, through the project's scripts, inside the owner's approval. The owner never runs SQL. Delete this block if the project has no production database.

* Production SQL apply script: `<path and exact command, for example bin/apply-production-sql.sh <component> <sha> --dry-run <db> <files>>`. Dry run first, then the same command without `--dry-run`.
* Production secret script: `<path and exact command, for example bin/set-production-secret.sh <component> <sha> <KEY>>`, with its allowed keys: `<list>`.
* Approval scope that allows both: `<for example bin/owner-approve.sh promote <component> <sha> --schema --apply>`. Valid for `<minutes>`, one component and one full commit sha.
* Migration login: `<least privilege login the SQL script uses, and where its credential lives>`. Preflight that checks it before any write: `<command, or none>`.
* Ledger: `<table or file that records applied SQL files, and how a changed file is handled>`.
* Backup before the first write: `<how it is made and verified, and where it lands>`. A failed backup stops the run.
* One time owner dry run: `<what the owner runs once to prove the scripts, login and backup work, and the date it passed>`.

## Owner approval

* Production needs the owner's explicit go for each release.
* Owner approval script: `<path and exact command, for example bin/owner-approve.sh <component> <sha>, or none>`. The owner runs it; the deploy skill gives them the exact command.

## Host status

* `<command that prints what each host runs, or none>`.

## Rollback

* `<emergency rollback steps, and when the schema blocks them>`.
