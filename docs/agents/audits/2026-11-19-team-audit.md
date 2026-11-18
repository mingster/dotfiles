# Team audit 2026.11.19: script performance and team guide review

Refs `mingster/dotfiles#1191`. This report covers the performance review of `script/head-checks.sh`, `script/wrap-up.sh`, `script/usage-gate.py`, `script/fleet-watch.py`, `script/worker-startup.sh`, `script/ship.sh`, and `script/checks-local.sh`, together with the `team-audit` check and guide review across `templates/agent-team/docs/agents/team.md`, `.claude/model-routing.md`, `docs/agents/coordinator-operations.md`, and role definitions.

## Ranked issue list by time saved

| Rank | Issue | Target | Measured cost | Estimated saving | Size |
| --- | --- | --- | --- | --- | --- |
| 1 | `<project-a>#8613` | `head-checks` database test selection | 962 s of 1,027 s per PR check run (15,672 tests in 1,720 files) | ~15.5 min (930 s) per PR check run | S |
| 2 | `mingster/dotfiles#1190` | `head-checks` remote database checkout lock | 3 collision FAILs on 2026.11.19 (20 to 30 min and 50k to 100k tokens per false rework) | 20 to 30 min and 50k to 100k tokens per concurrent check collision | S |
| 3 | `mingster/dotfiles#1198` | `wrap-up.sh --scheduled` and `board-clean.py` | 458 s median per 10 min round (76% host duty cycle); 17 stuck `verify-*` worktrees | ~3.8 min (230 s) per 10 min round (~23 min per hour) | M |
| 4 | `mingster/dotfiles#1199` | `usage-gate.py` and `fleet-watch.py` | 54.5 s median per 5 min sweep (up to 80 s on fenced starts); 16.3 s per worker start; 288 Haiku calls per day | ~35 to 45 s per 5 min sweep (~8 min per hour), 15 s per start, 288 Haiku turns per day | M |
| 5 | `mingster/dotfiles#1192` | Coordinator dispatch traps (`--from`, `ready-for-agent`, host fault rework) | Silent start failures, duplicate builders on hand starts, false rework handoffs on host faults | 15 to 25 min and 40k to 80k tokens per duplicate or false rework | S |
| 6 | `mingster/dotfiles#1200` | `checks-local.sh`, `ship.sh`, and `team-audit.sh` | 60.8 s hook test run on every non-hook PR; 10-page remote worker scan in `ship.sh`; 20 s mergeable poll | 60.8 s per non-hook `dotfiles` check run plus 5 to 20 s per merge | S |
| 7 | `mingster/dotfiles#1201` | `worker-startup.sh`, `brief-lint.sh`, `pr-body-gate.py`, and team docs | `brief-lint: missing Refs` rejections; 30+ min verifier stalls on malformed `Builder:` lines; 5 to 8 duplicate wake tool calls | 20 to 30 s and 10k to 15k tokens per wake, 30+ min per malformed `Builder:` line | M |
| 8 | `mingster/dotfiles#1188` | `check-stale-worktrees.sh` lint rule | Lingering worktrees after merge or release inflate host occupancy | 5 to 10 min per manual cleanup sweep | S |
| 9 | `mingster/dotfiles#1195` | `brief-lint.sh` `checks-local.sh` check per target repo | False brief rejections when the target repo has no `script/checks-local.sh` | 1 to 2 min and 5k tokens per rejected brief | XS |

**Top three savings.**
1. **`<project-a>#8613` (`head-checks` database test split):** saves ~15.5 minutes (930 s) per PR check run by keeping non-database unit tests local and running only `.db.test.` files on the database host.
2. **`mingster/dotfiles#1190` (`head-checks` remote checkout lock):** saves 20 to 30 minutes and 50k to 100k tokens per concurrent check collision (~60 to 90 minutes across 3 hits on 2026.11.19) by serializing or isolating the remote database checkout.
3. **`mingster/dotfiles#1198` (`wrap-up.sh --scheduled` deduplication and `board-clean.py` fix):** saves ~3.8 minutes (230 s) every 10 minutes (~23 minutes per hour on the coordinator host) and unblocks cleanup of 17 released `verify-*` worktrees.

## Performance findings

All live measurements on the coordinator host ran at 12 cores with a 1-minute load average of 4.23 (`uptime`).

### 1. `head-checks.sh` database step runs the full test suite (`<project-a>#8613`)

