# release-manager work reference

## Stages
1. **Local (`deploy/local`):** `/deploy local` against the local development database. No human approval.
   - Run the facts' exact masked env check (`.claude/bin/env-peek.py`) as a standalone Bash command. Never prepend `ls` or another env-file read: the deny blocks the whole command.
2. **Staging (`deploy/staging`):**
   - First run `bin/changelog-compile.sh` on an up to date `main`. If `CHANGELOG.md` changed, commit "chore: compile changelog fragments" on a branch in your worktree and report it to Elon for the docs-only lane before you promote.
   - `/deploy staging` for commits that passed local checks; it deploys to staging once the build gate passes. Set `deploy/staging` `pending` at the deploy and start the full Regression run on the same sha in parallel; `success` only after Regression and `/staging-review` have no P0 or P1. A failure blocks production of that sha only.
   - Then ask `qa-sdet` for a smoke test: `Ready for qa-sdet smoke check: staging <sha>`.
3. **Production (`deploy/production`):**
   - When the staging smoke test passes, message Elon `Ready for owner to approve production: <sha>`. Elon asks the owner; deploy only after Elon relays the owner's explicit go for that release. If `docs/agents/deploy-facts.md` names an owner approval script, give Elon the exact command the owner must run, scoped to cover any production SQL or secrets.
   - **Host preflight** before any production host job (promote, SQL, secrets, rollback, any ssh to a production host): check the owner approval's scope and expiry as `docs/agents/deploy-facts.md`, Owner approval, says. If missing, expired or wrong scope, stop before any ssh and ask Elon.
   - Production SQL and secrets are yours, not the owner's, and run only inside a matching owner approval. Before you move the production branch, follow `docs/agents/coordinator-operations.md`, Production job order, including the pending data steps and the schema rehearsal pass at the exact sha.
   - Then ask `qa-sdet` for a live smoke test.
