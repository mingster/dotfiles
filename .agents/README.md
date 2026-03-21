# `.agents` (global skills + Claude Code)

This directory is the **single canonical tree** for agent skills and Claude Code configuration:

| Path | Role |
|------|------|
| **`skills/`** | Shared skill packs. Used by the [skills CLI](https://skills.sh/) (`~/.agents` → this folder) **and** by Claude Code (`~/.claude/skills` → same folder via `script/setup-claude-code.sh`). |
| **`claude/`** | Claude Code only: `CLAUDE.md`, `laravel-php-guidelines.md`, `settings.json`, `statusline.sh`, and the **`agents/`** markdown agent definitions. Linked into `~/.claude/`. |
| **`.skill-lock.json`** | Lockfile for `npx skills@latest experimental_install` (see `script/bootstrap-agents.sh`). |

## Refreshing skills from upstream (e.g. [freekmurze/dotfiles](https://github.com/freekmurze/dotfiles))

Upstream keeps skills under `config/claude/skills/`. Merge **without** `--delete` so you do not remove skills that exist only in your `.agents/skills`:

```bash
rsync -a path/to/freekmurze-dotfiles/config/claude/skills/ ~/dotfiles/.agents/skills/
```

For Claude-only files:

```bash
rsync -a path/to/freekmurze-dotfiles/config/claude/*.md path/to/freekmurze-dotfiles/config/claude/*.json path/to/freekmurze-dotfiles/config/claude/*.sh ~/dotfiles/.agents/claude/
rsync -a path/to/freekmurze-dotfiles/config/claude/agents/ ~/dotfiles/.agents/claude/agents/
```

Edit `.agents/claude/settings.json` per machine (permissions, MCP, plugins).
