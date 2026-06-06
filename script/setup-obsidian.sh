#!/usr/bin/env bash
# Install Obsidian and wire up the vault for cross-machine sync via MEGAcmd.
#
# What this script does:
#   1. Installs Obsidian (brew cask on macOS, yay/AUR on Arch)
#   2. Installs MEGAcmd (brew on macOS, yay/AUR on Arch)
#   3. Creates ~/Documents/Obsidian as the vault directory
#   4. Logs into MEGA if not already logged in (interactive prompt)
#   5. Configures background sync: ~/Documents/Obsidian <-> MEGA:/Obsidian
#   6. Writes the obsidian MCP server path into ~/.claude/settings.local.json
#      (machine-specific; gitignored — so settings.json stays clean)
#
# Idempotent — safe to re-run. Steps that are already done are skipped.
set -euo pipefail

VAULT="$HOME/Documents/Obsidian"

# ── Helpers ──────────────────────────────────────────────────────────────────

is_mac()  { [[ "$OSTYPE" == "darwin"* ]]; }
is_arch() { command -v yay >/dev/null 2>&1; }

brew_cask_installed() { brew list --cask "$1" >/dev/null 2>&1; }
yay_installed()       { yay -Q "$1" >/dev/null 2>&1; }

# ── Install Obsidian ──────────────────────────────────────────────────────────

install_obsidian() {
    if is_mac; then
        if [ "$(uname -m)" = "x86_64" ]; then
            # Intel: download universal DMG from GitHub releases (no brew)
            [ -d "/Applications/Obsidian.app" ] && return 0
            local url
            url=$(curl -fsSL "https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest" \
                | grep '"browser_download_url"' \
                | grep '\.dmg"' \
                | grep -v 'arm64' \
                | sed 's/.*"\(https[^"]*\)".*/\1/' \
                | head -1)
            curl -fsSL "$url" -o /tmp/Obsidian.dmg
            hdiutil attach /tmp/Obsidian.dmg -mountpoint /Volumes/Obsidian -nobrowse -quiet
            cp -R "/Volumes/Obsidian/Obsidian.app" /Applications/
            hdiutil detach /Volumes/Obsidian -quiet
            rm -f /tmp/Obsidian.dmg
        else
            # Apple Silicon: brew cask
            brew_cask_installed obsidian || brew install --cask obsidian
        fi
    elif is_arch; then
        yay_installed obsidian || yay -S --noconfirm --needed obsidian
    else
        printf 'setup-obsidian: unsupported platform — install Obsidian manually\n' >&2
    fi
}

# ── Install MEGAcmd ───────────────────────────────────────────────────────────

install_megacmd() {
    if command -v mega-whoami >/dev/null 2>&1; then
        return 0
    fi
    if is_mac; then
        # MEGAcmd has no GitHub releases; brew is the reliable source on both architectures
        brew install megacmd
    elif is_arch; then
        yay -S --noconfirm --needed megacmd-bin
    else
        printf 'setup-obsidian: unsupported platform — install MEGAcmd manually\n' >&2
    fi
}

# ── Configure MEGA sync ───────────────────────────────────────────────────────

configure_mega_sync() {
    if ! command -v mega-whoami >/dev/null 2>&1; then
        printf 'setup-obsidian: MEGAcmd not installed — skipping sync\n' >&2
        return 0
    fi

    # Log in if not already authenticated
    if ! mega-whoami >/dev/null 2>&1; then
        printf '\nsetup-obsidian: MEGA login required for vault sync.\n'
        mega-login
        # Abort sync setup if login failed (user hit Ctrl-C or entered wrong password)
        if ! mega-whoami >/dev/null 2>&1; then
            printf 'setup-obsidian: login failed — skipping sync setup\n' >&2
            return 0
        fi
    fi

    printf 'setup-obsidian: logged in as %s\n' "$(mega-whoami)"

    # Check if this vault is already registered as a sync
    if mega-sync 2>/dev/null | grep -qF "$VAULT"; then
        printf 'setup-obsidian: sync already active for %s\n' "$VAULT"
        return 0
    fi

    printf 'setup-obsidian: configuring sync %s <-> MEGA:/Obsidian\n' "$VAULT"
    mega-mkdir /Obsidian 2>/dev/null || true   # ok if remote folder already exists
    mega-sync "$VAULT" /Obsidian
    printf 'setup-obsidian: sync configured\n'
}

# ── Write MCP path to settings.local.json ────────────────────────────────────
# settings.json is committed and shared — it must not contain machine-specific
# paths. settings.local.json is gitignored and generated here per machine.

configure_mcp() {
    local mcp_cmd="$HOME/.asdf/shims/mcp-obsidian"
    local settings="$HOME/.claude/settings.local.json"

    if [ ! -f "$mcp_cmd" ]; then
        printf 'setup-obsidian: mcp-obsidian not found at %s — install it with: npm install -g mcp-obsidian\n' "$mcp_cmd" >&2
        return 0
    fi

    mkdir -p "$(dirname "$settings")"

    # python3 is available on both macOS and Arch; use it for safe JSON merge
    if ! command -v python3 >/dev/null 2>&1; then
        printf 'setup-obsidian: python3 not found — update %s manually\n' "$settings" >&2
        return 0
    fi

    python3 - "$settings" "$mcp_cmd" "$VAULT" <<'PYEOF'
import json, sys
path, cmd, vault = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
cfg.setdefault("mcpServers", {})["obsidian"] = {"command": cmd, "args": [vault]}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF

    printf 'setup-obsidian: obsidian MCP path written to %s\n' "$settings"
}

# ── Main ──────────────────────────────────────────────────────────────────────

mkdir -p "$HOME/Documents"
mkdir -p "$VAULT"

install_obsidian
install_megacmd
configure_mega_sync
configure_mcp

printf 'setup-obsidian: vault at %s\n' "$VAULT"
printf 'setup-obsidian: open Obsidian, point it at %s, then restart Claude Code\n' "$VAULT"
