
## Token budget

Every agent and teammate pays for what it reads, on every turn after. These hold in every session.

- Search, then read the part. Grep or Glob first, then Read with `offset` and `limit`.
- Keep command output short: pipe test, build and lint output through `tail -40`. While working, run only the test files you touch; run the full suite once, at the end.
- Plan before you edit: 3 to 5 lines naming the files, the change and the test that proves it.
- Strikes. The same test failing twice after your change means stop editing: check whether a fake is stale or the test database is wrong. The same command failing 3 times in a row is a hard stop, enforced by `.claude/hooks/strikes.py`. Report the failing output and what was ruled out, and wait for the owner. This is the only strike rule; role files point here.
- Use `active_run.md` (git ignored) only on a ticket with more than one slice: write it at the start and when blocked.
- Report with `git diff main...HEAD --stat`, the branch name, test counts and only the failing output.

## Compact instructions

When the conversation is compacted, keep: your role, the task list and who acts next, the branch and worktree, the allowed files, the verify command, strike counts and the last failing output. Drop file contents and command output; they are re-read from the repo.

## Owner context commands

- **Context commands** (you or the lead run these; agents cannot): `/clear` between tickets, `/compact` at a slice boundary, `/btw` for a side question that should not grow the session. Lead only: `/fork` copies the conversation into a new background session and `/subtask` spawns a forked subagent, both cheap because they reuse the cached context, but a fork cannot spawn further agents. A worker's prompt cache lasts about 5 minutes and the main session's about 1 hour, so give workers the full contract up front and never park one waiting on a reply.

## Project facts the roles point to

Fill these in: the read only database URL variable, the masked env check, the local development database name, the staging and production hosts, and the support mailbox.
