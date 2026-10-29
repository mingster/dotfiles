# qa-sdet execution reference

## Execution
- Before installs/builds run `df -h /`; stop on low disk. Never move dependencies/worktrees to temp.
- **Verifier contract:** on the exact head SHA, read the code and the `head-checks.sh` Checks receipt, which must be PASS (a red one stops the line). Do not run tests, tsc or lint (owner rule 2026-10-27). Prove the load-bearing behaviour live (browser at a phone viewport for UI, real API request, or real script or job run), and audit the full diff against the spec. Docs only PRs use `head-checks.sh`'s doc link check.
- Return `Verdict: PASS|PASS+NOTES|FAIL head=<full sha> verifier=<dispatch id> author=<dispatch id>` as the first line, then what ran and what was observed, for the tech-lead to publish as a PR comment. Verifier, author and lead use distinct dispatch IDs. Cover every Unchecked path from the Checks receipt in the live lane and mention unchecked coverage in the Verdict. Partial or blocked verification is FAIL with the blocker, never PASS; first rerun a failed environment step (install, server start) once.
- Auth, tenancy, rate limits and money paths also need an independent secops-finops lane, and both must PASS. Reviewer model and provider: `.claude/model-routing.md`. No live access blocks the lane.
- Each new head needs fresh checks, except a clean merge of main, which carries the Checks PASS and the Verdict (`lead-merge.sh`, `verdict_carry`); an authored or conflict edit needs a new verdict. Gate loosening needs Elon's current-head countersign.
- Skills: `tdd`, `code-review`. Load `diagnosing-bugs` and `agent-browser` only for bug reproduction, E2E tests or browser smoke tests.
- **Local servers:** start your own server on your own port. Never stop one by name (`pkill`, `killall`; the guard denies it). Stop it with `kill $(lsof -ti tcp:<port> -sTCP:LISTEN)`, or `kill` on a pid saved from `$!` in a pidfile.
- **Paths:** quote bracketed paths; no escaped paths, `..` or paths outside the worktree (they stall approval); scratch goes in `<worktree>/.scratch/`; temp files never loose in `/tmp`.
