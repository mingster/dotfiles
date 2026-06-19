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
| `script/setup-cursor.sh` | Cursor app + rules (`~/.cursor/rules`) + user settings + global hooks |
| `script/setup-vscode.sh` | VS Code user settings and keybindings |
| `script/setup-antigravity.sh` | Antigravity IDE user settings and keybindings |
| `script/setup-obsidian.sh` | Obsidian app + vault at `~/Documents/Obsidian` |

Agent skills live as committed folders under `.agents/skills/`. They are shared across IDEs (Claude Code, Cursor, Zed, VS Code) via `~/.agents` and `~/.claude/skills`, so cloning the repo and running `install.sh` makes them available everywhere. No separate restore step.

MCP secrets go in `~/.claude/settings.local.json` (gitignored). See [AGENTS.md](AGENTS.md) for the full AI paths reference.

## Three-tier context system

Claude Code sessions load context in three tiers to keep the working window lean:

| Tier | Location | Loaded |
|------|----------|--------|
| **Project instructions** | `AGENTS.md` / `CLAUDE.md` in project root | Always (auto) |
| **Quick reference notes** | `~/.claude/notes/` → `.agents/claude/notes/` | On demand via `@`-include |
| **Deep docs and memory** | Obsidian vault `~/Documents/Obsidian` | On demand via `obsidian` MCP |

### Quick reference notes

Short cross-project rules and gotchas. Current topics: `stack`, `nextjs`, `prisma`,
`next-safe-action`. See [`.agents/claude/notes/`](.agents/claude/notes/) for the full index.

To add a learning from any project:

```bash
~/dotfiles/script/contribute-to-agents.sh <topic> "What I learned"
~/dotfiles/script/contribute-to-agents.sh nextjs "Nested route-group layouts cause dev 404s"
~/dotfiles/script/contribute-to-agents.sh prisma   # opens $EDITOR for a longer note
```

Commit the result to dotfiles so it is available on all machines.

### Obsidian vault

`~/Documents/Obsidian` is the memory and document hub. It holds project overview pages, extended
tech notes, architecture decision records, and session notes. The `obsidian` MCP server (configured
in `.agents/claude/settings.json`) lets Claude fetch notes on demand without loading them upfront.

Key entry points:

- `Projects Index.md` — all active projects
- `Tech Notes Index.md` — cross-project patterns with links to extended notes
- `Riben Life Docs/HOME.md` — full architecture docs for riben.life

To add a new project to the vault, create `Project Name.md` following the existing pattern and add
it to `Projects Index.md`.

### Vault sync (MEGAcmd)

`script/setup-obsidian.sh` (called by `install.sh`) handles the full sync setup on both macOS
and Arch: installs MEGAcmd, prompts for MEGA login if needed, and configures background sync of
`~/Documents/Obsidian` to `MEGA:/Obsidian`. Nothing to do manually — just run `sh install.sh`.

The MCP server path is written to `~/.claude/settings.local.json` (gitignored, generated per
machine) rather than committed to `settings.json`.

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
| `.agents/` | Skills (committed folders), Claude Code config (`claude/`) |
| `.config/` | App configs (fish, nvim, tmux, kitty, lazygit, ...) |
| `ide/cursor/` | Cursor settings, keybindings, rules, `hooks.json`, `hooks/*.sh`, `mcp.json.example` |
| `vscode/` | VS Code settings and keybindings |
| `Antigravity/` | Antigravity IDE settings and keybindings |
| `AGENTS.md` | AI paths reference for humans and agents |
