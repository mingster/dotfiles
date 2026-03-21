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

## Claude Code CLI and Claude Code Desktop (skills)

[Claude Code](https://code.claude.com/docs/en/overview) in the **terminal** and in the **Claude Code desktop app** (download from [code.claude.com](https://code.claude.com/download)) both load **personal skills** from **`~/.claude/skills/`**. This repo wires that directory to **`~/dotfiles/.agents/skills`** via **`script/setup-claude-code.sh`** (run from **`install.sh`** or your platform **`system_setup.sh`**).

After linking, the same skill folders appear in:

- **`~/.agents/skills/`** (via **`~/.agents`** → dotfiles) for the [skills CLI](https://skills.sh/)
- **`~/.claude/skills/`** for Claude Code CLI and Claude Code Desktop

User **`~/.claude/settings.json`** is symlinked from **`.agents/claude/settings.json`**. It includes **`"Skill"`** in **`permissions.allow`** so Claude can invoke skills discovered under **`~/.claude/skills/`** without listing each skill by name. Tighten **`.agents/claude/settings.json`** on your machine if you want to allow only specific skills (see [permission rules in the docs](https://code.claude.com/docs/en/permissions)).

If you set **`CLAUDE_CONFIG_DIR`**, Claude Code uses that directory instead of **`~/.claude`** for config. Point it at a clone of that tree or add symlinks there so **`skills/`** still resolves to **`~/dotfiles/.agents/skills`**.

The separate **Anthropic Claude** chat app (MCP, **`~/Library/Application Support/Claude/`** on macOS) does **not** use the same **`~/.claude/skills`** layout as Claude Code. Use MCP or in-app skills for that client.

### Duplicate skills in Cursor

[Cursor loads global skills](https://cursor.com/docs/context/skills) from **`~/.cursor/skills/`** and from **`~/.claude/skills/`** (compatibility). If both paths point at the same skill tree, **each skill shows up twice** in Agent. **`script/setup-claude-code.sh`** removes **`~/.cursor/skills`** when it resolves to the same directory as **`~/.claude/skills`**. Re-run **`install.sh`** or that script after tools create **`~/.cursor/skills`**. Prefer a single tree under **`~/dotfiles/.agents/skills`** via **`~/.claude/skills`** only.
