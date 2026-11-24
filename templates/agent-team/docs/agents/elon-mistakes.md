# Coordinator mistakes and their checks

Read it before adding a coordinator check or after the coordinator repeats a mistake.

Each row is a mistake the coordinator made in a real Run, and the check in `~/dotfiles/script/elon-tick.sh` that now catches it. `elon-tick.sh --run <run_id>` runs every check (read only) and prints one numbered ACTION list, or `OK nothing to do`. A check that cannot read its input prints `NOT CHECKED`, never OK.

**Rule:** every new coordinator mistake adds a row here and a check (with a fake `gh`/`orca` test in `script/tests/elon-tick.test.sh`) in the same PR. Keep this file and `docs/agents/elon-mistakes.md` in dotfiles identical.

| Check | Mistake | What the ACTION line asks |
|-------|---------|---------------------------|
| M1 | An open PR had no live worker that owned it, so nobody fixed or shipped it. | `ORPHAN PR`: dispatch a fullstack-dev PR owner whose brief names the PR. |
| M2 | A worker that owned an open PR was released after `worker_done`, leaving the PR orphaned. | Do not release that dispatch until the PR has a live owner. |
| M3 | An issue waiting on a vendor review sat for days while the reply was already in the support mailbox. | Read the new mail and update the issue. The issue body carries `Waiting on: <sender> since YYYY-MM-DD`. |
| M4 | A `ready-for-agent` issue was started while its `Blocked by #n` was open, and `blocked` issues stayed blocked after their blockers closed. | Relabel to `blocked`, or back to `ready-for-agent`. |
| M5 | A brief named a closed issue on its Refs line or a closed PR on its Role line. | Stop the worker and resend a fixed brief. |
| M6 | The inbox waiter (`orchestration check --run <run> --wait`) was not running, so worker mail went unread. | Arm the waiter. |
| M7 | A Review or Verdict FAIL on a PR went unanswered. | Send the defect to the owner dispatch, or dispatch an owner. |
| W1 | The fleet-watch loop was down. | Start it from the coordinator terminal. |
| W2 | A worker was stalled, idle or on a prompt (`worker-watch.sh`). | Act on it per pstack Orchestrate. |
| W3 | Fewer live workers than `work_order.target_workers`. | Start ready issues, or architect-pm supply when none are ready. |
| W4 | `needs-triage` and `ready-for-human` issues waited unseen. | Triage them, or batch them to the owner. |
| W5 | A worker question or escalation went unanswered for 15 minutes. | Answer it. |

GitHub budget: one `gh pr list` and one `gh issue list` per repo per run. Repos come from `pr_watch.repos` in the fleet-watch config; the mailbox from each repo's `repo_roots` checkout.
