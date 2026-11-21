# Team audit 2026.11.21: speed up and coordinator friction

Refs `mingster/dotfiles#1304`. Window: 2026.11.14 to 2026.11.21 (7 days). All numbers come from logs on the coordinator host and PR timestamps, not estimates. Nothing listed here was fixed since the 2026.11.19 audit (all of its issues are closed).

## Ranked issue list by time saved

| Rank | Issue | Target | Measured cost | Estimated saving | Size |
| --- | --- | --- | --- | --- | --- |
| 1 | `mingster/dotfiles#1321` | `fleet-watch.py` verifier start | Review PASS to Verdict median 14.2 min, dispatch to Verdict median 8.1 min: about 6 min per PR waiting for a verifier, about 69 Verdicts a day | about 3 min per PR, about 200 PR minutes a day | S |
| 2 | `mingster/dotfiles#1322` | `heavy-gate.py` on the DB host, `head-checks.sh` DB step | DB step 425 min a week; 16 gate waits hold 270 min; 85 of 124 runs on fallback limits | about 35 min a day | S |
| 3 | `<project-a>#9049` | Playground regression `unit` job | 4.4 rounds a day, round median 24.9 min, `unit` job median 5.2 min repeats head-checks tests | about 22 min a day | M |
| 4 | `<project-a>#9050` | `head-checks-tsc.sh` | 145 min a week, median 29 s, max 765 s | about 10 min a day | S |
| 5 | `mingster/dotfiles#1323` | Verifier start before `pr-body-gate.py` | One full verifier round spent on a PR without `## Self-check` | about 8 min a day | S |
| 6 | `mingster/dotfiles#1324` | `worker-startup.sh` refusals (Verify line, title, `grok_hosts`) | 15 refusals a week, 8 by brief-lint; every grok start refused today | about 8 min a day | M |
| 7 | `mingster/dotfiles#1325` | `ship.test.sh` and slow script tests | 395 s and a false FAIL on a host that cannot fetch | about 5 min a day | S |
| 8 | `mingster/dotfiles#1327` | `guard-bash.py` false positives | A heredoc brief and three read only commands denied | about 5 min a day | M |
| 9 | `mingster/dotfiles#1326` | `ship.sh` from a non git cwd | Misleading `cannot read head` error | about 2 min a day | S |
| 10 | `mingster/dotfiles#1328` | Builder edits to owner gated files | A passing PR held for an owner trailer | one held PR per event | S |
| 11 | `mingster/dotfiles#1329` | `agent-team.sh` sync drift | DRIFT in two project repos, same class as 2026.11.19 | removes a repeat finding | S |
| 12 | `mingster/dotfiles#1330` | Duration logs for `worker-startup.sh` and `fleet-pull.sh` | No median or max can be measured today | makes the next audit measurable | S |

Already open, so not filed again: `#1303` and `#1314` (wrap-up round 206 s median, 571 s max), `#1312` (grok workspace trust), `#1305` (Grok first verifier order), `<project-a>#9007` (orphan tsc after a cancelled run). `<project-a>#9035` is closed; its contract test step now runs median 20.5 s.

## Top three savings

1. Verifier start on the Review PASS event (`#1321`): about 200 PR minutes a day of waiting.
2. DB host heavy-gate cap and recalibration (`#1322`): about 35 min a day of check time.
3. Regression `unit` job (`<project-a>#9049`): about 22 min a day on the release path.

## Speed up table (steps over 10 minutes)

| Step | Median | Max | Fix | Minutes saved a day |
| --- | --- | --- | --- | --- |
| Review PASS to Verdict, `<project-a>`, Antigravity verifier (n=416) | 14.2 min | 117.9 min | `#1321` | about 200 PR minutes |
| Verifier dispatch to Verdict, `<project-a>` (n=221) | 8.1 min | 40.9 min | `#1323` stops wasted rounds | about 8 |
| `head-checks` DB step, `--db-only` (n=118) | 6 s | 91.7 min | `#1322` | about 35 |
| `head-checks` total per run, `<project-a>` (n=180) | 1.8 min | 92.5 min | `#1322`, `#9050` | included above |
| Playground regression round (n=35) | 24.9 min | 78.8 min | `<project-a>#9049` | about 22 |
| `head-checks-tsc.sh` (n=178) | 29 s | 12.8 min | `<project-a>#9050` | about 10 |
| `checks-local.sh` with `ship.test.sh` selected | 6.6 min | 6.6 min | `#1325` | about 5 |
| GitHub Actions Checks, `<project-a>` (n=300) | 4.4 min | 102 min | no new fix; the `head-checks` job is 3.3 min average | 0 |
| Coordinator heavy-gate wait (n=37) | 28 s | 27.9 min | covered by `#1322` limits work | 0 |
| `wrap-up.sh --scheduled` round (n=606) | 3.4 min | 9.5 min | open `#1303`, `#1314` | not counted |
| Verdict PASS to merge, `ship.sh` | 0.8 min | 329 min | none; the tail is owner waits | 0 |

