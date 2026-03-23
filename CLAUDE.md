# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

## Architecture

Top-level `install.sh` is the single entry point for all platforms. It sets `~/dotfiles` as a symlink to the repo, refreshes home dotfiles, wires up `.agents` / Claude Code / Cursor, then delegates to the platform `system_setup.sh` (detected via `$OSTYPE` and `/etc/os-release`).

Platform folders `mac/`, `arch/`, `debian/` each contain a `system_setup.sh` (full env installer) and optional `install_*.sh` / `uninstall_*.sh` for optional stacks. A new platform behavior belongs in the matching folder, not in `install.sh`.

App configs under `.config/` are managed with GNU `stow`; on macOS `mac/stowall` stows everything. `~/.stow-local-ignore` controls what stow skips.

`install.sh` copies `.gitconfig` (arm64) or `.gitconfig-x64` (x86_64) rather than symlinking, because git config must be a real file.

## Commands

Run ShellCheck (same as CI, error-severity only):

```bash
bash script/shellcheck-dotfiles.sh
```

For full diagnostics on a single file:

```bash
shellcheck -x install.sh
```

Stow dry-run (verify before applying):

```bash
stow -n <package>           # dry-run a single package
mac/stowall                  # stow all .config packages on macOS
```

Bootstrap without running system_setup (e.g., unsupported distro or CI):

```bash
DOTFILES_SKIP_SYSTEM_SETUP=1 sh install.sh
```

Restore skills from lock file:

```bash
bash script/bootstrap-agents.sh
```

## Conventions

- Scripts must pass `shellcheck --severity=error`. CI enforces this on `install.sh`, `mac/stowall`, and the three `system_setup.sh` files.
- Installs must be idempotent; safe to re-run. Follow the Homebrew install pattern for external tools (check before installing).
- `_outdated/` is read-only historical context. Update active files under `mac/`, `arch/`, `debian/` instead.
- Do not edit `vscode/vscode-settings.code-profile` directly; update `vscode/install-vscode-extensions.sh` and re-export.
- `cursor/mcp.json` is gitignored. Use `cursor/mcp.json.example` as the template.
