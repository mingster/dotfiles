# Labels

Every label the team uses, in one place. One set of 20 issue labels serves every repo of the team. `script/fleet-watch.py` reads it to pick, order and route work without a coordinator turn. A normal ready issue carries only `ready-for-agent` and `P2`, and every open issue carries a state and a P label (Gate at filing). The script code is the source of truth: when a script and this page disagree, the script wins and this page is the bug.

Each table row names the label, what it means, who sets it (a role or a script, with the file), when, and what happens next.

## The five canonical triage roles

The Matt Pocock skills (`triage`, `to-spec`, `to-tickets`) speak in five triage roles. This table maps them to the label strings used here. When a skill mentions a role (for example "apply the AFK-ready triage label"), use the label string from this table.

| Role in the skills | Label here        | Meaning                                              |
| ------------------ | ----------------- | ---------------------------------------------------- |
| `needs-triage`     | `needs-triage`    | The maintainer needs to evaluate this issue          |
| `needs-info`       | `blocked`         | Waiting on a reporter, a vendor or another repo      |
| `ready-for-agent`  | `ready-for-agent` | Fully specified, ready for an AFK agent              |
| `ready-for-human`  | `owner`           | Waits on the owner                                   |
| `wontfix`          | none              | Close the issue with the reason "not planned"        |

## State (4)

An open issue without a hold label carries `needs-triage` or `ready-for-agent`, never both.

| Label | Meaning | Set by and when | What happens next |
| ----- | ------- | --------------- | ----------------- |
| `needs-triage` | Brief incomplete, failed `script/brief-lint.sh`, or awaiting priority and routing review. | architect-pm (role rule in `templates/agent-team/docs/agents/team.md`, Labels). `script/fleet-watch.py` adds it and removes `ready-for-agent` when the brief lint fails on a ready issue, and when a worker start fails with no PR. `script/issue-labels-migrate.py` gives it to an open issue with no state and no hold label. | architect-pm rewrites and labels the issue. fleet-watch never starts it. A second lint failure on the same brief adds an `issue_lint_stuck=<n>` digest line instead of another comment. |
| `ready-for-agent` | Lint clean brief, one P label, no hold label, no open `blockedBy` edge. | architect-pm or the owner, after triage. | fleet-watch starts it when it is eligible (acceptance criteria present, no hold label, not blocked, no open PR already closing it). `script/fleet-watch.py` removes the label when the worker starts, and `release_ready_label` in `script/worker-startup.sh` removes it again for any started worker of any role, so the issue scan never starts a second worker. |
| `needs-redesign` | A PR failed Verdict or Review twice. No third patch. | Automation only. `script/fleet-watch.py` adds it to the PR when the second rework round is spent and the head is still red. `script/pr-review.sh` adds it to the PR when a second Review or Verdict FAIL is posted. | The coordinator closes the PR with the lesson and dispatches a redesign. fleet-watch skips a PR that carries it. |
| `needs-elon` | An automation cap was reached. | Read by `script/fleet-watch.py` (the name comes from `worker_stall.needs_elon_label` in `script/fleet-watch.config.example.json`) and skipped for rework. No script adds it today (the "failed twice" issue was retired, see `docs/agents/fleet-watch-design.md`), so a person or a role applies it. | The coordinator decides and removes it. |

`script/team-audit.sh` (the `labels` check) reports any open `ready-for-agent` issue that also carries `blocked`, `owner`, `deferred`, `tracking`, `needs-triage`, `needs-elon` or `needs-redesign`. The remedy is to remove `ready-for-agent` until the conflicting label is cleared.

## Priority (4)

Every `ready-for-agent` issue carries one of these. fleet-watch ranks them in `issue_scan_priority` in `script/fleet-watch.py`. No P label ranks as `P2`.

| Label | Meaning | Set by and when | What happens next |
| ----- | ------- | --------------- | ----------------- |
| `P0` | Outage, security hole, money loss, broken trunk, or any bug. Replaces `hotfix` and `incident`. | architect-pm at triage. `script/issue-labels-migrate.py` gives it to an issue that had `bug`, `hotfix` or `incident`, and drops its other P labels. | Starts first. `script/team-audit-metrics.ts` counts the P0 issues filed this month, and counts a PR titled or labeled `hotfix` as a bad merge. |
| `P1` | Core workflow broken without a workaround, or a release blocking slice. | architect-pm at triage. | Starts after every `P0`. Counted by `script/team-audit-metrics.ts`. |
| `P2` | Standard unit of work. The default. | architect-pm at triage. | Starts after `P1`. |
| `P3` | Minor polish or cleanup. | architect-pm at triage. | Starts last. |

