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

Protected branch names (`main`, `master`, `staging`, `production`), `--force`, invalid bodies, and secret env files in the outgoing publish range exit before push or `gh` mutations. After origin URL preflight, a read-only `git fetch --no-tags --refmap= origin refs/heads/main` loads the destination `main` tip into `FETCH_HEAD`; env inspection uses `<FETCH_HEAD-sha>..HEAD` (never a cached `origin/main` tracking ref or a generic `git fetch origin` fallback) so unpublished local `main` commits are included when the fetched tip is older than a stale tracking ref. Non-fast-forward pushes are refused after that fetch when the remote feature tip is known and not an ancestor of HEAD. Secret env files (`.env` and `.env.*` except documented templates such as `.env.example`) are refused when any path touching them appears anywhere in those outgoing commits, including add-then-delete history, merge-resolution-only paths, and non-ASCII path segments; inspection uses raw NUL-delimited paths from `git log --name-only -z --diff-merges=combined` and does not read file contents. Fetch or base discovery failure is fail-closed. Branch names must pass `git check-ref-format --branch` and match the receipt scalar charset (including embedded `+` and `@` when Git-valid) before fetch, push, or receipt write. The worktree `origin` fetch URL (`git remote get-url origin`) and every Git-resolved effective push URL (`git remote get-url --push --all origin`; includes `pushurl`, `insteadOf`, and `pushInsteadOf`) must identify the same GitHub `owner/name` as `--repo` when the URL is GitHub-shaped. All `gh` calls pass `--repo github.com/owner/name` so an inherited `GH_HOST` cannot redirect API operations away from the validated GitHub origin. Resolution errors fail closed. For disposable `file:` or absolute-path fixture remotes with `COORDINATOR_PUBLICATION_FIXTURE_ORIGIN=1`, every resolved push URL must canonicalize to the same path as the fetch URL. Fixture tests export `GIT_ALLOW_PROTOCOL=file` and the git stub refuses fetch/push when any resolved remote URL is not file-local.

## Retries and resume

Push and `gh pr create` each retry at most three times. A receipt under the worktree git directory records progress with a fixed six-field schema (no shell evaluation on read); writes use a temp file and rename inside the git directory so interruption leaves the last complete receipt. A completed run prints `PUBLISHED <url>`.

## Fixture tests

```bash
bash ~/dotfiles/script/tests/coordinator-publication.test.sh
```

Uses disposable local remotes and a stub `gh`; no real GitHub mutations.
