# Changelog

How the changelog is kept. The plain language weekly summary is [RELEASE-NOTES.md](../RELEASE-NOTES.md). The full technical list is [CHANGELOG.md](../CHANGELOG.md).

## How it works

1. **Fragments.** Every pull request adds one file to `changelog.d/`. It holds only that PR's entry, in the `CHANGELOG.md` format (one or a few lines of prose, with the PR or issue number in brackets). A PR never edits `CHANGELOG.md`, so two PRs never conflict on it.
2. **Naming.** `<issue>-<short-slug>.md` when the PR has an issue (for example `1244-fill-seats-per-pass.md`), or `<branch-slug>.md` when it has none. `changelog.d/README.md` is never compiled.
3. **Compile.** `bin/changelog-compile.sh`, run from the repo root, inserts every fragment directly under the top `## [Unreleased]` heading of `CHANGELOG.md`, then deletes the fragments. With no fragments it changes nothing. With no `## [Unreleased]` heading it exits 1. `/deploy staging` runs it. A compile can also land as its own docs PR.
4. **Dated headings.** The script writes no dates and needs an `## [Unreleased]` heading on top, so that heading stays, empty. After a compile, put a `## [<date>]` heading right under it, so the new entries sit in a dated section. Entries are separated by one blank line.
5. **Backlog warning.** `script/fleet-watch.py` sends one notice when a checkout holds more than 50 fragments (`changelog_fragment_warn`). Compile them when you see it.

Test: `bin/changelog-compile.test.sh`.

## Index of CHANGELOG.md sections

| Heading | Covers |
| --- | --- |
| `## [Unreleased]` | Empty. The next compile lands here |
| `## [2026-11-20]` | Fragments merged from 2026-11-17 to 2026-11-20: fleet-watch seats and loop, placement limits, the 20 label issue set, brief and title rules, ship pulling dotfiles to the fleet, apps in `/Applications` |
| `## [2026-11-17]` | Everything compiled before that, up to 2026-11-17 (the date of the earlier compile): board Done cards, wrap-up, the command guard, usage gate, verifier routing, head-checks, team audit |

New sections go on top. Update this table when a compile adds one.
