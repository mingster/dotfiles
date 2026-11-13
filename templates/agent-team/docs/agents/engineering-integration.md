# Engineering integration

Read before judging engineering reviews or tests. Docs and changelog only PRs follow Orchestration rule 3 in `~/dotfiles/templates/agent-team/docs/agents/team.md`.

## Review and tests

- **Review judge:** extra Strong / Claude Opus cross review follows `team.md`, Extra Strong review; record an explicit request and its reason on the issue or PR. Auth, schema, tenant isolation, gate scripts, diff size, uncertainty and a model fallback do not require it. QA and exact-head Checks stay required; when both pass, the lead proceeds. PR bodies name the QA Verdict and say `Extra Strong review: required (<money transaction or explicit request>)` or `Extra Strong review: skipped (outside owner rule)`.
- **When qa-sdet runs for a merge:** cold review runs in GitHub Actions after `Checks` pass (`~/dotfiles/script/pr-review.sh`). `ship.sh` merges a PR touching anything beyond markdown and `changelog.d/` only on a `Verdict: PASS` from a dispatch other than the builder; a cold `Review: PASS` does not satisfy it (only `Review: FAIL` blocks), and a PR of only markdown and `changelog.d/` files lands on a cold `Review: PASS`. The one verifier (`qa-sdet`, another model family) runs the change as a user would, parent against head (a changed script in a temp environment), per `qa-sdet-execution.md`; it never re-reads the diff for style. When `Checks` is FAIL at the head, return the PR to its author without starting QA. A small fix after a PASS (under about 30 lines, same files, no new behaviour beyond the finding) needs no re-review; note it in the Verdict. A larger or production-behaviour change gets a re-review.
- **Test only the change:** run the unit's listed cases and the touched unit tests; the unit is done when they pass. Full regression runs only in release-manager's development pass before staging, or for a very large update with the coordinator's approval recorded on the issue. Shared code is no exception. A diagnosis rerun reruns only the named failing spec files.
- **No coordinator Verdict:** except for a Cursor-built PR (coordinator-operations rule 3), the coordinator never posts a `Verdict:` or `Review:` line on a PR head; either makes the cold `Review` skip that head.
- **PASS checks:** the coordinator runs no tests and no tsc before a Verdict. `~/dotfiles/script/head-checks.sh` runs them once per head: scoped tests, the guards `web/src/__tests__/` and `web/src/utils/__tests__/`, and `python3 bin/check-intent-roots.py`. Every tracked `docs/intent/<dir>/spec.md` or `tickets.md` needs a tracked regular sibling `intent.md`, including after removal or rename; an untracked file does not count. When a check is red, compare it with the clean-main baseline at the current `origin/main` sha; a failure absent from the baseline blocks the merge. A test file that fails to load (bun prints `error:` and runs 0 tests) is a failure. The Verdict lists the receipt's pass, fail and load-error counts, and the e2e specs matched by the changed strings.
- **Iterating:** run a test file with `ONLY=<new cases>`; run its whole case list once at the end with `JOBS=<n>`.
- **Test judge:** a new test or check names the real failure it prevents and needs your approval (the coordinator's for gate checks). Per-PR checks stay under 60 s; cut a test before adding one over budget.
- **Hooks:** Claude Bash PreToolUse runs the guard (blocks explicit `.env.local` copy or link operands into Orca worktrees) and the advisory (warns on `fullstack-dev` starts named by `--task-title`: `agent_type=elon` gets a coordinator warning, a missing caller identity a neutral reminder, other callers nothing; it never denies a start, and a start without a role title is outside advisory coverage). Regressions: `python3 -m unittest discover -s .claude/hooks/tests` and `python3 bin/check-intent-roots.test.py`; they prove configured-command contracts only. Hook and settings changes merge per `team.md`, Role changes, with approval of the exact final head.
- **Exemption evidence:** verify a bypass, exemption or allowlist only with a receipt showing the exempt path ran (a log line with the exempt value), or a run from the client that fails without it.
- **PR body:** `## Verification` with 1 to 3 real runs and outcomes. No Test plan section (it lives in the spec and unit), no tool credit.

## Verifier brief

- Name the exact test command (`post-verdict.sh --command`). Confirm the Verdict's verifier and author dispatch IDs with `orca orchestration worker-show` (`script/ship.sh` enforces this). Delete, never edit, your own malformed Verdict that a fresh one supersedes, and note it in the PR body.
- Briefs use literal placeholders such as `<issue>`, never global replacement of one letter. Before dispatch, verify the scope names its own issue and dependency PRs are MERGED (a queued dependency uses no lane). Browser briefs give a unique session on every call.

## Merge rules

Read before every merge.

- **Review tier (ADR 0088):** the Review judge above. No checks rerun after a clean merge of trunk.
- Screenshots only when the brief asks for the owner's look before production; the coordinator shows them.
- Merge trunk in; never rebase, force push or `--admin`. `origin/main` failures get a follow-up issue, not a block. Release-manager may rerun named failing specs only, even a new spec no worker could run.
- **One writer per branch:** findings go back to its author; you and the verifier never push to it.
- **Review notes:** on PASS+NOTES, write one line per note in the merge comment, `verified safe: <evidence>` or the fix issue number, before you merge.
- **Spec-linked PR (#5834):** check `architect-pm-work.md`, Shared input rule and State matrix rule (states: signed out, signed in not bound, bound, failure).