Verifier families: 614 of 664 Verdicts came from Antigravity and 3 from Grok. Grok first ordering (`#1305`) cannot help until `grok_hosts` (`#1324`) and workspace trust (`#1312`) are fixed. In `mingster/dotfiles`, dispatch to Verdict median was 7.5 min for Antigravity (n=88), 2.7 min for Claude (n=22) and 8.5 min for Grok (n=3).

## Performance findings

### 1. Verifier waits for the next fleet-watch scan (`mingster/dotfiles#1321`)

* **Evidence:** PR comment timestamps for 416 Verdicts in `<project-a>` and 96 in `mingster/dotfiles`; `orca orchestration worker-show --full` for dispatch times.
* **Limiter:** `fleet-watch.py` starts verifiers only on its 5 min pass, plus host and usage checks.
* **Cost:** about 6 min per PR between Review PASS and the verifier start.
* **Proposed fix:** `pr-review.sh` triggers one verifier pass for that PR when it posts `Review: PASS`, with every gate kept. Log `review_to_verifier_s`.
* **Size:** S.

### 2. DB step waits on an uncalibrated heavy-gate (`mingster/dotfiles#1322`)

* **Evidence:** 180 full `head-checks` logs on the coordinator host. Gate lines such as `load 22.51 exceeds 5` and `waiting for 1 of 2 slots`; 85 runs print `hardware fingerprint changed or missing`.
* **Limiter:** the DB host runs on fallback limits and the step has no wait cap.
* **Cost:** 270 of the 425 weekly DB step minutes are 16 waits; 7 runs took over 10 min.
* **Proposed fix:** recalibrate the DB host, cap the wait at about 10 min then post `Checks: INFRA`, and log wait seconds in the receipt.
* **Size:** S.

### 3. Regression rounds rerun unit tests (`<project-a>#9049`)

* **Evidence:** regression job logs on both job hosts, 35 rounds in 8 days; one round hit the 2700 s gate timeout.
* **Limiter:** the `unit` job (median 5.2 min, max 9.8 min) repeats tests `head-checks` passed at the same sha, and only two hosts run jobs.
* **Proposed fix:** skip `unit` when the sha has `Checks: PASS`, or run it on a third host in parallel. Needs a decision, so labeled `needs-triage`.
* **Size:** M.

### 4. Full tsc on every check (`<project-a>#9050`)

* **Evidence:** `head-checks-tsc.sh` ran in 176 of 178 runs; p90 69 s.
* **Proposed fix:** incremental tsc with a per host `.tsbuildinfo` cache keyed by lockfile and tsconfig hash.
* **Size:** S.

### 5. `checks-local.sh` in `mingster/dotfiles` (`mingster/dotfiles#1325`)

* **Evidence:** an empty diff takes 9 s. Over 120 merged PRs the selector picks a median of 2 tests; `no-project-names.test.sh` (7.6 s) is always picked, so a typical PR takes about 17 s. That is fast and needs no change.
* **Limiter:** the rare heavy picks: `ship.test.sh` 395 s, `agent-team.test.sh` 257 s, hook unittests 167 s, `wrap-up-guards.test.sh` 135 s, `wrap-up.test.sh` 132 s.
* **Bug:** `ship.test.sh` failed 4 cases on a builder host because `session-sync: dotfiles fetch failed, skipped` joins the expected output. The test is not hermetic.
* **Proposed fix:** stub the session sync fetch in the test; split `agent-team.test.sh` so the selector can run its parts in parallel.
* **Size:** S.

### 6. Steps with no duration log (`mingster/dotfiles#1330`)

`worker-startup.sh` and `fleet-pull.sh` log outcomes only, so no median or max exists. `fleet-pull` did not finish clean 7 times this week (a dirty local checkout). Start failures: 4 `agent_not_in_foreground`, 1 readiness timeout.

