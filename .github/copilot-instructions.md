# Copilot / AI contributor guidance (dotfiles)

Purpose
- This repository contains personal dotfiles and platform install scripts for macOS, Arch, Debian and more. The goal of this document is to give AI agents just-enough, actionable context to be productive quickly — where to read, how to test, and what conventions to follow.

High-level architecture (big picture)
- Top-level: generic dotfiles and helpers (e.g., `install.sh`, `.gitconfig`, `.stow-local-ignore`).
- Platform folders: `mac/`, `arch/`, `debian/`, `rasp/`, `ms/` contain platform-specific installation and system setup scripts (naming pattern: `install_*.sh`, `uninstall_*.sh`, `system_setup.sh`).
- Agent skills: `install.sh` and platform `system_setup` scripts create **`~/dotfiles/.agents`** and symlink **`~/.agents` → `~/dotfiles/.agents`**. Skill content and `.skill-lock.json` live under `.agents/` in the repo; restore with **`bash script/bootstrap-agents.sh`** or `npx skills@latest experimental_install` from `~/.agents` (optional: **`DOTFILES_INSTALL_SKILLS=1`** with `install.sh`). See `README.md`.
- Claude Code (CLI + [Desktop](https://code.claude.com/download)): canonical tree is **`~/dotfiles/.agents/`** (shared **`skills/`**; Claude-only files under **`claude/`**). **`script/setup-claude-code.sh`** links **`~/.claude/`** (including **`~/.claude/skills`**). User **`settings.json`** should include **`"Skill"`** in **`permissions.allow`** so skills are usable. Do not commit secrets (see `.gitignore`).
- Cursor: **`~/dotfiles/cursor/rules`** is canonical for global rules (synced from **riben.life** `web/.cursor/rules`); **`~/.cursor/rules`** symlinks there. **`script/link-cursor-user.sh`** symlinks **`cursor/settings.json`** and **`keybindings.json`** into the Cursor **User** directory (same idea as VS Code user settings). **`cursor/mcp.json.example`** shows MCP shape; real **`mcp.json`** with keys stays local / gitignored.
- **`AGENTS.md`** at repo root summarizes paths and boundaries for agents working in this repo.
- Config packages: `~/.config` managed via GNU `stow` using `mac/stowall` (run `mac/stowall` to stow everything in `.config`). **`mac/stowall`** uses **`$HOME/dotfiles`** (override with **`DOTFILES`**); align with the `~/dotfiles` symlink from `install.sh`.
- Editor and tooling: `vscode/` stores VS Code profiles and an extension install script `vscode/install-vscode-extensions.sh` (use this file to update extension lists — avoid editing the binary-ish `vscode-settings.code-profile` unless necessary).

Key workflows (how to run & validate changes)
- Install / bootstrap: run `sh install.sh` from repo root. It runs **`mac/system_setup.sh`** on macOS, **`arch/system_setup.sh`** or **`debian/system_setup.sh`** on Linux (from `/etc/os-release`), unless **`DOTFILES_SKIP_SYSTEM_SETUP=1`**.
- Prepare macOS: `sh mac/osxprep.sh` then `sh mac/osx.sh` (carefully review `osx.sh` before running — it changes OS defaults).
- Stow configs (linking into `$HOME`): from repo root run `mac/stowall` or `stow -n <package>` for a dry-run; use `stow -v` for verbose output.
- ShellCheck: CI runs `script/shellcheck-dotfiles.sh` (error-severity only). Run locally before pushing; use plain `shellcheck` on a file for full info-level hints.
- VS Code extensions: update `vscode/install-vscode-extensions.sh` and run it (`code --install-extension ...`) to install from the canonical list.

Project-specific conventions & patterns
- Platform-first scripts: adding or modifying platform behavior should live under the matching platform folder (e.g., a mac-only change => `mac/`).
- Install scripts check and install Homebrew when needed (pattern: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`). Follow that pattern for idempotent installs.
- Avoid editing generated or exported artifacts: `vscode/vscode-settings.code-profile` is a generated profile; prefer editing the source script (`vscode/install-vscode-extensions.sh`) or the original user settings under `vscode/`.
- Use `.stow-local-ignore` to exclude files/packages from stow; do not add secrets or machine-local files to the repo.

Testing & verification notes
- For config changes: test a dry-run with `stow -n` and then apply with `stow -R <package>` or use `mac/stowall`.
- For install scripts: run locally on the same platform in a VM or throwaway machine. Scripts are shell-based — read them first and test incrementally.
- For VS Code: run `vscode/install-vscode-extensions.sh` to validate extension changes; DO NOT edit `vscode-settings.code-profile` to change extension lists — it’s an export.

Files to read first (essential reading order)
1. `README.md` and `AGENTS.md` (overview, install steps, AI path map)
2. `install.sh` (symlinks, `.agents`, `script/setup-claude-code.sh`, Cursor; optional `DOTFILES_INSTALL_SKILLS`; then OS-specific `system_setup` unless `DOTFILES_SKIP_SYSTEM_SETUP`)
3. `mac/system_setup.sh`, `mac/osxprep.sh`, `mac/stowall` (mac-specific flows; `DOTFILES_BREW_UPGRADE=1` enables `brew upgrade` in `system_setup.sh`)
4. `script/shellcheck-dotfiles.sh` (ShellCheck entrypoints used by CI)
5. `vscode/install-vscode-extensions.sh` and `vscode/vscode-settings.code-profile` (extension and settings notes)
6. `.stow-local-ignore` and `.gitconfig` (linking and git configuration patterns)

PR guidance for contributors/agents
- Keep PRs small and platform-targeted. Example: "Add `brew` package X to `mac/install_my_software.sh` and document the reason in the script".
- Include a short validation checklist in PR description: dry-run stow output, script run log or a screenshot showing `code --list-extensions` for VS Code changes.
- Do not commit secrets or personal tokens. If a change requires secret keys, leave instructions in the README and reference environment variable names only.

Helpful tips & pitfalls
- Architecture-sensitive files: `install.sh` copies `.gitconfig` differently for `arm64` vs `x86_64` — be careful when modifying `git` settings.
- `_outdated/` contains older scripts and references for historical context — prefer updating active files under `mac/`, `arch/`, `debian/`.
- Use `stow -n` before applying changes to avoid accidental overwrites.

If something is unclear or you need sample tasks to start, ask me which area (mac config, VS Code profile, stow package) you want to tackle and I’ll supply focused action items.
