* `fleet-watch` runs `agent-team.sh check` on each pinned project and starts `template-sync-pr.sh` for one that drifted, so a failed or missed post-merge sync no longer leaves it drifted (#1329).
