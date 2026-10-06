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

## Standing go

`<owner, date>`. No approval of its own when all hold: local and staging statuses `success`, the schema diff empty, no prerequisite, not a rollback, `<project condition>`. Everything else waits for the owner's go for that commit.

## Host status

* `<command that prints what each host runs, or none>`.

## Rollback

* `<emergency rollback steps, and when the schema blocks them>`.
