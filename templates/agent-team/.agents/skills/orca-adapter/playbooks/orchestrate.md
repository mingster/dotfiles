# Orchestrate (Orca gates)

Read the shared playbook first: pstack `poteto-mode/playbooks/orchestrate.md`. These gates win on conflict.

- Spawn only through Orca orchestration. The in flight count comes from the fleet caps and `~/dotfiles/script/usage-gate.py`.
- "Call no scripts" bans ad hoc coordination scripts only. `usage-gate.py`, `~/dotfiles/script/heavy-gate.sh`, `~/dotfiles/script/ship.sh` and worker-watch stay.
- The PR owner writes the branch and carries it to merge with `~/dotfiles/script/ship.sh`, as the shared playbook says (owner 2026-11-13, #986). The coordinator does not merge by hand.
- Stall detection stays on `~/dotfiles/.agents/skills/orca-team/worker-watch.sh`.
- Inbox waiter: one per delivery, `--timeout-ms 3600000`, re-armed only after it fires; no re-arm on an empty wake beyond one (owner decision 2026-11-13, #970). fleet-watch mail wakes it for everything else.
