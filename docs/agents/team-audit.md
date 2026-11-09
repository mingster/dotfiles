# Team Audit Usage

`script/team-audit.sh` runs six deterministic checks across team files, records observations, and prints the audit report.

## Commands

```bash
# Run the six checks on project roots (default: script/team-audit.local.conf)
~/dotfiles/script/team-audit.sh [<project-root> ...]

# Checks plus metrics, as three sections: problems, proposals, stage times
~/dotfiles/script/team-audit.sh --report [<project-root> ...]

# Record an observation in ${TEAM_AUDIT_LOG:-$HOME/agent-state/team-observations.tsv}
~/dotfiles/script/team-audit.sh --log "<finding>" "<evidence>"
```

Exit 0 when clean, 1 on any finding (also for `--report`), 2 on a usage error.

## Checks

`sync`, `budget`, `wording`, `skills` (frontmatter, skill lock, orca-team helpers, and every role `skills:` name), `labels` (an open `ready-for-agent` issue that also carries one of `CONFLICT_LABELS`), and `receipt` (role file commits after the `ROLE_RECEIPT_BASE` sha carry `Owner-approved:`). No check polls upstream repositories. A failed gh call prints a `WARN` line, which the report lists as a gap.

## Observation TSV format

`--log` writes six tab separated columns (`date`, `finding`, `evidence`, `count`, `fix_ticket`, `status`). Logging an existing finding increments `count` and prints `promote: open a fix ticket for <finding>` once `count` reaches 2.

## Stage times

`--report` runs `script/team-audit-metrics.ts --repo <owner/name>` per project with two gh calls (one GraphQL search for merged PRs, one `gh issue list`). It reads dispatch times from `${TEAM_AUDIT_DISPATCHES:-$HOME/agent-state/team-dispatches.tsv}` (columns `issue` and `dispatched_at`, header first, the earliest row per issue counts). Queue runs from `ready-for-agent` to dispatch, build from dispatch to the first Checks result on the PR's first commit, merge from that result to merge. A PR with all four timestamps counts as fully verified.

Per host fleet metrics are out of scope for `script/team-audit-metrics.ts`.
