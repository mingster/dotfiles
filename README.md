# Ming’s dotfiles

Personal configuration for a productive shell and editor setup on **macOS** and **Linux** (Arch, Debian). Install scripts link configs from this repo into your home directory so you can version everything in git and reproduce the same environment on a new machine.

Inspired by [Mathias Bynens’s dotfiles](https://github.com/mathiasbynens/dotfiles). More background on the dotfiles idea: [dotfiles.github.io](http://dotfiles.github.io).

---

## Table of contents

- [Quick start (macOS)](#quick-start-macos)
- [Quick start (Linux)](#quick-start-linux)
- [What’s included](#whats-included)
- [AI, Cursor, and Claude Code](#ai-cursor-and-claude-code)
- [Environment variables](#environment-variables)
- [Installation](#installation)
  - [What `install.sh` does](#what-installsh-does)
- [Optional: more software](#optional-more-software)
- [Repository layout](#repository-layout)
- [Feedback & thanks](#feedback--thanks)

---

## Quick start (macOS)

```bash
mkdir -p ~/GitHub && cd ~/GitHub
git clone https://github.com/mingster/dotfiles.git && cd dotfiles

sh mac/osxprep.sh          # Command Line Tools + prep
sh mac/osx.sh              # Optional: macOS defaults (review first)
sh install.sh              # Symlinks, .agents, Cursor, Claude Code; runs mac/system_setup.sh
```

Each run of `**install.sh**` (bash script, runnable as `sh install.sh` or `bash install.sh`):

1. Sets `**~/dotfiles**` to a symlink → **the absolute path of the directory that contains `install.sh`** (re-running from another clone retargets `~/dotfiles`).
2. Refreshes home links for git, vim, `**.agents**`, **Claude Code** (`script/setup-claude-code.sh` → `~/.claude/`), and **Cursor** (rules + user settings via `script/link-cursor-user.sh`).

If `**~/dotfiles` exists as a real directory** (not a symlink), the script **exits with an error** so nothing is overwritten blindly.

---

## Quick start (Linux)

Same clone location as macOS. `**install.sh`** sets up home symlinks (including `**.agents**`, **Claude Code** via `script/setup-claude-code.sh`, **Cursor** via `script/link-cursor-user.sh`), then runs the right `**system_setup`** for the machine:


| OS                                                                 | Script                   |
| ------------------------------------------------------------------ | ------------------------ |
| macOS                                                              | `mac/system_setup.sh`    |
| Arch (`ID=arch` in `/etc/os-release`, or Arch-like `ID_LIKE`)      | `arch/system_setup.sh`   |
| Debian / Ubuntu / Mint / Pop!_OS / Zorin, or Debian-like `ID_LIKE` | `debian/system_setup.sh` |


Unsupported distros print a message but still keep the symlinks from earlier in the script. To **only** link dotfiles and skip the heavy installer (testing, unsupported distro), use `**DOTFILES_SKIP_SYSTEM_SETUP=1`**.

```bash
mkdir -p ~/GitHub && cd ~/GitHub
git clone https://github.com/mingster/dotfiles.git && cd dotfiles

sh install.sh                       # symlinks + platform system_setup
```

Requirements: `**bash**`, `**git**`, and `**sudo**` where the platform script installs packages. Read `**arch/system_setup.sh**` or `**debian/system_setup.sh**` before running on a machine you care about. They are full environment installers.

On **Windows** (Git Bash / MSYS), `**install.sh`** still runs the symlink block when `**$HOME/dotfiles**` resolves; `**system_setup**` is skipped and Cursor user linking may not apply (see `script/link-cursor-user.sh`).

---

## What’s included


| Area             | Notes                                                                                                                                                                                                                                                 |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Shell & terminal | [Fish](https://fishshell.com/), [Fisher](https://github.com/jorgebucaran/fisher), [Tide](https://github.com/IlanCosman/tide) v6 (`fisher install ilancosman/tide@v6`)                                                                                 |
| macOS            | [Homebrew](https://brew.sh), preferences via `mac/osx.sh`                                                                                                                                                                                             |
| Fonts            | [Nerd Fonts](https://github.com/ryanoasis/nerd-fonts) — Hack (see `mac/system_setup.sh`)                                                                                                                                                              |
| Terminal tools   | [tmux](https://github.com/tmux/tmux/wiki), [lf](https://www.joshmedeski.com/posts/manage-files-with-lf/), [lazygit](https://github.com/jesseduffield/lazygit)                                                                                         |
| Editors          | VS Code extension lists under `vscode/`; Cursor under `cursor/`                                                                                                                                                                                       |
| Config           | GNU [stow](https://www.gnu.org/software/stow/) via `mac/stowall` on macOS; on Linux run `stow` yourself against `~/dotfiles/.config` packages if you use the same layout                                                                              |
| Linux            | `arch/system_setup.sh`, `debian/system_setup.sh`, plus `arch/install_*.sh` / `debian/install_*.sh` for optional stacks                                                                                                                                |
| CI               | [ShellCheck](https://www.shellcheck.net/) on `install.sh`, `mac/stowall`, and `mac` / `arch` / `debian` `system_setup.sh` (see `script/shellcheck-dotfiles.sh`); JSON validation for `.agents/.skill-lock.json` when that file is present in the repo |


---

## AI, Cursor, and Claude Code

Dotfiles wires **skills** ([skills CLI](https://skills.sh/)), **Claude Code**, and **Cursor** (global rules + user `settings.json` / `keybindings.json`) into your home directory.


| Topic                      | Summary                                                                                                                                                                                                                                                                                                                                                                                                                   |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Agent skills**           | `~/.agents` → `~/dotfiles/.agents`. Lock file: `.agents/.skill-lock.json`. Restore: `bash ~/dotfiles/script/bootstrap-agents.sh` or `DOTFILES_INSTALL_SKILLS=1 sh install.sh`. See [.agents/README.md](.agents/README.md).                                                                                                                                                                                                |
| **Claude Code** | `script/setup-claude-code.sh` links `~/.claude/` into `~/dotfiles/.agents` (`skills/`, `claude/`, `claude/agents/`). **Claude Code CLI** and **Claude Code Desktop** ([code.claude.com](https://code.claude.com/download)) both use `~/.claude/skills/`, same tree as the skills CLI. `.agents/claude/settings.json` includes `"Skill"` in `permissions.allow` so skills under that tree can run (tighten if you want). See [.agents/README.md](.agents/README.md). Do not commit secrets (see `.gitignore`). |
| **Cursor**                 | Rules: `~/.cursor/rules` → `~/dotfiles/cursor/rules` (see `cursor/rules/README.md`). User settings: `script/link-cursor-user.sh` → Cursor **User** `settings.json` and `keybindings.json`. Prisma-related editor options align with riben `web/.vscode/settings.json`. MCP: use `cursor/mcp.json.example`; keep real keys out of git.                                                                                     |
| **Entry point for agents** | [AGENTS.md](AGENTS.md) — paths and boundaries for work in this repo.                                                                                                                                                                                                                                                                                                                                                      |
| **Copilot on GitHub**      | [.github/copilot-instructions.md](.github/copilot-instructions.md)                                                                                                                                                                                                                                                                                                                                                        |


## Environment variables


| Variable                       | When set                            | Effect                                                                                                                                                                                                                                                                                           |
| ------------------------------ | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `DOTFILES_INSTALL_SKILLS=1`    | With `install.sh`                   | Runs `npx skills@latest experimental_install` via `script/bootstrap-agents.sh` (needs Node / `npx`).                                                                                                                                                                                             |
| `DOTFILES_BREW_UPGRADE=1`      | With `install.sh` on **macOS** only | Runs `brew upgrade` in `mac/system_setup.sh` (otherwise only `brew update`). Ignored on Linux.                                                                                                                                                                                                   |
| `DOTFILES_SKIP_SYSTEM_SETUP=1` | With `install.sh`                   | Skips `**mac/`** / `**arch/**` / `**debian/**` `system_setup.sh` (symlinks, `.agents`, Claude Code, and Cursor setup still run).                                                                                                                                                                 |
| `DOTFILES`                     | Optional                            | Some helpers default to `$HOME/dotfiles`; set this if your dotfiles root differs (used by `script/bootstrap-agents.sh`, `script/setup-claude-code.sh`, `script/link-cursor-user.sh`). `**install.sh**` does not read `DOTFILES`; it derives the repo path from the location of `**install.sh**`. |


Examples:

```bash
DOTFILES_INSTALL_SKILLS=1 sh ~/GitHub/dotfiles/install.sh
DOTFILES_BREW_UPGRADE=1 sh ~/GitHub/dotfiles/install.sh
```

---

## Installation

### 1. Clone the repository (all platforms)

```bash
mkdir -p ~/GitHub && cd ~/GitHub
git clone https://github.com/mingster/dotfiles.git && cd dotfiles
```

### 2. Run `install.sh` (all platforms)

From the repo root (or use absolute paths):

```bash
sh install.sh
```

This ensures `**~/dotfiles**` → this repo, links shell/git/vim dotfiles (overwriting previous symlinks), sets up `**.agents**`, **Claude Code** (`script/setup-claude-code.sh`), **Cursor** rules + user settings, and optional skills when `**DOTFILES_INSTALL_SKILLS=1`**. It then runs the platform `**system_setup**` detected from `**OSTYPE**` and `**/etc/os-release**` on Linux (see [Quick start (Linux)](#quick-start-linux)), unless `**DOTFILES_SKIP_SYSTEM_SETUP=1**`.

### What `install.sh` does

Order of operations (see source in `[install.sh](install.sh)`):

1. `**~/dotfiles**` → symlink to this repo (fails if `**~/dotfiles**` exists and is not a symlink).
2. **Home symlinks** (targets under the repo): `.csvignore`, `.editorconfig`, `.gitattributes`, `.gitflow_export`, `.gitignore`, `.gitignore_global`, `.hgignore_global`, `.nanorc`, `.vimrc`, `.vim`.
3. `**~/.gitconfig`** copied from `.gitconfig` (arm64) or `.gitconfig-x64` (x86_64).
4. `**git config --global**` `core.excludesfile` and `core.attributesfile` pointing at files in this repo.
5. `**mkdir -p ~/dotfiles/.agents**`, `**~/.agents**` → `**~/dotfiles/.agents**`.
6. `**bash script/setup-claude-code.sh**`: `**~/.claude/**` ← symlinks into `**.agents/skills**`, `**.agents/claude/**`, and `**.agents/claude/agents/**`.
7. `**~/.cursor/rules**` → `**~/dotfiles/cursor/rules**`.
8. If `**DOTFILES_INSTALL_SKILLS=1**`: `**bash script/bootstrap-agents.sh**`.
9. `**bash script/link-cursor-user.sh**`: Cursor User `**settings.json**` and `**keybindings.json**` → `**~/dotfiles/cursor/**` (macOS and Linux paths only).
10. Unless `**DOTFILES_SKIP_SYSTEM_SETUP=1**`, run `**mac/system_setup.sh**`, `**arch/system_setup.sh**`, or `**debian/system_setup.sh**` as detected.

Platform `**system_setup**` scripts also call `**bash script/setup-claude-code.sh**` (and other links) so a manual re-run of `**system_setup**` stays aligned.

**Symlink loop (`Too many levels of symbolic links`):** `install.sh` uses the physical repo path (`pwd -P`) so `~/dotfiles` and paths like `~/dotfiles/mac/system_setup.sh` do not walk a circular symlink chain. If you still see this error, remove the broken symlink `rm ~/dotfiles` (only if it is a symlink, not a real folder), then run `install.sh` again from your clone (for example `cd ~/GitHub/dotfiles && sh install.sh`). Do not point two locations at each other (for example `~/dotfiles` → `~/GitHub/dotfiles` and `~/GitHub/dotfiles` → `~/dotfiles`).

**Duplicate skills in Cursor:** Cursor loads global skills from both `~/.cursor/skills/` and `~/.claude/skills/`. If both point at the same tree, every skill appears twice. `script/setup-claude-code.sh` removes a redundant `~/.cursor/skills` when it matches `~/.claude/skills` (re-run `install.sh` or that script). See [.agents/README.md](.agents/README.md#duplicate-skills-in-cursor).

### 3. macOS-only steps

#### Software updates and Command Line Tools

```bash
sh ~/GitHub/dotfiles/mac/osxprep.sh
```

Run **before** or **after** `install.sh` depending on whether you need CLT first; adjust to your workflow.

#### Optional: system defaults

Review `mac/osx.sh`, then:

```bash
sh ~/GitHub/dotfiles/mac/osx.sh
```

#### Optional: extra apps

Review and edit first. Installs many CLI and GUI packages:

```bash
sh ~/GitHub/dotfiles/mac/install_my_software.sh
```

### 4. Linux-only notes

`install.sh` already invokes `**arch/system_setup.sh**` or `**debian/system_setup.sh**` when `**/etc/os-release**` matches (see [Quick start (Linux)](#quick-start-linux)). To run a script **again** manually (for example after editing it):

```bash
cd ~/GitHub/dotfiles
bash arch/system_setup.sh    # or debian/system_setup.sh
```

Read the script first: both install packages, change the default shell to fish, configure UFW and desktop tooling, etc.

---

## Optional: more software

- **macOS:** `mac/install_*.sh` — Android, AWS, databases, Python, Node, nginx, etc.
- **Linux (Arch):** `arch/install_*.sh` — Node, Java, PostgreSQL, MongoDB, NVIDIA, KDE, Claude Code (`arch/install_claude.sh`), Zed (`arch/install_zed.sh`), and others.
- **Linux (Debian):** `debian/install_*.sh` — TeX, Zotero, Mullvad, singularity, VNC, etc.
- **Editors (all):** [vscode/vscode_README.md](vscode/vscode_README.md), [vscode/install-vscode-extensions.sh](vscode/install-vscode-extensions.sh), [cursor/install-vscode-extensions_cursor.sh](cursor/install-vscode-extensions_cursor.sh)

---

## Repository layout


| Path                       | Role                                                                                                                  |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `install.sh`               | Top-level bootstrap: `~/dotfiles` symlink, home dotfiles, `.agents`, Claude Code, Cursor, then `system_setup`         |
| Top-level dotfiles         | Repo root files linked into `$HOME` (for example `.gitconfig`, `.vimrc`, `.vim`, `.gitignore_global`, …)              |
| `mac/`, `arch/`, `debian/` | Platform-specific installers and `system_setup.sh`                                                                    |
| `mac/stowall`              | Stow all packages under `$HOME/dotfiles/.config` (`DOTFILES` overrides root in that script)                           |
| `script/`                  | `bootstrap-agents.sh`, `setup-claude-code.sh`, `link-cursor-user.sh`, `shellcheck-dotfiles.sh`                        |
| `.agents/`                 | Skills (`skills/`, `.skill-lock.json`), Claude-only files under `claude/`; see [.agents/README.md](.agents/README.md) |
| `.config/`                 | App configs consumed via `stow` / platform scripts (nvim, fish, tmux, kitty, …)                                       |
| `cursor/`                  | Cursor user `settings.json`, `keybindings.json`, `rules/`, `mcp.json.example`                                         |
| `vscode/`                  | VS Code settings and extension install script                                                                         |
| `AGENTS.md`                | Short map of AI-related paths for work in this repo                                                                   |
| `.github/`                 | Copilot instructions, workflows (ShellCheck, skill-lock JSON)                                                         |
| `_outdated/`               | Older scripts kept for reference                                                                                      |


---

## Feedback & thanks

Suggestions and improvements are [welcome](https://github.com/mingster/dotfiles/issues).

Thanks to [josean-dev / dev-environment-files](https://github.com/josean-dev/dev-environment-files), [Sketchybar setup (josean.com)](https://www.josean.com/posts/sketchybar-setup), @ptb’s [Mac OS X Lion Setup](https://github.com/ptb/Mac-OS-X-Lion-Setup), [Ben Alman](https://github.com/cowboy/dotfiles), [Chris Gerke / Insta](https://github.com/cgerke/Insta), [Cãtãlin Mariş](https://github.com/alrra/dotfiles), [Gianni Chiappini / gf3](https://github.com/gf3/dotfiles), [Jan Moesen / tilde](https://github.com/janmoesen/tilde), [Lauri Ranta / OS X notes](http://osxnotes.net/defaults.html), [Matijs Brinkhuis](https://github.com/matijs/dotfiles), [Nicolas Gallagher](https://github.com/necolas/dotfiles), [Sindre Sorhus](https://sindresorhus.com/), [Tom Ryder](https://github.com/tejr/dotfiles), [Kevin Suttle / OSXDefaults](https://github.com/kevinSuttle/OSXDefaults), [Haralan Dobrev](http://hkdobrev.com/), and everyone who [contributed](https://github.com/mingster/dotfiles/contributors) or [suggested improvements](https://github.com/mingster/dotfiles/issues).