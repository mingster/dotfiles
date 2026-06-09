#!/usr/bin/env bash
# Set up Claude Desktop on macOS / Linux.
# Merges dotfiles config files into the live Claude Desktop configs,
# preserving machine-local keys (localAgentModeTrustedFolders, etc.).
# Idempotent: safe to re-run.
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"

case "${OSTYPE:-}" in
  darwin*)
    CLAUDE_SUPPORT="$HOME/Library/Application Support/Claude"
    if [ ! -d "/Applications/Claude.app" ] && [ ! -d "$HOME/Applications/Claude.app" ]; then
      echo "setup-claude-desktop: Claude Desktop not installed; skipping." >&2
      exit 0
    fi
    ;;
  linux*)
    CLAUDE_SUPPORT="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
    if ! command -v claude-desktop >/dev/null 2>&1 && [ ! -d "$CLAUDE_SUPPORT" ]; then
      echo "setup-claude-desktop: Claude Desktop not installed; skipping." >&2
      exit 0
    fi
    ;;
  msys* | cygwin*)
    echo "setup-claude-desktop: Windows not automated; configure Claude Desktop manually." >&2
    exit 0
    ;;
  *)
    echo "setup-claude-desktop: unknown OSTYPE=${OSTYPE:-}, skipping." >&2
    exit 0
    ;;
esac

mkdir -p "$CLAUDE_SUPPORT"

# --- claude_desktop_config.json (MCP servers + preferences) ---
SRC_DESKTOP="$DOTFILES/init/claude_desktop_config.json"
DST_DESKTOP="$CLAUDE_SUPPORT/claude_desktop_config.json"

if [ ! -f "$SRC_DESKTOP" ]; then
  if [ -f "$CLAUDE_SUPPORT/claude_desktop_config.json" ]; then
    echo "setup-claude-desktop: $SRC_DESKTOP not found; running backup to seed it first"
    bash "$(dirname "$0")/backup-claude-desktop.sh"
  else
    echo "setup-claude-desktop: missing $SRC_DESKTOP" >&2
    exit 1
  fi
fi

python3 - <<EOF
import json, os

src = json.load(open("$SRC_DESKTOP"))

dst = {}
if os.path.isfile("$DST_DESKTOP") and not os.path.islink("$DST_DESKTOP"):
    try:
        dst = json.load(open("$DST_DESKTOP"))
    except Exception:
        dst = {}

# Machine-local keys inside preferences: preserved, not overwritten by dotfiles.
LOCAL_PREF_KEYS = {
    "localAgentModeTrustedFolders",
    "bypassPermissionsGateByAccount",
    "remoteToolsDeviceName",
    "epitaxyPrefs",
}

merged = dict(dst)
for top_key, top_val in src.items():
    if isinstance(top_val, dict) and isinstance(merged.get(top_key), dict):
        section = dict(merged[top_key])
        for k, v in top_val.items():
            if k not in LOCAL_PREF_KEYS:
                section[k] = v
        merged[top_key] = section
    else:
        merged[top_key] = top_val

with open("$DST_DESKTOP", "w") as f:
    json.dump(merged, f, indent=2)
    f.write("\n")

print("setup-claude-desktop: merged $SRC_DESKTOP -> $DST_DESKTOP")
EOF

# --- config.json (app preferences: theme, locale, etc.) ---
SRC_CONFIG="$DOTFILES/init/claude_config.json"
DST_CONFIG="$CLAUDE_SUPPORT/config.json"

if [ -f "$SRC_CONFIG" ]; then
  python3 - <<EOF
import json, os

src = json.load(open("$SRC_CONFIG"))

dst = {}
if os.path.isfile("$DST_CONFIG") and not os.path.islink("$DST_CONFIG"):
    try:
        dst = json.load(open("$DST_CONFIG"))
    except Exception:
        dst = {}

# Keys in config.json that are sensitive or machine-local: never overwrite.
LOCAL_CONFIG_KEYS = {
    "oauth:tokenCache",
    "updaterLastSeenVersion",
    "hasTrackedInitialActivation",
    "lastSeenRequireCoworkFullVmSandbox",
}

merged = dict(dst)
for k, v in src.items():
    if k not in LOCAL_CONFIG_KEYS and not k.startswith("dxt:"):
        merged[k] = v

with open("$DST_CONFIG", "w") as f:
    json.dump(merged, f, indent=2)
    f.write("\n")

print("setup-claude-desktop: merged $SRC_CONFIG -> $DST_CONFIG")
EOF
fi
