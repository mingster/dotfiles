# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [2026-11-20]

Docs: orca-gaps.md records the verified cause of the remote worker_done rejection (#1159). The coordinator's server rejects the relayed worker_mail because it looks up remote dispatches in the local dispatch table; the coordinator releases the worker with worker-release. Upstream report: stablyai/orca#43618.

* `script/ship.sh` pulls the latest dotfiles to every fleet host in the background after it merges a `mingster/dotfiles` PR (`fleet-pull.sh`, 5 minute timeout, never fails the ship). Merges of other repos do not trigger it. The result goes to `~/.claude/state/fleet-pull-after-ship.log`, and `fleet-watch` reports a host that did not update.

Fix protected-paths so changelog fragments ending in model-routing.md or AGENTS.md are no longer owner-gated; only files with that exact name are (#1176).

`worker-startup.sh` refuses any `--title` that is not `#<issue>|<role>` (for example `#123|qa-sdet`; a verifier uses its PR number) and sets the title on the worker terminal and pane. `fleet-watch` emits that form for builder, rework, fix, verifier and sweep starts and still reads the old `<role> - <job>` titles of workers already running (#1182).

Fix: ship.sh now sets every worktree of the shipped issue completed (builder, verify, rework and their -2..-n copies) by path, since the branch: selector failed (#1184). A released worker's worktree is completed unless its branch has an open PR (a detached verifier counts as none). worker-startup.sh shows the --title on the board card and removes the worktree it created when the start fails.

Fixed: head-checks no longer reports a false FAIL when the database host checkout has a stale or missing install. remote-heavy.sh now reinstalls (with the project's postinstall) when node_modules is missing as well as when the lockfile changes, and a database host step that hits load errors with zero failing tests is reported as a host fault (#1186).

Added check-stale-worktrees.sh. wrap-up.sh prints leftover worktrees whose PR is merged or closed, and fleet-watch adds one digest line for each (#1188).

head-checks now locks the remote database-step checkout so two runs never share it. The second run waits, then reports host busy (INFRA, not FAIL). A database step that executed 0 tests reports a host fault (INFRA), so no rework starts.

Add the 2026.11.19 team audit and script performance report (`docs/agents/audits/2026-11-19-team-audit.md`) with ranked fix issues (#1198, #1199, #1200, #1201, #1192, #1190, #1188, #1195) (#1191).

Fixed three coordinator dispatch traps. Fleet-watch handoff lines no longer print `--from`, so the coordinator's own terminal is the sender. `worker-startup.sh` removes `ready-for-agent` from the issue of a builder it starts. A Checks FAIL that is a host fault, or whose database step ran no tests, prints a rerun line instead of a rework handoff. (#1192)

brief-lint requires `script/checks-local.sh` in Verify only when the target repo has that script (#1195).

`worker-startup.sh` resolves `--repo path:<dir>` to its Orca repo id (`orca repo list`) before placement, so a path places by `worker_placement.repos` the same as `id:`. A path with no repo id is refused with one line (#1197).

Scheduled wrap-up runs the host-wide sweeps once per round instead of once per repo, board-clean recognises owner-prefixed throwaway branches, and it checks board data before probing a host (#1198).

Faster usage gate and fleet-watch (#1199): `usage-gate.py` reads active workers with one `worker-list --terminal-state active` call and reuses it for every provider, `publish` skips the Claude token renewal when Orca already has a fresh reading and copies to hosts in parallel, and `fleet-watch` reuses its pull request list in `babysit_pass` and stops starting workers for the rest of a pass once Orca fences one.

- checks-local.sh runs the hook unittests and check-guard-false-positives.sh only when a hook, brief-lint.sh or checks-local.sh changed. ship.sh checks the local Orca for the branch before paging remote workers and waits 4 s per mergeable reread (15 rereads). team-audit.sh counts an `Owner-approved:` line that a squash merge separated from `Co-authored-by:` by a blank line (#1200).

- worker-startup.sh adds `Refs #<issue>` from the `#<issue>|<role>` title when a brief has none, and brief-lint.sh accepts `Refs:`, `Closes`, `Fixes`, `Resolves` and `--issue-body`. pr-body-gate.py bounces a PR body without a valid `Builder: agent=<provider> model=<model>` line, and fleet-watch reads `Builder: <agent>/<model>` and `agent=agy`. model-routing.md and coordinator-operations.md lose the contradicted verifier rule, the refused `fullstack-dev-small` title rule and the per-wake fleet-pull and ps sweeps (#1201).

Added `script/fleet-watch-loop.sh`, a pid-guarded 5 minute loop started from the coordinator terminal so fleet-watch's own worker starts pass the Orca fence. Its starts now drop `--from`, use `--repo id:`, and skip an issue or rework start when a live worker already has the same title.

fleet-watch: an issue start is skipped when an open PR already closes, refs or is branched for the issue, and a Verdict or Review FAIL becomes a digest line (FAIL: send to architect-pm) instead of an automatic rework start (#1209). Checks FAIL reruns stay automatic.

- worker-startup.sh, ship.sh, head-checks.sh and fleet-watch-loop.sh now fast-forward a clean, behind dotfiles checkout when they start (`script/lib/dotfiles-fresh.sh`, built on session-sync.sh). A dirty, diverged or offline checkout gets one warning line and is left alone. `check-dotfiles-fresh.sh` in checks-local.sh fails when one of them drops the preflight (#1211).

The pre go live waiver (`pre_go_live_host.until` in guard-config.json) now also covers the promote script and the SCHEMA_APPROVED schema check in the guard-bash template. Hand pushes to a production branch, force pushes, deletions, apply scripts and credential writes keep their gates.

* One 20 label issue set (state, `P0` to `P3`, `size:S`/`size:L`, six `role:*`, four hold labels) drives `fleet-watch`: hold labels block a start, issues start by priority, then size, then age, a `role:*` or `size:*` label picks the worker through `usage-gate.py pick --role`, a started worker of any role removes `ready-for-agent`, a failed start with no PR returns the issue to `needs-triage`, and a live `#<n>|` worker of any role blocks a second start. A bug is always `P0`. `script/issue-labels-migrate.py OWNER/REPO` (dry run by default) creates the labels and relabels open issues. `team-audit.sh` uses the new hold set.

* `fleet-watch` now reconciles settled remote workers whose relayed `worker_done` the coordinator rejected (`unknown_dispatch`): it synthesizes the completion, releases the dispatch on the remote host and the coordinator, and frees the remote seat. `worker-startup.sh` and the agy rules no longer tell workers to send `worker_done` to the home Run ID, and `pr-review-gates.sh` lists remote workers (#1220).

A worker or verifier that vanishes at startup (`terminal_exited`, `agent_readiness`, `agent_not_in_foreground`, `dispatch_input`) is started once more by `worker-startup.sh` and `fleet-watch.py` before it is parked or skipped as `already`. `wrap-up.sh` keeps a new terminal that has no output and no agent yet. `worker-budget.py` denies `worker_done` while unread orchestration mail waits, `orca-reply.sh` and `guard-bash.py` refuse mail to a settled or released worker, and `fleet-watch.py` releases a dead "New messages" follow-up of a finished worker.

- fleet-watch skips a PR whose verifier runs under a detail title or a verify worktree, and worker-startup warns on a duplicate verifier start.

- fleet-watch can run one standing antigravity verifier per configured trial host (`babysit.standing_verifier`, off by default), with a 5 PR and context cap, a wake probe that falls back to a fresh verifier, and a trial log (`fleet-watch.py --trial-summary`).

* `fleet-watch` no longer counts the coordinator's rejected copy of a remote `worker_done` (`unknown_dispatch`) as an accepted one. It synthesizes the completion, releases the dispatch on the remote host and the coordinator, and sends one plain status line saying no hand release is needed (#1228).

Worker placement counts live and recently started workers per host, skips a host at its cap, ranks hosts by worker share first and 5 minute load per core second (load is a gate and a tie break, so back to back starts spread; picks are recorded even when the inventory cannot be read), considers every host in host_caps, and picks the coordinator host last. worker-startup.sh --on <host> now maps a local repo id through worker_placement.repos (#1231, #1230).

brief-lint now resolves the lint directory from the local --repo even with --on <remote>, so checks-local.sh is required only for repos that have it (#1233).

The placement burst guard scales each host cap by cores (cores_per_worker, default 2) and skips a host whose free memory (sensor `memfree=` GB, less mem_gb_per_worker, default 4, per recent start) is used up. Host caps are unchanged (#1235).

Fix the PR body gate: a Self-check with only a `bunx`, `npx`, `uv` or `node` command, or a `Command (from dir):` heading, now counts as naming a command (#1237).

Fix: an antigravity worker stuck on the agy sign-in screen is noticed (#1240). worker-startup.sh reads the screen about 60 seconds after start, stops the dispatch and restarts the same brief on claude sonnet. fleet-watch checks every running antigravity worker each sweep, marks the host agy-unavailable for 6 hours (skipped for antigravity placement and standing verifier hosts) and sends one digest line per host per 6 hours that asks the coordinator for the owner push.

A numbered Acceptance list now passes brief-lint, and a ready issue that fails lint a second time goes back to needs-triage with an `issue_lint_stuck=<n>` digest line (#1242).

fleet-watch: one issue_scan pass now starts every eligible issue the host caps and the usage gate allow, instead of one per pass. It counts this pass's starts per host, re-checks the usage gate before each later start, and moves on to the next candidate after a failed, deferred, live or skipped one. Refs #1244.

Apps install into /Applications again. No install script passes `--appdir` to the old per-category folder, and every lookup of an app (Orca, Visual Studio Code, Sourcetree, Antigravity) goes through `script/lib/app-path.sh`, which finds `/Applications` first and falls back to the old folder for apps not yet moved. `script/check-appdir.sh`, run by `checks-local.sh`, fails on any new mention of the old folder (#1248).

fleet-watch issue_scan starts every ready dotfiles issue before any other repo's issue, whatever its P label. The shared team rules say so too.

Agent team roles: the builder runs the project performance checklist and adds a `Perf:` line to the PR body, and the verifier fails a miss or a missing `Perf:` line back to the builder.

agent-team.sh check no longer fails when a kept project hook differs from the template. A project owns its kept hooks; the template is only the starting point.

Template guard honours an optional `pre_go_live_host.until` (ISO date, Asia/Taipei) in the project guard-config.json: the `host` approval is waived before that date. Without the key, or with a malformed value, nothing changes.

## [2026-11-17]

Move an Orca board card to Done when its pull request is merged or closed, its linked issue is closed, its worker is released with no pull request, or its worker failed or stopped. The coordinator's scheduled wrap-up runs that check on every paired host and skips a host it cannot reach. A worker with no pull request sets Done itself, `ship.sh` sets Done on the host that holds the worktree, and Cursor placement passes the remote repo selector.

The coordinator's scheduled wrap-up removes a Done card after 30 minutes on the host that holds it, including its worktree, branches, terminals and session, and leaves a board comment when a guard keeps the card. Released verify, QA and RM branches go even with local commits.

The shell guard allows `$?`, `$#`, `$$`, `$!`, `$-`, and `$0` to `$9` when they are not part of a path. It allows any other variable in a word with no path separator, unless the text before the variable can complete a protected directory name. The guard still denies a glob, a brace, a substitution, `find -exec`, or `xargs` that can name a restricted script or a credential directory. The hook loads on Python 3.9.

Name script/checks-local.sh in fleet-watch verifier and rework briefs only when that repo has the script (#1011).

fleet-watch keeps shipping and scanning when the local host is full: it skips a lint-failing issue, places the next one on a free host, releases a green succeeded worker, and does not recount a conflict-only rework (#1016).

* The build grill gate stops a start when any named issue cannot be read, or when its title, body or labels use money or price wording, until a `Grill approved:` line is present. That line is a speed bump, not proof of who wrote it, because every agent posts as the owner. release-manager can push production with no owner go only after a fresh fetch of `origin/main` shows the test-data status line and no live store. Another repo, a URL remote, a failed fetch, or a rewritten local `origin/main` does not waive the go (#1017).

ship.sh rereads a pull request while GitHub reports mergeable UNKNOWN, and fleet-watch releases a verifier on a merged or closed pull request (#1018).

Route verifiers by model family, keep one verifier on a rework head, and refuse a builder finish that skips Acceptance or Self-check (#1018, #1030, #1031, #1027).

worker-startup --on this machine starts the worker locally, with no --environment (#1019).

New `tune-agent-docs` skill cuts words from agent guide files without changing a rule. It lists the strings scripts and tests parse, keeps them byte identical, and maps every old rule to its new place. It merges rules repeated across files into one place with a pointer before polishing lines. The agent team role files and team docs drop from 12750 to 10195 words (20%).

Make script/checks-local.sh fast and stable for fleet-watch and wrap-up changes: the wrap-up temp file walk no longer forks per entry, wrap-up.test.sh is split in two so the halves run side by side, the local pool runs 8 jobs with the longest tests first and prints each test's time, and fleet-watch admission tests stub the host load and memory reads (#1024).

brief-lint.sh checks an optional brief type, and post-verdict.sh refuses a FAIL that has no `--command` or no `- [ ]` fix line (#1026, #1027).

Grill, root-cause analysis and audit workers run on a different model family than the coordinator and than the authors of the work under review (#1029).

Team guides now describe the builder finish as the full local check, real artifact proof and a `ship.sh` merge by the PR owner, and cite headings that exist.

The merge gate counts a commit as owner-approved when any Owner-approved trailer on that commit has a non-whitespace value. An empty or whitespace trailer stays missing.

`guard-bash-config.test.sh` sets `GUARD_APPROVAL_ROOT` to a missing directory, so a host that already has `/usr/local/etc/agent-team` still runs the owner-approval cases against the temp home file (#1034). When `TMPDIR` is unset, the same test points `TMPDIR` at the parent of its `mktemp` directory so macOS `mktemp` and Python share one temp directory (#1034). `approval-sign.test.sh` saves `codesign -dv` output before it checks the hardened-runtime flag, so a `grep -q` early exit cannot fail the pipeline under `pipefail` (#1034).

* `role-word-budget.test.sh` checks the current release-manager rollback guard (`A production rollback is a production deploy`), and CI now selects it whenever a `templates/agent-team/` file changes (#1037).

fleet-watch holds head-checks on a refused host, names an overflow host only when that host has the repo, and reads the environment list once per pass. Team audit records the first-pass Verdict rate per builder agent and model (#1042, #1027).

Fixed the guard-bash-config test so it no longer fails when TMPDIR is set to a non-default directory (#1047).

The usage-gate overflow hint uses the current dispatch repo when a local worker-start omits --repo, so the named host is one that maps that repo.

The weekly audit counts a pull request under its last line-start Builder tag, so a quoted example is no longer a builder (#1051).

fleet-watch drops a settled release_unknown seat after it proves the worker is gone. No process is using that workspace, and the worktree is missing or clean. A failed check keeps the seat, and the host cap is unchanged (#1054).

Document in `team.md` (and reference from the `guard-bash.py` role file deny message) that when a change to an owner-gated file only copies rules the owner already approved, the coordinator may add the `Owner-approved:` trailer citing the source decisions in the commit and PR body, while a new rule or loosened limit still waits for the owner (#1057).

head-checks checks a force-pushed PR head when the local branch diverged and that head is newer. When the diverged head is older it waits for GitHub to catch up, and refuses only after that wait.

Head check steps use a bash that runs, so a PATH entry with a /usr/bin/bash shebang no longer stops the throwaway database drop on blueDevil.

ship.sh judges each check name by its newest run and ignores a SKIPPED run when the same name has a SUCCESS at the head.

fleet-watch --admit no longer counts an exited worker as occupying a seat when Orca owns no resource and the visible worktree has no unpushed commits (#1066).

Each fleet-watch pass fills `local_host`, `host_caps`, `host_load_ceilings`, and `worker_placement` from the stub config when the pass config lacks them. A pass with no `host_caps` logs `pass_config_no_host_caps`. Issue scan also matches a host by the local Orca repo id.

The usage gate pick now keeps the role's preset provider when headroom is within 2 points, so near-equal readings no longer flip the recommendation between providers and block every start.

`script/ship.sh` refuses the merge when a Review: FAIL at the head has no later Review: PASS for that head and no Countersign. A Verdict does not cover that FAIL.

Agents no longer use Codex or ChatGPT. The Orca upgrade skip list, the commented ChatGPT cask, and the Codex installer note are gone. The routing pick test refuses a Codex or ChatGPT result (#1074).

The fleet toolchain check now fails and names a host whose regression runtime.conf has no E2E_SHARD line, because the regression fleet silently skips that host and the round overruns its time cap. The check reads only whether the line exists and never prints the file values. Hosts with no runtime.conf are not affected.

The `git commit` team gate now asks for an `Owner-approved:` trailer on every path `script/lib/protected-paths.sh` protects, reading that file instead of a second list.

The usage gate marks an Antigravity pool blocked until its reset when a "quota reached, resets in" banner is piped to `usage-gate.py banner`, and treats a preset Antigravity model id missing from `agy models` as not eligible.

Map builder models to their provider family by model prefix regardless of the agent field, stop verifier dispatch in `fleet-watch.py` when a pull request has an unknown builder family, and write the exact `Builder: agent=<agent> model=<model>` line into builder specs from `worker-startup.sh` (#1080).

Gate `head-checks.sh` `tsc` steps through `heavy-gate.py` (`--weight 1`) so they wait on slots, load, and free memory instead of running beside two other heavy jobs. When a `tsc` step is killed by the OS (exit 137), log it as a retryable infra failure, retry once when load drops, and report `Checks: INFRA` (not a code `FAIL`) if the retry is also killed (#1081).

fleet-watch skips a verifier start for every PR named in a live batch verifier task title, not only the first. (#1082)

* Cursor builders now run on `grok-4.7-high` (`grok-4.7-high-fast` only when urgent) instead of `grok-4.7-xhigh`. Owner request 2026-11-15.

The guard hook lets a `promote <sha>` approval cover read only inspection and Prisma client regeneration on the release host, for the hosts and app directory named in the new `promote_host_steps` key of `guard-config.json` (`app_dir`, `read_hosts`, `write_hosts`). Regeneration must follow a HEAD check or checkout of the approved sha, joined by `&&` only (`;` is refused), removing `prisma/generated/client` must be followed by `prisma generate`, and paths with `..` or `.ssh` are refused. `run-production-data-step.sh` takes only the sha and a step name. Without the key, nothing changes.

Fix the ship.sh test that expected a verifier on the same model as the builder to pass. The family rule refuses it, so the test now uses a verifier from a different family.

Start a verifier in `fleet-watch.py` only after `Review: PASS` is posted on the same head (leaving `Review: FAIL` to send the pull request back to the builder with no verifier), and brief a re-verify after a fix to check only the prior `FAIL` items and the diff since the last verified head (#1082).

Run live browser checks in `qa-sdet` only when the diff touches UI files (pages, components, locale copy), state in the Verdict why no live check ran on other pull requests, share one running dev server on latest `main` via `script/live-check-server.sh` with a 30 minute lock wait limit before posting FAIL on a blocked check, and remove stale script paths from the team docs (#1082).

- `wrap-up.sh` no longer proposes an idle Orca worktree whose branch has an open PR or whose commits no remote holds (the last copy); it names them as kept. A `peer_changed` error from `worker-show` is now reported and skipped like an unpaired host, so one stale peer no longer fails the host preview.

fleet-watch reruns head-checks after a Checks: INFRA receipt at most `head_checks.infra_reruns` times per head (default 2), then posts one digest line and stops. A new head resets the count (#1088).

fleet-watch no longer mails a settled or released worker (rework head notices, builder bounces), so that mail stops coming back as escalations (#1089).

Route builders and reviewers to the Grok CLI agent (`grok-4.7`) instead of Cursor. `usage-gate.py` gates `grok` by a live worker count (one per host), `pick` orders grok, Claude, Antigravity, then Cursor, and the hook, `worker-startup.sh`, fleet-watch verifier pick and routing doc follow. (#1097)

The usage gate reads the Claude weekly usage of the Orca active account when Orca lists managed Claude accounts, and keeps the old reading when it lists none or the call fails. Before a Claude start, an active account at the ceiling is swapped for a managed account under it with `orca account select`, and the switch is logged with account id prefixes and percentages only. Running workers keep their account.

The grill gate now resolves a bare `#N` against the repo on the brief's first dotfiles `Refs` line, and no longer falls back to the `OWNER/dotfiles` placeholder when `DOTFILES_REPO` is unset.

* The coordinator role file says an ambiguous or short reply to a choice that includes an owner only step is a decision, never permission to do that step (#1108).

Fix the Cursor fallback model name in the routing doc and make `usage-gate.py show --provider grok` print a line without `--json`.

- usage-gate: a `pauses` entry in `usage-gate.config.json` (provider, until date, reason) blocks that provider, and any Cursor model of its family, in `check` and `pick` until the date. fleet-watch and `worker-startup.sh` call those, so a paused provider is skipped and the next in the fallback order is used. Seeded: grok until 2026-11-20 (mingster/dotfiles#1115).

* fleet-watch types a short nudge into a worker that has been idle for 5 minutes with an unread orchestration message, at most twice per message, and skips a terminal that is not writable.

Forced `--on` hosts are now load checked (exit 4 with the least loaded alternative unless `--force-host REASON`). The coordinator host needs `--force-host chrome-dev|line-desktop|host-file`. `--force-host` with a reason maps to its host in `worker_placement.reasons`. Each start prints live workers per host.

Provider priority is now Claude, Antigravity, Grok, Cursor for every role: usage-gate chains and pick, preset chains, the worker-startup builder lock, fleet-watch fallbacks and the routing docs.

* `agent-team.sh` migration accepts a `HOST_DEPLOY_COMMANDS` host list built with `list(<shared list>)`, so a project with that guard syncs again (#1121).

Fixed: ship.sh runs the private name check on PR text only for public repos, so private repos can ship PRs that name their own project.

agent-team check now fails when a kept shared hook (such as guard-bash.py) differs from the template, so a project that sync never overwrites no longer misses a merged rule silently. (#1125)

The Bash guard no longer reads the body of a quoted heredoc as commands when it only feeds a text sink (`cat > file`, `cat <<'EOF' > file`, `git commit -F -`, `gh ... --body-file -`). Heredocs fed to a shell, ssh, python or an unquoted opener are still scanned. (#1126)

1128: worker-placement picks the host with the lowest load relative to its ceiling instead of the first host under it.

Make the guard hook tests run on Python 3.9, the system python on some fleet hosts, so `script/checks-local.sh` no longer fails there.

Make the `agent-team.test.sh` dry-run check read its output without a pipe, so a fast `grep -q` no longer fails it with a broken pipe.

The agent-team no-placeholder test no longer edits the real elon.md template to fake a stale copy; it edits the copy under its temp HOME, so tests that run in parallel no longer race on the template. (#1129)

Fixed: fleet-watch verifier briefs now run `script/checks-local.sh` in Verify when the repo has it, and re-verify briefs pass brief-lint.

New `script/check-guard-false-positives.sh` replays the allow and deny command fixtures under `templates/agent-team/.claude/hooks/tests/fixtures/` through the template guard and fails when one flips. `checks-local.sh` runs it, and each later false positive becomes one new allow fixture in the PR that fixes it. (#1135)

* The fleet Node pin moves to 24.22.3, the latest Node.js 24 LTS.

* `fleet-toolchain-check.sh --apply` now upgrades Node.js on a peer to the coordinator's version through the host's asdf, even when that peer's dotfiles checkout still has the old pin, and the version probe reads Node from the home directory so a checkout pinning a Node the host lacks no longer shows "version unreadable".

The fleet worker count shows live, in progress dispatched workers from `orca orchestration worker-list`, so the coordinator, automation sessions and finished workers no longer inflate it (#1147).

- Orca automation runs now show their result. The precheck wrapper prints `ok <name>: <summary>` or `FAILED <name>: <summary>` and exits 1 for a good run or 2 for a failed one, so the two look different in `orca automations runs` and the Automations view. Manual "Run now" gets a real prompt that runs the job once. A reinstall keeps the owner's enabled state for the opt in jobs. The wrap-up round bounds its board steps by the time left before Orca's precheck limit, and a killed run no longer reports the previous round's summary (#1148, #1149).

- `automation-precheck-staging-daily.sh` passes the coordinator run's terminal as `--from` when it sends the wake, so the scheduled 19:00 run no longer fails with `no_active_sender_terminal`. A failed send now logs the Orca error text. (#1148)

fleet-watch flags a malformed Verdict or Review first line on an open PR, and brief-lint requires a verify brief to name post-verdict.sh or the exact Verdict first line (#1157).

worker-startup refuses a fullstack-dev brief whose Refs issue a merged PR already closed (Closes, Fixes, Resolves, Delivers), unless --allow-delivered REASON is given. A failed gh lookup lets the start go on (#1158).

fleet-watch (opt in with board_stale_check) reports a settled worktree that board-done would move to Done but that is still In progress or In review an hour later, one notice per worktree, at most five per pass (#1160).

fleet-watch sends one notice when a repo_roots checkout holds more than 50 files in changelog.d (changelog_fragment_warn overrides the limit), and again only when the count doubles (#1161).

ship.sh no longer refuses when GitHub says a PR diff is too large. It builds the diff locally from the base and head commits, so every lane check reads the same content.

wrap-up: the idle worktree sweep now keeps a worktree that a running process uses as its cwd or holds open files in, and logs the skip.

* fleet-watch hands a worker start to the coordinator when Orca refuses it with `consumer_fenced`. The urgent notice reads `handoff <kind> <target>` and carries the ready `worker-startup.sh` command, instead of a bare `parked` line (#1170).

Add design process rules (usage first, spikes, delete before adding, automate last, design tiers) to the agent team templates and skills.

Tighten shared agent coordination, ticket and reviewer contracts; preserve live worktrees and surface stalled or failed dispatches.

* `run-scoped-tests.py` no longer selects `*.db.spec.*` files. They are integration specs that need a test database, so a PR that changes only those specs now passes the scoped unit step with no tests selected (#217).

Fix wrap-up eligibility for clean detached worktrees at merged or closed PR heads, requiring remote branch reachability and retaining worktrees with active Orca terminals anywhere inside them.

The heavy job guard now recognizes Bun global options, bun x, bun run tsc and commands inside shell control flow. These commands require the shared machine gate while lint and development commands remain allowed.

Fix the worker-start usage hook to check the named Antigravity model's quota pool, retaining the worst-pool check when no model is specified.

- bun-pin-check.sh warns when a host's bun is older than the repo's pin (packageManager or engines.bun), or differs from this machine's bun when there is no pin. start-codex-worker.sh runs it (new --host flag); coordinators run it before any other worker-start.

- worker-pane-close.sh in sweep mode (no arguments, as run by wrap-up.sh) now closes a settled dispatch's terminals only once its linked worktree is gone, so a lead or worker on a correction pass keeps its pane. Explicit dispatch ids, as used by worker-finish.sh, behave as before.

Merge cleanup and wrap-up keep every worktree whose directory name starts with `lead-`, not only `lead-queue`, so a lead that opens a PR from its own worktree no longer loses its terminal.

wrap-up.sh now removes Chrome code_sign_clone dirs that no running process holds open.

### Changed

- Agent-team elon, tech-lead and release-manager role files trimmed under the 800 word budget; the Cursor trust marker and host preflight detail moved to docs/agents.

Wrap-up now keeps a detached worktree whose head is an open PR head, even when it holds untracked files such as images, and keeps every detached worktree when the PR lookup through gh fails.

lead-merge runs one preflight that reports every refusal needing no head-checks, a batch drops refused PRs and merges the rest, and head-checks posts a bounded receipt with the full log in a named file.

lead-merge.sh now allows one merge run per repo. A `lead-merge.lock/` directory in the git common dir (pid and start time) is held from the start of a single or batch run to the last merge and released before cleanup, on every exit path. A second run waits up to `LEAD_MERGE_LOCK_WAIT_SECONDS` (default 1200), printing the holder, then refuses. A lock whose pid is gone is taken over. A batch whose origin/main moved during the train checks prints "main moved" and merges nothing.

A lead-merge batch now reads the dispatch inventory once and passes it to its preflight and gate children through LEAD_MERGE_DISPATCHES_FILE, falling back to one live read when the file is missing or unreadable.

Merge pipeline: `script/post-verdict.sh` posts a Verdict in the exact form lead-merge parses. Preflight now names every ignored Verdict (wrong line, missing `author=`, edited or minimized PASS) by comment URL with the fix. A FAIL is retired only by `Countersign: Elon head=<sha> reason=supersedes <comment url>`. An `author=` listed in `coordinator_ids` (in `script/lead-merge.local.json`) is accepted when the verifier is a known dispatch.

- head-checks.sh falls back to sha256sum when shasum is absent. remote-heavy.sh defaults --gate to the remote DOTFILES_DIR checkout and its export lines are tested. fleet-watch.py records existing failed dispatches on its first pass and reports only new ones.

- remote-heavy.sh now works on hosts whose login shell prints to stdout over ssh. HEAD travels as a base64 git bundle on stdin instead of a git ssh push, and the job output and the artifact listing are framed between tagged markers, so banner or exit lines are dropped.

Fix `script/tests/lead-merge.test.sh` failing 20 verdict-from cases on Linux. The generated copy diff was exported in the environment and passed the 128KB per-variable exec limit that Linux enforces (macOS does not). The gh stub now reads the diff from a file, and a guard fails any case that exports a variable over 100KB.

- lead-merge.sh --batch with one PR now runs as a plain single merge (same gates, same receipt) instead of refusing.

- Added script/orca-reply.sh: one helper that replies to an orchestration message and then nudges the recipient terminal so an idle session wakes, and refuses an empty recipient. Coordinator docs now use it instead of the bare reply command.

- remote-heavy.sh now explains when the remote lacks the bundle's base commit, documents that the remote command gets no caller stdin, and has tests for the missing end marker, branch-equal-to-main and failed remote fetch paths.

lead-merge: read the dispatch inventory only in batch children, write the cache via temp file and mv, and test the refusal and fallback paths.

wrap-up cleanup test no longer depends on the host having `lsof`; it stubs one, so it passes on Linux hosts without it.

Remote worker worktrees now start from a fresh origin/main with dependencies installed, through a repo setup hook (`script/worktree-setup.sh`).

Team hooks: guard-bash lets a single bun test file run ungated, and strikes ignores tooling failures (missing module, prisma generate, heavy-gate).

lead-merge: `--dry-run` now holds on the single PR path (`--pr N --head S`, and `--batch` with one PR). All gates run, it prints `[dry-run] would merge PR N head=<sha>` and exits 0 without merging, retargeting or cleaning up. Fixes #333.

The Screenshots gate ignores files with status `removed`, so a PR that only deletes UI files no longer needs a phone screenshot. Added, modified and renamed files still count.

lead-merge: the trunk check accepts a shared locale JSON file when main and the PR only added distinct keys and the three way merge is clean. Changed or removed keys, the same key added on both sides, text conflicts and non locale files are still refused.

Write Cursor workspace trust before worker dispatch with a local start helper, and route Cursor and Antigravity workers to the main Mac until remote attach works.

lead-merge now uses the newest Verdict at the current head, so a corrected Verdict replaces an invalid one.

* `run-scoped-tests.py` takes `--on-test-change <glob>` (repeatable, relative to `--root`). Whenever any changed file is a test (added, renamed, modified or deleted), the matching tests are selected too, so repo-wide contract suites that scan every test file are no longer skipped (#357).

Add `script/bootstrap-asdf-tools.sh`, an idempotent per host bootstrap that installs the python and nodejs pins from the root `.tool-versions` through asdf and writes them to `~/.tool-versions`.

Tests that change HOME now also pin ASDF_DATA_DIR, so the asdf shims keep working under a temp HOME. A new check fails when a HOME-changing test skips the asdf pin (#359).

* Pin python and nodejs in a root `.tool-versions`. Tests that change HOME now export the asdf pin first so the shim keeps working (#359, closes #356). New `no-hardcoded-interpreter.test.sh` fails on a hardcoded python path.

* Move the python pin from 3.14.10 to 3.15.2 in `.tool-versions` and `mac/install_python_dev.sh`; `bootstrap-asdf-tools.sh` now installs 3.15.2 on every host.

Let the install skip the host readiness check with DOTFILES_SKIP_SETUP_CHECK=1, and make the orca-skills-home test print every install and orca log on failure.

- switch-login-shell-zsh.sh makes zsh the login shell on a set up host. arch/system_setup.sh and mac/system_setup.sh now chsh to zsh when $SHELL is not zsh (fish stays installed). .zshrc only evals brew shellenv when brew exists, so Arch hosts load it cleanly.

heavy-gate: a job marked HEAVY_GATE_CLASS=long keeps one slot free for short scoped test jobs.

- Stopped installing fish everywhere: the mac, arch and debian setups install and link only zsh, the fish config and fisher/tide scripts are removed, and kitty, nvim and lf use the login shell or zsh.

- `wrap-up.sh` previews and, with `--apply`, removes agent temp files: stale Claude Code scratch session dirs, throwaway Chrome profiles, loose numbered logs and scripts, and Playwright output. Held open items, the current session and the coordinator waiter files are kept. See `docs/agents/wrap-up-temp-files.md`.

lead-merge now accepts the coordinator of an Orca run as a Verdict author, so a coordinator authored PR merges on a host with no coordinator_ids entry. The host file stays as an extra allow list, and an unreadable Orca run refuses.

Heavy-gate: short jobs skip the load sensor while only long jobs hold slots (memory floor still applies).

Trimmed the elon and release-manager role files back under the 800 word budget, which fixes the four agent-team.test.sh failures that were blamed on the asdf shims (#379).

Expand copy-only owner approval vocabulary across English, Traditional/Simplified Chinese and Japanese price, cancellation, legal/privacy and promise topics, with grouped provenance and regression coverage.

Require owner Copy approval for edits about sensitive topics and changed numbers or currency, even when term counts stay unchanged; preserve literal currency symbols to avoid treating ordinary words as NT$.

Require independent verifier topic attestation for the copy-only light route, freeze the multilingual backstop, and ignore unchanged key context without a value match.

Fix copy-only classification to compare sensitive-term counts across complete base and head copy files, including retained context and adjacent locale values.

Copy-only tooling now sends changed spelled-out quantities (such as 一百 to 二百, 百 to 千, one hundred to two hundred) to owner Copy approval, with semantic-review guidance in the vocabulary doc. A missing guard-bash.py now falls back to the configured approval namespace or refuses with a clear message instead of exiting silently.

- wrap-up: closes every finished Orca terminal (settled dispatch or exited process) on the local host and all listed environments, keeps its own, live and unknown-running ones, and reports `terminals closed=N kept=M`.

wrap-up: a pending dispatch whose worker-show fails is skipped with a warning instead of silently keeping every worktree; other worker-show failures warn before retaining all worktrees (#386).

wrap-up.sh preview no longer keeps a worktree only because of a terminal it plans to close, so the dry run matches what --apply removes.

wrap-up.sh --fleet also cleans finished worktrees and local branches on every host in an untracked fleet config, over ssh. Dry run by default, per host counts and a fleet total, unreachable hosts only warn.

wrap-up: Chrome code_sign_clone cleanup now also scans the sibling X dir of the per-user temp dir (#391)

wrap-up now drops idle build caches (`.next` by default, names set by `WRAP_UP_BUILD_CACHE_DIRS`) in the worktrees it keeps, and a failed single delete (worktree, local branch or remote branch) warns and counts as kept instead of stopping the run.

The fleet run now allows each host 900 seconds by default (was 300), since a host with a large backlog of finished worktrees needs more than 5 minutes. Every removal that rests on nothing running there (worktrees, stale branches, build caches, Chrome clones, temp items) now goes through one process check, and a failing or missing lsof or ps keeps the item and counts it as kept.

head-checks records `Duration: <seconds>s` for each check and ends the receipt with `Total: <seconds>s` (#396).

* Spec for cutting merge train time: entry gate, direct drop, parallel bisect and one merge queue per repo, in `docs/specs/398-merge-train-speed.md` (#398).

QA admission preserves the usage gate's independent reviewer provider and model, binds the exact repository, project, path, head and native workspace identity, and selects a configured host below its cap. Complete native worker pages count live and retained resources without inferring model or process identity from terminal previews. Full hosts fall through to an eligible host; all-host refusals print occupied/cap and live/retained counts.

Expiring operator policy is optional and may narrow configured caps, load ceilings, providers and workspace bindings. Fresh finite host loads remain required. Local routing uses the native local workspace; paired routing pins the saved server ID. Admission is a snapshot, not an atomic capacity reservation.

Before enabling automatic dispatch, provision verified fleet configuration at `~/.config/fleet-watch/config.json`, or export `ON_WORKER_DONE_FLEET_CONFIG` to an existing configuration file in the invoking coordinator environment. No configuration is installed automatically. The JSON object requires a nonempty `host_caps` object mapping exact native saved-environment names (or the local sensor alias) to positive integer occupied-seat limits. Optional `host_load_ceilings` maps those same names to positive finite load limits; otherwise each host's live sensor core count is the ceiling. Set `local_host` when the local sensor alias differs from the OS hostname before its first dot. Populate limits from verified routing configuration, including any existing provider constraints; the usage picker still chooses the independent provider/model, and an explicit optional policy can narrow provider/model eligibility. Missing files, unknown caps, missing native host bindings or unknown/stale load observations refuse admission. This machine's default file is absent: source tests pass with disposable configuration, while installed automatic dispatch remains unconfigured until the coordinator provisions verified limits.

Resolution briefs request `git show --remerge-diff`; all briefs require `HEAVY_GATE_TIMEOUT_SECONDS=1500`, waiting for admission, and reading exact-head Checks last. The #444 receipt parser and its original assertions remain unchanged. No installed helper or configuration is synchronized.

- `pick --role reviewer` uses Codex gpt-6.1-sol medium, Cursor composer-2.5, and Antigravity gemini-3.8-flash only. `on-worker-done.sh` accepts `--author-family codex`, drops the Opus fallback, and exits when no cross-family reviewer is allowed.

Allow remote Cursor workers through `start-cursor-worker.sh --on`, writing workspace trust in the execution environment through an Orca terminal before dispatch. Preserve local launches and stop dispatch when worktree creation or remote trust fails.

Fixed Cursor worker startup to preserve Orca `id:` and `path:` repository selectors and show worktree creation errors before exiting with the original failure status.

Fix reviewer selection to exclude the author's provider as well as the existing model-family exclusions, including Cursor and Antigravity authors. Preserve the non-zero cross-family unavailable result when no other reviewer can start.

Fix agent CLI bootstrap and remote launch readiness: install missing provider CLIs after platform setup, preserve tracked shell rc files after vendor installers, ignore vendor binaries in the legacy Linux helper directory, and report CLI and sign-in file presence without reading credentials. Add a remote worker start helper that refuses missing or unconfirmed CLI preflights, including the remote Cursor start path.

Add an agent settings backup inventory and read-only coverage audit against tracked templates and an external private manifest, restore default Claude keybindings, and remove an unused MCP server from the public Codex template and global instructions. Reject literal credentials in tracked agent settings.

Fix wrap-up terminal cleanup to use every page of the coordinator's dispatch inventory, including remote workers, when matching local and remote terminals. Preserve existing keep rules and close no terminals if dispatch discovery or pagination is incomplete.

Rearm the coordinator waiter after every completed read. `script/coordinator-waiter.sh` drains subsequent deliveries before rearming a background waiter, binds Run and dispatch in receipts, records explicit recovery states, and detects absent or crashed waiters.

fleet-watch: count builders, QA, children, and completed pending-push committers against the host cap. Confirmed push plus release frees the slot exactly once. Retained resources are classified with evidence. Paged remote inventory, retries, and duplicate observations deduplicate by dispatch and resource identity. Missing or failed remote inventory and release_unknown never authorize a start.

Verdict publication: preserve historical Verdict comments and support linked corrections via script/post-verdict.sh without deletion or edit API calls.

Paginate Run local and remote dispatches, preserve endpoint and environment and read each terminal at its issuing server. Disconnected hosts produce unknown coverage and are never healthy. Record author and verifier selected model families separately from provider, block shared families across providers and reject unknown model families.

Fix wrap-up cleanup to keep default, Pages, and protected branches locally and remotely. Refresh remote refs before planning, recheck remote branch SHAs before deleting with leases, and report counted worktree and clone keeps when lsof is unavailable.

Wrap up deletes unused branches at least 8 hours old locally and remotely on every apply, while preserving existing safety checks. The stale flag remains accepted for compatibility.

Fix Linux wrap-up cleanup when lsof is missing by checking fuser across each target tree, then falling back to proc holder links when fuser is absent. Inspection errors continue to retain items, and macOS holder checks stay unchanged.

### Fixed

- Preserve the command's exit status when macOS denies process-group cleanup after all live members have exited; continue to fail when live members remain or inspection fails.

Fix Linux cleanup checks without lsof by preferring a single scan of process holders and batching the fuser fallback with psmisc-compatible arguments. Inspect only processes owned by the current uid so inaccessible system daemons do not block cleanup; skip own-uid non-dumpable processes on permission-denied reads and processes that vanish during inspection, while keeping items on every other inspection error.

Fix directory-scanning guard selection with repeatable `--directory-guard DIRECTORY GUARD` pairs in `script/run-scoped-tests.py`. For example, a project's `.agents/head-checks.conf` test command can use `python3 "$DOTFILES_DIR/script/run-scoped-tests.py" --root web --runner 'bun test --isolate' --directory-guard src/admin src/guards/admin-copy.test.ts {files}`. Both paths are literal and relative to `--root`; quote paths containing spaces and repeat the pair for more guards. Directory descendants match by path segment, even when deleted; overlapping mappings select each guard once. Renames match the supplied paths: pass both old and new paths to cover both directories (the existing head-checks name-only diff may supply only the new path). Empty, absolute, parent-traversing or escaping paths, existing files used as directories, missing guards and guards excluded by the existing e2e/DB rules fail with exit 2 before the runner, even without changes. Deleted directories remain valid and `.` maps the root. Browser guards retain the existing availability check and UNCHECKED reporting. Without mappings selection is unchanged. This adds CLI support only; no project mapping is deployed.

Keep heavy-gate capacity occupied for cleanup survivors or unverifiable groups until positive empty or zombie-only inspection permits reclaim, preserving completed child status and rejecting quarantined nested tokens.

Fix the canonical shell guard to distinguish quoted command text from active shell substitutions and to inspect nested shell scripts. Leading standalone quoted `cat` reports remain literal data; ambiguous reports and excessive nesting remain conservatively denied. The owner approved the complete production proposal with SHA256 `40a5a5c9819a6659e1b75cadfec6d7b454b69d39628461806a2a210f4fbf5232`; installed consumers are not synchronized by this change.

QA reviewer starts now check the exact head receipt for failed Checks, zero executed tests and Bun load errors. Head checks record Bun execution counts before trimming command output and preserve those counts in capped receipts.

- `worker-finish.sh` and `worker-pane-close.sh` treat native `worker-release --json` as the only lifecycle mutation: strict boolean `ok`, CLI exit, exact requested `dispatchId`, and `state`/`processAction` before worktree removal or clearing pane records. Retained, pending, malformed, id-mismatch, and missing-dispatch receipts fail closed; dirty, conflict-unmerged, or uninspectable worktrees are kept after release, with separate status/diff/index queries that fail closed instead of swallowing errors. Worktree removal requires proven `HEAD` ancestry in trusted `origin/main` or an exact merged PR head, with merge-base exit codes captured outside `if` tests so query errors cannot fall through to PR-based removal. Pane cleanup verifies native disappearance only after one strict parse of a complete `terminal list` receipt (`ok`, `result.truncated` exactly false, nonempty `hostScope.hostIds`, empty `omittedHostIds`, and every terminal row a dict with a nonempty string `handle`); incomplete or malformed inventory preserves pane state and never prints verified closed, and generic `terminal close` is not used.

- Require unreaped-child identity before heavy-gate cleanup signals, revoke nested authorization independently of filesystem writes, and retain capacity for nested survivors and unknown inspection.

The guard-bash hook lets `set-production-secret.sh` run without the owner's approval while today (UTC) is before `pre_go_live_secrets.until` in a project's `guard-config.json`, but only for `<sha> --host prod-1 STORE_DOCUMENTS_<NAME>` or a `--copy-to-standby` run. Any other key, no `--host prod-1`, no such config key, a bad date, or on and after the date keeps the approval rule. Every other apply script keeps it.

Add remote-heavy artifact fetching with repeatable --fetch globs and --into, preserving the remote command exit status. Add remote-shot to guard the expected remote database before running a Playwright capture spec and fetching PNGs locally without copying the env file.

Cursor composer is its own model family in `usage-gate.py` and `on-worker-done.sh`, so a Cursor author no longer gets a Cursor reviewer (#502).

fleet-watch tells Elon when a PR merges, a Verdict lands, or an open PR stays failing for `pr_watch.stuck_minutes` (default 30). Add `pr_watch` to the live config to turn it on. (#504)

Cursor `check --model` no longer treats Auto + Composer headroom as allowed for models outside the Composer pool; composer-2.5 checks are unchanged.

Run the private name guard in head checks, and make its failure output show file names only so a failed run can't post a name to a public PR comment.

Finish scrubbing private project names from dated audit artifacts, changelog fragments, fleet-watch example config, mac server install paths, and the Arch Postgres pull script via untracked local overlays (#518). Move the no-project-names guard regex list to `~/.config/dotfiles/project-names.pattern` (override with `NO_PROJECT_NAMES_FILE`); the guard skips when that file is missing or empty.

Per-terminal notice delivery in fleet-watch saves state when one terminal send fails, retries only missed terminals, and logs send stderr so PR notices are not repeated on earlier terminals.

remote-heavy.sh now adds /opt/homebrew/bin to the remote PATH when that folder exists, so Homebrew tools resolve without a hand made link.

A weight 2 heavy job now gets a turn once it has waited 5 minutes (HEAVY_GATE_MAX_WAIT_SECONDS), instead of waiting behind a stream of weight 1 jobs. Lighter jobs still run until then.

A gate that dies before it publishes its process group no longer holds its slot forever. The command now starts only after its group is recorded, so a dead owner with no published group is reclaimed automatically. A slot that cannot be proved empty stays held and is named in the wait notice.

head-checks now tests a trial merge of the PR head with main, reports both shas in the receipt, and fails with a clear message on a merge conflict.

Wrap up reads the current worker list paging again and reads every Run on every Orca before closing anything, so a live worker of another Run is never closed. It now also closes a terminal where an agent sits idle after its worker finished, keeps coordinators and any terminal with output in the last 10 minutes, and closes nothing if any Run or page cannot be read.

The fleet watch, QA admission, usage gate, worker watchdog and `orca-team` pane scripts follow `nextCursor` in `worker-list` and still accept the older `page` object. Readers that decide a worker is gone or act on a terminal read every Run and fail closed on a partial read. The wrap-up skill says an agent with no output time is kept.

- The `reviewer` chain in `.orca/presets.json` now ends with Cursor `composer-2.5`, so `usage-gate.py pick --role reviewer` offers a reviewer for a Claude authored PR when Cursor is usable, and `on-worker-done.sh` no longer reports none available. The author family is still never offered.

post-verdict.sh refuses an author that is not a dispatch id, unknown or a configured coordinator id, and lead-merge.sh ignores a PASS Verdict with a bad author (a FAIL still blocks) so a valid Verdict at the same head can carry the merge.

head-checks now puts the bun and asdf shim directories on PATH before it runs the checklist, so a non-login ssh run finds bunx.

wrap-up.sh now installs the merged Orca preset right after it fast forwards the main checkout, on the coordinator and on every --fleet host. A dirty checkout or one not on main is reported and left alone. setup-orca.sh skips an identical preset and backs up a differing one before replacing it.

Fleet wrap-up now closes the terminals of each host's own Orca, and a terminal with no dispatch and no running agent is closed so its worktree can be removed. Running agents, unsettled dispatches, `lead-` worktrees, uncommitted work and the main checkout are still kept, with the reason printed.

- `lead-merge.sh` reads the Checks receipt with `main=` again, and a newer FAIL at the head blocks the merge or a carry.

QA admission reads a worktree inventory larger than 100 in full instead of refusing every start; a reply still truncated after the re-read still refuses.

lead-merge now reads every page of worker-list for current Orca, which returns the next cursor at the top level of the reply, so dispatch ids on older pages are known again. The older reply shape still pages, and too many pages still stops.

Start QA from the worker done hook when no Checks receipt exists yet at the exact head, and tell the reviewer that Checks are pending. A Checks FAIL at the head, an unreadable comment list and a bad receipt still refuse, and a reviewer who finds a FAIL receipt stops the review.

- `lead-merge.sh` can run the real `head-checks.sh` on a named host, for a batch train and for a single PR with no Checks at its head. Set `LEAD_MERGE_REMOTE_HOST`, `LEAD_MERGE_REMOTE_REPO_DIR` and `LEAD_MERGE_REMOTE_DIR`, or `head_checks_remote` in the untracked `lead-merge.local.json`. The exact commit ships through `remote-heavy.sh`, and a receipt for any other commit, or a failed ship, ssh or run, stops the merge with no receipt posted. With no host set nothing changes.

Heavy gate: a job can declare its memory with `--memory-mb` or `HEAVY_GATE_MEMORY_MB`, and that amount counts as taken while it runs, so jobs that would not fit together wait. Head checks declare 9216 MiB for the whole run (`HEAD_CHECKS_MEMORY_MB` overrides), and a check killed with exit 137 now says the run was interrupted and the code was not judged.

 Remote heavy runs forward `--memory-mb` or `HEAVY_GATE_MEMORY_MB` to the remote gate, with no default. A job that declares nothing and runs playwright (directly, through bunx or npx, or inside bash -c) now declares 8192 MiB by default, and a declared value wins. Remote head checks declare 9216 MiB too. An oversize job runs alone only among jobs that declare memory.

Heavy gate: short jobs admitted on the high-load only-long path now write declared memory into the slot, so later jobs respect the same memory budget. Drop a duplicate `re` import in `heavy-gate.py`.

Harden the scheduled wrap-up (#571). The round lock is created atomically with its pid and taken over through a guard, so two runs cannot both own it. The pane sweep keeps a record when worker-show fails, and writes pane files atomically. Every local branch delete keeps a branch with commits on no origin ref. The browser sweep keeps temp-profile browsers while a head-checks, QA or gated run is on the host, or while any dispatch there is still live. It also keeps agent-browser daemons that may be attached to a Chrome, Chrome Dev, Chromium or Edge browser outside temp (Brave and Linux Chrome are not covered). A closed PR branch with unpushed commits keeps its worktree and its origin branch too.

Scheduled wrap-up: `script/wrap-up-scheduled.sh` runs one locked, load checked round every two hours from launchd, and wrap-up now closes stale throwaway Chrome Dev, Chromium and agent-browser processes (never stable Chrome or a profile outside temp).

fleet-watch no longer types into terminals by default. Notices queue and go out as one orchestration message per run terminal at most every 10 minutes; a dead lead pane, failed dispatch, absent inbox waiter, or host over cap goes at once. Verdict notices go at once to the owning lead when an owner record exists. Runs may opt in with `"typed": true` for the legacy terminal send path. `script/coordinator-drain.sh` filters lead "Worker stopped without reporting" escalations from the coordinator inbox check; fleet-watch reports dropped counts per lead in its digest.

The usage gate hook now limits a lead's context. A session whose git worktree is named `lead-*` is warned at 150k tokens and denied plain Bash commands at 170k, except `lead-handoff.sh`, `lead-merge.sh` and `orca` commands, with a deny message that names the handoff command. The size comes from the latest usage entry at the end of the transcript. An unreadable transcript only warns, and coordinators, workers and unknown sessions are never limited.

Added script/lead-handoff.sh, which appends one line per lead handoff (branch, head, remainder, dispatch ids) to a state log and rejects incomplete entries.

Add a test that runs the real `script/head-checks.sh` on a fixture repo (PASS and FAIL, with and without `main=` and `train-heads=`) and feeds its output to the `lead-merge.sh` readers, so a change to the `Checks:` line shape turns it red.

The agent team test now runs in head checks and no longer reads this repo's own role history. The dispatch template names host roles, not machines.

Close the elon.md role gaps in the agent team template: owner updates, 5 minute rule, full Owner-Reserved list, no hand merges or Verdicts, copy, secrets, success metrics, host fill rule, and pillars and roles in the elon skill.

- `script/wrap-up.sh`: derive worktree paths from `projection.workspace.id` when `worker-list` rows omit `.workspace`, so Remote Dispatch skips still retain the path; `finish-worker` dispatch discovery matches the same shapes.

Fleet-watch stall pass: task-scoped restart records expire by TTL only (not worker list), skip stall when Orca inventory fails or worker list is empty, clear state when the worker recovers or is live, and label once after restart per Elon T4 (c). `gh pr list` failures are distinguished from an empty result so a bad lookup retries labeling instead of opening the no-PR fallback once.

fleet-watch treats `terminal_handle_stale` and `terminal_not_found` from Orca `terminal show` JSON as a missing lead pane; leads tests carry the real stale-handle stdout fixture. (#636)

- Add a GitHub hosted workflow that runs script tests mapped from changed `script/` paths, with a skip list for macOS-only and heavy-gate suites (#656).

- Stop prepending the global Claude instructions file in `script/start-cursor-worker.sh` worker briefs (#656).

Text-only pull requests merge on Checks PASS without Review or QA Verdict when every changed file (including deletions) is markdown or under `changelog.d/`, owner-gated paths include any `AGENTS.md` or `model-routing.md` and still need an Owner-approved trailer on every commit including merges, and the Cursor reviewer uses the usage-gate model (`grok-4.7-high`, never `composer-2.5`).

head-checks runs a short docs lane (name checks only) when every changed path is a doc, instead of the full test suite.

Add coordinator-publication.sh with body validation, refusal gates, bounded retries, and disposable fixture tests for engineering branch push and PR open (mingster/project-a#6676). Require github.com in origin URL parsing, merge-aware env history inspection bound to fetched destination main, host-qualified gh --repo, receipt-safe branch preflight, fail closed on push URL and history inspection errors, explicit refs/heads/main fetch without generic fallback, red-green runner proof gates, and extend red-green runner OLD SHA override.

Fix start-remote-worker so remote workers start: the preflight terminal now uses an existing remote worktree, and a failed preflight prints the host and the Orca error.

Archive and delete aged closed-PR remote branches in `clean-finished.py` when no local worktree remains (mingster/dotfiles#676).

Fleet-watch issue scan fans out one-shot rework from check, review, and rollup failures (two rounds, then `needs-elon`); workflow notices watch all workflows when `pr_watch.workflows` is omitted and label twice-failed runs. Lead-merge preflight blocks `statusCheckRollup` failures and `Review: FAIL` at the head.

Fleet-watch and lead-merge pick the newest Checks and Review receipt per head (by `createdAt`, tolerant of `main=`). Rollup rework uses `workflow_watch` from before the pass. Add `fleet-toolchain-check.sh` on elon startup and `wrap-up.sh --fleet`.

Share receipt-state between lead-merge and fleet-watch (per-kind newest; Verdict PASS does not clear Review FAIL). Fleet-toolchain resolves Orca via the same path order as wrap-up (app CLI before stale ~/.orca/cli/bin).

Wrap-up now calls `find_orca_dir` before every non-scheduled `orca` invocation so a stale `~/.orca/cli/bin/orca` is not chosen, and `update_main` passes `-c pull.rebase=false` so a host-wide `pull.rebase=true` with extra `branch.main.merge` entries cannot break fast-forwarding main. `head-checks` with `--pr` waits until GitHub's PR head matches the local branch tip (bounded by `HEAD_CHECKS_PR_HEAD_WAIT_SECONDS`) before testing that sha, and refuses with no receipt when GitHub stays stale.

Scope dotfiles `head-checks` script suites through `select-changed-script-tests.sh` with prefix and Python test mapping plus full-suite fallback for unmapped script changes, and run fast repo-wide guards before the selector.

Fix on-worker-done admission stub, issue_scan stamp isolation, and fleet-watch deliver_notices mocks.

Store post-publication checks/reviewer stamps in coordinator-local state keyed by repo and head so fleet-watch on the coordinator does not respawn when the author worktree lives on a remote builder (#683).

Start head-checks and cross-family reviewer in parallel after publication and from fleet-watch; admit remote-host builder worktrees via qa-admission repo_id.

*`review_verdict_at_head` ignores newer Checks receipts so fleet-watch does not respawn a reviewer after `Verdict: PASS` (#683).

- `test_setup.py` install fixture stubs `script/check-agent-startup.sh` so `install.sh` reaches the mocked `setup-check.sh` in unittest.

wrap-up: pane-close capture temp files are removed via `guarded_scratch_rm` so destructive-command lint in `wrap-up.test.sh` passes ([#694](https://github.com/mingster/dotfiles/issues/694)).

### Changed

* Dotfiles pull requests now rely on GitHub Actions (`script-tests` and `shellcheck`) for checks instead of spawning `head-checks.sh` through `heavy-gate.py`, `post-verdict.sh` posts a `review` commit status at the reviewed head, and the Script tests workflow installs Bun for `test_head_checks_execution.py`.

- Review starts in GitHub Actions when the unified `Checks` workflow succeeds: merge `script-tests` and `shellcheck` into `.github/workflows/checks.yml`, add `review.yml`, and port generic `script/pr-review.sh` with `usage-gate.py` cross family pick. Remove coordinator publication reviewer dispatch and `on-worker-done.sh` (#717).

- Skip macOS-only `secrets-pack` and Bun-only head-checks execution tests on GitHub hosted runners so Script tests stays trustworthy (#717).

- Give scheduled wrap-up a per-repo time budget instead of a shared round cap, and align acceptance tests (#717).

- `script/fleet-pull.sh` resets configured repositories on `agent_hosts` to `origin/main` and cleans untracked files while keeping ignored files and fast-forwarding `~/agent-state` only (#724)

Read the baseline coordinator host from `agent-state/coordinator.conf` in `script/fleet-toolchain-check.sh` and `script/install-fleet-automations.sh`, check all eleven worker tools across the coordinator and fleet hosts (`git`, `gh`, `jq`, `python3`, `shellcheck`, `bun`, `node`, `orca`, `claude`, `agent`, `agy`), exit non zero on unreachable hosts, missing tools, or unreadable versions, upgrade brew, asdf, and self updating CLIs under `--apply`, register the daily `fleet-toolchain` coordinator automation, and drop `codex` from `script/weekly-update.sh` and `docs/agents/team-reference.md`.

Route every worker start and stall restart through `script/worker-startup.sh`, fast forward the state directory in `script/fleet-pull.sh`, `script/elon-startup.sh`, `script/worker-startup.sh`, and `script/start-remote-worker.sh`, and fail `script/fleet-pull.sh` when any checkout is dirty, diverged, behind after pull, or unreachable.

Trap `EXIT`, `TERM`, and `INT` in `script/automation-precheck-wrapper.sh` so every run writes one `phase=end` trace line (`exit=143` on `TERM`, `exit=130` on `INT`) and stops the child process group on `TERM`. Bound the pane close step in `script/wrap-up.sh` with `run_limited`, stop starting new repos in `--scheduled` once the round budget is spent (logging skipped repos so the round finishes before `WRAP_UP_PRECHECK_TIMEOUT`), and install `wrap-up-scheduled` enabled at `*/10 * * * *` on every Orca host while passing `WRAP_UP_ISSUE_REPO` from `automations.env` and skipping hosts without the Orca app (#724).

Move unused scripts and their tests to `_outdated/script/` and remove stale references from live docs, head checks, and test suites (#725).

Route docs only tickets and small scripts to the Light tier, and update the Antigravity Light tier model to gemini-3.8-flash-medium.

Fix the SDLC follow-ups: ticket diagrams and docs say GitHub issues, not tickets.md, and record the owner rulings on the remaining items.

Link shared agent team hooks (`guard-bash.py`, `strikes.py`, `worker-budget.py`, `session-start.md`), helpers (`env-peek.py`, `state-of-play.sh`), and Tier 2 team skills to user level (`~/.claude/hooks/`, `~/.claude/bin/`, `~/.agents/skills/`, and `~/.claude/skills/`) via `setup-claude-code.sh`, `setup-agent-skills.sh`, and `fleet-pull.sh`, and update `templates/agent-team/.claude/settings.json` to invoke user level paths and register `guard-bash.py` on `PreToolUse` for `Write|Edit|MultiEdit|NotebookEdit`.

- Unified template hooks (`guard-bash.py` with `guard-config.json` and template path protection, `strikes.py` for Vitest, Maven, and Gradle, and `worker-budget.py` for post `worker_done` tool gating) and moved project role specifics out of `support-csm.md` into `docs/agents/team-facts.md` (`## Role facts`) (#732)

- Enforce the coordinator load and memory overflow hard gate in `script/fleet-watch.py` and `script/usage-gate-hook.py`, fail closed in `script/usage-gate.py check` when no provider is allowed, and merge `.orca/presets.project.json` over global presets.

Register daily 19:00 Asia/Taipei `staging-daily-1900` Orca automation and `script/automation-precheck-staging-daily.sh` precheck to skip when staging matches `origin/main` and otherwise wake the coordinator for staging deploy and `/staging-review` (#734).

Fleet-watch stall restarts pass `--from` using the configured `runs[].terminal` for the resolved run so `worker-start` works when the watchdog runs outside an Orca terminal; missing terminal logs `stall_no_sender_terminal` and keeps the pending record. Stall retry and worker-stop failure logs include the Orca error code when the CLI returns JSON (else the exception type name).

Narrow `team-audit.sh` script-list noise by skipping machine-setup-style names while still requiring `heavy-gate.sh` and `worker-startup.sh` when absent from the tool lists.

`script/wrap-up.sh` now verifies post removal state after worktree removal, local branch deletion, terminal close, and browser kill, recording a failure via `fail_item` if any target remains present.

Fix agent-team migration data loss, ordering, path validation, and check coverage for guard config, AGENTS.md, and legacy Tier 2 skills.

Weekly update, the sync drift precheck, skill impact report and test selection now call `agent-team.sh` instead of the retired adopt, init and sync scripts, which fixes the failing role word budget test.

The weekly update only runs `agent-team.sh check` on projects and never adopts or writes into them (`WEEKLY_UPDATE_SYNC_PROJECTS` is gone). The retired autoinit SessionStart hook is removed from the Claude Code settings, since `agent-team.sh` has no equivalent.

Rebuild `script/agent-team.sh` (`machine`, `project`, `sync`, `check`, and `all`) for one command project adoption and migration, wire `script/head-checks.sh` and `script/lead-merge.sh` to `script/agent-team.sh check`, and move `adopt-agent-team.sh`, `init-agent-project.sh`, `sync-team-skills.sh`, and `agent-project-autoinit.sh` to `_outdated/script/` (#736).

- Pane sweep no longer drops state files when `worker-list` cannot be read fully; wrap-up scheduled apply keeps `sweep: deadline reached` lines in the detail log.

`archive/*` branches are kept on every wrap-up delete path (ancestor, closed PR, patch-merged, default, worktrees-only, and `--branch`), not only in the stale loop. (#7362)

Fleet watchdog doc and script both describe a five-minute pass schedule. (#7362)

Stale cleanup no longer lists or deletes remote branches under `archive/`; they are reported as kept. (#7362)

Fleet watchdog doc: pass interval is every 5 minutes; stall labeling matches PR lookup from the worker row then branch name. (#7362)

### Changed

- `script/team-audit-metrics.ts --repo <owner/name>` now holds the weekly team audit metrics for every project. `team-audit.sh` and the drift and weekly prechecks call `agent-team.sh check` instead of the retired `sync-team-skills.sh --check`. The obsolete `agent-team-setup.md` and the 10 role draft are deleted; their still valid setup, lead-merge, wrap-up and asdf notes moved into `team-reference.md` and `orca-automations.md`.

Free host cap slots when worker-list rows have terminalState released and liveness exited, including projection.liveness.verdict on --full inventory rows.

Add `script/weekly-update.sh` (spec T17): one entry for Matt Pocock and pstack upstream, bun and Node LTS pins, and project skill gates via the four existing sync scripts. Three tested PRs plus a summary, no merge. Proof: `bash script/tests/weekly-update.test.sh`.

heavy-gate appends each admission wait with host and seconds; fleet-watch flags median waits over two minutes and stale wrap-up rounds with deduped issues.

- `script/team-audit.sh` keeps six checks (sync, budget, wording, skills, labels, receipt), drops the sdlc, script-list, ready-brief and upstream polling checks, and adds `--report` (checks plus metrics in three sections) and `--log` (the TSV observation log). `script/team-audit-metrics.ts` uses two gh calls and times builds from worker dispatch. `process-review.md` is gone (refs #741).

Reclaim heavy-gate slots when a dead owner leaves a `running` marker but inspection proves every recorded group empty or zombie-only; fleet-watch opens an issue when a slot stays held for ten minutes. (#7431)

Treat Checks receipts with global test execution counts as sufficient even when an earlier command line matches `bun test` but omits per-command metadata (for example scoped-runner lint steps).

Fail closed in `script/automation-precheck-staging-daily.sh` when the coordinator run id is absent from the fleet-watch config, warn and skip when a configured staging branch is missing on `origin`, and resolve repositories only from the fleet-pull config `repos` list plus `FLEET_STAGING_REPOS` (#744).

### Added

- Track `orca-agy.md` for Antigravity global rules, link it from `script/setup-antigravity.sh`, and verify startup instruction links with `script/check-agent-startup.sh`.

- Tell Cursor workers started by `script/start-cursor-worker.sh` to read the global instruction file in dotfiles before work begins.

Add `script/install-fleet-automations.sh` to install Orca `fleet-watch` (5 min precheck, 280 s timeout) and `wrap-up-scheduled` (2 h) on every host, enabled only on the coordinator named in `agent-state/coordinator.conf`. Private paths come from `~/.config/fleet-watch/automations.env` or env vars; tested with a fake `orca` in `script/tests/install-fleet-automations.test.sh`.

- Register `sync-team-skills-drift` (daily) and `team-audit-weekly` (Monday) in `install-fleet-automations.sh` with precheck helpers and `docs/agents/orca-automations.md`.

Register `weekly-update` fleet Orca automation, canonicalize dotfiles repo path when `~/dotfiles` is a symlink, and extend the automation scan doc. Proof: `bash script/tests/install-fleet-automations.test.sh`.

- `worker-start-check.sh` fails when an Antigravity worker is on the sign-in screen, and `worker-startup.sh` returns that failure to the caller.

Preserve standalone `CLAUDE.md` body in `AGENTS.md` before rewriting the pointer, and keep real `~/.cursor/skills` directories when only Claude symlinks collide. (#736)

Fix worker placement: per-environment repo maps, local 0.7 load-per-core bar, explicit browser brief line, and skip when fleet config is absent.

- Restructure root README for newcomers: agent team overview, task lifecycle, setup via `agent-team.sh`, and a Fleet and load section; move detailed guideline content behind `docs/agents/` links.

worker-startup.sh picks a fleet host from fleet-watch config and fleet-load when --on is omitted, with tests and a --pick-host-only dry check.

### Fixed

- Pin asdf in `test_fleet_watch_overflow.py` and `test_usage_gate.py` so `asdf-pin-coverage.test.sh` passes ([#759](https://github.com/mingster/dotfiles/issues/759)).

Fix fleet-watch stall shell test expectations after worker-startup routing.

Add review gates from #760: doc-fact-check, cross-model Verdict refusal, coordinator Cursor review, and builder self-review enforced in brief-lint, ship.sh and lead-merge.sh.

`agent-team.sh machine` and `setup-agent-skills.sh` refuse to wire the real home from a git worktree or from any path other than `~/dotfiles`, and `agent-team.sh check` fails on a machine link that points into a worktree.

Worker placement stays local when --worktree-path is given, the cursor branch passes the usage gate first, and an all-unmapped refusal says no host has a repo mapping.

- A failing or timed out load sensor now makes `worker-placement.py` return a refusal, so `worker-startup.sh` prints `worker-placement: refused (load sensor ...)` and exits 4 instead of dying with a generic failure.

Make wrap-up plan what apply does and finish the fleet cleanup itself.

A local branch counts as an ancestor only when it is also inside its own upstream, so the dry run no longer lists deletes that git refuses. The summary counts print before the pane step, and `--help` states the worst case runtime. The unpushed keep reason now gives the commit count, or says the count is unreadable. A main checkout whose only changes are untracked symlinks is clean, so it is fast forwarded.

Wrap-up releases finished workers on this Orca and every environment, and closes terminals of settled dispatches, or of worktrees this run removed, on every environment. A terminal in a worktree with no dispatch record is kept. The dry run lists each release and close. The caller's own terminal and live workers are never touched.

Only one `--apply` runs at a time (a second one prints the holder and exits 75), and each pane close call has its own short timeout (`WRAP_UP_PANE_CALL_TIMEOUT`, default 10 seconds).

Review gates derive the builder from the Verdict author, carry self-review across clean main merges, and resolve agent/model from worker-startup launch records instead of the PR body.

Merge gates match user/slug branches to worktrees, accept coordinator-built Verdict authors, and persist agent/model launch records from worker-startup on every start path.

Skip `script/tests/orca-skills-home.test.sh` when `orca` is not on PATH so hosted runners exit 0 instead of failing with command not found. Refs #767.

- Move `script/team-audit.test.sh` to `script/tests/team-audit-log.test.sh` so script test basenames are unique (refs #767).

### Changed

- Team audit skill and docs now point at `script/team-audit-metrics.ts` and `agent-team.sh` instead of the retired paths, and describe team skills as machine links (`script/setup-agent-skills.sh`) with `agent-team.sh check` reporting project copies as drift and `sync` removing them. `team-reference.md` again says `agent-team.sh project` refreshes the Token budget, Compact instructions and Owner context commands sections in `AGENTS.md`. `team-audit.md` notes per host fleet metrics are out of scope for `team-audit-metrics.ts`.

With `author=unknown`, the review gates pick the worker that has the PR branch checked out in the PR's repo, so a same-named worktree in another repo no longer matches. `ship.sh` refuses a patch-id carry over an empty or whitespace-only commit. The gaps for pre-#765 workers and unauthenticated coordinator ids are documented.

Fix the flaky default per-repo budget case in the wrap-up scheduled test by giving the round enough headroom.

wrap-up: remote shells close only at a path the environment no longer reports, scheduled rounds close them too, and start-remote-worker.sh preflight runs under POSIX sh (#774).

`agent-team.sh project` now migrates a project guard whose config block builds values from helper constants (f-strings, a list comprehension, `os.path.join`). Two new guard-config.json keys, `host_deploy_commands` and `remote_read_only`, carry the production deploy commands and remote read only patterns, and the template guard enforces them, so a migrated project allows and blocks the same commands as before.

A host the old guard's backstop named outside its config block (such as an artifact store) migrates to a new `backstop_hosts` key, so ssh, scp, rsync and git remote commands naming it still need `host` approval. An invalid `REMOTE_READ_ONLY` regex now refuses the migration instead of being dropped.

### Fixed

- `agent-team.sh project` moves a role pin forked in `.claude/model-routing.md` into `.orca/presets.project.json` and the `## Model routing` section of `docs/agents/team-facts.md` before it rewrites the file. A row that matches an older committed template is a stale copy, not a pin, and is left out. A second run changes nothing.

- An allow rule copied from `.claude/settings.json` that runs a project file the same run removes (such as `.claude/bin/env-peek.py`) is dropped with a printed `drop` line (also in the `$CLAUDE_PROJECT_DIR` and `${CLAUDE_PROJECT_DIR}` forms), since the shared copy under `~/.claude/bin` replaces it.

Fix wrap-up-detached.test.sh: pin asdf before it changes HOME, so asdf-pin-coverage.test.sh passes again.

Fix wrap-up-detached.test.sh: point it at its own state dir so a live wrap-up run on the machine no longer holds the apply lock and fails the test.

* agent-team.sh project keeps a managed hook file (such as guard-bash.py) that a kept project hook or a kept settings hook command still loads by name, and prints why. Before, the kept hook exited 1 on every Bash call (#786).

Rename a fixture directory in the kept-hook sibling test to a neutral name so the project name guard passes (refs #786).

Generated `docs/agents/team.md` no longer links `coordinator-operations.md` and `engineering-integration.md`, which `agent-team.sh project` does not copy; it names them at their template path. New test `agent-team-doc-links.test.sh` checks that relative links in the generated `docs/agents/*.md` resolve (#788).

Install dotfiles skills as individual home links, preserve tool-managed skills when migrating legacy directory links, and keep Orca orchestration outside the dotfiles checkout.

* `select-changed-script-tests.sh` always selects `script/tests/no-project-names.test.sh`, so CI runs the project name guard on every PR (#792).

A test HOME is now any HOME other than the account home, not one under TMPDIR, so TMPDIR=/Users no longer exempts the real home. `setup-claude-code.sh` and `install.sh` refuse a worktree before their first write to HOME, and machine backs up a dangling `~/.claude/settings.json` link instead of writing through it (#797).

wrap-up treats a truncated Orca worktree list as an unreadable pin lookup, so it removes nothing that depends on it. It also treats a truncated or failed Orca environment list as unreadable, so it closes no terminals. Tests now cover the truncated pin list, the truncated worker-list page and the truncated environment list.

agent-team.sh machine writes the user level roles and session hook as copies that say "this project", and project renders {{PROJECT_NAME}} in synced docs (#807).

Tests now cover that `agent-team.sh check` accepts the hook files `project` keeps for a kept project hook, and still flags a shared hook copy that nothing kept loads.

* `script/worker-startup.sh --run` appends `issue<TAB>dispatched_at` to `~/agent-state/team-dispatches.tsv` (or `TEAM_AUDIT_DISPATCHES`), so the team audit queue and build stage times have a dispatch point. It replaces the Elon prose duty in `elon-dispatch.md`, which no dispatch had followed.

- `ship.sh` refuses to ship while the latest Checks run on main is not success, unless the PR body has `Fixes main: <run id>`. `fleet-watch` tells the coordinator once per red run id. (#817)

Add script/checks-local.sh, which runs the Checks workflow's script-tests selection and shellcheck for the files a branch changed under a temp HOME, and make brief-lint.sh require builder briefs' Verify to call it (#818).

* `script/sync-pstack-template-skills.sh` copies whole upstream trees from cursor/plugins (pstack, cursor-team-kit and The Algorithm from dyl-stack) into the team template, prunes skills removed upstream, and replaces a same name Tier 1 skill (this sync replaced `tdd`). The Orca adapter moved to `.agents/skills/orca-adapter/`.

* `orca-adapter/ORCA-ADAPTER.md` is now a thin layer over pstack: tool mappings, an allowlist and gates only. Orca gate overlays for eight pstack playbooks live in `orca-adapter/playbooks/`.

* Cursor builders run on `grok-4.7-high` (`grok-4.7-high-fast` only when urgent) instead of `composer-2.5`. `usage-gate.py` allows only the Grok models, and a Grok author always gets a Claude reviewer.

* `team.md` is now a rule table: each rule names the script, hook or check that enforces it, or "none". Team rules 1 and the first half of 9 are gone; rule 8 is one line.

* Role files hold four parts in the poteto-agent style: identity, read poteto-mode and ORCA-ADAPTER.md, the pstack playbooks the role uses, and its Standing authority copied verbatim. `/elon` routes to pstack Orchestrate, and `/elon status` runs `ketchup`.

* Removed the `crew`, `team-grill-backlog`, `wrap-up` and `staging-review` team skills, which repeated pstack. Delivery now runs through `/elon` (pstack Orchestrate), the staging review is pstack `swarm` with the staging overlay, cleanup is pstack `worktree-cleanup` (`script/wrap-up.sh` stays), and `deploy` and `grill-backlog` keep only our gates. Team docs no longer restate pstack playbooks.

* `team-audit` finds mistake classes with `workflow-from-chats` over the last 7 days of transcripts and fixes each one with `/correct`. The report names the gap that only the coordinator host's transcripts are read.

* Team docs, role files and our own team skills use the pstack terms (#833): user for owner, the coordinator for Elon in prose, PR owner for builder, verifier for reviewer, unit for ticket, kickoff for dispatch brief, trunk for the main branch, user decisions for Owner-Reserved, and swarm live lanes for the staging review. Script-matched strings stay as they were: the `## Acceptance criteria` heading, the `Owner-approved:` trailer, `Countersign: Elon`, `Builder:`, labels and script names. Vendored pstack and cursor-team-kit files are untouched.

* Rename the 19:00 Orca automation to `daily-program-1900`. Its precheck now always wakes the coordinator to run the standing program from `templates/agent-team/docs/agents/daily-run.md` and skips only the staging deploy when staging equals `origin/main`. Re-install removes the old `staging-daily-1900` entry. `/elon daily run` is gone; `/elon status` stays (#834).

* `setup-agent-skills.sh` removes a broken skill link that points into a dotfiles checkout, then relinks the skill if it moved. Links into other folders are still left alone.

`fleet-toolchain-check.sh --apply` now prints each failed step with its host and last error line and exits non-zero, instead of hiding all output, including an ssh session that dies. Peers below the coordinator install the coordinator's claude and bun versions, and a peer level with or above it keeps its own; other tools still update to latest. A Mac on Apple's jq gets Homebrew jq, and peers run the toolchain bootstrap from their own home, so the Linux host no longer looks for a macOS path.

`fleet-pull.sh` now runs `agent-team.sh machine` on every host whose dotfiles pulled cleanly, including agent hosts, so the daily `fleet-toolchain` run keeps role files in `~/.claude/agents/` and `~/.claude/hooks/session-start.md` in step with the template. A failed render prints `fail <host> <repo> (agent-team.sh machine failed: <last error line>)` and the run exits non-zero.

* `fleet-toolchain-check.sh` compares peers only against the coordinator: a peer below or above it is reported, and the coordinator is no longer reported below the highest version in the fleet. The coordinator alone is compared against the latest release (#842).

`fleet-toolchain-check.sh --apply` now upgrades Orca. A peer below the coordinator moves to the coordinator's version, and the coordinator moves to latest. macOS hosts replace `/Applications/_dev/Orca.app` from the matching release zip, and Arch hosts install `stably-orca-bin` when the AUR has that version. Because the upgrade restarts Orca, a host with a live claude, codex, agent or agy process is skipped and named as `<host> apply: orca upgrade skipped, live agents: <names>`.

`mac/bin/update.sh` now upgrades a cask whose app sits in another folder than brew recorded, and both `mac/bin/update.sh` and `arch/bin/update.sh` restart Orca when the run changed its version. `arch/bin/update.sh` runs `yay -Syu` once and passes its arguments through, so `--noconfirm` runs it unattended.

Session start now runs `script/session-sync.sh` from `state-of-play.sh`. It fast-forwards the main checkout of the project and of `~/dotfiles` when it is on main, clean and behind, leaves a dirty or diverged checkout alone, and prints `session-sync: <tool> <have> is below <host> <want>` for tools below the fleet floor. The daily `fleet-toolchain-check.sh` run on the coordinator writes that floor to `~/agent-state/fleet-floor.json`. Offline hosts skip the fetch after 5 seconds and the session still starts.

Tests no longer export a git identity. They take it from a gitconfig file in their temp dir (`script/tests/lib/git-identity.sh`), and `guard-bash.py` refuses a `git commit` or `git push` signed as `test@example.invalid` outside a temp checkout. (#844)

The team rule table now holds five process gates: merge on the coordinator host, a 40 hex Self-review sha in builder briefs, database head checks on the database host, a screen read after Antigravity starts, and `orca terminal send --environment` for remote workers. lead-merge, worker-startup, brief-lint and head-checks enforce the first three.

head-checks no longer refuses when the checkout holds an old local copy of the PR branch. A local branch that is an ancestor of the PR head is ignored; a real divergence still refuses.

Scheduled wrap-up cleans up again. It no longer asks Orca to release workers that are already released or retained, which used up the whole time limit and skipped the terminal, branch protection and worktree steps. Releases now stop at half the time limit, an `ok:true` release receipt counts as released, and a dispatch on an offline host keeps only its own worktree instead of every worktree. Failed rounds now open their issue on the private `mingster/agent-state` repo by default.

A worker pane sweep that runs out of time no longer fails the scheduled wrap-up round for every repo. It is logged as a note and retried next run, while any other pane close failure still fails the run.

Head check steps now use the real python3 and node binaries, so a test that sets its own HOME no longer hits an asdf shim that exits 126.

The Orca upgrade in the fleet toolchain check now waits for the old process by pid instead of looping on `pgrep -f`, which satisfies the head-checks lint and still waits up to 30 seconds.

The Claude usage gate now renews an expired Claude login token (one minimal Claude prompt) before reading usage on hosts without a keychain, so an idle Linux runner no longer fails with `refresh failed: HTTPError`.

ship.sh now lands every PR lead-merge.sh lands, with the gates the owner kept: the verifier must differ from the builder (read from the Verdict line and a Builder line in the PR body), docs only PRs land on a cold Review: PASS, and --mechanical and --verdict-from are ported. The Self-review, builder dispatch, coordinator id and cwd checks are gone. post-verdict.sh takes --agent and --model (#866).

ship.sh is now the only merge path. lead-merge.sh, its tests and the merge train spec are removed, and every doc, playbook and role template says ship.sh. The coordinator runs ship.sh itself. Builders put a `Builder: agent=<a> model=<m>` line in the PR body and verifiers pass --agent and --model to post-verdict.sh. The local config moved from lead-merge.local.json to ship.local.json (#866).

Self-hosted runner jobs now fast-forward a clean, behind ~/dotfiles before they run, through the new script/dotfiles-sync.sh (same rule as session start). The Review workflow calls it first, and project workflows are told to do the same.

The template guard now checks role file commits in the repo that `git -C`, `--git-dir` or `--work-tree` names, reads the approval trailer from a `commit -F` message file, and reads the worker brief from a heredoc, `--spec-file -`, `$(cat f)`, `$(< f)` or a heredoc inside `$(...)`. A bug in a team gate no longer skips the production guards.

Wrap-up no longer calls worker-release again for a worker whose terminal state is already release_unknown. The summary counts those workers once as needing no action, so a round can release finished workers and close their terminals, including ones whose liveness is sleep.

A scheduled wrap-up closes a local shell that no dispatch owns once it has had no output for 60 minutes, and it closes a terminal whose worker has already ended even when worker-release has not finished. Terminal close runs before release, and each slow step has its own short time limit so one round can finish every repo.

- Builders (`fullstack-dev` and light-tier roles) pick Cursor `grok-4.7-high` whenever it is allowed, then that role's Claude entry, then Antigravity. `worker-startup.sh` refuses a Claude start for those roles while that pick stands, unless `--route-override` logs a reason. Strong roles never pick Cursor (#878).

The five minute babysit pass reads the coordinator config, refuses a config that has no runs and names that file in the log, copies the active run onto issue_scan, and takes the fullstack-dev model from usage-gate. It starts one verifier when head-checks succeeded and the head has no Verdict. The existing needs_fix rework start stays the fix worker. Owner-only paths are reported and not dispatched. (#881)

- The Cursor usage gate reads included usage from GetCurrentPeriodUsage, so the weekly ceiling counts every model that bucket lists, including grok-4.7-high, and refuses a worker model the bucket does not list. The usage-summary auto percent no longer overrides that reading. (#882)

Fleet automation prechecks and worker-startup share one PATH helper that adds the asdf shims and `/usr/sbin` when those directories exist, so a scheduled pass can find the pinned node, `lsof` for an Antigravity quota reading, and `sysctl` for placement load. The Antigravity reader also calls `/usr/sbin/lsof` when `lsof` is off PATH. Worker startup resolves a symlink repo to the physical checkout before creating a worktree, so Orca finds the registered repo. Re-run `script/install-fleet-automations.sh --install` so registered commands pick up the new PATH. A helper under `script/lib` selects the tests that reference it. (#884)

A shell whose worktree or working directory belongs to a live dispatch stays open on a scheduled round and on a manual run. A terminal close or a worktree remove that has already finished is counted as done; a session that is still open, or a worktree that is still there, is still reported as a failure.

A scheduled wrap-up closes a terminal whose liveness is sleep or exited, and a prompt with no output for 60 minutes when no unsettled dispatch owns it. A dispatch that is running, ready, pending or waiting keeps its terminal unless that liveness is sleep or exited. The prompt is the last non-empty line, so a progress line, a heading or a wait for a reply stays open.

Wrap-up closes sleeping terminals on every run, not only the scheduled round. A terminal Orca reports asleep, or a shell idle at its prompt for 60 minutes with no live dispatch, is closed. A connected agent with no dispatch record is kept as an owner session.

Role file and team.md rule row carry the board status Finish step, and a worker release with no PR sets the board status to completed (#898).

Set the Orca board status through the worker lifecycle: worker-startup.sh and start-cursor-worker.sh set `in-progress`, every brief Finish (brief-lint.sh) sets `in-review` before worker_done, ship.sh sets `completed` after a merge, and wrap-up.sh removes only `completed` worktrees. orca-board-backfill.sh (dry run by default, `--apply`) sets the status of existing worktrees from their PR state.

Fixed the team gate test briefs for the in-review Finish rule, and checks-local and CI now always run the hook tests under templates/agent-team/.claude/hooks/tests/.

`agent-team.sh project` keeps every project key and entry in `.claude/hooks/guard-config.json` and adds only template defaults that are missing. A file that is not valid JSON, or whose root is not an object, is left unchanged and the sync exits non-zero (#904).

Wrap-up keeps a connected agent with no dispatch on a fleet host, and keeps a terminal whose screen shows an unanswered question, a pending ask, or an escalation, even when its dispatch looks settled. A finished worker idle at its prompt is still closed.

The shipping script now lets a docs only PR land on a verifier Verdict PASS or PASS+NOTES at the exact head, with the same author and builder checks as the verdict lane. A FAIL Review or FAIL Verdict, or a Verdict at an older head, still refuses.

The shell guard denies globs, braces, variables, substitutions, and find or xargs that can name a restricted script or a credential directory without that path appearing as text.

agy no longer signs out after a login shell or a scripted Orca restart. A new `.zlogin` keeps `bin/agy` first in login shells, and the Orca reopen in `mac/bin/update.sh` and `fleet-toolchain-check.sh` drops the SSH variables so Orca and its terminals do not pass them on (#911).

fleet-watch: issue scan logs why it refused, babysit and issue scan send as the run's current coordinator handle, and a refusal or start failure for 3 passes in a row sends one notice. A running dispatch whose terminal has exited and released no longer holds a seat. (#915)

The owner approval file can now be root owned (#917). `script/approval-root-setup.sh <namespace>...` (run by the owner with sudo, safe to re-run, `--dry-run` shows the plan) creates `/usr/local/etc/agent-team/<namespace>/` owned by root, installs `script/approval-write.sh` as `/usr/local/libexec/agent-team/approval-write`, and sets sudo to ask every time for it. Once that folder exists, `guard-bash.py` reads approvals only from it, so a file under `~/.config` grants nothing. Each project's owner approve script must write through `sudo /usr/local/libexec/agent-team/approval-write <namespace>`.

- orca-team: the wrap-up worker pane sweep now finishes. Pane records of ended or vanished dispatches older than 3 hours (`ORCA_PANE_RECORD_MAX_AGE`, minutes) are forgotten, running dispatches are skipped without a worker-show, ended dispatches with no record are only read when one of their terminals is listed, and the Runs are walked once instead of twice. On the coordinator host a round dropped from about 410s to about 13s. The pane sweep timeout line now starts with `Warning:` and goes to stderr.

The credential folder is root owned and reached through one root owned gate (`script/secrets-gate.sh`). Receivers take the push as root over a forced command key, so the shared worker account is never on the path. Owner run setup, `secrets-sync.sh` and `env-peek.py` moved onto it. See `docs/agents/credential-folder.md`.

The shell guard lets `~/dotfiles/script/secrets-refs.sh <dir> <pattern>` name the credential folder as its pattern. It prints file and line only, never the matched text.

Add a pinned codegraph trial: `script/codegraph-setup.sh`, an opt in `--codegraph` flag on `agent-team.sh machine|project|sync|all`, a pin check in `fleet-toolchain-check.sh`, `docs/agents/codegraph.md`, and the pinned `codegraph prompt-hook` hook with `codegraph-setup.sh uninstall`. Refs #924.

* The Bash guard tests now cover that a message that only mentions the owner approval file passes by `--body-file`, stdin from a file or inline double quotes, and the denials that already hold.

After two failed Verdicts or Reviews a PR gets the `needs-redesign` label and a redesign message instead of `needs-elon` and a third patch; the coordinator closes it and dispatches a fresh worker on a new brief.

Builders hand off only on green PR checks (brief-lint requires the Finish line), ship.sh lets a wording only change merge after a Verdict, and the no project names test prints a SKIPPED line when it has no pattern file.

Every host installs the PostgreSQL client (Homebrew libpq, apt postgresql-client, pacman postgresql) and `.zshrc` resolves `psql` and `createdb` from it. Shell startup no longer sources `~/dotfiles/.env`, so API keys are not exported into every shell; `bin/with-keychain` reads them from the macOS keychain for one command (#942).

codegraph-setup wires and removes the Antigravity MCP entry in the legacy `~/.gemini/antigravity` path as well as the migrated `~/.gemini/config` path.

Add `script/approval-sign.sh` so the owner approval signing path reads the signing secret from a macOS Keychain item behind Touch ID user presence (`kSecAccessControlUserPresence`) via an on-demand Swift helper, fails closed when user presence is denied or the item is missing, and provides a one-time `migrate` command that creates the Keychain item from the existing secret file, verifies a signing run, and deletes the file (#945).

Fail closed without Touch ID: the Keychain helper no longer falls back to the login keychain, is signed with hardened runtime, and refuses to store when it lacks the keychain entitlement (#945).

wrap-up --apply now removes every non-main Orca worktree with no terminal on this host and each fleet host, keeping branches and any worktree with uncommitted tracked changes (#953).

ship.sh and fleet-watch babysit now treat `templates/agent-team/.claude/hooks/*` and `templates/agent-team/.claude/settings.json` as owner only paths, like the root copies.

ship.sh no longer carries a Verdict over an edit inside an existing code fence or a change to a top level CLAUDE.md (#956).

Antigravity workers start on an unknown usage verdict (the gate exits 0 with a note); other providers stay fail closed. The `usage-gate-pace.py` wrapper is no longer needed.

Babysit no longer starts a verifier for a PR that already has a live verifier worker, whether the coordinator started it by hand or babysit did, and retries on the next pass once that worker has finished. (#964)

fleet-watch no longer counts already released dispatches, or completed workers that pushed nothing once released, as held seats (#966).

brief-lint now runs once, in worker-startup.sh, and checks only what a person writes (Refs, Acceptance, Out of scope, Verify). worker-startup.sh appends the fixed Finish block (self-review, green checks, in-review status, worker_done) when the brief has no `## Finish`. The babysit pass no longer lints before it starts a worker (#968).

The `## Self-review` with the full head sha step is gone. worker-startup's appended Finish block and the fleet-watch rework brief no longer ask for it, `pr_review_gate_self_review` is removed from `script/lib/pr-review-gates.sh`, and the coordinator docs no longer describe it. Ship and the Verdict head match are unchanged (#969).

fleet-watch tests pin the coordinator wake path for a 60 minute inbox waiter: no alert on a live waiter, an alert after ten minutes on a dead one, and notices reach the run terminal as inbox mail. (#970)

* `script/tests/test_fleet_watch_966.py` pins host load and free memory, so it no longer fails on a busy coordinator. The freed branch in `classify_worker` now reports the real `pushed` value instead of always `True` (#971).

Babysit now logs why a worker start failed (last stderr line) in the fleet-watch log and the babysit_start_failed notice. A start refused by the usage gate or host placement (exit 3 or 4) is logged as start_deferred and no longer counts toward the failure notice.

When the local host is full, `issue_scan` in `fleet-watch.py` now starts the ready issue on the first other configured host that admits, using `--on <host>` and that host's repo id from `orca repo list --environment <host>`, and logs the placement or every host's refusal; covered by `script/tests/test_fleet_watch_979.py`.

* `script/agent-team.sh` sync and check manage `docs/agents/fleet-watch.md` once `templates/agent-team/docs/agents/fleet-watch.md` exists, so the elon-dispatch pointer resolves in a synced project (#984).

Remove codegraph: delete the trial setup script, docs, `--codegraph` option and fleet toolchain probe (not adopted, #924 closed).

Add the fleet-watch design (monitor and dispatcher split, sender identity with a GitHub fallback, one try then park, the 5 minute verifier target) with ADR 0002 and its tickets.

fleet-watch bases babysit and rework worktrees on the fetched remote PR branch, logs Orca's error message as the start reason, sends coordinator notices with a sender and drops those for terminals not in runs, and stops a failing stall restart after one retry (#986).

* Agent team guides: no step waits on the coordinator (owner 2026-11-13). The filer labels a lint-clean issue `ready-for-agent`, architect-pm owns `needs-triage` with a 2 hour limit, no hold on ready issues behind open PRs, a same-file rule (fold or blocked-by), Acceptance as a checklist with proof per item, Verdicts that walk that list from another model family, and the PR owner merging with `ship.sh`.

* Owner pauses (owner, coordinator chat 2026-11-13): the owner now approves only money rules and prices, spending and contracts, customer messages, irreversible data deletion, production deploys once a real store is live, and one look at a new feature or page before production. Role file and hook changes and weekly update PRs merge on a passing Verdict.

Usage gate rework (#987). Running workers are counted from today's `worker-list` shape, so the reserve is no longer always 0 (strong models hold 2 points, others 1). Ceilings per provider (Claude 95, Cursor included pool 100, Antigravity pools 95) live in `script/usage-gate.config.json`, read by `check`, `pick` and fleet-watch. A missing reading falls back to the last good one under 2 hours old and 10 points under the ceiling, else blocks; Antigravity with no reading is allowed in `check` and `pick`. The daily cap blocks automatic starts only (`--auto`, passed by fleet-watch). `pick` ranks non builder roles by headroom per day left. fleet-watch logs a `usage_gate_refused` line per refusal and sends one coordinator notice after 30 minutes of refusals with over 20 points of headroom. Cursor no longer shows negative headroom or a fake 100% today. Docs and ADR 0001 now match the code.

Add a single agent team command for machine setup, project adoption and safe reset previews, with configuration backups and preservation of customized roles and product facts.

Record the Orca and gh replies fleet watch tests replay. wrap-up --fleet compares a fresh scratch-run recording with that version and fails on a mismatch (#990).

Deliver fleet-watch notices to run:<id> from the sender terminal fleet watch already uses, log sent=<n> or the Orca error, and drop an unsent notice after 24 hours instead of 20 passes (#991).

Each fleet-watch pass logs started, refused, parked, failed, sent, send_failed and refused_reasons, including zeros, and the automation summary shows those counts instead of `no change`. A gate or pick refusal names its reason. (#992)

Fleet watch reads the coordinator Run and repo names from Orca and git, so the private config keeps only machine paths and host caps.

A failed fleet-watch start is tried once and parked with one notice. A usage-gate or host-cap refusal is logged and retried, and a closed PR or issue drops the parked, failed, stall_stopped and babysit rows.

- Fleet watch reruns one failed workflow once per head, reworks a pull request that stays red, and labels `needs-redesign` after two rounds. It no longer opens a `needs-elon` issue when a workflow fails twice. A red Checks run on main still sends one notice. (#996)

Fleet-watch restarts only workers it started (verifiers, rework, scanned issues) after 30 minutes without output, and reports every other stalled worker once so the coordinator recovers those with worker-watch.sh.

- `head-checks.sh` replaces a check worktree whose gitfile points at a deleted repo, and posts no Checks receipt when that worktree still cannot be replaced because nothing was checked. (#999)

* CI workflows use `actions/checkout@v7` and `actions/setup-python@v7`, which run on Node.js 24, so the Node.js 20 deprecation warning is gone.

* Agent team guard: `gh pr merge --admin` runs only while the owner's `merge` approval window is live (up to 24 hours, any PR). The template settings no longer deny admin merges outright, so the hook decides.

* Agent team guard: a command fed to a shell or interpreter where the hook cannot read it (`echo ... | sh`, `sh <<< ...`, a heredoc into a shell, `bash -c "$(...)"`, `python3 -c` or `node -e` code that starts a process) is denied, so admin merges, production pushes and host ssh cannot slip past the gates that way.

Agent team template: add the host admission rule (start a worker when load per core is under 0.7 and free memory is at least 4 GB; host caps are the ceiling) to the Fleet dispatch section of elon-dispatch.md.

- `docs/adr/0001-shared-team-skills-and-usage-caps.md` records the three tiers of skills, why team skills are committed copies, and the usage gate hook with its owner reserved thresholds.

- Matt Pocock skill setup is now automatic: a Claude Code SessionStart hook (script/agent-project-autoinit.sh) seeds docs/agents in any mingster GitHub repo that lacks them, and Cursor and Codex global instructions tell the agent to run init-agent-project.sh. The skills inventory no longer says the mattpocock-skills plugin is enabled.

agy always runs through `bin/agy`, which unsets the SSH variables so it reads the keychain token store. `pr-review.sh`, `fleet-toolchain-check.sh` and `usage-gate.py` launch it that way (#897).

### Added

- Document Antigravity (`agy`) Orca reporting and on-demand `MEMORY.md` lookup in `.agents/claude/CLAUDE.md`.

* The agent team guard hook denies any command or `Read` that names the owner approval secret file or `AGENT_APPROVAL_SECRET`, and a glob into the approval folder. Prose mentions stay allowed. The settings hook matcher now includes `Read`. Run `agent-team.sh sync` in each adopted project to pick it up.

- Set `gemini-4-argon-medium` as the default model for `elon` and `tech-lead` (Teddy), enable `statusline.sh` in Antigravity CLI settings, and count `agy` sessions in `count-agents.sh`.

- Team audit skill names the metrics the script really prints, reports unreadable sources as gaps, and keeps observations until the report is published.

- Agent team rule: every UI flow takes the fewest taps and fields. Prefill known values, pre-select the default choice, skip steps that do not apply, never ask twice. Specs name the shortest path; verifiers flag an avoidable tap or field.

Private project and host names fail at the earliest point. One checker, `script/check-project-names.sh` (arguments in, `<source>:<line>: <message>` out), is called by a `commit-msg` hook (`.githooks/`, wired by `worktree-setup.sh`), by `checks-local.sh` (branch commits, changed files and the PR title and body; a missing pattern file fails), by `ship.sh` (refuses a PR title or body with a private name) and by `no-project-names.test.sh`. The prose rule in `.agents/gemini/rules/orca-agy.md` that the check now covers is removed.

A second checker, `script/check-commit-trailers.sh`, flags a trailer line git does not parse (for example a blank line between `Owner-approved:` and `Co-Authored-By:`); the commit-msg hook and `checks-local.sh` call it, and the agent team template carries `bin/check-commit-trailers.sh` and `.githooks/commit-msg` so adopted repos get it on sync.

head-checks reuses a persistent `_checks` worktree (locked per run) so installed packages survive between runs, and the worker watchdog escalates zero live workers once per empty episode and ignores finished runs.

* `script/setup-claude-code.sh` makes `~/.claude/agents` a real directory with one link per tracked agent, so the role files `agent-team.sh machine` writes there no longer land in the dotfiles checkout as untracked files.

Add `script/clean-finished.py` to preview and apply removal of finished worktrees per wrap-up redesign issue decisions. Fetch `origin` before decisions, treat tip safety as main ancestry or cherry only, force-remove hook-only worktrees, align preview keep lines and counts with apply, archive closed pull request tips to `archive/<branch>` before deleting aged remotes, fail on Orca record removal errors, and treat detached commits on a remote branch as on a remote.

- start-codex-worker.sh starts Codex workers without the agent_readiness failure (warm-up turn first, then worker-start). worker-panes.sh continues the pane color from the panes already in the coordinator's tab. The model-routing template now points Codex starts at the script.

Add generic coordinator move scripts (new-coordinator.sh, secrets-pack.sh, secrets-unpack.sh) with tests, and a dotfiles .zshenv (Homebrew, bun and npm settings, PATH, optional ~/.zshenv.local) linked by install.sh.

Copy is approved at the spec, never at merge: write-spec, to-spec and to-tickets carry a User-facing copy table (tw, en, jp), and lead-merge.sh drops the copy-only lane, its sensitive word config and the owner copy approval check. Release-manager promotes main to staging after merges without waiting for the queue to drain (owner rule 2026-10-23).

- Add a shared coding agent session counter for Claude Code, Codex, and Cursor CLI, excluding Codex daemons and child processes and Cursor IDE helpers.

lead-merge keeps an Elon countersign across a content neutral head move (equal stable patch-id) and judges trunk drift from the current head when a verdict is retained.

Cursor runs only composer-2.5 (owner 2026-11-04). The reviewer, elon, tech-lead, fullstack-dev and other presets drop Cursor Claude and GPT entries, `usage-gate.py pick` skips any other Cursor model, and the routing template no longer names a Cursor reviewer fallback.

Cursor `grok-4.7-high` reviews Claude authored PRs when Argon is out, replacing the Composer exception.

Switch default shell from fish to zsh across installation scripts, link .zshrc and .p10k.zsh in install.sh, and install Oh My Zsh and plugins during macOS setup.

* The deploy skill (rule 10) now says the deploy stamps the version, the prepare step keeps formatting only, and production keeps the staging version.

- Shared deploy skill and team template: removed the standing go. Every production release needs the owner's explicit go, and the skill tells the owner to run the project's owner approval script (named in `docs/agents/deploy-facts.md`) with the exact command.

Batch reviewed pull requests into one checked merge train, isolate a failing change by bisection, and preserve stacked pull requests when cleaning merged branches.

- orca-team: `worker-pane-close.sh` now closes the Setup terminal and plain shells a finished worker leaves on another host, matching them by worktree path since that path does not exist on the coordinator's machine. Terminals on the repo main branch, the caller's own terminal and running workers' terminals stay open, and a local worktree with unpushed commits keeps its shells. Every Run's coordinator terminal (from `run-list`), the caller and any terminal or worktree a live dispatch uses stay open, whichever Run owns them, and nothing closes when the Run list cannot be read. A settled dispatch from another Run still has its leftovers closed.

Fleet worker counts read the address to ssh alias map from a local `fleet-workers.local.json` overlay.

- Project `docs/agents/` holds only five fixed path files; team docs live once in the template and area notes go in `docs/<area>/` (owner 2026-11-07).

- Global CLAUDE.md and AGENTS.md send area notes to `docs/<area>/`, matching the five file rule for project `docs/agents/` (owner 2026-11-07).

The template guard now carries the rules a hand kept project guard had on its own, so such a project can adopt the template copy with no loss. Two new guard-config.json keys: `force_push_branches` (branch globs a force push needs `force-push <branch>` for, added to the built in `main`, so no config can drop it; `["*"]` guards every branch) and `secrets_dir_exceptions` (the sentences the secrets dir deny shows for the scripts that may read it).

A configured approval folder is now closed to Edit and Write as a whole, not only its `approval.json`. An approval whose `expires_at` is NaN no longer counts as live. A quoted heredoc fed to `git commit -F -` is read as a commit message, not as commands. The template hook test brief now meets the current brief-lint rules, so all template hook tests pass again.

Fixed: the head-checks database step no longer forwards the calling Mac's PATH and HOME to the database host.

- `fleet-watch.py` and `coordinator-publication.sh` retry `head-checks.sh` until a Checks receipt exists at the PR head; a spawn stamp or detached start alone no longer blocks later passes.

- `receipt-state.py` adds `checks-receipt-at-head` for publication gating.

Retry worker pane and terminal cleanup until handles are verified gone, preserve pending cleanup records, and sweep ended workers on wake without closing running dispatches.

Team and shared skills now call Orca and Matt Pocock procedures instead of repeating them, while keeping project roles, delivery gates and command aliases.

Elon dispatches merge workers for landing PRs (including docs-only mechanical lane); workers commit locally and never push; threads-only rework commits for Elon publication.

* The team guard, `release-manager.md`, `release-manager-work.md` and `env-peek.py` now name the per machine tool, `python3 "$HOME/.claude/bin/env-peek.py"`, instead of the project copy that a project sync removes.

The template guard has a new `guard-config.json` key, `exact_only_scripts` (a list of repo relative script paths). A project lists a script that handles its own credentials and prints no value; the script then runs only as the whole command: its path (from the repo root, or absolute in this repo), then plain arguments with no newline, `$`, backtick, `;`, `|`, `&`, `<`, `>`, `(`, `)`, `{` or `}`. The script may appear only as the first word, so any wrapper program, env prefix, pipe, redirect glued to the path, look-alike path or symlink to the script is denied. Direct reads of the credential dir stay denied, and a project without the key sees no change. The loader drops an entry that contains a NUL, or whose path cannot be resolved. If the rule itself errors, the guard denies the command.

Faster delivery review loop: on-worker-done requires exact-head Checks PASS before QA, emits needs-author on FAIL, and reviewer briefs cite the receipt instead of rerunning tests; sync fullstack-dev, qa-sdet, team-audit, and engineering-integration templates from project-a #6730/#6731.

### Fixed

- orca-team close scripts read the flat worker JSON of current Orca (state, stage, liveness, terminal, workspace), with the older nested shape as a fallback. A worker that `succeeded`, or whose stage is `released`, or whose liveness is `exited`, now counts as finished, so its pane closes itself.

- After a confirmed release, `worker-pane-close.sh` again closes the leftover coordinator pane and the worker's Setup terminal. It never closes the agent terminal (native release owns it), the caller's own terminal, or a terminal of a live dispatch.

- `worker-panes.sh`, `worker-watch.sh`, `worker-finish.sh`, `wrap-up.sh`, `merge-cleanup.sh` and `worker-watchdog.sh` read the same flat rows.

setup-review-runner.sh takes the runner dir as an optional third argument instead of a fixed project path.

Fleet watch opens one issue when the agent-state backup has not pushed for 30 minutes.

Fleet watch reruns a failed Checks or Review run once, then opens one issue.

Tests set `FLEET_WATCH_LOG_PATH` so fleet-watch passes append to a temp log instead of the default path under the test home. `script/team-audit.sh` script-list reads path lists from `TEAM_AUDIT_TOOL_LISTS` (unset skips with a NOTE); matching uses whole basenames only. Stall restarts now pass `--run` with the worker-list run id so `worker-start` is not resolved against the wrong Run; pending retries persist that id, and legacy pending rows without it use the single configured run when there is exactly one.

Fleet watch skips opening a duplicate GitHub issue when an open issue already matches the fixed stale backup title, so one incident stays at one open issue. (#7363)

fleet-watch validates inbox message and worker list elements before `alerts()`, clears the Orca skip latch only after a successful `alerts()` return, and resilience tests assert workflow checks and one skip line over two passes on malformed records. (#7363)

When Orca inbox or worker inventory fails, fleet-watch still runs backup and other non-worker checks and emits one skip notice instead of aborting the pass. (#7363)

Add `script/worker-startup.sh` for daily host checks (fast-forward main, node and bun pins, conditional bun install) and `--run` to start workers via Orca, with `script/tests/worker-startup.test.sh`.

Harden pin handling: compare node before requiring asdf; one state file per lock path and `bun install` only where the hash changed; bun install fetches with an explicit `curl` (override `CURL`) so failures are visible without `pipefail`; usage gate runs via `PYTHON` (default `python3`) and optional `USAGE_GATE_CLI`.

Add optional `issue_scan` to `fleet-watch.py` (off by default): start one ready issue per pass when gates pass (P0, P1, then FIFO) via `worker-startup.sh`, one rework worker per review-failing PR head, and a team-grill-backlog sweep pair when the ready queue is under 3 and the last sweep is over 2 hours old; covered by `script/tests/test_fleet_watch_scan.py`.

lead-merge accepts an owner copy approval when the head moves without a content change (matching zero context stable patch id).

The agent team grill gate now reads `dotfiles#<n>` in the dotfiles repo (set `DOTFILES_REPO` to `<owner>/dotfiles`) and also checks `start-cursor-worker.sh` briefs.

`agent-team.sh project` now accepts `HOST_DEPLOY_COMMANDS = set()` as an empty host deploy map, and a `REMOTE_READ_ONLY` value that is a union of literal command name sets. Those names are stored as `remote_read_only_commands` and the template guard adds them to the shared read only defaults. A regex `remote_read_only` list still replaces the defaults. An empty host deploy set is omitted.

Fix heavy-gate calibration to base the load limit on total CPU cores and discard a timed warm-up copy before measuring slot capacity.

Preserve completed command exit status when process-group cleanup fails; log the child status before cleanup and report remaining process details on stderr.

The team Bash guard now blocks direct heavy test, type check and build commands with a weighted heavy-gate rewrite. Team guidance requires at least 20% free memory and routes test commands through the gate.

Add a configurable 20-minute wall clock limit to heavy-gate commands with process-group cleanup and timeout exit status 124.

Add persisted hardware calibration and a shared weighted job gate for heavy commands and repository head checks.

The usage gate hook refuses a direct remote `worker-start` and repairs the preset link before reading roles.

- start-codex-worker: the real Codex hooks prompt lists no file paths, so trust it by matching the "N hooks are new or changed" count to the commands in .codex/hooks.json, still only when those files match origin/main.

start-codex-worker.sh trusts the Codex "hooks are new or changed" prompt only when the hooks files and the files they run are identical to origin/main; otherwise it selects nothing and exits 4 with the diff.

The agent-team guard hook accepts a `host` approval record of up to 336 hours (other scopes except `merge` stay at 30 minutes), so a project script can offer `host <hours>`.

The merge gate lets a PR that marks an intent Accepted merge when every commit touching that intent file carries an `Owner-approved:` trailer. Without it the refusal names the trailer.

Restore two release guard rules ("reformulate", "discretion") in the release-manager role template that earlier word-budget trims dropped, and update the release guard check to match the deploy skill's current "Elon copies these" wording.

- Raise the tech-lead early handoff limit to about 150 calls or 170k context.

### Added

- `script/lead-merge.sh` lets the Tech Lead merge reviewed PRs under strict checks, with a Codex allow rule template in `templates/codex/lead-merge.rules` and owner setup steps in `docs/agents/team-reference.md`. The Tech Lead template now merges only through it.

Add mac/install_mac_server.sh to install agent team software on macOS servers using Homebrew and asdf, skipping personal applications, and applying macOS server tune-ups including power recovery, sleep prevention, network ordering, and global spotlight disabling.

- install_mac_server.sh now covers the gaps found setting up the coordinator Mac as the main fleet host: starship, zsh-completions and libpq (psql, createdb for head-checks) are installed, insecure zsh completion directories lose group write, the node pin of the project-a and project-b checkouts is installed, Remote Login is turned on, sudo asks once up front, and the script ends by listing the sign-ins left to do by hand.

- Matt Pocock skills synced to upstream 6fd9479 (plugin 1.3.1): six skills updated, retro added, the CONTEXT.md naming and the to-tickets contract sections kept. Codex model routing set to gpt-6.1-sol medium (workhorse, strong) and gpt-6-luna low (light). init-agent-project.sh now works inside a git worktree.

Mechanical lane for the Tech Lead: `lead-merge.sh --mechanical` accepts a pure substitution or deletion diff with Checks PASS instead of a Verdict; tech-lead.md gets a short section.

- `docs/agents/persistent-memory-protocol.md` template now describes the `active_run.md` ledger (product neutral) instead of `task_plan.md` and `progress.md`, matching crew.

- lead-merge.sh now cleans up after the MERGED read-back through the new script/merge-cleanup.sh (PR head branch and worktree, ticket lanes for the same issue with dirty diffs saved to ~/orca/workspaces/_ref, recovery/* older than 7 days) and script/worker-finish.sh (release, pane close, worktree removal). DRY_RUN=1 previews. wrap-up.sh stays the weekly safety net and logs findings to ~/.claude/state/team-observations.md.

lead-merge accepts a `Checks: PASS head=<V>` comment for a later head when every commit after V is a clean merge of main, reusing the Verdict carry check. The team templates now run tests and type checks once in head-checks, tier the review, and let head-checks run on any fleet host.

Fleet-watch host admission no longer counts settled worker rows without a seat as occupied, so a host with one live worker is admitted or overflows (#1155).

Fleet-watch shell and audit tests redirect pass logs via `FLEET_WATCH_LOG_PATH` (or isolated HOME for stall). Embedded tests prefer `/usr/bin/python3` when present so broken `python3` shims do not fail CI. Leads test stubs `read_orca_inventory` so a vanished lead pane does not fail the whole inventory path. Audit guards invoke `worktree-idle` with `sys.executable`.

- Fold worker stall and agent-state backup logging into `fleet-watch.py`; remove `worker-watchdog.sh`, its plist and test.

Release managers run the facts' masked env check as a standalone Bash command, with an exact project permission and every Read deny preserved.

Only the coordinator marks `needs-redesign`. A worker that sees a second failed check, Verdict or Review stops and notifies the coordinator instead of labeling the PR.

On a redesign request the coordinator first grills with architect-pm for the root cause and the owner decisions, then closes the PR and dispatches the redesign.

* Review docs now say the coordinator never posts a Verdict or Review line, and that a code or script PR gets one verifier that runs the change (parent against head) without re-reading the diff or re-running the tests Checks already ran.

* The fleet Node pin is back on the latest Node.js 24 LTS (24.22.2), and `fleet-toolchain-check.sh` takes "latest" Node from the pinned major only, so a newer LTS major no longer flags hosts on 24.

Stop tracking Orca-bundled skills (orca-cli, computer-use, orca-per-workspace-env). Setup installs them with `orca skills install --all`, and the collision check rejects copies of bundled names.

* `fleet-toolchain-check.sh --apply` now runs `orca skills install --all` on every fleet host, so the daily `fleet-toolchain` automation installs and updates the bundled Orca skills.

Move custom Orca worker panes, cleanup, monitoring helpers and tests into the `orca-team` skill so Orca can install and update its official `orchestration` skill. Update team instructions and audit checks to use the new helper paths.

- worker-pane.sh now closes its own terminal about 10 seconds after its dispatch ends (completed, failed, cancelled or released), through ORCA_TERMINAL_HANDLE, so a pane whose split timed out after the screen saver no longer stays open. worker-pane-close.sh stays the main path. Removed the stray empty orker-panes.test.sh.

Refuse Strong tier roles in `start-cursor-worker.sh` and document that architect-pm and peers must start via usage-gate pick and orchestration worker-start, not Cursor.

- Tech lead template now spells out the merge criteria for PRs.

- Agent team architecture doc refreshed to match the current setup.

Pre-build grill gate (owner 2026-11-02): team.md, elon-dispatch, elon role, crew Step 1 and sdlc-skill-map require category grills with Elon and explicit owner approval of all grill results before UI, code or money implementation.

Worker starts now repair a drifted Orca preset: `~/.orca/presets.json` is a link to dotfiles, not a copy.

Clarify lead standing authority, premise checks and strike counting, owner approval for competing prototypes, and owner requested team audits with structural fixes and delivery metrics.

- Remove the Tech Lead role: Elon dispatches and merges once per wake, the lead context limit and lead handoff are gone. The usage gate now fails closed, and Cursor and remote worker starts pass through it.

Adopt pinned pstack principles and poteto-mode through the Orca engineering adapter, preserving publication and release gates.

QA admission now counts workers across every Run in the runtime (paginated run-list plus per-Run worker-list), so a Run-scoped worker-list no longer causes a false refusal. Incomplete pages, unknown scope, duplicate dispatches and unavailable remote inventory still refuse.

- README now states the team guideline only: goal, principles, targets, lifecycle, roles, owner decisions, review and tools.

README rewritten as a user guide for new readers; the long agent team reference moved to docs/agents/team-reference.md.

Add a ready-brief check to team-audit.sh: open ready-for-agent issues must carry Acceptance criteria, Requirement owner, Done condition and Deleted in one text, with a team-audit: allow opt-out.

New `script/remote-heavy.sh` runs a heavy job (type check, tests, Playwright) for the current commit on another host under that host's heavy-gate, so a busy laptop can hand the work off.

A remote worker start now updates dotfiles and the preset link on the target host first.

- Codex is retired from the agent team. Implementation runs Claude first, then Antigravity (`gemini-4-argon-medium`), up to 3 lanes. Removed the Codex reader, refresh and `--avoid-provider codex` from `usage-gate.py`, the launcher handling from `usage-gate-hook.py` and the Cursor hook, `start-codex-worker.sh`, `setup-codex.sh`, `.codex/` and `templates/codex/`. Added a `gemini` family to the usage gate and `on-worker-done.sh`. Rewrote the routing in `templates/agent-team` and the repo `.orca/presets.json`.

- Remove Oh My Zsh and its plugins from the shell setup. Starship is the only prompt tool, and compinit now runs on every host.

`setup-review-runner.sh` installs or repairs a macOS runner, removing the session setting that hid the login keychain from `claude`.

remote-heavy creates a missing remote --dir as a detached worktree of --repo-dir, so a new lane needs no manual setup.

Adopting the agent team now installs the four role pages (architect, Elon dispatch, QA, release manager) that role files point at, and the role word budget test checks the release manager rules in the page that holds them. The release guard rules test now runs in the head checks.

Trimmed elon, fullstack-dev, qa-sdet and release-manager role files under the 800 word budget by deleting text that restates team.md, model-routing.md or AGENTS.md.

Worker finish runs head-checks first and refuses worker_done on a failing head (`--skip-head-checks "<reason>"` for docs only); role rules for head-checks, test iteration, issue premise.

- Removed project names, paths and hosts from the tracked agent configs (`.codex/config.toml` trust entries, Claude `autoMode.environment` lines, Antigravity CLI trusted folders, IDE spell words) and dropped the temporary exclusion list from the no-project-names guard. The values now live in untracked overlays: `settings.local.json` for Claude, Antigravity CLI, Cursor and Antigravity IDE (the IDE ones through the new `script/apply-ide-overlay.py`, which keeps the JSONC file byte for byte), and `.codex/config.local.toml` appended once by `setup-codex.sh` when it first creates `~/.codex/config.toml`. `link-cursor-user.sh` and `setup-antigravity.sh` write a rendered copy instead of a symlink when an IDE overlay exists.

- Removed project names, hosts and company ids from the public tree: docs and tests use placeholders, dated project reports are deleted, per machine values move to untracked `*.local.json` overlays (`script/apply-local-overlay.py`), and `script/tests/no-project-names.test.sh` guards it.

- Removed the local account name from the protected configs: the Codex config template and the lead merge rules template use `__HOME__` (rendered by `setup-codex.sh` and the README `sed` line), the Cursor hook commands use `$HOME`, and the Antigravity CLI trusted folder moves to the untracked `settings.local.json`. The guard's temporary exclusions are gone.

- Removed the local account name from tracked files: shell and git configs use `$HOME` or `~`, the Claude Desktop and iTerm2 exports no longer carry a home folder (setup renders `__HOME__`), the retired obsidian vault doc, a shell history dump and a fish config backup are deleted, and the no project names guard now rejects the account name too.

- setup-cursor.sh keeps the cursor-agent login (authInfo) when it copies the CLI config. A plain copy logged cursor-agent out on every run, including agent-team machine and the install scripts.

* `worker-startup.sh` skips `bun install` for a brief with a `Setup: none` line and only fast-forwards the new worktree to `origin/main` (`worktree-setup.sh --git-only`). Remote hosts keep the install.

ship.sh `--verdict-from` accepts a generated team copy PR that also deletes a canonical role file or an unkept shared hook, the paths `agent-team.sh check` flags. Any other non generated path is still refused.

The verdict lane of `ship.sh` accepts a generated team copy whose bytes match the template render at dotfiles `origin/main`, including the project name substitution `agent-team.sh` uses, and a deletion of a generated copy that `agent-team.sh check` demands. A copy that differs from that render is still refused.

- Team skills (elon, ceo, crew, tl, deploy) now have one product neutral source in `templates/agent-team/.agents/skills/`; `script/sync-team-skills.sh` writes them into a project as committed generated copies and `--check` fails on drift. Product facts move to each project's `docs/agents/team-facts.md` and `docs/agents/deploy-facts.md`.

- `orchestration` (with `worker-watch.sh`) and `to-tickets` are reconciled in the shared skills tree; the remaining mattpocock skills are vendored from plugin v1.2.3 and the plugin is disabled, and `~/.cursor/skills` is no longer recreated, so no skill is listed twice.

- Skills inventory for the <project-a>, <project-b> and template agent teams, with a dedupe and symlink migration plan (`docs/agents/skills-inventory.md`).

- Trimmed the shared skills tree from 60 to 31: removed copies of Cursor built in skills and four unused Matt Pocock skills, and synced Matt Pocock skills to upstream 49dd158.

- Add hostname to Starship right prompt in Tokyo Night style.

- Replace Powerlevel10k with Starship across macOS, Arch, and Debian setups, remove .p10k.zsh, initialize Starship in .zshrc, and alias ls with color support.

- Add Starship Tokyo Night preset configuration and link it in install.sh.

Team audit 2026-10-23 (closing pass): team docs carry the owner rules for one PR per fix batch, at most 2 heavy jobs under load 12, explicit branch pushes and head-checks commands in every brief; Elon clears a jammed merge queue himself instead of cutting the lead's lanes; the tech-lead sends decisions as tagged escalations; Elon's wake checklist moves to coordinator-operations.md.

* fleet-watch alerts once when a configured lead pane is gone (`leads` in the private config). The worker-start hook and both start wrappers refuse an empty `--spec` before calling Orca. `start-cursor-worker.test.sh` resolves python before changing HOME, as #359 did for the other tests. Model routing: `outcome_unknown` counts as a failed start, and the Cursor start rule uses the wrapper in every project.

Team audit: preserve Verdict history, count pending-push host slots, rearm inbox waiters, require partial-mock and reviewer-family evidence, and stop repeated failed premises. Shared role references retain owner policies while reducing duplicate context.

- Correct team audit lifecycle, ledger and copy-approval contradictions; sync canonical review/cleanup guidance and record role, capacity and metrics evidence with explicit outstanding gates.

Team audit 2026-11-01: condense elon, qa-sdet, and tech-lead role files; align Cursor presets with composer pool; harden QA admission tests; deploy skill Playground gates; benchmark-checklist and bro skills synced.

Team audit 2026-11-04: the coordinator is the first host for workers and coordinators, the wake loop watches reviewers on every run, and lead-merge runtime and reviewer chain rules are written down.

Owner answers applied: leads start no worker on any fleet host, regression runs on the headless host (project-a), Cursor gpt-5.6-sol-high joins the reviewer chain last, Elon gets a standing grill approval for tickets with no money, auth, schema change or new UI page, and the grill hook reads the real worker brief.

* `script/fleet-watch.py` still starts a verifier for a PR on an owner-only path. It reports the path once per head, and only the ship waits for the owner.

* `script/worker-startup.sh` refuses a builder brief for a backlog line (`#<issue> L<n>`) that a merged PR title already carries.

* The coordinator skill reads the task and worker lists before it answers a status or recap question.

- Team audit skill no longer calls the metrics script a dry run.

- `script/team-audit.sh` check `mp-upstream` flags vendored Matt Pocock skills that fell behind upstream, and `script/sync-mattpocock-skills.sh` refreshes them while keeping the local `CONTEXT.md` naming and `to-tickets` edits.

Elon now verifies actual worker task progress and owns recovery through checked delivery. Team routing preserves unknown process states and defers lifecycle transitions to native Orca evidence, replacing premature retry and shared-path cleanup instructions.

- Agent team role files, model routing, team skills and the architecture overview rewritten to be concise: the commit, push and merge owner rule and the worker launch steps now live once in `.claude/model-routing.md`, with one line pointers elsewhere.

- Team templates and create-pr gain the 2026-10-07 lessons (Codex start check, Cursor quota, heartbeats, clean PR bodies); skills inventory notes the Codex description budget.

- Agent team: team-audit.sh flags role-file commits from 2026-11-03 without an Owner-approved trailer (receipt check, test added); grill gate exemptions; heartbeat rule moved to the drain; worker-budget hook skips sessions without a worker brief.

- `worker-finish.sh` skips head-checks when the worktree head is already in `origin/main` or its PR is merged, so post-merge cleanup no longer blocks on the heavy gate.

- `worker-watchdog.sh` no longer nudges or escalates a terminal that waits on a background shell or monitor, or a coordinator with an armed `orchestration check --run <run> --wait` waiter.

The worker turn budget hook no longer warns or stops the Tech Lead (lead-* worktrees). Workers keep 120 and 200.

Cleanup scripts keep the lead-queue worktree. lead-merge refuses Verdicts whose verifier or author dispatch id is unknown to Orca, and the countersign trigger for test.todo needs a word boundary.

- Agent team release evidence stays in ignored local folders, durable results go in release PRs or issues, and raw logs are deleted after production or a superseding attempt.

### Changed

- Agent-team templates assign push, pull request creation and merge for engineering, sales, PM and docs branches to the Tech Lead. Workers commit locally; Elon retains priorities and owner approval decisions.

to-tickets bundles slices under about 30 minutes of work in the same area into one ticket, since start, review and merge overhead outweighs that much work (owner rule 2026-10-23).

- The usage gate's daily cap is no longer a fixed 12% of the week. It is what is left of the week under the 95% ceiling at the start of the day, divided by the days left until the weekly reset. `--cap N` still fixes it.

- Usage gate now also covers coordinators running in Cursor and Antigravity: `ide/cursor/hooks/usage-gate.sh` adapts `usage-gate-hook.py` to Cursor `beforeShellExecution` and Antigravity `PreToolUse`, and `setup-antigravity.sh` merges the Antigravity hook into `~/.gemini/config/hooks.json`.

Fixed the usage gate to read Cursor's Auto + Composer pool percentage and billing cycle reset, with desktop and cursor-agent credentials on macOS and Linux. Missing pool usage remains unknown; aggregate and API usage do not affect the verdict.

- usage-gate: a rejected (401/403) Cursor token from a stale desktop install no longer hides a valid cursor-agent CLI token; the reader tries the next credential store.

- `script/usage-gate.py` now gates Cursor like Claude and Codex. It reads the plan usage percentage and billing cycle end from the Cursor dashboard summary (using the session the app already holds, never printed or stored) and applies the same daily cap, 95% ceiling and per-worker reserve over the cycle. The hook gates `--agent cursor`.

- `script/usage-gate.py`: a provider without a reader (cursor, antigravity, ...) and a reading older than 6 hours now count as no reading (exit 4), and the codex reader also finds the weekly window under `secondary`; tech-lead template drops the nonexistent `dispatch-worker.sh`.

- `script/usage-gate.py`: a reading older than 6 hours still blocks on the weekly ceiling while its `resets_at` is in the future (weekly usage cannot fall before the reset); it only stops counting for the daily cap. Past the reset it is no reading (exit 4).

Usage gate reads the keychain when the Claude credentials file holds an expired token, so a Mac with an old file still gets a fresh reading.

- `script/usage-gate-hook.py` PreToolUse hook enforces the usage gate on every claude or codex `worker-start`, wired into the agent team template.

Correct Antigravity quota mapping to keep Gemini Flash, Gemini Pro/Argon, and Claude pools separate, with Gemini Flash as the default check. Ignore ambiguous legacy Gemini banners. Report Cursor Composer 2.5 usage as unknown with a dashboard instruction when its allowance cannot be verified, rather than substituting aggregate plan usage.

Usage gate publish copies the Claude reading, numbers only, to hosts that cannot read it, renews a token with under an hour left, and accepts readings up to 15 minutes old. Fleet watch runs it for hosts in usage_hosts.

- `script/usage-gate.py`: "used today" now counts from the start of the local day (codex: last event before midnight, a week that began today counts from 0; claude: first statusline reading of the day, written by `statusline.sh`) instead of the first gate check; codex readings pick the newest event by timestamp instead of file name; a start is refused when used today plus a reserve of 1% of the week per running worker (`--reserve`) reaches the cap or ceiling; `show` prints one table of every provider with local reset times (`--json` for rows); the hook message gives the reset in local time. Role files, model routing, ADR and architecture doc updated to match.

lead-merge now carries a PASS Verdict across a clean merge of main (only merge commits of main after the Verdict head that replays cleanly to the same tree), so merging main no longer forces a re-review. The team doc also states a cap of 6 open PRs per project.

lead-merge.sh: `--verdict-from <owner/dotfiles#N>` lets a configured repo PR made only of generated team copies (and passing `sync-team-skills.sh --check` at its head) merge on the Verdict of the matching merged dotfiles PR. worker-panes.sh now refuses a missing anchor terminal before splitting.

lead-merge.sh: `--verdict-from` also refuses unless the dotfiles `templates/agent-team` matches `origin/main`, so an unmerged template cannot vouch for its own generated copies.

The worker watchdog now takes `--all-runs` instead of hard-coded run and coordinator IDs: it discovers every run with a live worker each cycle and escalates to that run's own coordinator. It also escalates worker_done, escalation and question messages left unread for 5 minutes, and when a send fails it writes the alert to `~/.orca/state/worker-watchdog/alerts.log` instead of failing silently.

- worker-watchdog test: every assert now goes through a counting check helper and the suite exits non-zero with a pass and fail summary, since a failed bare `[[ ]]` does not stop macOS bash 3.2. Four stale asserts that still expected a coordinator nudge now expect only the worker nudge.

- orca-team: `worker-pane-close.sh --release <id>` releases a validated worker, marks it released and closes its terminals. The sweep (run by wrap-up) now closes a marked worker even while its worktree still exists, so Codex workers on external terminals no longer pile up after release.

- orca-team: `worker-panes.sh` no longer opens a second pane for a worker whose recorded pane is still open. Each run with no ids used to add one duplicate mirror per running worker (36 mirrors for 4 workers on 2026-10-26, each polling Orca).

Close leftover worker shell terminals in created or reused linked git worktrees while protecting main checkout sessions.

- The agent-team template role files (elon, tech-lead, crew) now say to rename a worker terminal only after "Setup succeeded", open its pane with worker-panes.sh, and close it with worker-pane-close.sh after worker-release.

Worker watch now flags idle input prompts and Antigravity network stops with exit 4, preserves busy screens as OK, and tells coordinators to resume affected workers immediately.

- Make daily usage caps advisory pacing hints; only fresh provider weekly/cycle usage plus running worker reserve can block starts, with refresh attempts, explicit unknown failures, and source/age reporting.

- Add a 90-second Orca worker watchdog with idle nudges, cooldowns and coordinator escalations, plus an optional KeepAlive launchd template and install instructions.

- `wrap-up.sh` no longer keeps every worktree because of a dispatch on a host this one no longer pairs with.

Wrap-up no longer keeps a worktree whose only change is the `.remote-heavy-lock-sha` install stamp.

- `script/wrap-up.sh` is now the one wrap-up tool. `--scheduled` replaces `wrap-up-scheduled.sh`, `--branch` replaces `merge-cleanup.sh` and `--finish-worker` replaces `worker-finish.sh`; those three scripts and the scheduled config file are gone.

- A scheduled round takes its repos from `orca repo list` (only those with `.agents/head-checks.conf`) and its load limit from the cores (skip at 0.7 per core), finds the orca CLI in a bare environment, writes one line per round, and opens one GitHub issue after two failed rounds in a row, on the repo in `WRAP_UP_ISSUE_REPO` (unset opens none). A round over 4 minutes is a failure.

- Env names moved: `MERGE_CLEANUP_CALL_TIMEOUT_SECONDS` is `WRAP_UP_CALL_TIMEOUT`, `MERGE_CLEANUP_PAGE_SIZE` is `WRAP_UP_PAGE_SIZE`, `WORKER_FINISH_ARCHIVE_DIR` is `WRAP_UP_ARCHIVE_DIR`.

* `mac/system_setup.sh` adds the asdf shims to `~/.zprofile` after `brew shellenv`, so non interactive login shells (scripts and agents) resolve `python3` and `node` to asdf instead of Homebrew.

### Added

- `AGENTS.md` single-source convention: `AGENTS.md` at the repo root, `CLAUDE.md` a one-line `@AGENTS.md` pointer, area-specific content in `docs/agents/<topic>.md`

- `docs/agents/` docs: `agent-files.md`, `issue-tracker.md`, `triage-labels.md`, `domain.md`, `obsidian.md`

- `script/init-agent-project.sh` to scaffold `docs/agents/` per project for the engineering workflow skills

- Engineering workflow section in `.agents/claude/CLAUDE.md` (five-stage grill/spec/tickets/implement/review loop)

### Changed

- `script/setup-claude-code.sh` now copies `~/.claude/CLAUDE.md` instead of symlinking it (cowork sessions skip a symlinked global memory file)

- Root `CLAUDE.md` reduced to `@AGENTS.md`; architecture and conventions moved into `AGENTS.md`

- `.agents/claude/settings.json`: emptied `enabledPlugins` (removed the `mattpocock-skills` plugin, whose skills are all vendored under `.agents/skills/`, plus three stale entries)

- Trimmed the derivable `.agents/` directory tree from `AGENTS.md`

### Changed (earlier)

- `create-pr` skill now writes a CHANGELOG.md entry before committing, using Keep a Changelog format
