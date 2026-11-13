# Fleet watch design

Status: Proposed (2026-11-13). Source: the grill and the owner decisions on [#986](https://github.com/mingster/dotfiles/issues/986). [PR #989](https://github.com/mingster/dotfiles/pull/989) is merged as the stopgap. Fleet watch is in a feature freeze until the tickets below land. A change to `script/fleet-watch.py` outside those tickets needs the coordinator's go.

[Fleet watch](fleet-watch.md) describes today's single pass. This document is the target. Read it before changing `script/fleet-watch.py`, its tests, or its automation. The decision that is hard to reverse is recorded in [ADR 0002](../adr/0002-fleet-watch-monitor-and-dispatcher.md).

## Why

The owner's complaint is "each review and check take too long". GitHub Actions checks run in 0 to 2 minutes. The wait is fleet watch itself. One 4000 line pass every 5 minutes monitors, dispatches, opens issues and mails. A slow dispatcher delays or kills the whole pass, failed starts retry forever, and no notice reached the coordinator from 10 Nov until #989 merged on 13 Nov (677 failed sends, all `no_active_sender_terminal`). Nobody noticed, because silence looked like health.

## Target

**Green checks to a started verifier within 5 minutes, for at least 90% of green heads in a rolling 7 days.** A head that is parked, or that never gets a verifier, counts as a miss. That rule keeps the number honest. Today's failed starts never reach the "started" side and would otherwise drop out of the count.

Baseline, measured on 2026-11-13 from `~/.orca/logs/fleet-watch.log` (10 to 13 Nov) against the GitHub check runs at each head. 49 verifier starts. Median 221 s, 90th percentile 395 s, maximum 1000 s. 37 of 49 (76%) were within 300 s. This counts only heads that did get a verifier. Heads stuck in a start failure loop (for example `start_fail=7806` on 49 passes) are missing from it, so the true share is lower.

**How it is measured.** The dispatcher writes one line per green head when it settles that head:

```
verifier_started repo=<owner/name> pr=<n> head=<sha> green_at=<iso> started_at=<iso> lag_s=<n>
verifier_parked  repo=<owner/name> pr=<n> head=<sha> green_at=<iso> parked_at=<iso> reason=<text>
```

`green_at` is when the head checks became green. It is the `createdAt` of the Checks PASS receipt or the latest `completedAt` of the head check runs, whichever came first. The dispatcher already reads both from `gh pr list`. The metric is `lag_s <= 300` over all `verifier_started` and `verifier_parked` lines of the last 7 days, with every parked line a miss. `script/team-audit-metrics.ts` reports it weekly. Anyone can recompute it from the log alone, without calling GitHub.

**Why the target is reachable.** The dispatcher runs every 2 minutes and does babysit first. Its babysit step has a 60 second budget. The worst case is 120 s of waiting plus 60 s of work, which leaves two minutes of margin under 300 s.

## Two jobs

Fleet watch becomes two Orca automations with separate state files and separate time limits. Neither calls the other. They share code in one module (`fleet_watch` helpers for Orca, `gh` and the log), not state.

| | Monitor | Dispatcher |
|---|---|---|
| Schedule | `*/5 * * * *` | `*/2 * * * *`, skipped when the previous run still holds its lock |
| Time limit | 60 s | 110 s |
| Does | Reads Orca and GitHub, decides what is wrong, sends notices | Starts verifiers (babysit), rework and scanned issues, runs `head-checks.sh`, restarts its own stalled workers |
| Never | Starts, stops or restarts a worker | Sends a notice itself. It writes notice lines to the monitor's outbox file |
| State | `monitor.state.json` | `dispatcher.state.json` |

The monitor keeps today's alerts (failed dispatch, host cap, lead pane gone, waiter absent, stuck PR, merged, new Verdict, red main), plus backup, heavy gate and wrap up staleness. These are all reads.

The dispatcher keeps babysit, issue scan, rework and the head checks runs. Its order inside one run is babysit, then rework, then new issues, so the target path runs first and is never starved by slower steps.

**The outbox.** The dispatcher appends one JSON line per notice to `dispatcher.outbox.jsonl`. The monitor claims the file at the start of its pass (rename, then read), merges the lines into its queue, and deletes the claimed file once sent. Nothing else writes it. A crashed monitor leaves the claimed file, and the next pass reads it again. Duplicate text is merged, as today.

**Why split.** A third of today's passes run past a minute. Six were killed at 280 s, and a killed pass sends nothing, because notices go out last. With the split, a broken dispatcher cannot silence the monitor, and a slow monitor cannot delay a verifier.

## Sending notices

**Identity.** Fleet watch sends as itself, never as the receiver. PR #989 passes the receiving terminal as `--from`. Orca accepted it on the first pass after the merge (state `notice_sent_at` set at 21:46 on 2026-11-13, the first successful send this state file has recorded). It still hides who sent the mail and makes a Verdict routed to a lead look like it came from that lead, and it works only while Orca lets any process speak for any live terminal. The Orca CLI (1.4.258) says a sender in no Run must address `run:<id>` or `dispatch:<id>`.

#990 recorded the replies from a shell with no terminal, Orca 1.4.258. A send with no `--from`, including a send to `run:<id>`, returns exit 1 and `no_active_sender_terminal`. A send whose `--from` is a live terminal titled `fleet-watch` and whose `--to` is `run:<id>` returns exit 0 and `{"ok": true, "result": {"messageId": "<id>"}}`. That owned terminal is the sender identity. The #989 `--from` of the coordinator terminal also returns exit 0, and it speaks as the receiver, so it stays the stopgap. Recordings are in `script/tests/fixtures/fleet-watch/orca-1.4.258/` (see Tests).

**Addressing.** Mail goes to the Run (`run:<id>`), not to a terminal handle. The Run id is read from Orca each pass (see Config). A Verdict for a dispatch with an owner record still goes to that lead.

**Cadence.** Unchanged. Urgent notices go at once, the rest at most every 10 minutes as one digest, duplicates merged.

**Fallback.** After 3 failed sends in a row to the same Run, the monitor opens one GitHub issue in the private `mingster/agent-state` titled `fleet-watch cannot reach the coordinator`, labelled `needs-elon`. The body holds the Orca error and the undelivered notices. It never goes to `mingster/dotfiles`, because that repo is public and notices name private projects. It is opened at most once while open. The first successful send closes it with a comment. Undelivered notices stay queued until sent or until 24 hours old. The 20 pass give up rule is removed, because it threw away 632 notices without anyone seeing them.

## One try, then park

Every start the dispatcher makes (verifier, rework, scanned issue, head checks run, stall restart) is keyed by what it acts on.

| Start | Key |
|---|---|
| Verifier | repo, PR, head sha |
| Rework | repo, PR, head sha, round |
| Scanned issue | repo, issue, `updatedAt` |
| Head checks | repo, PR, head sha |
| Stall restart | dispatch id |

A start is tried once per key. If it fails, the key is **parked**. The dispatcher sends one notice with the failure reason (the first line of Orca's `error.message`) and does not try that key again. A parked key re-arms only when the key changes (a new push, a new label or edit on the issue) or when `config.json` changes its modification time. A gate refusal (usage gate, host cap) is not a failure. It is logged with its reason and retried on the next run, because the cause outside fleet watch can change without the key changing.

Parked keys live in `dispatcher.state.json` and are pruned when the PR closes or the issue closes. The `failed`, `stall_stopped` and `babysit` maps are pruned the same way, so state stops growing.

## Who restarts which worker

The dispatcher restarts only workers it started itself. Those are verifiers, rework workers and scanned issue workers, recognised by the dispatch ids it recorded at start. A worker with no terminal output for 30 minutes gets one `worker-stop` then `worker-start --retry-of`. If that restart fails, or the retry is silent for another 30 minutes, the dispatch is parked and reported once.

Every other worker belongs to the coordinator. The monitor reports it as stalled once, and the coordinator decides with `worker-watch.sh` as `coordinator-operations.md` describes. The monitor never stops it.

## Red checks

A red head check on an open PR gets this sequence, and nothing else.

1. **Rerun once.** The dispatcher reruns the failed workflow run once per head (a flaky runner is the common cause).
2. **Rework.** If the rerun is red too, the dispatcher starts one rework worker for that head. At most two rework rounds per PR.
3. **Redesign.** After the second round fails, the dispatcher labels the PR `needs-redesign` and sends one notice. Only now does a human see an issue level signal. The coordinator closes the PR and dispatches a redesign.

The "X failed twice on <sha>" `needs-elon` issue is removed. It opened 47 issues in four days, all closed by hand, while rework was already running on the same heads. Red checks on `main` still get one notice from the monitor, because no PR owns them.

## Config

The hand kept config holds only values that are true per machine:

- repo paths per host (`repo_roots`),
- host caps (`host_caps`),
- which optional monitors are on, with their per host paths (`backup.stamp`, `heavy_gate.hosts`, `wrap_up.hosts`).

Everything else is read from the system each pass. The Run id and the coordinator terminal come from Orca (`orchestration run-list` and `run-show`). The repos (`owner/name`) come from the `origin` remote of each path in `repo_roots`. The agent and model come from `usage-gate.py pick`. Issue scan is on whenever the coordinator Run exists.

Every alert issue goes to the repo it is about. A stalled dotfiles worker labels a dotfiles PR. A fleet watch fault or a backup alert opens in the private `mingster/agent-state`, because it names private hosts and projects. There is no `label_repo` or `issue_repo` key.

A pass that finds no coordinator Run in Orca logs `no coordinator run`, keeps its notices queued, and exits 0. The silent alarm covers it if that lasts an hour. On a backup host, `coordinator_watch` stays as today.

## Knowing it works

**Per pass counts.** Each monitor and dispatcher run ends with one line in the log and the same counts as the wrapper summary, so `summary=no change` disappears.

```
monitor pass 12.3s notices_new=2 sent=1 send_failed=0 queued=1 outbox_read=3
dispatcher run 41.0s started=1 refused=2 parked=0 failed=0 refused_reasons=host_cap:1,usage_gate:1
```

A refusal always carries its reason. `started`, `refused`, `parked`, `failed`, `sent` and `send_failed` are counts, never omitted when zero.

**The silent alarm.** When the monitor has had undelivered notices for 60 minutes, it raises "fleet-watch silent" by a route that is not Orca mail. That is the GitHub fallback issue above. If `gh` fails too, it runs `coordinator_watch.alert_command` when one is set, and always writes `SILENT` as the wrapper summary so the Orca automation list shows it. A dispatcher that has not logged a run for 10 minutes is reported by the monitor the same way.

## Tests

New tests are named by behaviour, not by issue number (`test_fleet_watch_outbox.py`, not `test_fleet_watch_990.py`).

**Recorded real Orca replies.** Today every Orca reply in the tests is a fake written by hand, which is how Orca's `no_active_sender_terminal` change went unnoticed (grill problem 9). From #990 on, every Orca and `gh` call the tests stub replays a reply recorded from the real CLI.

- A recorder script runs each call fleet watch makes (send, worker-list, worker-start failure, run-list, terminal list, inbox, `gh pr list`) against live Orca and GitHub and saves stdout, stderr and the exit code under `script/tests/fixtures/fleet-watch/orca-<version>/`, with handles and hosts replaced by placeholders.
- The tests load replies from those files only. A test may not build an Orca reply inline.
- A `fleet-watch-contract` check reruns the recorder in dry mode on the coordinator during `wrap-up.sh --fleet` and fails when a reply's shape (keys, error codes, exit code) differs from the recording. A new Orca version therefore fails loudly once, instead of fleet watch failing silently for days.

## Tickets

Filed as sub issues of #986, none labelled `ready-for-agent`. The coordinator labels each one when it is ready to start.

| Issue | Ticket | Blocked by |
|---|---|---|
| #990 | Record real Orca replies and settle the sender identity | none |
| #991 | Deliver notices as fleet watch, with the GitHub fallback and the silent alarm | #990 |
| #992 | Per pass counts in the log and the wrapper summary | #990 |
| #993 | Read the Run and repos from the system; config holds only per machine values | #990 |
| #994 | Split the dispatcher into its own automation with the outbox and the verifier latency line | #991, #992, #993 |
| #995 | One try then park for every dispatcher start | #994 |
| #996 | Red checks go rerun, rework, redesign; remove "failed twice" issues | #995 |
| #997 | Restart only own workers; report the rest | #995 |

## Not changed

- Merging stays with `script/ship.sh`. Neither job merges.
- The coordinator's inbox waiter and its 60 minute timeout (#970) stay. The waiter now depends on the monitor's mail, which this design makes observable.
- `coordinator_watch` on a backup host stays as today.