## Mistake classes and coordinator friction

Each class below was counted in the coordinator `fleet-watch.log` (runtime lines, not source text) and confirmed in the coordinator transcripts. The /correct outcome for each is a script fix, not a rule: the rule table in `team.md` already says the right thing, and the gap is that a script lets the mistake through. So no `team.md` change was needed, and each class has an issue instead. Proof is the logged failure; the checks are not built yet (out of scope).

| Class | Count (7 days / today) | /correct fix | Proof |
| --- | --- | --- | --- |
| brief-lint refused dotfiles briefs whose Verify lacks `script/checks-local.sh` | 8 / 4 | `#1324` (brief template carries the line) | `fleet-watch.log` refusal lines |
| worker-startup refused a title without an issue number | 1 today | `#1324` (print the corrected title) | `--title must look like '#<issue>\|<role>'` |
| Fleet config has no `grok_hosts`, so every grok start was refused | 3 / 1 | `#1324` (seed the key, warn in startup checks) | `has no grok CLI (list it under grok_hosts ...)` |
| `ship.sh` from a non git cwd gave a misleading error | 1 today | `#1326` | `cannot read head <sha> ... for owner receipt` |
| A PR reached Verdict PASS without `## Self-check`, then ship refused | 1 today | `#1323` | `PR body needs ## Self-check with a command and its output` |
| Guard hook denied a heredoc brief that names a heavy command | 1 today, plus 3 denials in this audit session | `#1327` (recurrence of closed `#443`) | `hides the command from the guard` |
| A builder added an `AGENTS.md` line, so a passing PR needed an owner trailer | 1 today (60 `Owner-approved` lines this week include normal approvals) | `#1328` (closed `#1078` caught it only at commit time) | `touches owner-gated paths without Owner-approved trailer` |
| grok blocked by workspace trust on one host | 19 / 17 | skipped, open `#1312` | trust lines in `fleet-watch.log` |

Observation log rows in `~/agent-state/team-observations.tsv` date from 2026.11.09 to 2026.11.15. Each is fixed in a PR, covered by a closed issue, or still open under its own ticket; none is new this week.

**Gap:** the transcripts were searched with exact strings, not the full `workflow-from-chats` pass. Raw string counts across transcripts are inflated, because workers read the source files that contain the same messages, so the counts above come from `fleet-watch.log` runtime lines and the coordinator's own report. Transcripts of hosts other than the coordinator host are not read.

## `team-audit.sh --report` results and stage metrics

Running `ROLE_RECEIPT_BASE="fbfd874e ad4b1d1124 afa4e9acd" bash script/team-audit.sh --report` across the configured project roots produced:

* **Deterministic check findings:**
  * `sync`: `<project-a>` and `<project-b>` drift in `.claude/settings.json`, `.claude/model-routing.md` and `docs/agents/team.md` (fix: `#1329`, plus a manual `agent-team.sh sync` until then).
  * `receipt`, `budget`, `wording`, `skills`, `labels`: clean.
* **Known gap:** transcripts of hosts other than the coordinator host are not read.

### Stage times and delivery metrics

#### `mingster/dotfiles`

| Stage | Median (min) | p75 (min) | Max (min) | Samples |
| --- | --- | --- | --- | --- |
| queue | 23.15 | 345.87 | 514.03 | 11 |
| build | 10.77 | 17.90 | 81.60 | 22 |
| merge | 19.03 | 41.50 | 456.75 | 92 |

Delivery: `median_ticket_start_to_merge_minutes=81.05`, `first_pass_checks_fail_rate=0.03`.

#### `<project-a>`

| Stage | Median (min) | p75 (min) | Max (min) | Samples |
| --- | --- | --- | --- | --- |
| queue | 189.72 | 191.82 | 207.07 | 8 |
| build | unknown | unknown | unknown | 0 |
| merge | 29.40 | 69.70 | 258.85 | 91 |

Delivery: `median_ticket_start_to_merge_minutes=188.4`, `first_pass_checks_fail_rate=0.18`, `p0_filed_this_month=12`, `p1_filed_this_month=20`.

#### `<project-b>`

All stages unknown (no samples).

### Receipt baseline for the next audit

```sh
ROLE_RECEIPT_BASE="8368caa1 d802d5c3aa afa4e9acd"
```
