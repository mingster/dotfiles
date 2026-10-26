# Engineering integration

Read before judging engineering reviews or tests. Docs-only PRs follow Elon's mechanical lane in `docs/agents/team.md`, Orchestration.

## Review and tests

- **Review judge:** every PR body says `Review: required (<reason>)` or `Review: skipped (<reason>)`. Required for money or identity (payments, wallet, ledger, auth, permissions, secrets), gates (lead-merge, hooks, deploy, usage gate), schema or data changes, protected paths, logic over about 50 lines, a new feature slice, a shared-code fix, or an author with low confidence. Else skip. When unsure, require.
- Required means one cross-family reviewer, covering security, who reads the Checks receipt (never reruns it) and posts the Verdict `lead-merge.sh` checks.
- **Test only the change** (owner rule 2026-10-21): run the ticket's listed test cases and the touched unit tests; the ticket is done when they pass. Regression (the full suite) runs only in release-manager's development pass before staging, or for a very large update with the owner's approval through Elon recorded on the issue. Shared code is no exception, and a diagnosis rerun is a targeted rerun of the named failing spec files.
- **Test judge:** a new test or check must name the real failure it prevents; you approve it (Elon for gate checks). Per-PR checks stay under 60 s; cut a test before adding one over budget.
- **Lead PASS checks:** before merge the tech-lead runs the whole test directories of every touched area plus the repo-wide guard test directories, and compares failures with the clean-main baseline recorded for the current `origin/main` sha; a failure absent from that baseline blocks the merge. When an exported type, a schema or a shared module changes, also run the full type check on the head sha. The Verdict lists the dirs run and the e2e specs matched by the changed strings. Before every PASS run the full typecheck on the merged head and read its exit code. A test file that fails to load counts as a failure, and the Verdict lists the pass, fail and load-error counts.
- **Iterating:** while working on a test file run it with `ONLY=<new cases>`; run that file's whole case list once at the end with `JOBS=<n>`.
- You run `~/dotfiles/script/head-checks.sh` once per head.
- **Exemption evidence:** verify a bypass, exemption or allowlist only with a receipt showing the exempt path ran (a log line with the exempt value), or a run from the client that fails without it. A pass on a path that never took the exemption proves nothing (2026-10-24: #4480).
- **PR body:** `## Verification` with 1 to 3 real runs and outcomes. No Test plan section in the PR body (the test plan lives in the spec and the ticket), no tool credit.

## Verifier brief (tech-lead)

- **Verifier brief:** name the exact test command (`lead-merge.sh --verify-command`). Before merge confirm the Verdict's verifier and author dispatch IDs with `orca orchestration worker-show`. Delete, never edit, a malformed Verdict of your own account that a fresh one supersedes, and note it in the PR body.
