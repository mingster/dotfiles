#!/usr/bin/env bash
# Copy the live Claude Desktop config into dotfiles, stripping machine-local keys.
# Run this after changing Claude Desktop settings, then commit the result.
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
DST="$DOTFILES/mac/claude_desktop_config.json"

case "${OSTYPE:-}" in
  darwin*)
    SRC="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
    ;;
  linux*)
    SRC="${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude_desktop_config.json"
    ;;
  *)
    echo "backup-claude-desktop: unsupported OS, skipping." >&2
    exit 0
    ;;
esac

if [ ! -f "$SRC" ]; then
  echo "backup-claude-desktop: $SRC not found; is Claude Desktop installed?" >&2
  exit 1
fi

python3 - <<EOF
import json

# Keys under "preferences" that are machine-local and should not be committed
LOCAL_PREF_KEYS = {
  "localAgentModeTrustedFolders",
  "bypassPermissionsGateByAccount",
  "remoteToolsDeviceName",
  "epitaxyPrefs",
}

with open("$SRC") as f:
    config = json.load(f)

if "preferences" in config:
    prefs = config["preferences"]
    stripped = [k for k in prefs if k in LOCAL_PREF_KEYS]
    config["preferences"] = {k: v for k, v in prefs.items() if k not in LOCAL_PREF_KEYS}
else:
    stripped = []

with open("$DST", "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")

print(f"backup-claude-desktop: saved to $DST (stripped: {stripped})")
EOF
