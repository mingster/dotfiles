Each PR adds one file here named `<issue>-<short-slug>.md` (or `<branch-slug>.md` with no issue).
The file holds only the changelog entry line(s), in the same format as CHANGELOG.md. Do not edit CHANGELOG.md in a PR.
`bin/changelog-compile.sh` moves every fragment under `## [Unreleased]` in CHANGELOG.md and deletes it. The release step runs it.
This README is never compiled.
