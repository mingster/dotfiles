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
# Usage: setup-obsidian.sh   (no arguments; -h and --help print this line, any other argument exits 2)
# Arguments are read only when run directly; a test that sources this file passes its own $1.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1-}" in
    -h|--help) echo "Usage: setup-obsidian.sh   (Install Obsidian and wire up the vault sync; no arguments)"; exit 0 ;;
  esac
  if [ "$#" -ne 0 ]; then
    echo "Usage: setup-obsidian.sh   (no arguments; got: $*)" >&2
    exit 2
  fi
fi
set -euo pipefail

VAULT="$HOME/Documents/Obsidian"

# ── Helpers ──────────────────────────────────────────────────────────────────

is_mac()  { [[ "$OSTYPE" == "darwin"* ]]; }
is_arch() { command -v yay >/dev/null 2>&1; }

brew_cask_installed() { brew list --cask "$1" >/dev/null 2>&1; }
yay_installed()       { yay -Q "$1" >/dev/null 2>&1; }

# ── Install Obsidian ──────────────────────────────────────────────────────────

cleanup_obsidian_dmg() {
    [ -z "${OBSIDIAN_MOUNT:-}" ] || hdiutil detach "$OBSIDIAN_MOUNT" -quiet || true
    [ -z "${OBSIDIAN_WORK:-}" ] || rm -rf "$OBSIDIAN_WORK"
}

install_obsidian() {
    if is_mac; then
        if [ "$(uname -m)" = "x86_64" ]; then
            # Intel: download universal DMG from GitHub releases (no brew)
            local apps=${OBSIDIAN_APPLICATIONS_DIR:-/Applications}
            [ -d "$apps/Obsidian.app" ] && return 0
            local url
            url=$(curl -fsSL "https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest" \
                | grep '"browser_download_url"' \
                | grep '\.dmg"' \
                | grep -v 'arm64' \
                | sed 's/.*"\(https[^"]*\)".*/\1/' \
                | head -1) || true
            if [ -z "$url" ]; then
                printf 'setup-obsidian: no Obsidian DMG URL in the latest release (API rate limit?)\n' >&2
                return 1
            fi
            # The trap detaches the volume (when attached) and removes the temp dir, even when a step fails.
            OBSIDIAN_WORK=$(mktemp -d)
            OBSIDIAN_MOUNT=""
            trap cleanup_obsidian_dmg EXIT
            curl -fsSL "$url" -o "$OBSIDIAN_WORK/Obsidian.dmg"
            hdiutil attach "$OBSIDIAN_WORK/Obsidian.dmg" -mountpoint "$OBSIDIAN_WORK/mnt" -nobrowse -quiet
            OBSIDIAN_MOUNT="$OBSIDIAN_WORK/mnt"
            cp -R "$OBSIDIAN_MOUNT/Obsidian.app" "$apps/"
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
        # Official MEGAcmd from MEGA NZ — provides mega-whoami, mega-login, mega-sync, etc.
        brew install --cask megacmd-app
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
    local mcp_cmd
    mcp_cmd=$(command -v mcp-obsidian 2>/dev/null || true)
    local settings="$HOME/.claude/settings.local.json"

    if [ -z "$mcp_cmd" ]; then
        printf 'setup-obsidian: mcp-obsidian not found — install it with: npm install -g mcp-obsidian\n' >&2
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
