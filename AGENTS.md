# Agent guidance (dotfiles repo)

This file orients humans and coding agents working **in this repository** (`$HOME/dotfiles`).

## Read first

1. [README.md](README.md) — install flow and overview.
2. [.github/copilot-instructions.md](.github/copilot-instructions.md) — conventions for GitHub Copilot on this repo.
3. [install.sh](install.sh) — creates `~/dotfiles` symlink, refreshes home dotfile symlinks, then delegates to the platform `system_setup.sh` (detected via `$OSTYPE`). Use `DOTFILES_SKIP_SYSTEM_SETUP=1` to skip software install.

## Architecture

`install.sh` is the single entry point for all platforms. It sets `~/dotfiles` as a symlink to the
repo, refreshes home dotfiles, wires up `.agents`, Claude Code and Cursor, then delegates to the
platform `system_setup.sh` (detected via `$OSTYPE` and `/etc/os-release`).

Platform folders `mac/`, `arch/`, `debian/` each contain a `system_setup.sh` (full env installer)
and optional `install_*.sh` / `uninstall_*.sh` for optional stacks. New platform behavior belongs
in the matching folder, not in `install.sh`.

`ide/` holds editor config shared across platforms: `ide/cursor/`, `ide/vscode/`,
`ide/antigravity/`. Scripts in `script/` symlink these into the platform specific locations
(`~/Library/Application Support/...` on macOS, `~/.config/...` on Linux).

App configs under `.config/` are managed with GNU `stow`; on macOS `mac/stowall` stows everything.
`~/.stow-local-ignore` controls what stow skips.

`install.sh` copies `.gitconfig` (arm64) or `.gitconfig-x64` (x86_64) rather than symlinking,
because git config must be a real file.

## Commands

```bash
bash script/shellcheck-dotfiles.sh            # ShellCheck at error severity, same as CI
shellcheck -x install.sh                      # full diagnostics on a single file
stow -n <package>                             # dry-run a single stow package
mac/stowall                                   # stow all .config packages on macOS
DOTFILES_SKIP_SYSTEM_SETUP=1 sh install.sh    # bootstrap without running system_setup
```

## AI-related paths (after bootstrap)

