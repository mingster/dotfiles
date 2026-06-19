# Global Cursor hooks (user-level)

Installed by `script/setup-cursor.sh` into `~/.cursor/hooks.json` and `~/.cursor/hooks/*.sh`.

## `ensure-changelog-before-pr.sh`

Blocks `gh pr create` when the branch touches **shippable** paths but the repo **changelog** file was not updated.

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
