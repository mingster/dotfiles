# Team audit 2026.11.23: follow up on the 2026.11.21 speed up

Refs `mingster/dotfiles#1321`. Window: 2026.11.21 to 2026.11.23, with "today" meaning 2026.11.23 from 00:00 local time. The "before" column repeats the 2026.11.21 window (2026.11.14 to 2026.11.21), measured again with the same scripts so both columns use one method. All numbers come from logs on the coordinator host, the regression hosts and PR timestamps, not estimates. Every issue the 2026.11.21 audit filed is closed.

## Ranked issue list by time saved

| Rank | Issue | Target | Measured cost | Estimated saving | Size |
| --- | --- | --- | --- | --- | --- |
| 1 | `mingster/dotfiles#1640` | fleet-watch babysit verifier start (recurrence of `#1170`) | No automatic verifier start since 2026.11.22 01:50 UTC; the coordinator started about 259 verifiers by hand today | coordinator turns spent on hand dispatch, not PR minutes (Review PASS to Verdict is already fast) | S |
| 2 | `mingster/dotfiles#1535` | Wrap-up round, main project repo worktree step | Round median 6.7 min every 10 min (about 67% of the time), was 3.4 min | about 3 to 4 min of coordinator load per round | M |
| 3 | `mingster/dotfiles#1641` | `team-audit.sh` worker-startup durations | Report says `unknown` off the coordinator host | makes the next audit measurable | S |
| 4 | `mingster/dotfiles#1633` | `head-checks` on a second host | FAIL on `sed: illegal byte sequence` | one false FAIL per affected run | S |

No other new step over 10 minutes was found.

## Status of the 2026.11.21 findings

| Finding | Status | Before median / max | Today median / max |
| --- | --- | --- | --- |
| `#1321` Review PASS to Verdict, `<project-a>` | fixed by hand, automatic path broken (`#1640`) | 13.8 min / 668.6 min (n=468) | 9.7 min / 42.9 min (n=207) |
| `#1321` Review PASS to Verdict, `mingster/dotfiles` | worse | 8.6 min / 36.7 min (n=27) | 12.2 min / 128.3 min (n=53) |
| `#1322` DB step, `head-checks --db-only` | tail fixed, median worse | 6 s / 5499 s (n=118) | 31 s / 861 s (n=117) |
| `#1322` heavy-gate waits | fixed | 16 waits, 270 min a week | 5 waits, median 250 s, max 600 s, 21.7 min today |
| `#9050` tsc step | fixed | 29 s / 765 s | 24.5 s / 93 s (n=124) |
| `#9049` Playground regression round | fixed | 31.1 min / 93.3 min (n=35) | 8.4 min / 28.3 min (n=5, since the fix) |
| `#1325` `ship.test.sh` | fixed | 395 s, false FAIL | 295 s, 145 passed, 0 failed |
| `#1330` duration logs | fixed (logs exist), report gap (`#1641`) | not measurable | worker-startup 42 s / 122 s today (n=456); fleet-pull 58 s / 300 s (n=102) |
| `#1303`, `#1314` wrap-up round | worse | 3.4 min / 9.5 min | 6.7 min / 9.5 min (n=102) |
| `head-checks` total per run, `<project-a>` | tail fixed, median worse | 80 s / 5545 s (n=183) | 112 s / 962 s (n=124) |

The "before" Review PASS to Verdict for `<project-a>` is 13.8 min with this method; the 2026.11.21 doc reported 14.2 min (n=416), close enough to compare. The 2026.11.21 doc had no `mingster/dotfiles` baseline, so its before column is new. The regression "before" is 31.1 min here against 24.9 min in the 2026.11.21 doc; the methods differ (this one counts a round from its first job log to its last), so compare the two columns here, not across docs.

## Top three savings

1. Restore the automatic verifier start (`#1640`): it removes about 259 hand dispatches a day from the coordinator.
2. Make the wrap-up round cheap again (`#1535`): about two thirds of every 10 minutes is spent in it today.
3. Read worker-startup durations from the coordinator host (`#1641`): it closes the last measurement gap from `#1330`.

## Speed up table (steps over 10 minutes)

| Step | Median | Max | Fix | Minutes saved a day |
| --- | --- | --- | --- | --- |
| Review PASS to Verdict, `mingster/dotfiles` (n=53 today) | 12.2 min | 128.3 min | `#1640` | not estimated (masked by hand dispatch) |
| Review PASS to Verdict, `<project-a>` (n=207 today) | 9.7 min | 42.9 min | `#1640` | 99 of 207 still over 10 min |
| Playground regression round (n=5 since the fix) | 8.4 min | 28.3 min | none needed, under the 30 min ceiling | none |
| Wrap-up round, coordinator host (n=102 today) | 6.7 min | 9.5 min | `#1535` | about 4 min a round of host load |

## Performance findings

### 1. Verifier start is manual again (`mingster/dotfiles#1640`)

* **Evidence:** `fleet-watch.log` has no `verifier=` start after 2026.11.22 01:50 UTC. The last `review_to_verifier_s` values were 26 and 6. From 2026.11.22 03:40 UTC babysit fails with `consumer_fenced` (113 or more lines), and from 2026.11.23 07:20 UTC also with `need --from or ORCA_TERMINAL_HANDLE` (13 or more lines). Today 259 `qa-*` briefs in `~/agent-state/briefs` match 257 Verdict comments across repos.
* **Limiter:** the scheduled fleet-watch run has no coordinator terminal, so worker-start is fenced. This is the same class as closed `#1170` and `#1199`.
* **Cost:** Review PASS to Verdict looks fixed (`<project-a>` median 13.8 to 9.7 min) only because the coordinator starts every verifier by hand. In `mingster/dotfiles` it is worse (8.6 to 12.2 min, max 128.3 min).
* **Proposed fix:** make the scheduled babysit path start a verifier without a coordinator terminal, with a test for that path.
* **Size:** S.