| Tool | Home path | Canonical in repo |
|------|-----------|---------------------|
| Agent skills (shared tree, read by all IDEs) | `~/.agents` | `~/dotfiles/.agents` |
| Claude Code (CLI + [Desktop](https://code.claude.com/download)) | `~/.claude/` (symlinks into place; skills at `~/.claude/skills`) | `~/dotfiles/.agents/` (`skills/` shared; `claude/` for CLAUDE.md, settings, agents) |
| Cursor rules (global) | `~/.cursor/rules` | `~/dotfiles/ide/cursor/rules` (synced from `~/projects/riben.life/web/.cursor/rules`) |
| Cursor User settings | `…/Cursor/User/{settings,keybindings,environment}.json` | `~/dotfiles/ide/cursor/` (via `script/link-cursor-user.sh`) |
| Cursor hooks (global) | `~/.cursor/hooks.json`, `~/.cursor/hooks/*.sh` | `~/dotfiles/ide/cursor/` (via `script/link-cursor-hooks.sh`) |
| VS Code User settings | macOS: `…/Code/User/` Linux: `…/Code - OSS/User/` | `~/dotfiles/ide/vscode/` (via `script/setup-vscode.sh`) |
| Antigravity IDE User settings | macOS: `…/Antigravity IDE/User/` Linux: `~/.config/Antigravity IDE/User/` | `~/dotfiles/ide/antigravity/` (via `script/setup-antigravity.sh`) |
| Obsidian vault (agent memory) | `~/Documents/Obsidian` | created and synced by `script/setup-obsidian.sh`; MCP config in `~/.claude/settings.local.json` (generated per machine) |

## Setup scripts (called from `install.sh`)

| Script | What it does |
|--------|-------------|
| `script/setup-claude-code.sh` | Links all `.agents/claude/*` into `~/.claude/`; links skills |
| `script/setup-claude-desktop.sh` | Merges Claude Desktop config (macOS and Linux) |
| `script/setup-cursor.sh` | Installs Cursor; links rules, user settings, and global hooks |
| `script/setup-vscode.sh` | Links VS Code settings and keybindings |
| `script/setup-antigravity.sh` | Links Antigravity IDE settings and keybindings |
| `script/setup-obsidian.sh` | Installs Obsidian + MEGAcmd; creates vault; configures sync; writes obsidian MCP to `~/.claude/settings.local.json` |
| `script/setup_fishshell.fish` | Installs fisher + plugins; restores tide config |
| `script/init-agent-project.sh` | Not called from `install.sh`. Run per project to scaffold `docs/agents/` for the engineering skills |
| `script/backup-tide.fish` | Saves current tide config to `.config/fish/tide_config.fish` |

## `.agents/` structure

`.agents/skills/` holds the shared skill packs (linked as `~/.claude/skills` and `~/.agents/skills`). `.agents/claude/` holds Claude Code config. Every file in `.agents/claude/` except `README.md` is automatically linked into `~/.claude/` by `setup-claude-code.sh`. Add a new file there and re-run `install.sh` (or the script directly) to pick it up.

## Engineering workflow skills

The global `CLAUDE.md` (`.agents/claude/CLAUDE.md`) sets a default five stage loop for non-trivial work,
backed by skills vendored from [mattpocock/skills](https://github.com/mattpocock/skills) under `.agents/skills/`:

| Stage | Skill |
|-------|-------|
| Grill | `grill-with-docs` (wraps `grilling` + `domain-modeling`) |
| Spec | `to-spec` |
| Tickets | `to-tickets` |
| Implement | `tdd` (or `implement` / `implement-spec` for a whole spec) |
| Review | `code-review` |

Each repo needs its own `docs/agents/` config (issue tracker, triage labels, domain doc layout) before
`to-spec`, `to-tickets`, `triage`, and `code-review` will work there. That is per project, not part of
the dotfiles bootstrap. Scaffold it with:

```bash
cd <repo> && ~/dotfiles/script/init-agent-project.sh --labels
# or, for many at once
~/dotfiles/script/init-agent-project.sh --labels ~/projects/* ~/pstv/web2
```

The script infers the tracker from the `origin` remote, seeds `docs/agents/*.md` from the templates in
`.agents/skills/setup-matt-pocock-skills/`, appends an `## Agent skills` block to `AGENTS.md` (creating
a `CLAUDE.md` pointer when the repo has neither file), and with `--labels` creates the five triage
labels on the GitHub remote. It is idempotent and never overwrites a file that already exists. Use
`--dry-run` first. For a repo that needs judgement (monorepo, non-GitHub tracker), run the
`setup-matt-pocock-skills` skill instead.

Configured so far: `riben.life`, `mingster.com`, `dotfiles`, `pstv/web2`, `pstv/fileServer`,
`pstv/jellyfin`, `pstv/pstv_op`, `pstv/streaminator`.

## Agent instruction file convention

`AGENTS.md` is the single source in every repo; `CLAUDE.md` is a one line `@AGENTS.md` pointer.
Keep `AGENTS.md` under 200 lines and push area-specific content into `docs/agents/<topic>.md`
behind a pointer that names when to read it. Full convention, including why `~/.claude/CLAUDE.md`
is copied rather than symlinked: `docs/agents/agent-files.md`. Read it before adding, moving, or
growing an agent instruction file in any repo.

## Three-tier context system

Context is loaded in three tiers to keep sessions lean:

| Tier | Location | Loaded how |
|------|----------|------------|
| **Project instructions** | `AGENTS.md` / `CLAUDE.md` in the project root | Always (auto at session start) |
| **Quick reference notes** | `~/.claude/notes/` (source: `.agents/claude/notes/`) | On demand — `@`-include when needed for a task |
| **Deep docs and memory** | Obsidian vault `~/Documents/Obsidian` | On demand — `obsidian` MCP |

Vault layout and MEGAcmd sync setup: `docs/agents/obsidian.md`. Read it before changing
`script/setup-obsidian.sh`, the vault structure, or the sync configuration.

## Contributing learnings back from a project

When a project surfaces something reusable (a recurring bug pattern, a framework gotcha, an
architectural decision), add it to the shared notes so all projects benefit:

```bash
~/dotfiles/script/contribute-to-agents.sh <topic> "What I learned"
# e.g.
~/dotfiles/script/contribute-to-agents.sh laravel "Always eager-load relationships in Nova resources to avoid N+1"
```

This appends a dated entry to `.agents/claude/notes/<topic>.md`. Commit it to dotfiles to
share with future sessions and other machines.

To load a note in a specific project, add this to the project's `CLAUDE.md`:

```
@notes/laravel.md
```

## Restoring on a new machine

```bash
# Full bootstrap (first run — brew not yet installed)
sh install.sh

# Refresh dotfile symlinks only (brew already installed)
sh install.sh

# Install Claude Code marketplace plugins (manual — see .agents/claude/plugins.md)
```

## Boundaries

- No secrets in committed files. MCP secrets go in `~/.claude/settings.local.json` (gitignored globally via `.gitignore_global`).
- Prefer small, focused changes; match existing shell and doc style.
- Scripts must pass `shellcheck --severity=error`. CI enforces this on `install.sh`, `mac/stowall`, and the three `system_setup.sh` files. Run: `bash script/shellcheck-dotfiles.sh`
- Installs must be idempotent and safe to re-run. Follow the Homebrew pattern for external tools: check before installing.
- `_outdated/` is read-only historical context. Update the active files under `mac/`, `arch/`, `debian/` instead.
- Do not edit `ide/vscode/AzureDataStudio.code-profile` directly. Update `script/install_vscode_extensions.sh` and re-export.
- `ide/cursor/mcp.json` is gitignored. Use `ide/cursor/mcp.json.example` as the template.

## Agent skills

### Issue tracker

GitHub issues in this repo, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, label strings unchanged. See `docs/agents/triage-labels.md`.

### Domain docs

Single context: `CONTEXT.md` plus `docs/adr/` at the repo root. See `docs/agents/domain.md`.
