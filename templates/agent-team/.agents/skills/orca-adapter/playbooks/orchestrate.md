# Orchestrate (Orca gates)

Read the shared playbook first: pstack `poteto-mode/playbooks/orchestrate.md`. These gates win on conflict.

- Spawn only through Orca orchestration. The in flight count comes from the fleet caps and `~/dotfiles/script/usage-gate.py`.
- "Call no scripts" bans ad hoc coordination scripts only. `usage-gate.py`, `~/dotfiles/script/heavy-gate.sh`, `~/dotfiles/script/lead-merge.sh` and worker-watch stay.
- The PR owner writes the branch. Only the coordinator publishes and merges.
- Stall detection stays on `~/dotfiles/.agents/skills/orca-team/worker-watch.sh`.
