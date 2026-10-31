# Spec: cut merge train time (#398)

Status: Accepted (owner 2026-10-29). No code yet.
Source: issue #398. Measure before and after with the per check durations from #396.

## Problem

Only one merge run per repo can hold the lock, and that lock is correct: a train is checked on
the exact merged head, so a second train on a moving main would prove a stale base. The cost is
how long one train holds the lock. A red train is bisected, and every bisect group is a full
`head-checks.sh` run, one after another. One bad PR in an 11 PR train costs 8 to 10 runs. A train
on 2026-10-29 (11 PRs, one locale check failure) held the lock for more than 28 minutes, and every
other lead waited on it.

Goal: a train with one bad PR finishes in about 2 runs, a train with no bad PR in 1 run, and no
lead waits on another lead's lock.

## Current flow

`script/lead-merge.sh --batch N N ...`

| Step | What happens | Lines |
|------|--------------|-------|
| Lock | `lead-merge.lock/` in the git common dir, pid and start time. A second run waits up to `LEAD_MERGE_LOCK_WAIT_SECONDS` (1200), then refuses. A dead pid is taken over under a `.takeover` guard. Batch children inherit `LEAD_MERGE_LOCK_HELD=1`. | 76 to 124 |
| Base | Fetch main once; `batch_base` is the base for every run. | 130 to 131 |
| Preflight | Each PR runs the single path with `LEAD_MERGE_PREFLIGHT_ONLY=1`. Refused PRs are dropped with their reasons. Preflight checks open, base main, head match, `MERGEABLE`, owner paths, generated copies, Verification heading. It does **not** look at Checks. | 145 to 161, 347 to 411, 472 |
| Compose | `append_train` merges PRs onto `batch_base` in queue order with `git merge-tree`; a conflicting PR is skipped. One survivor runs the single path through `exec`. | 163 to 194 |
| Check | `check_group` runs `head-checks.sh --ref <train> --base <batch_base> --train-heads ...`. Green: the receipt is posted on every PR in the group. Red: the failing step is printed (`show_red`), the group splits in half, and both halves are checked **one after the other**, the green half too. A single red PR is a failure. Two green halves of a red group return the whole group as an interaction. | 196 to 267 |
| Survivors | After any failure, all survivors are checked once more together, because two green halves do not prove their sum. | 269 to 292 |
| Main moved | Fetch main again; if it moved, merge nothing. | 294 to 297 |
| Gates | Each passing PR runs the gate only path (`LEAD_MERGE_GATE_ONLY=1`). A drop also drops every later train mate, so main only gets a tested prefix. | 298 to 314 |
| Merge | Each PR merges with `--match-head-commit`, after proving main's tree equals the expected prefix. Cleanup runs after the last merge, after the lock is released. | 315 to 344, 833 to 853 |

The single path requires `Checks: PASS head=<head>` or the containing train line, and refuses a
`Checks: FAIL` at the head (lines 471 to 490). In a batch the train receipt is the proof.

`script/head-checks.sh`

| Step | What happens | Lines |
|------|--------------|-------|
| Budget | The whole run goes through `heavy-gate.py gate --head-checks` (one slot, short class). The gate exports `HEAD_CHECKS_SLOTS`, the configured slot count (default 2). | 4 to 12, `heavy-gate.py` 292 to 346 |
| Worktree | Tries `_checks`, `_checks-2` ... up to `HEAD_CHECKS_SLOTS`, each with a `.lock` dir and pid. Waits up to `HEAD_CHECKS_WAIT_SECONDS` (600), then refuses with no verdict. Worktrees persist so `node_modules` survives. | 113 to 154 |
| Checklist | Runs `.agents/head-checks.conf` lines in order. `{files}` expands to every changed path. The first failing command stops the rest. | 155 to 205 |
| Receipt | `Command:` line (with `{files}` expanded), `Scoped tests:` and `Selected:` lines, the last 20 output lines, `Result:`. Cut to `HEAD_CHECKS_RECEIPT_CAP` with the full log in `HEAD_CHECKS_LOG_DIR`. | 37 to 83, 186 to 203 |

