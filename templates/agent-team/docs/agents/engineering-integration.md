# Engineering integration

Read before judging engineering reviews or tests. Docs-only PRs follow Elon's mechanical lane in `docs/agents/team.md`, Orchestration.

## Review and tests

- **Review judge:** every PR body says `Review: required (<reason>)` or `Review: skipped (<reason>)`. Tiers (owner rule 2026-10-27). **Lead review only** (the Verdict's verifier is the lead's own dispatch id) for copy, i18n, test-only, docs, display-only admin changes, and small changes (under about 150 changed lines, no new data flow). **Claude Opus cross review only** for payments, wallet or ledger, auth or sessions, schema or migrations, tenant isolation, gate or check scripts, and large cross-area changes. When unsure, require cross review.
- A cross reviewer reads the code and the Checks receipt (never reruns tests, tsc or lint) and posts the Verdict `lead-merge.sh` checks. A small lead fix after a review PASS (under about 30 lines, same files, no new behaviour beyond the review finding) needs no re-review; the lead notes it in the Verdict. A larger or production-behaviour change still gets a re-review.
- **Test only the change** (owner rule 2026-10-21): run the ticket's listed test cases and the touched unit tests; the ticket is done when they pass. Regression (the full suite) runs only in release-manager's development pass before staging, or for a very large update with the owner's approval through Elon recorded on the issue. Shared code is no exception, and a diagnosis rerun is a targeted rerun of the named failing spec files.
- **Test judge:** a new test or check must name the real failure it prevents; you approve it (Elon for gate checks). Per-PR checks stay under 60 s; cut a test before adding one over budget.
- **Lead PASS checks:** before merge the tech-lead runs the whole test directories of every touched area plus the repo-wide guard test directories, and compares failures with the clean-main baseline recorded for the current `origin/main` sha; a failure absent from that baseline blocks the merge. When an exported type, a schema or a shared module changes, also run the full type check on the head sha. The Verdict lists the dirs run and the e2e specs matched by the changed strings. tsc runs once, in `head-checks.sh`; the lead runs no typecheck of its own before a Verdict (owner rule 2026-10-27). A test file that fails to load counts as a failure, and the Verdict lists the pass, fail and load-error counts.
- **Iterating:** while working on a test file run it with `ONLY=<new cases>`; run that file's whole case list once at the end with `JOBS=<n>`.
- You run `~/dotfiles/script/head-checks.sh` once per head.
- **Exemption evidence:** verify a bypass, exemption or allowlist only with a receipt showing the exempt path ran (a log line with the exempt value), or a run from the client that fails without it. A pass on a path that never took the exemption proves nothing (2026-10-24: #4480).
- **PR body:** `## Verification` with 1 to 3 real runs and outcomes. No Test plan section in the PR body (the test plan lives in the spec and the ticket), no tool credit.

## Verifier brief (tech-lead)

- **Verifier brief:** name the exact test command (`lead-merge.sh --verify-command`). Before merge confirm the Verdict's verifier and author dispatch IDs with `orca orchestration worker-show`. Delete, never edit, a malformed Verdict of your own account that a fresh one supersedes, and note it in the PR body.

Briefs use literal placeholder tokens such as `<issue>`, never global replacement of a single letter. Verify the scope names its own issue and dependency PRs are MERGED before dispatch; a queued dependency consumes no lane. Browser briefs include a unique session on every call.

## Merge rules (tech-lead)

Moved from the tech-lead role file on 2026-10-28 to keep it within the word budget; the tech-lead reads this before every merge.

- **Review tier and carry (owner rule 2026-10-27):** choose lead review or Opus cross review by Review judge above. Run no tsc or tests of your own before a Verdict. A small fix after a PASS needs no re-review (same doc). No checks rerun after a clean merge of main (`docs/agents/team.md`, Verdict carry).
- **Screenshots gate:** no PASS verdict on a PR that changes a UI path (`ui_path_patterns` in `lead-merge.local.json` beside `lead-merge.sh`; not tests, `*.test.*` or translation files alone) unless its body has a `## Screenshots` section, separate from `## Verification`, with a 390px phone image, plus an 820px tablet image for admin pages. `lead-merge.sh` refuses the merge without it.
- **One writer per branch:** findings go back to its author; you and the verifier never push fixes to it.
- **Review notes:** on PASS+NOTES, write one line per note in the merge comment, `verified safe: <evidence>` or the fix issue number, before you merge.
- **Spec rules on a spec-linked PR:** check that phone, email and amount entry uses the shared pasted-text normalizer (a new raw input is sent back), and that the spec's `## Test plan` has one case per state (for example signed out, signed in, linked, failure) or a one line reason for a missing state.