A bug is always `P0`. There are no `bug` or `enhancement` labels. An issue with several P labels keeps the highest when `script/issue-labels-migrate.py` runs.

## Routing (8)

No routing label means `fullstack-dev` on the Workhorse tier. The role picks the provider and model through `usage-gate.py pick --role`. Labels never name a provider or a model. Routing is read in `issue_scan_route` and `ISSUE_ROLE_ROUTES` in `script/fleet-watch.py`.

| Label | Meaning | Set by and when | What happens next |
| ----- | ------- | --------------- | ----------------- |
| `size:S` | Light tier unit: docs only, one small script, or a mechanical edit of 3 files or fewer. | architect-pm at triage. | Starts as `fullstack-dev-small`. Sorts before an unsized issue of the same priority. |
| `size:L` | Strong tier unit and Strong PR review. Replaces `design:architect`, `design:arena` and `review-strong`. | architect-pm at triage. | Starts as `fullstack-dev` with the `fullstack-dev-strong` preset. Sorts after an unsized issue. With `role:ops` it uses the `architect-pm` preset. |
| `role:pm` | Runs as architect-pm. | architect-pm at triage. | The worker title role is `architect-pm`. |
| `role:qa` | Runs as qa-sdet. | architect-pm at triage. | The worker title role is `qa-sdet`. |
| `role:ops` | Runs as release-manager. | architect-pm at triage. | The worker title role is `release-manager`. |
| `role:secops` | Runs as secops-finops. | architect-pm at triage. | The worker title role is `secops-finops`. |
| `role:growth` | Runs as sales-marketing. | architect-pm at triage. | The worker title role is `sales-marketing`. |
| `role:support` | Runs as support-csm. | architect-pm at triage. | The worker title role is `support-csm`. |

## Hold (4)

A hold label keeps fleet-watch from starting the issue (`ISSUE_HOLD_LABELS` in `script/fleet-watch.py`) and never sits with `ready-for-agent`. When `script/issue-labels-migrate.py` finds both on an issue it removes `ready-for-agent`.

| Label | Meaning | Set by and when | What happens next |
| ----- | ------- | --------------- | ----------------- |
| `blocked` | Waits on an external dependency, another repo or reporter detail. The issue names what and who. | architect-pm or the coordinator. | The issue waits until the blocker clears, then the hold label comes off and `ready-for-agent` goes on. |
| `owner` | Waits on the owner: pause decisions, personal accounts, new page screenshots. | architect-pm or the coordinator. Reserved for owner work only. | The owner acts, then the hold label comes off. |
| `deferred` | Parked until a later milestone. | architect-pm or the coordinator. | Reviewed when the milestone arrives. |
| `tracking` | Umbrella issue that tracks child slices. | architect-pm when slicing a spec. | Never dispatched to one builder. The child slices carry the work. |

## Gate at filing

Every open issue carries one state label and one P label from the minute it is filed. `script/issue-label-gate.sh [--apply] [--repo OWNER/REPO]` is the mechanical check (`script/tests/issue-label-gate.test.sh` is its test). The default is a dry run that prints what it would change. It applies these rules:

- No state label (`needs-triage`, `ready-for-agent`, a hold label or `status:進行中`): add `needs-triage`.
- No `P0` to `P3` label: add `P2`.
- `status:進行中` beats a leftover `needs-triage` or `ready-for-agent`: both come off.
- Board status labels follow the state (see Status below).

Who runs it: `script/worker-startup.sh` runs it with `--apply` before every hand dispatch, so a worker start labels any issue filed without labels. The coordinator and architect-pm also run it right after filing an issue (`templates/agent-team/.claude/agents/elon.md`, Musts), and file with `gh issue create --label needs-triage --label P2` so the labels exist at filing. The gate only fills gaps: architect-pm still sets the real priority and moves the issue to `ready-for-agent` at triage. It never starts an issue. The gate reads only open issues of one repo, so run it once per project repo. fleet-watch does not run it yet.

## Status (board view)

Three labels show the state on the board in plain words. They are views of the state above, never routing inputs: fleet-watch ignores them. They sit outside the 20 issue labels.

