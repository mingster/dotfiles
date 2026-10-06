# Ming's dotfiles

Personal configuration for macOS, Arch and Debian. `install.sh` wires everything up and is safe to re-run.

## Quick start

```bash
mkdir -p ~/GitHub && cd ~/GitHub
git clone https://github.com/mingster/dotfiles.git && cd dotfiles
sh mac/osxprep.sh   # macOS only: Command Line Tools
sh install.sh
```

`install.sh` links `~/dotfiles` to this repo, links shell and git dotfiles into `$HOME`, creates `~/.agents`, sets up the AI tooling below, then runs the OS installer (`mac/`, `arch/` or `debian/` `system_setup.sh`). Already installed software is skipped. `DOTFILES_SKIP_SYSTEM_SETUP=1 sh install.sh` only refreshes links. `DOTFILES_BREW_UPGRADE=1` also runs `brew upgrade` on macOS.

## AI tooling

| Script | Sets up |
| --- | --- |
| `script/setup-claude-code.sh` | `~/.claude/` from `.agents/claude/`, skills at `~/.claude/skills/` |
| `script/setup-claude-desktop.sh` | Claude Desktop config |
| `script/setup-cursor.sh`, `link-cursor-user.sh` | Cursor app, rules, settings, hooks, and `~/.cursor/skills` |
| `script/setup-antigravity.sh` | Antigravity settings and `~/.gemini/config/skills.json` |
| `script/setup-vscode.sh` | VS Code settings |
| `script/setup-obsidian.sh` | Obsidian vault at `~/Documents/Obsidian`, synced with MEGAcmd |

### Skills

Reusable skills live in `.agents/skills/<name>/` and are visible to Claude Code, Codex, Cursor and Antigravity through `~/.agents`, `~/.claude/skills`, `~/.cursor/skills` and the Antigravity `skills.json`. A project skill with the same name as a central one silently wins, so keep the two sets apart:

| Kind | Lives in |
| --- | --- |
| Reusable across projects | here, `.agents/skills/<name>/`, and nowhere else |
| Project specific | `<project>/.agents/skills/<name>/`, with symlinks from `<project>/.claude/skills/` and `<project>/.cursor/skills/` |

Run `script/check-skill-collisions.sh` to find a project skill that shadows a central one, a broken symlink, or a missing `SKILL.md`. MCP secrets go in `~/.claude/settings.local.json` (gitignored). Paths reference: [AGENTS.md](AGENTS.md).

### Agent team template

`script/adopt-agent-team.sh [--project-name <name>] <dir>` installs the agent team into any repo: roles, the team skills (through `script/sync-team-skills.sh`), facts file skeletons, settings, hooks, model routing and a Token budget block for `AGENTS.md`. Elon is the front door and dispatches the teammates through Orca orchestration. Source: `templates/agent-team/`.

### Context and notes

Project instructions (`AGENTS.md`) load always. Short cross-project rules live in `~/.claude/notes/` (`.agents/claude/notes/`) and the Obsidian vault holds deep docs. Add a lesson from any project:

```bash
~/dotfiles/script/contribute-to-agents.sh nextjs "Nested route-group layouts cause dev 404s"
```

## Backups

```bash
bash script/backup-claude-desktop.sh   # Claude Desktop settings into init/
fish script/backup-tide.fish           # Tide prompt config
```

## Layout

| Path | Role |
| --- | --- |
| `install.sh` | Single entry point |
| `mac/` `arch/` `debian/` | Platform installers |
| `script/` | Setup, backup and agent team scripts |
| `.agents/` | Skills and Claude Code config (`claude/`) |
| `templates/agent-team/` | The agent team template |
| `.config/`, `ide/cursor/`, `vscode/`, `Antigravity/` | App and editor configs |

## Example prompts

```text
Adopt the agent team into ~/projects/acme with script/adopt-agent-team.sh, then show me what it installed.
```

```text
Run script/check-skill-collisions.sh and fix what it reports.
```
