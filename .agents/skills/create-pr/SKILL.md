---
name: create-pr
description: >-
  Create GitHub pull requests with gh CLI from the current branch. Use when the
  user asks to create a PR, open a pull request, createpr, or push and PR after
  feature work. Analyzes full branch diff vs base, pushes if needed, and returns
  the PR URL.
---

# Create PR

Open a GitHub pull request from the current branch using `gh`. **Do not** use the Task tool or todo list for this workflow.

## Prerequisites

- `gh` authenticated (`gh auth status`)
- Repo cloned; on a feature branch (not default branch unless user explicitly wants that)
- User has **not** asked you to commit — only create PR from existing commits unless they also asked to commit/push

## 1. Gather branch state (parallel)

Run these **in parallel** before writing the PR:

```bash
git status
git diff
git branch -vv
git log --oneline -10
git diff main...HEAD
```

If the default branch is not `main`, detect it (`git symbolic-ref refs/remotes/origin/HEAD` or `gh repo view --json defaultBranchRef`) and use that instead of `main` in `git diff <base>...HEAD`.

Also check whether the branch tracks a remote and is ahead/behind.

## 2. Analyze the full PR scope

- Review **all commits** on the branch since it diverged from base — not only the latest commit.
- Read staged + unstaged diff only to warn the user if uncommitted work would be **left out** of the PR (do not commit unless asked).
- Draft title and body from the combined change set.

### Title

- One line, imperative, scoped to the main outcome
- Prefer under ~72 characters; riben.life commits often use short messages (<50 chars) — PR title can be slightly longer but stay concise

### Body template

```markdown
## Summary
- <1–3 bullets: what changed and why>

## Test plan
- [ ] <concrete check the reviewer can run>
```

For riben.life (`web/` app): suggest `bun run lint` or targeted manual checks; use `bun run build` only when the user asked or the change touches schema, deps, or routing.

## 3. Push then create PR (sequential)

```bash
# Only if branch is not on remote or is behind and user asked to push / create PR
git push -u origin HEAD

gh pr create --title "the pr title" --body "$(cat <<'EOF'
## Summary
- ...

## Test plan
- [ ] ...

EOF
)"
```

Use a **HEREDOC** for `--body` so markdown and backticks are preserved.

Return the **PR URL** from `gh pr create` output to the user.

## Hard rules

| Do | Don't |
|----|--------|
| Use `gh` for all GitHub operations | `git config` changes |
| Push with `-u origin HEAD` when needed | Force-push `main`/`master` without explicit user request |
| Include every commit since branch diverged | Commit unless the user asked |
| Warn if uncommitted changes won't be in the PR | `git add -A` / commit proactively |
| Return the PR URL when done | Use Task tool or TodoWrite for this workflow |

## Optional follow-ups (only if user asks)

```bash
gh pr view --web          # open in browser
gh pr checks --watch      # wait for CI
gh pr edit --add-reviewer @user
```

## Linking issues

If the branch or commits reference an issue:

```markdown
Fixes #123
```

Add to the PR body `## Summary` or a dedicated line at the top.

## Example

Branch `fix/misc` with 2 commits (settings + geo defaults):

```bash
git push -u origin HEAD

gh pr create --title "Store settings and geo defaults on create" --body "$(cat <<'EOF'
## Summary
- Merge pickup into shipping tab; danger zone as collapsible panel
- Resolve supported countries for payment/shipping on storefront and admin
- GeoIP defaults on store creation

## Test plan
- [ ] Store settings: 語系與國家 saves TW; 金流設定 lists payment methods
- [ ] Storefront checkout shows TW-eligible methods
- [ ] `bun run lint` from `web/`

EOF
)"
```
