#!/usr/bin/env bash
# Set up Claude Desktop on macOS.
# Merges dotfiles/mac/claude_desktop_config.json into the live config,
# preserving machine-local keys (localAgentModeTrustedFolders, etc.).
# Idempotent: safe to re-run.
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
SRC="$DOTFILES/mac/claude_desktop_config.json"
CLAUDE_SUPPORT="$HOME/Library/Application Support/Claude"
DST="$CLAUDE_SUPPORT/claude_desktop_config.json"

if [ ! -f "$SRC" ]; then
  echo "setup-claude-desktop: missing $SRC" >&2
  exit 1
fi

mkdir -p "$CLAUDE_SUPPORT"

# Merge: dotfiles keys win, machine-local keys are preserved.
python3 - <<EOF
import json, sys, os

src = json.load(open("$SRC"))

dst_path = "$DST"
dst = {}
if os.path.isfile(dst_path) and not os.path.islink(dst_path):
    try:
        dst = json.load(open(dst_path))
    except Exception:
        dst = {}

# Machine-local preference keys to preserve (not overwritten by dotfiles).
LOCAL_KEYS = {"localAgentModeTrustedFolders"}

merged = dict(dst)
for top_key, top_val in src.items():
    if isinstance(top_val, dict) and isinstance(merged.get(top_key), dict):
        # Deep merge: dotfiles wins except for LOCAL_KEYS
        section = dict(merged[top_key])
        for k, v in top_val.items():
            if k not in LOCAL_KEYS:
                section[k] = v
        merged[top_key] = section
    else:
        merged[top_key] = top_val

with open(dst_path, "w") as f:
    json.dump(merged, f, indent=2)
    f.write("\n")

print("setup-claude-desktop: merged $SRC -> $DST")
EOF
