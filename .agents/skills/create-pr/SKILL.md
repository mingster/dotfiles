---
name: create-pr
description: >-
  Commit, verify build, and open a GitHub PR with gh CLI. Use when the user asks
  to create a PR, open a pull request, createpr, commit and PR, or push and PR
  after feature work. Always runs `bun run build` from web/ before commit; only
  checks in build-passing code.
---

# Create PR

**Always commit, then push, then open the PR.** Run a production build first and only commit when it passes. **Do not** use the Task tool or todo list for this workflow.

## Prerequisites

- `gh` authenticated (`gh auth status`)
- Repo cloned; work from a feature branch (create one from default branch if needed)
- Commands for riben.life app run from **`web/`**

## 1. Gather branch state (parallel)

```bash
git status
git diff
git branch -vv
git log --oneline -10
git diff main...HEAD
```

If the default branch is not `main`, detect it (`git symbolic-ref refs/remotes/origin/HEAD` or `gh repo view --json defaultBranchRef`) and use that instead of `main` in `git diff <base>...HEAD`.

## 2. Branch setup

- If on the default branch with uncommitted work: `git fetch origin <base>` then `git checkout -b fix/<short-topic> origin/<base>`.
- If already on a feature branch, keep it (rebase on `<base>` only if the user asked).

## 3. Verify build (required before commit)

From **`web/`**, run:

```bash
cd web && bun run build
```

- **Build must exit 0** before any commit. This overrides the usual “don’t run build for routine edits” rule for this workflow only.
- If build fails: fix TypeScript, import, and compile errors, then re-run until green. **Do not commit** failing code.
- Optional quick check before full build: `bun run lint` — but **build is mandatory** for create-pr.

## 4. Commit

Stage all changes that belong in the PR. **Exclude** unless explicitly requested:

- `.env*` / secrets
- `.cursor/hooks/state/` (machine-local agent state)
- Unrelated local-only churn

Follow repo commit style: short imperative message (<50 chars when possible):

```bash
git add -A   # or selective paths after excluding the above
git commit -m "$(cat <<'EOF'
Short imperative summary

EOF
)"
```

If there is nothing to commit after build passes, skip to step 6 (push + PR from existing commits).

## 5. Draft PR title and body

- Review **all commits** on the branch since it diverged from base — not only the latest.
- Title: one line, imperative, main outcome (~72 chars max).

### Recent Changes (required for product PRs)

If the branch touches `web/src/`, `web/bin/`, `web/prisma/`, or `fileServer/docs/` (except HOME-only typo fixes), **prepend one line** to `fileServer/docs/HOME.md` under `## Recent Changes` **before** `gh pr create`. A Cursor hook blocks PR creation until HOME.md is updated.

Format:

```text
- YYYY-MM-DD — [[path/to/note|Short label]] — one-line what changed
```

Helper (from repo root; uses `~/dotfiles/script/prepend-recent-change.ts`):

```bash
bun ~/dotfiles/script/prepend-recent-change.ts --link STRIPE_STORE_SUBSCRIPTION_METADATA --label "Platform subscription pricing" --summary "List/special monthly and yearly ×11"
```

Commit the HOME.md change with the rest of the PR. Per-repo config: `.cursor/changelog-hook.json`. See `doc-vault-context.mdc` in project rules.

```markdown
## Summary
- <1–3 bullets: what changed and why>

## Test plan
- [ ] <concrete check the reviewer can run>
```

Mention in test plan that `bun run build` passed locally before commit.

## 6. Push and create PR (sequential)

```bash
git push -u origin HEAD

gh pr create --title "the pr title" --body "$(cat <<'EOF'
## Summary
- ...

## Test plan
- [ ] ...
- [ ] `bun run build` passed locally before commit

EOF
)"
```

Use a **HEREDOC** for `--body`. Return the **PR URL** from `gh pr create` output.

## Hard rules

| Do | Don't |
|----|--------|
| Run `bun run build` from `web/` before commit | Commit when build fails |
| Commit all PR-relevant changes, then push + PR | Open a PR with uncommitted work left out |
| Use `gh` for GitHub operations | `git config` changes |
| Push with `-u origin HEAD` | Force-push `main`/`master` without explicit user request |
| Return the PR URL when done | Use Task tool or TodoWrite for this workflow |
| Update `fileServer/docs/HOME.md` Recent Changes before `gh pr create` when shipping product code | Skip changelog for deps-only or chore-only PRs |

## Changelog hook (global)

User hook `~/dotfiles/ide/cursor/hooks/ensure-changelog-before-pr.sh` (linked into `~/.cursor/hooks/` by `script/link-cursor-hooks.sh`) **denies** `gh pr create` when shippable paths changed but the repo changelog (see `.cursor/changelog-hook.json` or auto-detect) was not updated. Re-run `bash ~/dotfiles/script/link-cursor-hooks.sh` or `install.sh` after pulling dotfiles.

## Optional follow-ups (only if user asks)

```bash
gh pr view --web
gh pr checks --watch
gh pr edit --add-reviewer @user
```

## Linking issues

```markdown
Fixes #123
```

Add to the PR body when branch/commits reference an issue.

## Example

```bash
cd web && bun run build

git add -A
git commit -m "$(cat <<'EOF'
Update client state after AI menu scan

EOF
)"

git push -u origin HEAD

gh pr create --title "Refresh product and category lists after menu scan" --body "$(cat <<'EOF'
## Summary
- Return mapped columns from scan save action
- Merge new products/categories into client state without router.refresh

## Test plan
- [ ] AI scan from products/categories sheet shows new rows immediately
- [ ] `bun run build` passed locally before commit

EOF
)"
```
