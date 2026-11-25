Role: architect-pm. Supply worker for the work order. No code.

Refs #0
Setup: none

The work order has more free seats than `ready-for-agent` issues across the watched repos (listed at the end), so make ready work for the next passes. Aim for one `ready-for-agent` issue per free seat (the count is under Free seats at the end).

1. Grill the coordinator, never the owner: for every open `needs-triage` or `ready-for-human` issue, run `~/dotfiles/script/owner-decisions.sh <owner/repo> <issue>` first (exit 0 means the owner decided: apply it; exit 2 means the check failed: say so and skip the issue). Look up the facts in the code, the docs and the history. Close a duplicate or an issue main already fixes, naming the issue or commit. For each decision still open, ask the coordinator (Elon) one lettered question at a time with `orca orchestration ask` (A is your recommendation, with one line of why and the cost of B), then apply the answer, rewrite the issue and label it `ready-for-agent`. When the coordinator answers that the decision is the owner's, post the lettered question on the issue and leave its label as it is.
2. Claimed with no live worker: for each issue in that section at the end, close it with the PR named when a merged PR delivered its Acceptance, else take `status:進行中` off and label it `ready-for-agent`.
3. Follow ups: read the PRs merged in the last 7 days (`gh pr list --repo <repo> --state merged --limit 30`) and the Review or Verdict FAIL comments on open and recent PRs. File one issue for each follow up they name that has no open issue yet (search first with `gh issue list --search`).
4. Every issue you file or rewrite as ready has `## Acceptance` (provable `- [ ]` items), `## Out of scope`, `## Verify`, and exactly one of `P0` to `P3` (a bug is always `P0`). It must pass `bash script/brief-lint.sh --issue-body <file>`. Label it `ready-for-agent`.

Do not start builds, do not change code, and do not touch issues labeled `blocked`, `deferred`, `tracking` or `owner`. Never ask the owner directly.

## Acceptance
- [ ] Every open `needs-triage` and `ready-for-human` issue in the watched repos got one outcome: closed with a reason, decided with the coordinator and labeled `ready-for-agent`, or left for the owner with the lettered question posted because the coordinator said so.
- [ ] Every issue under Claimed with no live worker is closed with the delivering PR named or labeled `ready-for-agent`.
- [ ] Each follow up found in recent merged PRs and FAIL comments is an issue with Acceptance, Out of scope, a priority label and `ready-for-agent`, or the report says why it was not filed.
- [ ] At least one issue is `ready-for-agent`, or the report gives one reason per free seat left empty (for example: no open issue, every issue waits on the owner, every issue is blocked).
- [ ] No issue labeled `blocked`, `deferred`, `tracking` or `owner` was touched, and no file in the repo changed.

## Out of scope
- Code changes, builds, raising host caps, changing the work order target.

## Verify
`bash script/checks-local.sh` still passes (this worker changes no files).

## Finish
Run `orca worktree set --worktree active --workspace-status completed` before worker_done.
Send worker_done with the subject `supply ready=<n> cleared=<m> reasons=<k>`: n issues you made `ready-for-agent`, m issues whose stale `blocked` label came off this pass (the sweep names them as unblock lines), and k reasons for seats left empty. The body has one line per issue: repo and number, what you did (closed, ready, filed, asked, left for owner), and its priority, then one line per reason. fleet-watch reports a run with ready=0 and reasons=0, or with no such subject, as a failed supply run.

## Watched repos
