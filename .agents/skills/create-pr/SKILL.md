---
name: create-pr
description: Prepare, commit and publish a GitHub PR using the repository checks and changelog rules. Use when asked to create a PR. In an agent team, publication belongs to Elon.
---

# Create PR

Read `AGENTS.md` and, in an agent team, "Commit, push and merge" in `.claude/model-routing.md` first. Workers prepare local commits and report to Elon; they never push, open PRs or merge PRs. Elon handles publication and merge on completion under that policy. Outside a team, an explicit request to create a PR authorizes publication.

## Prepare

1. Inspect the worktree, current branch and all commits and changes since the default branch. Detect the default branch from Git or the repository metadata. Use a feature branch; keep an existing feature branch and rebase only when requested.
2. Use the `code-review` skill for review against that base and the originating issue or spec. Reuse a review of the same head when the project policy permits it. Follow the project's review timing, including merge on completion, without adding a second review gate here.
3. Run the repository's required checks. For a web app, detect its package from the repository instructions (`<project-b>_web/` or `web/` in the usual layouts) and run `bun run build` there before committing. A failed build blocks publication; use `diagnosing-bugs` when diagnosis is needed. Documentation changes use the repository's documentation checks.

## Changelog

When `changelog.d/` exists, add `<issue>-<slug>.md`, or `<branch-slug>.md` without an issue, in the repository's entry format. The release process compiles it; leave `CHANGELOG.md` alone. Otherwise update the root `CHANGELOG.md` under its Unreleased section using today's date. Skip changelog only when the owner explicitly allows it for a dependency or chore change.

For product changes covered by `.cursor/changelog-hook.json`, update the configured vault `HOME.md` Recent Changes section with `script/prepend-recent-change.ts` from dotfiles. Read that config for the actual paths and use the helper's `--link`, `--label` and `--summary` arguments. If the helper is unavailable, follow the existing file format. Confirm the required file or fragment appears in the branch diff and the configured changelog hook allows PR creation. Resolve a denial before publishing.

## Commit

Include all work belonging to the PR, including the changelog and required Recent Changes entry. Stage with `git add -A`, inspect the staged paths and diff, and unstage secrets, `.env*` and `.cursor/hooks/state/`. Respect explicit path exclusions and preserve unrelated work. Commit with the repository's message style. If the branch already contains all required commits, continue without an empty commit.

## Publish

Only the authorized publisher performs this section. In an agent team, use the push procedure in `.claude/model-routing.md`.

Prepare the title and body from the entire branch change. State the concrete outcome, link the issue or spec, and include scope, risk and validation evidence needed by the repository's review checklist. Use `Fixes #<number>` when appropriate. The owner's body rules prohibit a Test plan section, tool credit and Co-Authored-By suggestions, including on later edits.

Outside a team, push the feature branch with `git push -u origin HEAD`. Open the PR only after the push succeeds. Pass a prepared body file to `gh pr create --title <title> --body-file <path>` so newlines and literal text survive shell quoting. Report the returned PR URL. Follow the project's merge policy; opening a PR alone does not authorize merging it.
