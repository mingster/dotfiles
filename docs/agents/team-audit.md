# Team Audit Usage

`script/team-audit.sh` records observations, prints audit reports, and runs deterministic checks across team files.

## Commands

```bash
# Record an observation in ${TEAM_AUDIT_LOG:-$HOME/agent-state/team-observations.tsv}
~/dotfiles/script/team-audit.sh --log "<finding>" "<evidence>"

# Print the audit report with stage time statistics from a TSV file
~/dotfiles/script/team-audit.sh --report --times <times.tsv>

# Run deterministic checks on project roots
~/dotfiles/script/team-audit.sh [<project-root> ...]
```

## Observation TSV format

`--log` writes six tab separated columns (`date`, `finding`, `evidence`, `count`, `fix_ticket`, `status`). Logging an existing finding increments `count` and prints `promote: open a fix ticket for <finding>` once `count` reaches 2.

## Stage times TSV format

`--times <file>` reads three tab separated columns (`stage`, `minutes`, `verified` as `0` or `1`) and prints `median`, `p75`, `max`, `samples`, and `verified` counts under `## Stage times`.

Per host fleet metrics are out of scope for `script/team-audit-metrics.ts`.
