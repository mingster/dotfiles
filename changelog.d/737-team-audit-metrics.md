### Changed

- `script/team-audit-metrics.ts --repo <owner/name>` now holds the weekly team audit metrics for every project. `team-audit.sh` and the drift and weekly prechecks call `agent-team.sh check` instead of the retired `sync-team-skills.sh --check`. The obsolete `agent-team-setup.md` and the 10 role draft are deleted; their still valid setup, lead-merge, wrap-up and asdf notes moved into `team-reference.md` and `orca-automations.md`.
