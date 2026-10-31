# Engineering integration

Read before judging engineering reviews or tests. Docs-only PRs follow Elon's mechanical lane in `docs/agents/team.md`, Orchestration.

## Review and tests

- **Review judge:** Owner rule 2026-10-31: extra Strong / Claude Opus cross review is required only for issues involving money transactions (including payments, wallet movements and ledger postings), or when Elon or the human owner explicitly requests it for that issue. Record an explicit request and its reason on the issue or PR. Auth, schema, tenant isolation, gate scripts, diff size, uncertainty and a model fallback do not automatically require this extra review. Ordinary independent QA and exact-head Checks remain required; when both pass, the lead proceeds without waiting for an extra Strong review outside those two cases. PR bodies identify the ordinary QA Verdict and say `Extra Strong review: required (<money transaction or explicit request>)` or `Extra Strong review: skipped (outside owner rule)`.
- A cross reviewer reads the code and the Checks receipt (never reruns tests, tsc or lint) and posts the Verdict `lead-merge.sh` checks. A small lead fix after a review PASS (under about 30 lines, same files, no new behaviour beyond the review finding) needs no re-review; the lead notes it in the Verdict. A larger or production-behaviour change still gets a re-review.
- **Test only the change** (owner rule 2026-10-21): run the ticket's listed test cases and the touched unit tests; the ticket is done when they pass. Regression (the full suite) runs only in release-manager's development pass before staging, or for a very large update with the owner's approval through Elon recorded on the issue. Shared code is no exception, and a diagnosis rerun is a targeted rerun of the named failing spec files.
- **Test judge:** a new test or check must name the real failure it prevents; you approve it (Elon for gate checks). Per-PR checks stay under 60 s; cut a test before adding one over budget.
- **Lead PASS checks:** before merge the tech-lead runs the whole test directories of every touched area plus the repo-wide guard test directories, and compares failures with the clean-main baseline recorded for the current `origin/main` sha; a failure absent from that baseline blocks the merge. When an exported type, a schema or a shared module changes, also run the full type check on the head sha. The Verdict lists the dirs run and the e2e specs matched by the changed strings. tsc runs once, in `head-checks.sh`; the lead runs no typecheck of its own before a Verdict (owner rule 2026-10-27). A test file that fails to load counts as a failure, and the Verdict lists the pass, fail and load-error counts.
- **Iterating:** while working on a test file run it with `ONLY=<new cases>`; run that file's whole case list once at the end with `JOBS=<n>`.
- You run `~/dotfiles/script/head-checks.sh` once per head.
- **Exemption evidence:** verify a bypass, exemption or allowlist only with a receipt showing the exempt path ran (a log line with the exempt value), or a run from the client that fails without it. A pass on a path that never took the exemption proves nothing (2026-10-24: #4480).
- **PR body:** `## Verification` with 1 to 3 real runs and outcomes. No Test plan section in the PR body (the test plan lives in the spec and the ticket), no tool credit.

## Verifier brief (tech-lead)

- **Verifier brief:** name the exact test command (`lead-merge.sh --verify-command`). Before merge confirm the Verdict's verifier and author dispatch IDs with `orca orchestration worker-show`. Never delete or edit a prior Verdict. Post a linked correction using `script/post-verdict.sh` with original comment identity when replacing a prior comment, and note it in the PR body.

Briefs use literal placeholder tokens such as `<issue>`, never global replacement of a single letter. Verify the scope names its own issue and dependency PRs are MERGED before dispatch; a queued dependency consumes no lane. Browser briefs include a unique session on every call.

## Merge rules (tech-lead)

Moved from the tech-lead role file on 2026-10-28 to keep it within the word budget; the tech-lead reads this before every merge.

- **Protected hand merges:** run `~/dotfiles/script/protected-merge-check.sh <owner/repo> <pr>` before any hand merge of a protected path; refuse unless it passes with a PR comment whose first line starts `Owner go ` posted after the head commit's committer date.
- **Review tier and carry (owner rule 2026-10-27):** apply the extra Strong review scope in Review judge above; the QA Verdict is the ordinary review Verdict. Run no tsc or tests of your own before a Verdict. A small fix after a PASS needs no re-review (same doc). No checks rerun after a clean merge of main (`docs/agents/team.md`, Verdict carry).
- Screenshots: only when the brief says the owner must approve the screen; Elon shows them to the owner.
- **One writer per branch:** findings go back to its author; you and the verifier never push fixes to it.
- **Review notes:** on PASS+NOTES, write one line per note in the merge comment, `verified safe: <evidence>` or the fix issue number, before you merge.
- **Spec rules on a spec-linked PR:** check that phone, email and amount entry uses the shared pasted-text normalizer (a new raw input is sent back), and that the spec's `## Test plan` has one case per state (for example signed out, signed in, linked, failure) or a one line reason for a missing state.
