Role: architect-pm. Supply worker for the work order. No code.

Refs #0
Setup: none

The work order has more free seats than `ready-for-agent` issues across the watched repos (listed at the end), so make ready work for the next passes.

1. Triage: for every open `needs-triage` issue, run `~/dotfiles/script/owner-decisions.sh <owner/repo> <issue>` first (exit 0 means the owner decided: apply it; exit 2 means the check failed: say so). Look up the facts in the code, the docs and the history. Close a duplicate or an issue main already fixes, naming the issue or commit. Rewrite an issue that is ready and label it `ready-for-agent`. Post an open decision as lettered questions (A, B, C) with your recommended answer first, and leave it `needs-triage`.
2. Follow ups: read the PRs merged in the last 7 days (`gh pr list --repo <repo> --state merged --limit 30`) and the Review or Verdict FAIL comments on open and recent PRs. File one issue for each follow up they name that has no open issue yet (search first with `gh issue list --search`).
3. Every issue you file or rewrite as ready has `## Acceptance` (provable `- [ ]` items), `## Out of scope`, `## Verify`, and exactly one of `P0` to `P3` (a bug is always `P0`). It must pass `bash script/brief-lint.sh --issue-body <file>`. Label it `ready-for-agent`.

Do not start builds, do not change code, and do not touch issues labeled `blocked`, `deferred`, `tracking` or `owner`. Never ask the owner directly.

## Acceptance
- [ ] Every open `needs-triage` issue in the watched repos got one outcome: closed with a reason, rewritten and labeled `ready-for-agent`, or lettered questions posted.
- [ ] Each follow up found in recent merged PRs and FAIL comments is an issue with Acceptance, Out of scope, a priority label and `ready-for-agent`, or the report says why it was not filed.
- [ ] No issue labeled `blocked`, `deferred`, `tracking` or `owner` was touched, and no file in the repo changed.

## Out of scope
- Code changes, builds, raising host caps, changing the work order target.

## Verify
`bash script/checks-local.sh` still passes (this worker changes no files).

## Finish
Run `orca worktree set --worktree active --workspace-status completed` before worker_done.
Send worker_done with one line per issue: repo and number, what you did (closed, ready, filed, questions), and its priority.

## Watched repos
