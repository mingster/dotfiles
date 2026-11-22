# Global Cursor hooks (user-level)

Installed by `script/setup-cursor.sh` into `~/.cursor/hooks.json` and `~/.cursor/hooks/*.sh`.

## `ensure-changelog-before-pr.sh`

Blocks `gh pr create` when the branch touches **shippable** paths but the repo **changelog** file was not updated.

It also runs a Zero-Env scan. It reads only the lines the PR adds (not the whole file), in changed `.md`, `.mdx`, `.json`, `.yml` and `.yaml` files. A Postgres URL whose password is a placeholder (`password`, `changeme`, `<...>`, `${...}` or `[Omitted/Configured via Env]`) passes. When an added line holds a raw secret (a `sk_live_` key, a `LINE_PAY_SECRET=` value, or a Postgres URL with an inline password), it denies the PR and names the file. It never prints the matched line, so the secret stays out of hook logs and agent transcripts.

### Per-repo config (optional)

`<repo>/.cursor/changelog-hook.json`:

```json
{
  "changelog": "fileServer/docs/HOME.md",
  "recentHeading": "## Recent Changes",
  "shippablePrefixes": [
    "web/src/",
    "web/bin/",
    "web/prisma/",
    "fileServer/docs/"
  ]
}
```

Optional `"fragments": "changelog.d/"`: the PR then passes when it adds a file under that directory (README.md does not count) OR edits the changelog file. When the gate blocks, the message tells the author to add `changelog.d/<issue>-<slug>.md` instead of using the prepend helper. Without the key, behaviour is unchanged.

If missing, auto-detects `fileServer/docs/HOME.md`, `web/doc/HOME.md`, or `doc/HOME.md` when they contain `## Recent Changes`.

### Prepend helper

From repo root:

```bash
bun ~/dotfiles/script/prepend-recent-change.ts \
  --link STRIPE_STORE_SUBSCRIPTION_METADATA \
  --label "Platform subscription pricing" \
  --summary "List/special monthly and yearly ×11"
```

Override base branch: `PR_BASE_BRANCH=develop gh pr create ...`

Reload hooks in Cursor after editing `hooks.json` (or restart Cursor).

## `usage-gate.sh`

Runs the usage gate on every Orca `worker-start`. It only translates formats: the decision stays in `script/usage-gate-hook.py`. The same script serves Cursor (`beforeShellExecution`, deny exits 2) and Antigravity (`PreToolUse` on `run_command`, wired by `script/setup-antigravity.sh` from `ide/antigravity/hooks.json`). Tests: `bash ide/cursor/hooks/usage-gate.test.sh`.
