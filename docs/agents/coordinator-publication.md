# Coordinator publication

Coordinators publish engineering branches with `~/dotfiles/script/coordinator-publication.sh`; workers still stop at local commits.

## Command

```bash
~/dotfiles/script/coordinator-publication.sh \
  --repo owner/name \
  --branch <engineering-branch> \
  --body-file /path/to/pr-body.md \
  [--title "<title>"] \
  [--worktree /path/to/worktree]
```

The worktree must already be checked out on `--branch`. The helper never reads `@{upstream}` or the current branch name without an explicit `--branch`.

## PR body file

- `Closes #N` on its own line when closing an issue (at most one issue per line).
- `## Verification` with exactly three bullets (command or path and observed outcome).
- No `## Test plan` heading and no tool credit (`Generated with Claude Code`, `Co-Authored-By:`).

## Refusals

Protected branch names (`main`, `master`, `staging`, `production`), `--force`, non-fast-forward pushes, tracked secret env files anywhere in the branch diff (for example `web/.env.local`; `.env.example` is allowed), and invalid bodies exit before any network call. Local diff inspection for environment files is fail-closed when the base ref or diff cannot be resolved.

## Retries and resume

Push and `gh pr create` each retry at most three times. A receipt under the worktree git directory records a successful push so a later run can open the PR without pushing again. A completed run prints `PUBLISHED <url>`.

## Fixture tests

```bash
bash ~/dotfiles/script/tests/coordinator-publication.test.sh
```

Uses disposable local remotes and a stub `gh`; no real GitHub mutations.
