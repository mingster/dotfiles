# Engineering integration

Read before judging engineering reviews or tests. Docs-only PRs follow Elon's mechanical lane in `~/dotfiles/templates/agent-team/docs/agents/team.md`, Orchestration.

## Review and tests

- **Review judge:** extra Strong / Claude Opus cross review is required only for issues involving money transactions (payments, wallet movements, ledger postings), or when Elon or the owner explicitly requests it for that issue (record the request and reason on the issue or PR). Auth, schema, tenant isolation, gate scripts, diff size, uncertainty and a model fallback do not require it. Ordinary independent QA and exact-head Checks stay required; when both pass, the lead proceeds. PR bodies name the ordinary QA Verdict and say `Extra Strong review: required (<money transaction or explicit request>)` or `Extra Strong review: skipped (outside owner rule)`.
- A cross reviewer reads the code and the Checks receipt (never reruns tests, tsc or lint) and posts the Verdict `lead-merge.sh` checks. qa-sdet never runs `bun test`, tsc, lint or regression; that rule is stated once in `.claude/agents/qa-sdet.md` and here. When `Checks` is FAIL at the head, return the PR to its author without starting QA ([faster delivery spec](../intent/2026-11-01-faster-delivery-loop/spec.md) requirement 10). A small fix after a PASS (under about 30 lines, same files, no new behaviour beyond the finding) needs no re-review; note it in the Verdict. A larger or production-behaviour change gets a re-review.
- **Threads-only rework (owner pilot 2026-11-08):** failing Review or Bugbot at head → Elon dispatches a rework worker whose brief is `threads-only` (read threads, fix or dismiss with evidence, commit locally and report; Elon pushes, no merge).
- **Test only the change:** run the ticket's listed cases and the touched unit tests; the ticket is done when they pass. Full regression runs only in release-manager's development pass before staging, or for a very large update with the owner's approval through Elon recorded on the issue. Shared code is no exception. A diagnosis rerun is a targeted rerun of the named failing spec files.
- **PASS checks:** Elon runs no tests and no tsc before a Verdict. `head-checks.sh` runs them once per head: scoped tests plus the guards `web/src/__tests__/` and `web/src/utils/__tests__/`. Compare a failure with the clean-main baseline for the current `origin/main` sha only when a check is red; a failure absent from the baseline blocks the merge. A test file that fails to load (bun prints `error:` and runs 0 tests) counts as a failure. The Verdict lists the receipt's pass, fail and load-error counts, and the e2e specs matched by the changed strings.
- **Iterating:** run a test file with `ONLY=<new cases>`; run its whole case list once at the end with `JOBS=<n>`.
- **Test judge:** a new test or check must name the real failure it prevents; you approve it (Elon for gate checks). Per-PR checks stay under 60 s; cut a test before adding one over budget.
- Run `~/dotfiles/script/head-checks.sh` once per head. Its checklist runs `python3 bin/check-intent-roots.py` against `HEAD_CHECK_SHA` (default `HEAD`): every tracked `docs/intent/<dir>/spec.md` or `tickets.md` needs a tracked regular sibling `intent.md`, including after removal or rename. An untracked file does not count.
- Claude Bash PreToolUse configures the guard and advisory scripts. The guard blocks explicit `.env.local` copy or link operands into Orca worktrees. The advisory warns on `fullstack-dev` starts identified by the native `--task-title`: `agent_type=elon` gets an Elon warning, missing caller identity a neutral reminder, other callers nothing. It never denies a start. Run the hook regressions with `python3 -m unittest discover -s .claude/hooks/tests` and the intent-tree fixtures with `python3 bin/check-intent-roots.test.py`. This proves configured-command contracts only; starts without a role title are outside advisory coverage. Before merge the owner reads the complete hook and settings diff and Elon countersigns the exact final head.
- **Exemption evidence:** verify a bypass, exemption or allowlist only with a receipt showing the exempt path ran (a log line with the exempt value), or a run from the client that fails without it.
- **PR body:** `## Verification` with 1 to 3 real runs and outcomes. No Test plan section (it lives in the spec and ticket), no tool credit.

## Verifier brief

- Name the exact test command (`lead-merge.sh --verify-command`). Before merge confirm the Verdict's verifier and author dispatch IDs with `orca orchestration worker-show`. A merge worker Elon dispatches runs `lead-merge.sh` from `lead-elon` on the Orca runtime that holds those dispatches (another runtime is refused as unknown). Delete, never edit, your own malformed Verdict that a fresh one supersedes, and note it in the PR body.
- Briefs use literal placeholders such as `<issue>`, never global replacement of one letter. Verify the scope names its own issue and dependency PRs are MERGED before dispatch (a queued dependency uses no lane). Browser briefs include a unique session on every call.

## Merge rules

Read before every merge.

- **Review tier (ADR 0088):** apply the Review judge above; the QA Verdict is the ordinary review. No tsc or tests of your own before a Verdict. No checks rerun after a clean merge of main.
- Screenshots: only when the brief says the owner must approve the screen; Elon shows them.
- Merge main in; never rebase, force push or `--admin`. `origin/main` failures get a follow-up issue, not a block. Release-manager may rerun named failing specs only, even a new spec no worker could run.
- **One writer per branch:** findings go back to its author; you and the verifier never push to it.
- **Review notes:** on PASS+NOTES, write one line per note in the merge comment, `verified safe: <evidence>` or the fix issue number, before you merge.
- **Spec-linked PR (#5834):** phone, email and amount entry must use the shared pasted-text normalizer (send a new raw input back), and the spec's `## Test plan` needs one case per state (signed out, signed in not bound, bound, failure) or a one line reason for a missing state.
