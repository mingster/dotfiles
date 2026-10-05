# changelog.d

Every PR adds one file here, `<issue>-<short-slug>.md` (or `<branch-slug>.md` with no issue), holding only its entry line in the `CHANGELOG.md` format. PRs do not edit `CHANGELOG.md`, so they never conflict on it.
`/deploy staging` runs `bin/changelog-compile.sh`, which inserts the fragments under the top `## [Unreleased]` heading and deletes them. This README is never compiled.
