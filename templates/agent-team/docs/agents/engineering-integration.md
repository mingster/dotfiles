# Engineering integration

Read before judging engineering reviews or tests. Docs-only PRs follow Elon's mechanical lane in `docs/agents/team.md`, Orchestration.

## Review and tests

- **Review judge:** every PR body says `Review: required (<reason>)` or `Review: skipped (<reason>)`. Required for money or identity (payments, wallet, ledger, auth, permissions, secrets), gates (lead-merge, hooks, deploy, usage gate), schema or data changes, protected paths, logic over about 50 lines, a new feature slice, a shared-code fix, or an author with low confidence. Else skip. When unsure, require.
- Required means one cross-family reviewer, covering security, who reads the Checks receipt (never reruns it) and posts the Verdict `lead-merge.sh` checks.
- **Test only the change:** run the touched tests. Full regression for shared code needs a reason; release-manager owns the development pass before a deploy batch.
- **Test judge:** a new test or check must name the real failure it prevents; you approve it (Elon for gate checks). Per-PR checks stay under 60 s; cut a test before adding one over budget.
- **Iterating:** while working on a test file run it with `ONLY=<new cases>`; run the full suite once at the end with `JOBS=<n>`.
- You run `~/dotfiles/script/head-checks.sh` once per head.
- **PR body:** `## Verification` with 1 to 3 real runs and outcomes. No Test plan, no tool credit.
