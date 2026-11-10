# Shipping, deploy (Orca gates)

Read the shared playbook first: pstack `poteto-mode/playbooks/shipping.md`. These gates win on conflict.

- Each per PR verifier is a supervised Orca worker from a different model family than the author, never a Cursor cloud agent.
- Landing goes only through `~/dotfiles/script/ship.sh`, run by the coordinator. Never land with `gh` or Origin directly.
- Deploy commands and gates stay in `docs/agents/deploy-facts.md`.
- Release-manager uses the `runtime-forensics` and `worktree-cleanup` playbooks and the shared verify before land rule: only a PR with an independent `PASS` or `PASS+NOTES` verdict lands.
