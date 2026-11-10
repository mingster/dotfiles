# Opening a PR (Orca gates)

Read the shared playbook first: pstack `poteto-mode/playbooks/opening-a-pr.md`. These gates win on conflict.

- Workers commit locally. The coordinator publishes.
- Merges go only through `~/dotfiles/script/ship.sh`.
- A follow up updates the existing PR, never a duplicate.