### 2. DB step: tail fixed, median up (`mingster/dotfiles#1322`, closed)

* **Evidence:** today 117 DB steps, median 31 s, p90 91 s, max 861 s. Before: median 6 s, max 5499 s. Fingerprint warnings fell from 85 a week to 0. Gate waits today: 5, median 250 s, max 600 s (one run hit the 600 s cap on `load 8.91 exceeds 5`), 21.7 min in total.
* **Limiter:** the load ceiling of 5 on the DB host. The median rose because more runs reach the DB step now, not because one step got slower.
* **Cost:** about 22 min of waiting today, out of 329 min of total head-checks time.
* **Proposed fix:** none filed. Whether to raise the ceiling is an owner decision (grill item 1).
* **Size:** none.

### 3. Head-checks volume

* **Evidence:** 124 head-checks runs today on the coordinator host against about 26 a day before, so daily sums are not comparable. Per run: median 80 s to 112 s, max 5545 s to 962 s, 3 runs over 600 s today.
* **Limiter:** more PRs a day, not a slower step. tsc median 24.5 s, no-db step median 16.5 s.
* **Proposed fix:** none.

### 4. Regression rounds (`<project-a>#9049`, closed)

* **Evidence:** five rounds since the fix (2026.11.21 14:00 onward): median 8.4 min, max 28.3 min (one round with 73 jobs and 24 retries). The last three rounds had no second attempts. Rounds were already 8 to 11 min on the morning of 2026.11.21 while the `unit` job still ran, so the fix explains only part of the drop.
* **Gap:** no round ran today (last one 2026.11.22 19:45), although many commits merged. The cause was not traced.

### 5. Wrap-up round (`mingster/dotfiles#1535`)

* **Evidence:** coordinator host today: 102 rounds, median 403 s, max 571 s, every exit 0. The main project repo step alone takes 300 to 331 s per round. A second host: median 392 s. On 2026.11.21 the median was 3.4 min.
* **Limiter:** the per worktree loop in the main project repo, as described in `#1535`.
* **Proposed fix:** `#1535` (comment added with today's numbers). Cadence is grill item 2.
* **Size:** M.

### 6. Dotfiles stage times

* **Evidence:** build median 10.77 to 21.89 min (max 844.45), merge median 19.03 to 24.03 min. Open to merge for bundle PRs (three or more issues) median 33.2 min (n=11) against 29.6 min for single issue PRs (n=86), so bundling is not the cause.
* **Gap:** the top build samples were not inspected. The earliest dispatch row per issue counts, so a dispatched again issue inflates build time. Treat the rise as unconfirmed.

## Mistake classes and coordinator friction

| Class | Count | /correct fix | Proof |
| --- | --- | --- | --- |
| fleet-watch babysit fenced, verifiers started by hand | 113 or more `consumer_fenced`, 13 or more `need --from` since 2026.11.22 | `#1640` (recurrence of `#1170`) | `fleet-watch.log` runtime lines |
| Wrap-up round over half the interval | 102 rounds today | `#1535` | `wrap-up-scheduled-detail.log` |

Observation log rows in `~/agent-state/team-observations.tsv` still date from 2026.11.09 to 2026.11.15; none is new.

**Gap:** transcripts were not mined with `workflow-from-chats` in this follow up, and transcripts of hosts other than the coordinator host are not read.

## `team-audit.sh --report` results and stage metrics

Running `bash script/team-audit.sh --report` on a fresh `origin/main` worktree of `<project-a>` and on `mingster/dotfiles` produced:

* **Deterministic check findings:**
  * `receipt`: 5 commits touch role files without `Owner-approved:` (three in `mingster/dotfiles` from 2026.11.03 to 2026.11.11, two in `<project-a>` from 2026.11.05 and 2026.11.07). All predate the 2026.11.21 baseline; with `ROLE_RECEIPT_BASE` set to that baseline the check is clean, and `<project-b>` is clean too. The finding comes from running without a base, not from new commits.
  * `sync`, `budget`, `wording`, `skills`, `labels`: clean. No sync drift, so `#1329` holds.
* **Known gap:** worker-startup durations print `unknown` off the coordinator host (`#1641`).

### Stage times and delivery metrics

Last 100 merged PRs per repo, so the window is wider than today.

#### `mingster/dotfiles`

| Stage | Median (min) | p75 (min) | Max (min) |
| --- | --- | --- | --- |
| queue | 17.22 | 36.20 | 74.60 |
| build | 21.89 | 61.58 | 844.45 |
| merge | 24.03 | 49.05 | 500.75 |

Delivery: `median_ticket_start_to_merge_minutes=52.47` (was 81.05), `first_pass_checks_fail_rate=0.06` (was 0.03), `reopened_or_hotfix_rate=0.02`.

#### `<project-a>`

| Stage | Median (min) | p75 (min) | Max (min) | Samples |
| --- | --- | --- | --- | --- |
| queue | 17.84 | 30.82 | 220.15 | 92 |
| build | 16.98 | 45.12 | 137.77 | 41 |
| merge | 12.85 | 21.07 | 186.67 | 81 |

Delivery: `median_ticket_start_to_merge_minutes=42.69` (was 188.4), `first_pass_checks_fail_rate=0.05` (was 0.18), `p0_filed_this_month=13`, `p1_filed_this_month=62`.

#### `<project-b>`

Not measured in this follow up.

### Receipt baseline for the next audit

```sh
ROLE_RECEIPT_BASE="dd09bef6 dc075e8b1c 9a9e55c56"
```
