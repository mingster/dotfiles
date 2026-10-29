#!/usr/bin/env bash
# Read-only readiness checks. Never install tools or download browser binaries.
set -uo pipefail

DOTFILES="${DOTFILES:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
export DOTFILES
case "${1:-}" in
  --agent-settings-only) exec python3 -B "$DOTFILES/script/agent-settings-check.py" ;;
  '') ;;
  *) echo 'Usage: setup-check.sh [--agent-settings-only]' >&2; exit 2 ;;
esac
missing=0
report() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'OK %s\n' "$label"
  else
    printf 'MISSING %s\n' "$label"
    missing=1
  fi
}

codex_key() {
  [ -r "$HOME/.codex/config.toml" ] || return 1
  awk -v key="$1" -v value="$2" '
    /^[[:space:]]*\[/ { exit }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      line = $0
      sub(/^[^=]*=[[:space:]]*/, "", line)
      sub(/[[:space:]]*(#.*)?$/, "", line)
      quote = sprintf("%c", 39)
      if (line == "\"" value "\"" || line == quote value quote) found = 1
    }
    END { exit !found }
  ' "$HOME/.codex/config.toml"
}

agent_hooks() {
  python3 -B -c '
import json, sys
try:
    with open(sys.argv[1]) as source:
        hooks = json.load(source).get("hooks", {})
    sys.exit(0 if isinstance(hooks, dict) and any(hooks.values()) else 1)
except (OSError, ValueError, AttributeError):
    sys.exit(1)
' "$1"
}

skills_links() {
  local root=$1 item found=0
  [ -d "$root" ] || return 1
  for item in "$root"/*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    [ -L "$item" ] && [ -d "$item" ] || return 1
    found=1
  done
  [ "$found" = 1 ]
}

playwright_browsers() {
  local cache=${PLAYWRIGHT_BROWSERS_PATH:-}
  if [ -z "$cache" ]; then
    case "$(uname -s)" in
      Darwin) cache="$HOME/Library/Caches/ms-playwright" ;;
      MINGW*|MSYS*|CYGWIN*) cache="${LOCALAPPDATA:-$HOME/AppData/Local}/ms-playwright" ;;
      *) cache="${XDG_CACHE_HOME:-$HOME/.cache}/ms-playwright" ;;
    esac
  fi
  # Require installed browser executables, not just an empty cache directory.
  local engine item found
  for engine in chromium firefox webkit; do
    found=0
    for item in "$cache"/"$engine"-*; do
      [ -d "$item" ] || continue
      if find "$item" -type f \( -name chrome -o -name Chromium -o -name chrome.exe \
          -o -name firefox -o -name firefox.exe -o -name pw_run.sh \) -perm -100 -print \
          | grep -q .; then
        found=1
        break
      fi
    done
    [ "$found" = 1 ] || return 1
  done
}

report 'Codex sandbox_mode' codex_key sandbox_mode danger-full-access
report 'Codex approval_policy' codex_key approval_policy never
report 'Codex model' codex_key model gpt-6.1-sol
report 'Codex model_reasoning_effort' codex_key model_reasoning_effort medium
report 'presets.json' test -s "$HOME/.orca/presets.json"
report 'shared skills links' skills_links "$HOME/.agents/skills"
report 'Claude skills links' skills_links "$HOME/.claude/skills"
report 'Claude agent hooks' agent_hooks "$HOME/.claude/settings.json"
report 'Codex agent hooks' agent_hooks "$HOME/.codex/hooks.json"
report 'Cursor agent hooks' agent_hooks "$HOME/.cursor/hooks.json"
report 'gh auth' gh auth status
report 'orca CLI' command -v orca
for cli in claude codex agent agy; do
  report "$cli CLI" command -v "$cli"
done
# Presence only: do not open credentials or invoke provider login/status calls.
# A missing file does not prove signed out (keyrings/API keys may be used).
report 'claude sign-in file' test -f "$HOME/.claude/.credentials.json"
report 'codex sign-in file' test -f "${CODEX_HOME:-$HOME/.codex}/auth.json"
case "$(uname -s)" in
  Darwin) cursor_auth="$HOME/.cursor/auth.json" ;;
  MINGW*|MSYS*|CYGWIN*) cursor_auth="${APPDATA:-$HOME/AppData/Roaming}/Cursor/auth.json" ;;
  *) cursor_auth="${XDG_CONFIG_HOME:-$HOME/.config}/cursor/auth.json" ;;
esac
report 'agent sign-in file' test -f "$cursor_auth"
# Antigravity documents system-keyring authentication, with no sign-in file.
printf 'INFO agy sign-in file: system keyring (file presence unavailable; owner checks sign-in)\n'
report 'bun' command -v bun
report 'playwright browsers' playwright_browsers
python3 -B "$DOTFILES/script/agent-settings-check.py" || missing=1
exit "$missing"
