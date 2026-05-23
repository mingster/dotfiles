# Agent guidance (dotfiles repo)

This file orients humans and coding agents working **in this repository** (`$HOME/dotfiles`).

## Read first

1. [README.md](README.md) — install flow and overview.
2. [.github/copilot-instructions.md](.github/copilot-instructions.md) — conventions for GitHub Copilot on this repo.
3. [install.sh](install.sh) — creates `~/dotfiles` symlink, refreshes home dotfile symlinks, then delegates to the platform `system_setup.sh` (detected via `$OSTYPE`). Use `DOTFILES_SKIP_SYSTEM_SETUP=1` to skip software install.

## AI-related paths (after bootstrap)

| Tool | Home path | Canonical in repo |
|------|-----------|---------------------|
| [skills CLI](https://skills.sh/) | `~/.agents` | `~/dotfiles/.agents` |
| Claude Code (CLI + [Desktop](https://code.claude.com/download)) | `~/.claude/` (symlinks into place; skills at `~/.claude/skills`) | `~/dotfiles/.agents/` (`skills/` shared; `claude/` for CLAUDE.md, settings, agents) |
| Cursor rules (global) | `~/.cursor/rules` | `~/dotfiles/cursor/rules` (synced from `~/projects/riben.life/web/.cursor/rules`) |
| Cursor User settings | `…/Cursor/User/{settings,keybindings,environment}.json` | `~/dotfiles/cursor/` (via `link-cursor-user.sh`) |
| VS Code User settings | `…/Code/User/{settings,keybindings}.json` | `~/dotfiles/vscode/` (via `script/setup-vscode.sh`) |
| Antigravity IDE User settings | `…/Antigravity IDE/User/{settings,keybindings}.json` | `~/dotfiles/Antigravity/` (via `script/setup-antigravity.sh`) |
| Obsidian vault (agent memory) | `~/Documents/Obsidian` | created by `script/setup-obsidian.sh`; accessed via `obsidian` MCP server declared in `.agents/claude/settings.json` |

## Setup scripts (called from `install.sh`)

| Script | What it does |
|--------|-------------|
| `script/setup-claude-code.sh` | Links all `.agents/claude/*` into `~/.claude/`; links skills |
| `script/setup-claude-desktop.sh` | Merges Claude Desktop config (macOS and Linux) |
| `script/setup-cursor.sh` | Installs Cursor; links rules and user settings |
| `script/setup-vscode.sh` | Links VS Code settings and keybindings |
| `script/setup-antigravity.sh` | Links Antigravity IDE settings and keybindings |
| `script/setup-obsidian.sh` | Installs Obsidian; creates vault at `~/Documents/Obsidian` |
| `script/setup_fishshell.sh` | Installs fisher + plugins; restores tide config |
| `script/backup-tide.fish` | Saves current tide config to `.config/fish/tide_config.fish` |
| `script/bootstrap-agents.sh` | Restores skills from `.skill-lock.json` (requires Node/npx) |

## `.agents/` structure

```
.agents/
  .skill-lock.json          lockfile for skills CLI (npx skills@latest)
  skills/                   shared skill packs (linked as ~/.claude/skills and ~/.agents/skills)
  claude/
    CLAUDE.md               global Claude Code instructions (linked as ~/.claude/CLAUDE.md)
    settings.json           permissions, MCP servers, hooks, enabled plugins
    statusline.sh           status line script
    laravel-php-guidelines.md
    agents/                 subagent definitions (laravel-debugger, etc.)
    plugins.md              inventory of Claude Code marketplace plugins to install
    README.md               (not linked — documentation only)
```

Every file in `.agents/claude/` except `README.md` is automatically linked into `~/.claude/` by `setup-claude-code.sh`. Add a new file there and re-run `install.sh` (or the script directly) to pick it up.

## Restoring on a new machine

```bash
# Full bootstrap (first run — brew not yet installed)
sh install.sh

# Refresh dotfile symlinks only (brew already installed)
sh install.sh

# Restore skills from lockfile
DOTFILES_INSTALL_SKILLS=1 sh install.sh

# Install Claude Code marketplace plugins (manual — see .agents/claude/plugins.md)
```

## Boundaries

- No secrets in committed files. MCP secrets go in `~/.claude/settings.local.json` (gitignored globally via `.gitignore_global`).
- Prefer small, focused changes; match existing shell and doc style.
- Scripts must pass `shellcheck --severity=error`. Run: `bash script/shellcheck-dotfiles.sh`