So the engine already allows two head-checks runs at once on one host (two worktrees, two slots).
Only `check_group` is sequential.

Note for slice 4: the lock lives in the git common dir, so it serializes lead worktrees of one
clone on one host. It does not serialize two clones or two hosts. The main moved check (line 297)
is what catches that case today.

## Slices

Each slice is one PR. Proving tests use the existing fixture (`script/tests/lib/merge-fixture.sh`,
real git, fake gh and a fake head-checks that logs every run to `FX_HC_LOG`). A new test file must
also be added to `.agents/head-checks.conf`.

### Slice 0: extend the QA start script

The QA start script already exists: `script/on-worker-done.sh` (flags `--repo --pr --head
--author-family --worktree --run [--author-dispatch] [--dry-run]`). It starts the cross family
reviewer. The lead runs it right after the push, so no one else has to start QA. This slice
extends it; there is no new script.

Requirements

1. R0.1 `--author-family` also accepts `codex`; the reviewer is then a non Codex family (the
   usage-gate avoid flag for that family).
2. R0.2 A new `--resolution` flag, for a conflict-resolving main merge on a PR that already has a
   PASS. The brief asks for a review of the resolution only (`git show --remerge-diff`), not a full
   review. Without the flag the brief is the full review (Dual-Axis, Verdict).
3. R0.3 The host comes from the usage gate under its cap. With every host at cap the script refuses
   and prints the counts, so the coordinator sees the cap.
4. R0.4 The brief tells the reviewer to run tests through heavy-gate with
   `HEAVY_GATE_TIMEOUT_SECONDS=1500`, to wait for admission, and to read the Checks receipt last.
5. R0.5 Behaviour for `claude`, `cursor` and `antigravity` authors without `--resolution` is
   unchanged.

Acceptance criteria

- Author family `codex`: the picked reviewer family is not Codex.
- With `--resolution` the brief names `git show --remerge-diff` and no full review; without it the
  brief asks for the full review.
- Every host at cap: refusal that names the counts, no reviewer started.
- Every brief carries `HEAVY_GATE_TIMEOUT_SECONDS=1500` and the pending Checks rule.
- Existing `script/tests/on-worker-done.test.sh` cases still pass.

Proving test: new cases in `script/tests/on-worker-done.test.sh` (it already fakes the usage gate
and runs `--dry-run`).

### Slice 0b: routine relay script

Routine handoffs are automatic. The coordinator watches and steps in only when needed.

Requirements

1. R0b.1 A builder's `worker_done` goes to the owning lead by a relay script. The dispatch records
   the owning lead; the waiter forwards the message with branch, sha and payload path.
2. R0b.2 The lead pushes, starts QA (slice 0), runs head-checks and merges. After the push the lead
   releases the committer with the release script.
3. R0b.3 The coordinator receives nothing for these steps. It steps in only for a decision outside
   the lead's authority, a stalled or failed worker, a host or provider cap, an owner ask, or a
   bottleneck the counts show.
4. R0b.4 A `worker_done` with no recorded owning lead is not dropped: it goes to the coordinator.

Acceptance criteria

- A builder `worker_done` for a dispatch owned by lead L reaches L with branch, sha and payload
  path, and reaches no one else.
- After the push the committer is released once; a second release is a no-op.
- A `worker_done` with no recorded owner reaches the coordinator.

Proving test: new `script/tests/worker-done-relay.test.sh` with fake dispatch records and a fake
`orca`. Add it to `.agents/head-checks.conf`.

### Slice 1: direct drop

When a red train's failing step names files that only one PR in the train changed, drop that PR
and check the rest once, instead of bisecting.

Requirements

