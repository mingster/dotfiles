# Agent guidance (dotfiles repo)

This file orients humans and coding agents working **in this repository** (`$HOME/dotfiles`).

## Read first

1. [README.md](README.md) — install flow and overview.
2. [.github/copilot-instructions.md](.github/copilot-instructions.md) — conventions for GitHub Copilot on this repo.
3. [install.sh](install.sh) — symlinks for `~/.agents`, [script/setup-claude-code.sh](script/setup-claude-code.sh) (→ `~/.claude/`), `~/.cursor/rules`, [script/link-cursor-user.sh](script/link-cursor-user.sh), then runs **`mac/`**, **`arch/`**, or **`debian/`** `system_setup.sh` based on OS (or `DOTFILES_SKIP_SYSTEM_SETUP=1` to skip).

## AI-related paths (after bootstrap)

| Tool | Home path | Canonical in repo |
|------|-----------|---------------------|
| [skills CLI](https://skills.sh/) | `~/.agents` | `~/dotfiles/.agents` |
| Claude Code | `~/.claude/` (symlinks into place) | `~/dotfiles/.agents/` (`skills/` shared; `claude/` for CLAUDE.md, settings, agents) |
| Cursor rules (global) | `~/.cursor/rules` | `~/dotfiles/cursor/rules` (synced from `~/projects/riben.life/web/.cursor/rules`) |
| Cursor User settings | `…/Cursor/User/settings.json` | `~/dotfiles/cursor/settings.json` (via `link-cursor-user.sh`) |

Restore skills from the lockfile on a new machine:

```bash
bash ~/dotfiles/script/bootstrap-agents.sh
```

Or set `DOTFILES_INSTALL_SKILLS=1` when running `install.sh` to run that automatically (requires Node/npx).

## Boundaries

- No secrets in committed files: use env vars; keep local MCP config out of git (see `cursor/mcp.json.example`).
- Prefer small, focused changes; match existing shell and doc style.
