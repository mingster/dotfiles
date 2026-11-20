Role: architect-pm. Triage worker for idle seats. No code.

Refs #0
Setup: none
Grill approved: owner 2026-11-20 (owner rule: grill the backlog when seats are idle)

Open seats had no ready-for-agent issue to take, so work the backlog: every open issue labeled `needs-triage` or `ready-for-human` in this repo.

For each issue:
1. Look up the facts in the code, the docs and the history. Do not ask for what you can find.
2. Close an issue that duplicates another or that main already fixes. Say which issue or commit in the closing comment.
3. Rewrite an issue that is ready: a `## Acceptance` list of provable `- [ ]` items, `## Out of scope`, and a `## Verify` command. It must pass `script/brief-lint.sh`. Leave the label change to the coordinator.
4. For an issue with an open decision, post the decision as lettered questions (A, B, C), each with your recommended answer first. Do not guess.

Do not change labels to `ready-for-agent`, do not start builds, and do not touch issues that carry `blocked`, `deferred` or `tracking`.

## Acceptance
- [ ] Every open `needs-triage` and `ready-for-human` issue in this repo got one outcome: closed with a reason, rewritten ready, or lettered questions posted.
- [ ] No label was changed to `ready-for-agent`, and no issue labeled `blocked`, `deferred` or `tracking` was touched.

## Out of scope
- Code changes, builds, label changes, and issues labeled `blocked`, `deferred` or `tracking`.

## Verify
`bash script/checks-local.sh` still passes (this worker changes no files).

## Finish
Run `orca worktree set --worktree active --workspace-status completed` before worker_done.
Send worker_done with one line per issue: number, what you did, and the lettered questions still open. The coordinator decides, or asks the owner when the Owner pauses row in `team.md` applies, and then relabels `ready-for-agent`.
