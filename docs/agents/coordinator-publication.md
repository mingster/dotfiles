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

Protected branch names (`main`, `master`, `staging`, `production`), `--force`, non-fast-forward pushes, and invalid bodies exit before any network call. Secret env files (`.env` and `.env.*` except documented templates such as `.env.example`) are refused when any path touching them appears anywhere in the commits being published (`base..HEAD`), including add-then-delete history and non-ASCII path segments; inspection uses raw NUL-delimited paths from `git log --name-only -z` and does not read file contents. Inspection is fail-closed when the base ref or history cannot be resolved. The worktree `origin` fetch URL and every configured `remote.origin.pushurl` must identify the same GitHub `owner/name` as `--repo` when the URL is GitHub-shaped (credentials are never printed on mismatch). For disposable `file:` or absolute-path fixture remotes with `COORDINATOR_PUBLICATION_FIXTURE_ORIGIN=1`, every push URL must canonicalize to the same path as the fetch URL; fixture git also refuses fetch/push when any configured remote URL is not file-local.

## Retries and resume

Push and `gh pr create` each retry at most three times. A receipt under the worktree git directory records progress with a fixed six-field schema (no shell evaluation on read); writes use a temp file and rename inside the git directory so interruption leaves the last complete receipt. A completed run prints `PUBLISHED <url>`.

## Fixture tests

```bash
bash ~/dotfiles/script/tests/coordinator-publication.test.sh
```

Uses disposable local remotes and a stub `gh`; no real GitHub mutations.