| Label | Meaning | Set by and when | What happens next |
| ----- | ------- | --------------- | ----------------- |
| `status:接下來` | Ready and queued: the next batch to dispatch. | `script/issue-label-gate.sh`: added to a `ready-for-agent` issue with no hold label and not in flight, removed when the issue is no longer ready. | Goes when the worker starts. |
| `status:進行中` | A worker is building it now. | `script/worker-startup.sh` (`mark_issue_in_flight`): added when a worker start succeeds for the issue, with `needs-triage` and `ready-for-agent` removed. Rework and verify starts leave it alone. | The issue closes with the merged PR. If the worker dies without a PR, the coordinator removes the label and relabels the issue. |
| `status:等你決定` | Waits on the owner. | `script/issue-label-gate.sh`: added to an issue that carries `owner`, removed when `owner` is gone. | The owner acts and the `owner` label comes off. |

## Start order

Every dotfiles issue starts before any other repo's. Two places enforce it:

- fleet-watch orders its issue scan (`issue_scan_queue_key` in `script/fleet-watch.py`): every dotfiles issue before any other repo's, then priority (`P0` first, no P label counts as `P2`), then size (`size:S`, no size label, `size:L`), then oldest first, then lowest number.
- The coordinator's hand dispatch path enforces it too. `script/worker-startup.sh` (`refuse_before_dotfiles`) refuses a builder start whose brief `Refs` another repo while a dotfiles issue is `ready-for-agent` with no hold label and not in flight. Rework briefs, verify briefs, non-builder roles and a brief with no explicit repo are not refused. A start takes the free seat, so a ready dotfiles issue plus a start request is the whole seat test. `--skip-dotfiles-first REASON` overrides it and logs the reason. A failed `gh` call lets the start go on with a warning. `script/tests/worker-startup.test.sh` covers it.

An unlabeled or `needs-triage` dotfiles issue is not ready, so the gate above is what keeps it from being invisible: it gets labeled at the next start and architect-pm triages it first (`templates/agent-team/.claude/agents/elon.md`, Musts).

## Stale tasks

An Orca task is a view of work, not the work. `worker-release` settles the worker but leaves its task `blocked` or `failed`, so a task whose PR merged long ago still shows as dead work. `script/task-sweep.sh --run RUN_ID [--repo OWNER/REPO] [--apply]` marks such a task `completed` when the `Refs` line of its brief names this repo (or is a bare `#N`, which the dispatch scripts read as the host repo) and that issue or PR is closed. It prints one line per task, and a dry run is the default. A task with no `Refs` line, with another repo's `Refs`, or whose number is not in the repo is left alone. A task that failed on a still open issue stays `failed`. `script/tests/task-sweep.test.sh` is its test. The coordinator runs it with `--apply` at session start and after each merge (`elon.md`, Musts).

## Labels outside the 20

These are not issue labels, but scripts read or create them.

| Label | Meaning | Source and when | What happens next |
| ----- | ------- | --------------- | ----------------- |
| `review` | The runner label of the self hosted GitHub runner that runs the Review job. Not an issue or PR label. | `script/setup-review-runner.sh` registers a host's runner with `--labels review`. `.github/workflows/review.yml` selects it with `runs-on: [self-hosted, review]`. | The Review job runs on that host after Checks succeed on a PR. |
| `review-strong` | A retired PR label. A PR that still carries it gets a full opus review, never a carried forward pass, and is never skipped as docs only. | Read by `script/pr-review.sh` (`has_review_strong`). `script/issue-labels-migrate.py` maps it to `size:L` on issues. | Nothing sets it any more. Use `size:L` on the issue. |
| `author-family-<family>` | The model family that wrote a PR, so the reviewer can pick a different family. Optional. A trailer line `Author-Family: <family>` in a commit does the same. | Read by `script/pr-review.sh`. No script sets it. | The reviewer uses a family other than the author's. |
| `needs-info`, `ready-for-human`, `wontfix` | Labels created by `agent-team.sh project --labels` besides `needs-triage`, `ready-for-agent` and `needs-redesign`. They are the Matt Pocock role names, not part of the 20 set. | `create_github_labels` in `script/agent-team.sh`. | Nothing in `script/fleet-watch.py` reads them. The role table above says to use `blocked` and `owner` instead. Known gap: `--labels` seeds the skill role names, not the 20 set. |

## Setting up and migrating labels

- `script/agent-team.sh project <dir> --labels` creates labels on the GitHub remote of a new project (see the gap above).
- `script/issue-labels-migrate.py OWNER/REPO` prints counts as a dry run. `--apply` creates the 20 labels and relabels open issues. `--delete-old` then deletes the retired labels (`design:architect`, `design:arena`, `review-strong`, `area:e2e`, `secops`, `needs-info`, `owner-action`, `ready-for-human`, `bug`, `hotfix`, `incident` and the rest listed in its `RETIRED` table).
- `docs/agents/triage-labels.md` is a pointer to this page. `agent-team.sh` and a project's own `docs/agents/` expect that path, so it stays.