1. R1.1 After a red train run, lead-merge reads the failing step of the receipt (the block that
   `show_red` already finds, or the full log when the receipt was cut). It ignores the `Command:`,
   `Unchecked paths:`, `Scoped tests:` and `Selected:` lines, since those list every changed path.
2. R1.2 It matches the remaining text against each PR's changed paths (`git diff --name-only
   batch_base...head`). Let S be the matched paths. Direct drop applies only when S is not empty
   and every path in S was changed by the same single PR P, and by no other PR in the group.
3. R1.3 On a direct drop, P is returned as failing with the line `lead-merge: direct drop PR #P:
   failing step names <paths>, changed only by this PR`. The group without P is checked once.
   Green: those PRs pass. Red: bisect that remainder as today (no second direct drop in the same
   group, so the cost stays bounded).
4. R1.4 When the rule does not apply (S empty, or a path changed by two PRs), bisect exactly as
   today.
5. R1.5 The survivor run (lines 269 to 292) is skipped when the only failure was a direct drop,
   because the recheck in R1.3 already is the survivor run.
6. R1.6 The `batch complete` line also prints the number of head-checks runs, so before and after
   is visible without #396.

Acceptance criteria

- A 6 PR train where the red step's output names `locales/x.json`, changed only by PR 3: exactly 2
  head-checks runs, PRs 1, 2, 4, 5, 6 merge, PR 3 stays open with the direct drop line.
- Same train, but the named path is changed by PRs 3 and 5: the run count and outcome equal
  today's bisect.
- A red step whose only path mentions are on the `Command:` line: bisect, not a drop.
- Direct drop then a red recheck: bisect of the remainder, PR 3 still returned, no merge of an
  untested set.

Proving test: `script/tests/lead-merge-batch.test.sh`, new `fx_direct_drop` case (fake head-checks
that turns red while a named head is in `--train-heads`).

### Slice 2: parallel bisect

Check both halves of a red group at the same time on two check worktrees, inside the heavy job
budget.

Requirements

1. R2.1 `check_group` starts both halves together when a second head-checks slot is free now. It
   waits for both before deciding the interaction case.
2. R2.2 The second half never waits in the gate. It asks for a slot without blocking (a new
   no wait mode in `heavy-gate.py`, exit code distinct from a check failure). With no free slot it
   runs after the first half, as today.
3. R2.3 One train never has more than 2 head-checks runs at once, whatever the slot count.
4. R2.4 The merged, returned, conflicted and refused sets are identical to a sequential run for
   the same inputs. Shared state (`failures`, `pass_train`, `pass_heads`) is passed back through
   files, not shell variables.
5. R2.5 A busy refusal (`every check worktree is in use`) of one half is not a red result; that
   half is retried sequentially.

Acceptance criteria

- With 2 slots and a fake head-checks that sleeps 2 s and logs start and end, the two halves'
  intervals overlap, and the outcome equals the sequential run.
- With 1 slot, or with the second slot held by another job, the halves do not overlap and nothing
  waits in the gate for the second half.
- Never more than 2 concurrent runs in a 3 level bisect (counted from the fake's log).

Proving tests: `script/tests/lead-merge-batch.test.sh` (`fx_parallel_bisect`) and
`script/tests/heavy-gate.test.sh` (no wait claim: free slot admits, full slots exit at once with
the no wait code, nothing is left claimed).

### Slice 3: entry gate

A PR enters a train only with Checks PASS on its current head and a clean merge with main, so most
trains are green on the first run.

Requirements

1. R3.1 Batch preflight applies the same Checks rule as the single path (lines 471 to 490):
   `Checks: PASS head=<current head>`, or a PASS carried across a clean merge of main
   (`checks_carry`). A `Checks: FAIL` at the head, or no Checks, is a preflight refusal.
2. R3.2 The refusal reads `no Checks: PASS at the current head; run head-checks before the train`
   and is listed with the other preflight refusals.
3. R3.3 Clean merge with main means `MERGEABLE` (already checked) and a clean `git merge-tree` of
   the head onto `batch_base`. The PR does not have to be up to date with main, since that would
   force a merge of main and a new Checks run on every PR.
4. R3.4 The train run stays. The entry gate lowers the chance of a red train; it does not replace
   the proof on the merged head.

Acceptance criteria

- A batch of 3 where PR 12 has no Checks comment: PR 12 is dropped with the R3.2 reason, its head
  never appears in `FX_HC_LOG`, PRs 11 and 13 merge after one run.
- PR 12 with `Checks: FAIL head=<head>` after an older PASS: dropped.
- PR 12 with a PASS on an older head and only a clean merge of main since: enters the train.

Proving test: `script/tests/lead-merge-batch.test.sh`, new cases next to T2 in `fx_suite`. The
existing batch fixtures must add a PASS comment to every PR they expect to merge.

### Slice 4: one merge queue per repo

Leads mark PRs ready; one queue run takes every ready PR at that moment. No lead waits on another
lead's lock.

Requirements

1. R4.1 `lead-merge.sh --repo R --enqueue N --head SHA` records the PR and head in a queue in the
   git common dir (next to `lead-merge.lock/`), prints its position and returns at once.
2. R4.2 If no queue run holds the lock, enqueue starts one in the background, detached from the
   caller. A queue run takes the lock, snapshots the queue, runs the snapshot as one `--batch` in
   enqueue order, removes those entries, and repeats until the queue is empty. Then it releases
   the lock.
3. R4.3 An entry whose PR head no longer equals the enqueued head is dropped with `head moved since
   enqueue` and is not merged.
4. R4.4 Each entry gets a result (merged, returned with the reason, conflicted, refused) in a result
   file that `lead-merge.sh --status N` prints. The lead reads its result; it does not wait for it.
5. R4.5 Enqueueing the same PR twice keeps one entry with the newest head.
6. R4.6 A PR enqueued while a round runs is in the next round, never skipped.
7. R4.7 Direct `--pr` and `--batch` runs still work and take the same lock.

Acceptance criteria

- Two leads each enqueue 2 PRs while a round is running: both return in under a second, and the
  next round checks all 4 in one train.
- An entry whose head moved after enqueue is reported and stays open.
- A killed queue run leaves a stale lock that the next enqueue takes over, and the queue still holds
  the unprocessed entries.

Proving test: new `script/tests/lead-merge-queue.test.sh` on the shared merge fixture.

When slice 4 lands, the split of PRs between two leads for merging is deleted from the role files
and team docs.

## QA in parallel (owner 2026-10-29)
- The lead starts the QA reviewer itself right after the push, with the QA start script, `script/on-worker-done.sh` (it picks a model family other than the author's, a host under its cap, and the brief template: full review for a new PR, resolution only for a main merge). The coordinator is not in the loop and does not forward or start QA; it only watches counts and caps. The lead runs head-checks in parallel; neither waits for the other.
- The QA Verdict is the review Verdict. On a builder PR that gets a QA Verdict, the lead posts no second Verdict; the lead pushes, runs head-checks and merges. Opus cross review stays only for payments, wallet and ledger, auth, schema, tenant isolation, gate scripts and large diffs.
- QA runs tests through heavy-gate with HEAVY_GATE_TIMEOUT_SECONDS=1500 and waits for admission. A FAIL only because tests never ran is not a Verdict: keep waiting, or cite a Checks PASS receipt at the exact head that ran those files.
- QA reads the Checks receipt at the end and says pending when none is posted. Merge needs both a QA PASS and a Checks PASS at the same head.
- A conflict-resolving main merge on a PR that already has a PASS gets QA on the resolution only (git show --remerge-diff), not a full re-review.

## Risks

| Risk | Where | Mitigation |
|------|-------|------------|
| A dropped PR was innocent. A path names the PR whose test caught the bug, while another PR caused it (PR A adds a test, PR B changes the code it tests). | Slice 1 | The recheck without the dropped PR proves main stays green. The drop line says "named by the failing step", not "proven alone". The PR is only returned, never closed, and the lead reruns its own head-checks. Optional: confirm the dropped PR alone on base in parallel (open question 2). |
| A path in the output is incidental (a stack trace through a shared helper one PR touched). | Slice 1 | R1.2 needs every matched path to belong to one PR; the recheck catches a wrong guess at the cost of one run, then bisect runs as today. |
| Two check worktrees overload a host. Two full checklists run tests, builds and type checks at once, and on a 2 slot host they take every slot, so workers' heavy jobs wait for the train. | Slice 2 | R2.2 no wait claim, R2.3 cap of 2, the gate's load and memory sensors still apply. A cold `_checks-2` worktree installs packages on first use, which can make the first parallel run slower than sequential; warm it once on each host. |
| Parallel results race (receipts posted twice, wrong failure count). | Slice 2 | R2.4: results through files, outcome compared with the sequential run in the test. |
| The entry gate adds a head-checks run for PRs that skipped it, and drops PRs that would have passed in a train. | Slice 3 | The rule already applies to single merges; the team docs already say run head-checks once per head. Measure how many train PRs lacked a PASS before turning it on. |
| Queue fairness. One lead's large batch fills every round; a PR that keeps conflicting is retried forever; a PR enqueued during a long round waits a whole round. | Slice 4 | FIFO by enqueue time across leads, R4.6 next round guarantee, conflicted or red PRs leave the queue and need a new enqueue. A per round cap is open question 4. |
| Queue state is per clone and per host, like the lock. Two hosts can each run a queue. | Slice 4 | Unchanged from today; the main moved check (line 297) still refuses the stale run. |
| A detached queue run fails with nobody watching. | Slice 4 | Results go to files that `--status` reads; a run that dies leaves the queue intact for the next enqueue. |

## Order

Do slices 0 and 0b first, since the QA rule depends on them. Then slice 3. It is the smallest change: the Checks rule and `checks_carry` already exist for
the single path, preflight only has to call them. It is the lowest risk: it only refuses, it never
merges anything more. And it attacks the cause, not the cost: a train whose PRs each passed on
their own head is usually green on the first run, so it needs no bisect at all. Slices 1 and 2 then
make the remaining red trains cheaper, and slice 4 removes the waiting once trains are short.

Then slice 1 (biggest saving per red train, 8 to 10 runs down to 2), slice 2 (helps only the trains
slice 1 cannot attribute), slice 4 last (depends on short trains to be fair).

The issue lists slice 1 first. That order is also defensible if most red trains turn out to be
interactions between PRs that each passed alone, which slice 3 cannot catch. #396's data can tell.

## Open questions

All resolved: A for every question (Elon decisions 2026-10-29).

1. Order. A (recommended): slice 3 first, then 1, 2, 4. B: the issue's order, 1, 2, 3, 4.
2. Confirm a direct drop. A (recommended): no confirm run; the green recheck is enough and the PR is
   only returned. B: run the dropped PR alone on base in parallel with the recheck, and label it an
   interaction when that is green.
3. Second slot for parallel bisect. A (recommended): take it only when free now (no wait claim),
   otherwise sequential. B: always wait for it under the gate.
4. Round size in the queue. A (recommended): no cap; take every ready PR, since direct drop keeps a
   red round cheap. B: cap each round at 12 PRs, the rest go to the next round in order.
5. Queue state. A (recommended): files in the git common dir next to the lock, same scope as today.
   B: a GitHub label as the ready mark, visible across hosts, with the lock still local.
6. Entry gate on a stale base. A (recommended): PASS on the current head plus a clean merge onto
   main is enough. B: also require the PR to be up to date with main.