* **Evidence:** On a `<project-a>` PR (#8611), one `head-checks.sh` run took 1,027 s total. The preceding local scoped-test step (`script/run-scoped-tests.py`, 1-hop reverse import lookup) ran 1,649 tests in 19 s. The remote database step (`web/bin/head-checks-scoped-tests.sh` calling `web/bin/select-head-check-tests.ts run`) ran for 962 s (93.7% of total wall time) and executed 15,672 tests across 1,720 files (1,886 files on PR #8610), even though only about 54 files in the repository are `.db.test.` files.
* **Limiter:** `select-head-check-tests.ts` (lines 149 to 245) walks an unbounded transitive BFS across all string literals in `web/`. Touching any shared module reaches almost the entire test tree, and `runTests()` (lines 353 to 365) runs all selected files (both non-database unit tests and `.db.test.` files) on the remote database host via `script/remote-heavy.sh`. Because `.agents/head-checks.conf` line 15 ends with `# db`, `head-checks.sh` offloads the step over SSH even when zero `.db.test.` files are selected.
* **Cost:** ~15.5 minutes (930 s) of remote test execution per `<project-a>` PR check run.
* **Proposed fix:** Filter the database-host step to run only selected `.db.test.` files (and exit 0 locally with no SSH offload when none is selected), leaving non-database unit tests in the local `run-scoped-tests.py` step.
* **Size:** S.

### 2. Concurrent `head-checks.sh` runs share one remote database checkout with no lock (`mingster/dotfiles#1190`)

* **Evidence:** `script/head-checks.sh` locks local checkouts (`_checks` and `_checks-2`, lines 269 to 284), but both slots invoke `script/remote-heavy.sh` with the same `--dir "$db_remote_dir"` on the database host (line 423). In `remote-heavy.sh` (lines 88 to 90), a second run executes `git checkout -q --detach "$sha"` in that shared remote directory while the first run is inside `bun test`. On 2026.11.19, 3 PRs hit this collision (`0` tests executed, unique constraint errors from concurrent test data, or 101 module load errors), and each false `Checks: FAIL` triggered a needless rework handoff.
* **Limiter:** Unsynchronized shared remote worktree path (`$db_remote_dir`) and shared test database across local check slots.
* **Cost:** 20 to 30 minutes and 50k to 100k tokens per false FAIL rework round (60 to 90 minutes across 3 hits on 2026.11.19).
* **Proposed fix:** Lock the remote database-step checkout per lane (or map each local `_checks-N` slot to its own remote checkout directory and database), and report a database step with `0` tests executed as a host fault rather than a code `FAIL`.
* **Size:** S.

### 3. `wrap-up.sh --scheduled` repeats host-wide sweeps 3 times per round and `board-clean.py` keeps `<owner>/verify-*` worktrees (`mingster/dotfiles#1198`)

* **Evidence:** Across the last 8 completed scheduled rounds in `~/.orca/logs/wrap-up-scheduled.log` and `wrap-up-scheduled-detail.log`, `wrap-up.sh --scheduled` took a median of 458 s (range 446 to 466 s, 7.6 minutes) every 10 minutes, a 76% duty cycle on the coordinator host. Per-repo breakdown from `wrap-up-scheduled-detail.log`: `<project-a>` took 153 to 170 s (`step terminals seconds=46`, `step worktrees seconds=64`), `dotfiles` took 92 to 137 s (`step terminals seconds=48`, `step worktrees seconds=64`), `<project-c>` took 70 to 89 s (`step terminals seconds=52`, `step worktrees seconds=68`), and `board-done.py --fleet` plus `board-clean.py --fleet` took 107 to 120 s.
* **Limiter:**
  1. `scheduled_round` (`script/wrap-up.sh` lines 195 to 230) runs `wrap-up.sh --apply --repo <path>` in a loop across all 3 git repos. Inside each repo pass, host-wide operations run from scratch: `terminal_dispatches` (49 local `orca` CLI calls across 12 Runs reading 4,289 worker rows plus remote environment calls, ~48 s per repo, 146 s total), `release_finished_workers` (575 rows), `sweep_browsers`, `sweep_idle_worktrees` (`orca worktree list` unfiltered by repo), Chrome `code_sign_clone` cleanup, `/tmp/claude-*` scratch walk (166 directories, up to 20 s per repo), and `worker-pane-close.sh` (up to 20 s per repo). Two of the three passes do duplicate host-wide work.
  2. In `script/board-clean.py` (line 84), `is_throwaway(branch)` checks `branch.startswith(("verify-", "qa-", "rm-"))`, but Orca prefixes worktree branches with `<owner>/` (for example `<owner>/verify-8559`). Once a PR is squash-merged and its remote branch is deleted, `is_throwaway` returns `False` on every `<owner>/verify-*` worktree, so all 17 released verifier worktrees fail `unpushed` (`commits not on any remote`) and stay on disk (`applied: clean=0 keep=28`).
  3. In `script/board-clean.py` (line 616), `consider()` calls `facts_for()` / `remote_facts()` (spawning a remote terminal via `orca terminal create --environment`, polling `terminal read`, and closing it) before checking `keep_reason()`'s fast metadata guards (`Done for less than 30 minutes`, `main checkout`, `protected branch`, `archive branch`, `coordinator worktree`, `lead worktree`, `unreleased worker`).
* **Cost:** ~3.8 minutes (230 s) per 10-minute scheduled round (~23 minutes per hour), plus 17 released `verify-*` worktrees left on disk and re-probed over remote terminals every 10 minutes.
* **Proposed fix:** Run host-wide steps once per `scheduled_round`, match `is_throwaway` on `branch.split("/")[-1]` in `board-clean.py`, and evaluate metadata keep reasons before calling `facts_for()` / `remote_facts()`.
* **Size:** M.

### 4. `fleet-watch.py` wake time vs sweep limiters and `usage-gate.py` RPC pagination (`mingster/dotfiles#1199`)

* **Evidence:**
  1. **Wake time of 259 KB `script/fleet-watch.py` (6,795 lines):** `python3 script/fleet-watch.py --help` took a median of 63.61 ms across 7 runs (range 62.84 to 73.70 ms). Python bytecode parsing and imports are not the bottleneck; splitting the file would save under 30 ms per 5-minute run.
  2. **Full `fleet-watch.py` sweep duration:** across the last 50 runs in `~/.orca/logs/fleet-watch.log`, sweeps took a median of 54.5 s (p75 74 s, range 42 to 127 s).
  3. **`usage-gate.py` `live_workers` pagination:** `live_workers("claude")` (`script/usage-gate.py` lines 691 to 713) calls `orca orchestration run-list` (12 Runs) and paginates every page of `orca orchestration worker-list --run <id>` (49 `orca` CLI calls, 4,289 worker rows, 5.85 s) to find 5 live workers. Calling `orca orchestration worker-list --terminal-state active --limit 100 --json` returns `scope: {"source": "all"}` with those active workers in 0.143 s (1 RPC), or 1.40 s across 12 Runs with `--terminal-state active`. Because `pick` and `show` do not cache `live_workers` across providers, `usage-gate.py pick --role fullstack-dev` took 7.40 s and `usage-gate.py check --provider claude` took 8.88 s; `worker-startup.sh` calls both, spending 16.3 s per worker start.
  4. **`usage-gate.py publish` Haiku token renewal:** `publish(hosts)` (lines 557 to 580, called every 5 minutes by `fleet-watch.py`) calls `renew_claude_token()` before checking `fresh(claude_reading(), time.time())`. Because `~/.claude/.credentials.json` holds an expired pre-Orca timestamp (`expiresAt = 1794418745534`), `renew_claude_token()` spawns `claude -p ok --model haiku` (8.52 s plus 1 Haiku turn) on every 5-minute sweep (288 Haiku turns per day), even though `claude_reading()` (`orca account list --json`, 0.11 s) already has a fresh reading (`1.4 m` old). Serial `scp` to 3 hosts adds 3.5 s (12.0 s total per sweep).
  5. **Duplicate PR fetch and doomed fenced starts in `fleet-watch.py`:** `main()` calls `fetch_once(repo)` (`gh pr list --state all --limit 50` with 15 JSON fields: 8.80 s and 2.76 MB on `<project-a>`, 4.57 s and 337 KB on `dotfiles`), and `babysit_pass` then calls `fetch_open_prs(repo)` (+3.6 s) instead of reusing `fetch_once`. When Orca fences `worker-start` (`consumer_fenced`), `fleet-watch` still runs `worker-startup.sh` (`host_check` 3.30 s, `usage-gate` 7.4 to 8.9 s, `orca worktree create`, failed `worker-start`, `orca worktree rm --force`, ~11 to 12 s per candidate, +34 s across 3 candidates in `run=18806`) before emitting the `handoff` notice.
* **Limiter:** Uncached 49-page Orca RPC walks in `usage-gate.py`, unconditional `claude -p ok --model haiku` calls before checking Orca's fresh rate-limit reading, duplicate `gh pr list` calls, and full `worker-startup.sh` execution inside fenced `fleet-watch` passes.
* **Cost:** ~35 to 45 s per 5-minute `fleet-watch` sweep (~8 minutes per hour), 15 s per `worker-startup.sh` start, and 288 wasted Haiku turns per day.
* **Proposed fix:** Use `--terminal-state active` and cache active workers per process in `usage-gate.py`; check `fresh(claude_reading(), time.time())` before `renew_claude_token()` and parallelize `scp` in `publish()`; reuse `fetch_once` in `babysit_pass`; and short-circuit remaining starts in a `fleet-watch` pass to direct `handoff` notices once `consumer_fenced` is returned.
* **Size:** M.

### 5. `checks-local.sh` 60.8 s hook test suite on non-hook diffs, `ship.sh` remote worker scan, and squash trailer false positives (`mingster/dotfiles#1200`)

* **Evidence:**
  1. In `script/checks-local.sh` (line 56), `python3 -m unittest discover -s templates/agent-team/.claude/hooks/tests -p 'test_*.py'` runs unconditionally on every branch and takes 60.83 s (out of 65.8 s total when only docs changed; `no-project-names.test.sh` takes 4.40 s, `check-guard-false-positives.sh` 0.31 s, `shellcheck-dotfiles.sh` 0.29 s).
  2. In `script/ship.sh` (`board_environment_for_branch`, lines 26 to 72), the function paginates up to 10 pages of `orca orchestration worker-list --full --include-remote --limit 100` before checking `if branch_on_host "" "$branch"; then return 0; fi` (line 60). In addition, `SHIP_MERGEABLE_WAIT` defaults to 20 s per poll when GitHub reports `mergeable=UNKNOWN`.
  3. When `ship.sh` runs `gh pr merge --squash` (line 762), GitHub inserts a blank line between `Owner-approved: ...` and `Co-authored-by: ...`. That blank line moves `Owner-approved:` out of git's trailer block on `main`, causing `script/team-audit.sh` (`receipt_check`, line 325) to report false `FINDING receipt` errors on squash-merged commits (`9a1ad0ad` #1181, `ccc1cf55` #1143, `ded15940` #1111) that carry `Owner-approved:` in their commit bodies.
* **Limiter:** Unscoped execution of `templates/agent-team/.claude/hooks/tests` in `checks-local.sh`, remote-first pagination order in `ship.sh` `board_environment_for_branch`, and strict `%(trailers:key=Owner-approved)` parsing after GitHub squash merges.
* **Cost:** 60.8 s per non-hook `dotfiles` check run, 5 to 20 s per `ship.sh` merge, and false `FINDING receipt` audit failures.
* **Proposed fix:** Run the hook unittest suite in `checks-local.sh` only when hook files, `brief-lint.sh`, or `checks-local.sh` changed; check local `branch_on_host ""` first and poll `mergeable` every 4 s in `ship.sh`; and accept `^Owner-approved:` lines above `Co-authored-by:` in `team-audit.sh` `receipt_check`.
* **Size:** S.

## Team guide and workflow audit findings

### 6. Coordinator dispatch traps seen on 2026.11.19 (`mingster/dotfiles#1192`, `mingster/dotfiles#1195`, `mingster/dotfiles#1188`)

* **Evidence:**
  1. `fleet-watch.py` (`park_notice`, line 5035) included `--from <fleet-watch terminal>` in printed `handoff` commands; when pasted by the coordinator, `worker-startup.sh` passed the fenced terminal handle and the start failed silently (`#1192`).
  2. Hand dispatches via `worker-startup.sh` left the `ready-for-agent` label on the GitHub issue, allowing `fleet-watch` `issue_scan` to start a second builder on the same issue (`#1192`).
  3. `fleet-watch` emitted rework handoffs on `Checks: FAIL` receipts caused by database-host collisions (`Tests executed: 0` or `host fault`, `#1192`).
  4. `brief-lint.sh` required `script/checks-local.sh` in `## Verify` even when the target repository had no `script/checks-local.sh` (`#1195`).
  5. Released workers left worktrees behind on local and remote hosts with no read-only lint check in `wrap-up.sh` or the `fleet-watch` digest (`#1188`).
* **Cost:** 15 to 25 minutes and 40k to 80k tokens per duplicate builder or false rework dispatch.
* **Proposed fix:** Tracked in `#1192` (PR #1194), `#1195` (PR #1196), and `#1188` (PR #1189).
* **Size:** XS to S.

### 7. `brief-lint` missing `Refs` rejections, malformed `Builder:` lines stalling verifiers, and duplicate wake instructions (`mingster/dotfiles#1201`)

* **Evidence:**
  1. **`brief-lint: missing Refs`:** `script/worker-startup.sh` requires `--title '#<issue>|<role>'` (line 420) and already injects `## Finish` (`with_finish_block`, line 381) and the role preamble (`prepend_role_preamble`, line 439) before calling `script/brief-lint.sh` (line 679). However, if the brief omits a literal `Refs #<issue>` line (or writes `Refs: #<issue>` with a colon or `Closes #<issue>`), `brief-lint.sh` exits 1 with `brief-lint: missing Refs`. Filing a new issue per `team.md` (`Issue budget`, line 82) also fails `brief-lint.sh` before `gh issue create` because the issue number does not exist yet.
  2. **Malformed `Builder:` lines bypass `pr-body-gate.py` and stall `babysit_pass`:** `script/pr-body-gate.py` (`finish_block_reason`, called by `fleet-watch.py` `bounce_builder_dones` at line 6538) checks `Acceptance`, `## Self-check`, and `Closes/Refs`, but does not check the `Builder: agent=<provider> model=<model>` line. On 2026.11.19, `<project-a>` PR #8610 finished with `Builder: claude/sonnet (<host>)`, and on 2026.11.15 PRs #8007, #8042, and #8044 finished with `agent=fullstack-dev` or `agent=agy` (`team-observations.tsv` rows 32 to 34). All 4 passed `worker_done` without bouncing and then stalled in `fleet-watch` `babysit_pass` with `action=skip unknown-builder-family` or received a same-family verifier.
  3. **Contradictions and superseded rules in `templates/agent-team/.claude/model-routing.md` (2,950 words, ~4,000 tokens):**
     * Line 98 states `"A verifier reads the worker's worktree locally and puts findings in its worker_done, never in PR comments"`, and line 96 states `"Every worker spec states rules 1, 2 and 6"`, contradicting `qa-sdet.md` (lines 15 and 24), `team.md` (`Verdict`, line 61), and `ship.sh`.
     * Lines 63 to 82 (`## Argon builds, Claude debugs` and `## Saving quota`) prescribe `fullstack-dev-small - <job>` titles (which `worker-startup.sh` line 420 refuses with exit 2) and task-type routing superseded by the 2026.11.16 priority rule on line 7.
     * Lines 108 to 131 (`## Starting a worker`) instruct the coordinator to manually run `usage-gate.py pick`, `usage-gate.py check`, `git fetch origin main`, `git log --grep`, `gh pr list --search`, `orca terminal rename`, `orca terminal set-pane-title`, and `worker-start-check.sh` before and after every start, duplicating what `worker-startup.sh` already executes automatically.
  4. **Duplicate per-wake commands in `templates/agent-team/docs/agents/coordinator-operations.md` (`## Wake loop`, lines 38 to 52):** instructs the coordinator to run `~/dotfiles/script/fleet-pull.sh` (~12 s across 3 hosts), `gh api rate_limit` before any `gh` call, `worker-watch.sh`, and manual per-host `ps`/`lsof` worker sweeps on every wake, duplicating `fleet-watch.py` (every 5 minutes), `wrap-up.sh --scheduled` (every 10 minutes), and `ship.sh`'s post-merge `fleet-pull.sh` (#1173).
* **Cost:** 1 to 2 coordinator turns (~2 minutes, 5k to 10k tokens) per `brief-lint: missing Refs` rejection; 30+ minutes of verifier stall per malformed `Builder:` line (4 hits in 4 days); and 5 to 8 wasted coordinator tool calls (~20 to 30 s and 10k to 15k tokens) per wake.
* **Proposed fix:** Auto-inject `Refs #<issue>` from `--title` in `worker-startup.sh` and accept `Refs:` / `Closes` / `--issue-body` in `brief-lint.sh`; validate `Builder: agent=<provider> model=<model>` in `pr-body-gate.py` and normalize `Builder: <agent>/<model>` and `agent=agy` in `fleet-watch.py`; and remove the contradicted, superseded, and duplicated instructions from `model-routing.md` and `coordinator-operations.md`.
* **Size:** M.

## `team-audit.sh --report` results and stage metrics

Running `bash script/team-audit.sh --report` across the 3 configured project roots produced:

* **Deterministic check findings:**
  * `sync`: `<project-c>` has template drift in `.claude/model-routing.md`, `docs/agents/team.md`, and `docs/agents/elon-dispatch.md` (fix: run `bash script/agent-team.sh sync` on `<project-c>`, included in `#1201`).
  * `receipt`: commits touching role files since `2026-11-03` without `ROLE_RECEIPT_BASE` set, plus recent squash-merged commits (`9a1ad0ad` #1181, `ccc1cf55` #1143, `ded15940` #1111) where GitHub's squash merge inserted a blank line before `Co-authored-by:` (fix: `#1200`, and pass `ROLE_RECEIPT_BASE` below).
  * `budget`, `wording`, `skills`, `labels`: clean (0 findings).
* **Known gap:** transcripts of hosts other than the coordinator host are not read (`workflow-from-chats` reads only the coordinator host).

### Stage times and delivery metrics

#### `mingster/dotfiles`

Samples: 100, fully verified: 10.

| Stage | Median (min) | p75 (min) | Max (min) | Samples | Verified |
| --- | --- | --- | --- | --- | --- |
| queue | 43.65 | 230.07 | 514.03 | 23 | 10 |
| build | 10.33 | 38.23 | 456.87 | 21 | 10 |
| merge | 18.85 | 41.07 | 456.75 | 69 | 10 |

Delivery: `median_ticket_start_to_merge_minutes=152.28`, `first_pass_checks_fail_rate=0.06`, `first_pass_verdict_rate=agent=antigravity model=claude-opus-4-6:1/1,agent=antigravity model=gemini-4-argon-high:0/1,agent=antigravity model=gemini-4-argon-medium:1/5,agent=claude model=claude-opus-5-5:0.67/6,agent=claude model=claude-sonnet-5-5:0.63/8,agent=claude model=haiku:0.67/3,agent=claude model=opus:1/1,agent=claude model=sonnet:0.87/46,agent=claude model=sonnet-5-5:1/2,agent=claude model=sonnet-5.5:1/1,agent=cursor model=grok-4.7:0.83/6,agent=cursor model=grok-4.7-xhigh:0.87/15,agent=fullstack-dev model=grok-4.7:1/1`, `reopened_or_hotfix_rate=0.01`, `p0_filed_this_month=0`, `p1_filed_this_month=0`.

#### `<project-a>`

Samples: 100, fully verified: 7.

| Stage | Median (min) | p75 (min) | Max (min) | Samples | Verified |
| --- | --- | --- | --- | --- | --- |
| queue | 31.12 | 52.70 | 78.27 | 11 | 7 |
| build | 11.67 | 19.60 | 2843.45 | 31 | 7 |
| merge | 27.45 | 61.68 | 659.37 | 90 | 7 |

Delivery: `median_ticket_start_to_merge_minutes=101.98`, `first_pass_checks_fail_rate=0.26`, `first_pass_verdict_rate=agent=claude model=haiku:0/1,agent=claude model=sonnet:0.93/90`, `reopened_or_hotfix_rate=0.01`, `p0_filed_this_month=0`, `p1_filed_this_month=22`.

#### `<project-c>`

Samples: 1, fully verified: 0.

| Stage | Median (min) | p75 (min) | Max (min) | Samples | Verified |
| --- | --- | --- | --- | --- | --- |
| queue | unknown | unknown | unknown | 0 | 0 |
| build | unknown | unknown | unknown | 0 | 0 |
| merge | unknown | unknown | unknown | 0 | 0 |

Delivery: `median_ticket_start_to_merge_minutes=unknown`, `first_pass_checks_fail_rate=unknown`, `first_pass_verdict_rate=agent=cursor model=grok-4.7:0/1`, `reopened_or_hotfix_rate=0`, `p0_filed_this_month=0`, `p1_filed_this_month=0`.

### Receipt baseline for the next audit

```sh
ROLE_RECEIPT_BASE="fbfd874e ad4b1d1124 afa4e9acd"
```
