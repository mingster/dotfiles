#!/usr/bin/env bash
# Set up Claude Desktop on macOS / Linux.
# Merges dotfiles config files into the live Claude Desktop configs,
# preserving machine-local keys (localAgentModeTrustedFolders, etc.).
# Idempotent: safe to re-run.
set -euo pipefail

# Takes no arguments: -h/--help print usage, anything else is refused before any change (#1568).
if [ $# -gt 0 ]; then
  echo "Usage: setup-claude-desktop.sh (takes no arguments)" >&2
  case "$1" in -h | --help) exit 0 ;; *) exit 2 ;; esac
fi

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
# shellcheck source=lib/dotfiles-source.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/dotfiles-source.sh"
require_main_dotfiles setup-claude-desktop "$DOTFILES"

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

python3 - "$SRC_DESKTOP" "$DST_DESKTOP" <<'EOF'
import json, os, sys

src_path, dst_path = sys.argv[1], sys.argv[2]
src = json.load(open(src_path))
# The tracked file holds __HOME__ instead of the home folder; render it for this machine.
src = json.loads(json.dumps(src).replace("__HOME__", os.path.expanduser("~")))

dst = {}
if os.path.isfile(dst_path) and not os.path.islink(dst_path):
    try:
        dst = json.load(open(dst_path))
    except Exception as e:
        # Never overwrite a file we cannot read: the machine-local keys would be lost.
        sys.exit(f"setup-claude-desktop: {dst_path} is not valid JSON ({e}); fix or remove it, then re-run. Nothing written.")

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

with open(dst_path, "w") as f:
    json.dump(merged, f, indent=2)
    f.write("\n")

print(f"setup-claude-desktop: merged {src_path} -> {dst_path}")
EOF

# --- config.json (app preferences: theme, locale, etc.) ---
SRC_CONFIG="$DOTFILES/init/claude_config.json"
DST_CONFIG="$CLAUDE_SUPPORT/config.json"

if [ -f "$SRC_CONFIG" ]; then
  python3 - "$SRC_CONFIG" "$DST_CONFIG" <<'EOF'
import json, os, sys

src_path, dst_path = sys.argv[1], sys.argv[2]
src = json.load(open(src_path))

dst = {}
if os.path.isfile(dst_path) and not os.path.islink(dst_path):
    try:
        dst = json.load(open(dst_path))
    except Exception as e:
        sys.exit(f"setup-claude-desktop: {dst_path} is not valid JSON ({e}); fix or remove it, then re-run. Nothing written.")

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

with open(dst_path, "w") as f:
    json.dump(merged, f, indent=2)
    f.write("\n")

print(f"setup-claude-desktop: merged {src_path} -> {dst_path}")
EOF
fi
