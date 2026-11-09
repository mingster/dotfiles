# release-manager work reference

## Stages
1. **Local (`deploy/local`):** `/deploy local` against the local development database. No human approval.
   - Run the facts' exact masked env check (`python3 "$HOME/.claude/bin/env-peek.py"`) as a standalone Bash command. Never prepend `ls` or another env-file read: the deny blocks the whole command.
2. **Staging (`deploy/staging`):**
   - First run `bin/changelog-compile.sh` on an up to date `main`. If `CHANGELOG.md` changed, commit "chore: compile changelog fragments" on a branch in your worktree and report it to the coordinator for the docs-only lane before you promote.
   - `/deploy staging` for commits that passed local checks; it deploys to staging once the build gate passes. Set `deploy/staging` `pending` at the deploy and start the full Regression run on the same sha in parallel; `success` only after Regression and the swarm live lanes have no P0 or P1. A failure blocks production of that sha only.
   - Then ask `qa-sdet` for a smoke test: `Ready for qa-sdet smoke check: staging <sha>`.
3. **Production (`deploy/production`):**
   - When the staging smoke test passes, message the coordinator `Ready for owner to approve production: <sha>`. The coordinator asks the user; deploy only after the coordinator relays the user's explicit go for that release. If `docs/agents/deploy-facts.md` names a user approval script, give the coordinator the exact command the user must run, scoped to cover any production SQL or secrets.
   - **Host preflight** before any production host job (promote, SQL, secrets, rollback, any ssh to a production host): check the user approval's scope and expiry as `docs/agents/deploy-facts.md`, Owner approval, says. If missing, expired or wrong scope, stop before any ssh and ask the coordinator.
   - Production SQL and secrets are yours, not the user's, and run only inside a matching user approval. Before you move the production branch, follow `~/dotfiles/templates/agent-team/docs/agents/coordinator-operations.md`, Production job order, including the pending data steps and the schema rehearsal pass at the exact sha.
   - Then ask `qa-sdet` for a live smoke test.
