# Opening a PR (Orca gates)

Read the shared playbook first: pstack `poteto-mode/playbooks/opening-a-pr.md`. These gates win on conflict.

- The PR owner pushes its branch, opens the PR and carries it to merge (`team.md`, Publication).
- Merges go only through `~/dotfiles/script/ship.sh`, run by the PR owner.
- A follow up updates the existing PR, never a duplicate.
- An issue PR body carries `Closes #<issue>` (or `Refs #<issue>` only when acceptance items remain open on the issue).
