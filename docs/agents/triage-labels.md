# Triage Labels

One label set of 20 labels serves every repo of the team. `script/fleet-watch.py` reads it to pick, order and route work without a coordinator turn. A normal ready issue carries only `ready-for-agent` and `P2`.

## The five canonical triage roles

The skills speak in terms of five canonical triage roles. This table maps them to the label strings used here.

| Role in mattpocock/skills | Label in our tracker | Meaning                                                      |
| ------------------------- | -------------------- | ------------------------------------------------------------ |
| `needs-triage`            | `needs-triage`       | Maintainer needs to evaluate this issue                      |
| `needs-info`              | `blocked`            | Waiting on a reporter, a vendor or another repo              |
| `ready-for-agent`         | `ready-for-agent`    | Fully specified, ready for an AFK agent                      |
| `ready-for-human`         | `owner`              | Waits on the owner                                           |
| `wontfix`                 | none                 | Close the issue with the reason "not planned"                |

## State (4)

| Label             | Meaning                                                                                  |
| ----------------- | ---------------------------------------------------------------------------------------- |
| `needs-triage`    | Brief incomplete, failed `script/brief-lint.sh`, or awaiting priority and routing review. |
| `ready-for-agent` | Lint clean brief, one P label, no hold label, no open `blockedBy` edge.                  |
| `needs-redesign`  | A PR failed Verdict or Review twice. Set by automation only.                             |
| `needs-elon`      | An automation cap was reached. The coordinator decides and removes it.                   |

An open issue without a hold label carries `needs-triage` or `ready-for-agent`, never both. fleet-watch removes `ready-for-agent` when a worker starts. A start that fails with no PR puts the issue back to `needs-triage`.

## Priority (4)

Every `ready-for-agent` issue carries one of these. The default is `P2`.

| Label | Meaning                                                                                   |
| ----- | ----------------------------------------------------------------------------------------- |
| `P0`  | Outage, security hole, money loss, broken trunk, or any bug. Replaces `hotfix` and `incident`. |
| `P1`  | Core workflow broken without a workaround, or a release blocking slice.                   |
| `P2`  | Standard unit of work.                                                                    |
| `P3`  | Minor polish or cleanup.                                                                  |

A bug is always `P0`. Triage gives every bug `P0`, and there are no `bug` or `enhancement` labels.

## Routing (8)

No routing label means `fullstack-dev` on the Workhorse tier.

| Label          | Meaning                                                                                      |
| -------------- | -------------------------------------------------------------------------------------------- |
| `size:S`       | Light tier unit: docs only, one small script, or a mechanical edit of 3 files or fewer.      |
| `size:L`       | Strong tier unit and Strong PR review. Replaces `design:architect`, `design:arena`, `review-strong`. |
| `role:pm`      | Runs as architect-pm.                                                                        |
| `role:qa`      | Runs as qa-sdet.                                                                             |
| `role:ops`     | Runs as release-manager (architect-pm tier with `size:L`).                                   |
| `role:secops`  | Runs as secops-finops.                                                                       |
| `role:growth`  | Runs as sales-marketing.                                                                     |
| `role:support` | Runs as support-csm.                                                                         |

The role picks the provider and model through `usage-gate.py pick --role`. Labels never name a provider or a model.

## Hold (4)

A hold label keeps fleet-watch from starting the issue and never sits with `ready-for-agent`.

| Label      | Meaning                                                                              |
| ---------- | ------------------------------------------------------------------------------------ |
| `blocked`  | Waits on an external dependency, another repo or reporter detail. Name what and who. |
| `owner`    | Waits on the owner (owner pause decisions, personal accounts, new page screenshots). |
| `deferred` | Parked until a later milestone.                                                      |
| `tracking` | Umbrella issue that tracks child slices. Never dispatched to one builder.            |

## Start order

fleet-watch starts eligible issues by priority (`P0` first, no P label counts as `P2`), then size (`size:S`, no size label, `size:L`), then oldest first, then lowest number.

## Migration

`script/issue-labels-migrate.py OWNER/REPO` prints counts as a dry run. `--apply` creates the labels and relabels open issues. `--delete-old` then deletes the retired labels.

When a skill mentions a role (for example "apply the AFK-ready triage label"), use the label string from the first table.
