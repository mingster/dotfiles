# Ming's dotfiles

Personal configuration for macOS, Arch, and Debian. Run `install.sh` once to wire everything up. Re-run it anytime to refresh symlinks and settings.

## Quick start

```bash
mkdir -p ~/GitHub && cd ~/GitHub
git clone https://github.com/mingster/dotfiles.git && cd dotfiles

sh mac/osxprep.sh   # macOS only: Command Line Tools + prep
sh install.sh
```

`install.sh` is idempotent. Every install is guarded so already-installed software is skipped.

## What install.sh does

1. Sets `~/dotfiles` to a symlink pointing at this repo.
2. Links shell and git dotfiles into `$HOME`.
3. Creates `~/.agents` and wires up AI tooling (see below).
4. Detects the OS and runs the matching `system_setup.sh`.

| OS | Script |
|----|--------|
| macOS | `mac/system_setup.sh` |
| Arch (or Arch-like) | `arch/system_setup.sh` |
| Debian / Ubuntu / Mint / Pop / Zorin | `debian/system_setup.sh` |

Skip software installs and only refresh symlinks:

```bash
DOTFILES_SKIP_SYSTEM_SETUP=1 sh install.sh
```

## AI tooling

`install.sh` runs these scripts on every OS. Each one handles platform differences internally.

| Script | What it sets up |
|--------|-----------------|
| `script/setup-claude-code.sh` | `~/.claude/` linked from `.agents/claude/`; skills at `~/.claude/skills/` |
| `script/setup-claude-desktop.sh` | Claude Desktop config merged from `init/claude_desktop_config.json` |
| `script/setup-cursor.sh` | Cursor app + rules (`~/.cursor/rules`) + user settings |
| `script/setup-vscode.sh` | VS Code user settings and keybindings |
| `script/setup-antigravity.sh` | Antigravity IDE user settings and keybindings |
| `script/setup-obsidian.sh` | Obsidian app + vault at `~/Documents/Obsidian` |

Agent skills are managed via the [skills CLI](https://skills.sh/). Restore from the lockfile:

```bash
DOTFILES_INSTALL_SKILLS=1 sh install.sh
# or
bash script/bootstrap-agents.sh
```

MCP secrets go in `~/.claude/settings.local.json` (gitignored). See [AGENTS.md](AGENTS.md) for the full AI paths reference.

## Backup scripts

Run these after changing settings locally, then commit the result.

```bash
bash script/backup-claude-desktop.sh   # Claude Desktop preferences → init/claude_desktop_config.json
fish script/backup-tide.fish           # Tide prompt config → .config/fish/tide_config.fish
```

## Environment variables

| Variable | Effect |
|----------|--------|
| `DOTFILES_SKIP_SYSTEM_SETUP=1` | Skip `system_setup.sh`; still runs symlinks and AI tooling |
| `DOTFILES_INSTALL_SKILLS=1` | Restore skills from `.agents/.skill-lock.json` via `npx` |
| `DOTFILES_BREW_UPGRADE=1` | Run `brew upgrade` during macOS setup (default: `brew update` only) |

## Optional extras

- `mac/osx.sh` — macOS system defaults (review before running)
- `mac/install_my_software.sh` — GUI and CLI apps
- `mac/install_nodejs_dev.sh`, `install_java_dev.sh` — dev stacks
- `arch/install_*.sh`, `debian/install_*.sh` — platform-specific stacks

## Layout

| Path | Role |
|------|------|
| `install.sh` | Single entry point for all platforms |
| `mac/` `arch/` `debian/` | Platform installers and `system_setup.sh` |
| `script/` | Setup and backup scripts |
| `.agents/` | Skills, Claude Code config (`claude/`), skill lockfile |
| `.config/` | App configs (fish, nvim, tmux, kitty, lazygit, ...) |
| `cursor/` | Cursor settings, keybindings, rules, `mcp.json.example` |
| `vscode/` | VS Code settings and keybindings |
| `Antigravity/` | Antigravity IDE settings and keybindings |
| `AGENTS.md` | AI paths reference for humans and agents |
