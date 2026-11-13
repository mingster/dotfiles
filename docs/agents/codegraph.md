# codegraph (trial)

codegraph builds a local index of a repo's code (symbols and who calls whom) and answers "where is X used" in one call, so an agent reads less and greps less. Upstream: https://github.com/colbymchenry/codegraph (MIT). Trial status: the coordinator Mac only, hook on (second measurement, issue 924). Read this before changing `script/codegraph-setup.sh`, the pin in `script/codegraph/`, or rolling it out to another host.

## Pin and install

The pin is `script/codegraph/package.json` (exact version) plus `package-lock.json`, which holds the hash of the main tarball and of every platform tarball. `script/codegraph-setup.sh machine` copies both into `~/.local/share/codegraph/<version>/` and runs `npm ci --ignore-scripts`, so a changed tarball fails the install. The npm package ships with registry signatures and a build provenance attestation; `npm audit signatures` checks them.

We do not use upstream's `install.sh`. It downloads whatever release is latest and has no checksum step. `codegraph upgrade` is also off limits: it moves the host past the pin.

To bump the pin: change the version in `package.json`, run `npm install --package-lock-only --ignore-scripts` in `script/codegraph/`, read the release notes, rerun the setup test. Hosts that run the fleet toolchain check report any host whose codegraph differs from the pin.

## What setup changes

`machine --codegraph` does these things and nothing else:

1. Installs the pin under `~/.local/share/codegraph/<version>/` and links `~/.local/bin/codegraph` to it.
2. Turns telemetry off (`codegraph telemetry off`). It is on by default.
3. Adds the `codegraph` MCP server to `~/.claude.json`, `~/.cursor/mcp.json` and `~/.gemini/config/mcp_config.json`.
4. Allows `mcp__codegraph__*` in `~/.claude/settings.json`.
5. Keeps one `UserPromptSubmit` hook in `~/.claude/settings.json`: `$HOME/.local/bin/codegraph prompt-hook`. It runs the pinned link, never a `codegraph` found on PATH, and is the same text on every host. Without it the agent never calls the codegraph tools (issue 924, first trial). Owner decision 2026-11-13. Each run replaces the bare `codegraph prompt-hook` that `codegraph install` adds and restores the pinned one if it is missing; other hooks are untouched.
6. Removes the marked "CodeGraph" section `codegraph install` adds to `~/.claude/CLAUDE.md`, because that file is a copy of a dotfiles file and a second block there would drift.

`codegraph-setup.sh uninstall` removes the hook, the three MCP entries, the permission, the CLAUDE.md section and the `~/.local/bin/codegraph` link. It leaves the install under `~/.local/share/codegraph/` and the project indexes.

Nothing is written under `.claude/hooks`.

## Where the index lives

One SQLite file per working tree: `<repo>/.codegraph/codegraph.db`, plus a `.gitignore` inside `.codegraph/` that ignores everything except itself. That `.gitignore` shows up as an untracked file, so `.codegraph/` is also in this repo's `.gitignore`, in `.gitignore_global`, and `project --codegraph` adds it to the repo's `.git/info/exclude` (shared by all worktrees of that repo). Size on the coordinator Mac: dotfiles 14 MB, a large web app 441 MB.

## How it updates

Only an agent session keeps it fresh. When Claude Code, Cursor or Antigravity starts `codegraph serve --mcp`, the server watches the repo with native file events and syncs changed files 2 seconds after the last change (`CODEGRAPH_WATCH_DEBOUNCE_MS` changes this). Nothing runs in the background when no agent session is open, so an index can be stale after edits made outside a session. `codegraph sync` in the repo catches it up; `codegraph status` shows pending files.

## Worktrees

An index belongs to one working tree. A worktree without `.codegraph/` has no index (`codegraph status` says "Not initialized") and the agent falls back to grep. Worktrees do not share an index and nothing copies one: `codegraph init` in a new worktree builds a full index of its own (dotfiles: about 1 second; a large web app: about 27 seconds and 441 MB). Orca worktrees sit next to each other under `~/orca/workspaces/`, not inside the main checkout, so none of them inherits the main checkout's index.

So setup indexes the main checkout only, and skips a linked worktree with a message. Build a worktree index by hand with `codegraph init` when a long search heavy task justifies the cost, and remove it with `codegraph uninit` when the worktree is done. Upstream also warns when a worktree nested inside the main checkout borrows the main checkout's index, which would show the wrong branch.

## Rollout

Not yet. Run it only on the coordinator Mac until the owner has seen the measured numbers (issue 924). Do not pass `--codegraph` on other hosts. After the owner agrees, make it part of the default machine and project setup in `script/agent-team.sh`.
