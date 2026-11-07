#!/usr/bin/env bash
# Report fleet hosts whose orca, bun, or node is below the latest release or below mini6.
# Reuses .tool-versions via bootstrap-asdf-tools for node; warns on orca (manual install only).
# Usage: fleet-toolchain-check.sh [--apply]
# Config: FLEET_PULL_CONFIG or fleet-pull.config.json (same hosts as fleet-pull).
# Tests: FLEET_TOOLCHAIN_RUN, FLEET_TOOLCHAIN_LATEST_{ORCA,BUN,NODE}, FLEET_TOOLCHAIN_VERSIONS (json).
set -u
here=$(cd "$(dirname "$0")" && pwd)
cfg=${FLEET_PULL_CONFIG:-$here/fleet-pull.config.json}
dotfiles=${DOTFILES_DIR:-$HOME/dotfiles}
baseline_host=${FLEET_TOOLCHAIN_BASELINE_HOST:-mini6}
apply=0
[ "${1:-}" = --apply ] && apply=1
command -v jq >/dev/null 2>&1 || { echo 'fleet-toolchain-check: jq required' >&2; exit 2; }
[ -f "$cfg" ] || { echo "fleet-toolchain-check: missing $cfg" >&2; exit 2; }

run="${FLEET_TOOLCHAIN_RUN:-ssh}"
me=$(hostname -s)

norm_ver() { printf '%s' "$1" | sed -E 's/^v//; s/^[[:space:]]+|[[:space:]]+$//g'; }
older() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

read_pin() { awk -v t="$1" '$1 == t { print $2; exit }' "$dotfiles/.tool-versions" 2>/dev/null; }

version_from_json() { # <host> <tool>
  [ -n "${FLEET_TOOLCHAIN_VERSIONS:-}" ] || return 1
  jq -r --arg h "$1" --arg t "$2" '.[$h][$t] // empty' <<<"$FLEET_TOOLCHAIN_VERSIONS"
}

latest_orca() {
  [ -n "${FLEET_TOOLCHAIN_LATEST_ORCA:-}" ] && { norm_ver "$FLEET_TOOLCHAIN_LATEST_ORCA"; return; }
  python3 - <<'PY'
import json, os, urllib.request, re
cache = os.path.join(os.environ.get("HOME", "/tmp"), ".cache", "fleet-toolchain-orca-latest.json")
if os.path.isfile(cache):
    try:
        data = json.load(open(cache))
        print(re.sub(r"^v", "", data.get("tag", "")))
        raise SystemExit(0)
    except (OSError, ValueError, KeyError):
        pass
req = urllib.request.Request(
    "https://api.github.com/repos/stablyai/orca/releases/latest",
    headers={"Accept": "application/vnd.github+json", "User-Agent": "dotfiles-fleet-toolchain"},
)
with urllib.request.urlopen(req, timeout=15) as resp:
    data = json.loads(resp.read().decode())
tag = (data.get("tag_name") or "").lstrip("v")
print(tag)
os.makedirs(os.path.dirname(cache), exist_ok=True)
json.dump({"tag": tag}, open(cache, "w"))
PY
}

latest_bun() {
  [ -n "${FLEET_TOOLCHAIN_LATEST_BUN:-}" ] && { norm_ver "$FLEET_TOOLCHAIN_LATEST_BUN"; return; }
  curl -fsSL https://bun.sh/latest 2>/dev/null | sed 's/^bun-v//'
}

latest_node() {
  [ -n "${FLEET_TOOLCHAIN_LATEST_NODE:-}" ] && { norm_ver "$FLEET_TOOLCHAIN_LATEST_NODE"; return; }
  pin=$(read_pin nodejs)
  [ -n "$pin" ] || pin=$(python3 -c '
import json, urllib.request
req = urllib.request.Request("https://nodejs.org/dist/index.json", headers={"User-Agent": "dotfiles"})
with urllib.request.urlopen(req, timeout=15) as r:
    for row in json.load(r):
        if row.get("lts"):
            print(row["version"].lstrip("v")); break
')
  norm_ver "$pin"
}

host_orca() { # <host>
  local h=$1 v
  v=$(version_from_json "$h" orca) || true
  [ -n "$v" ] && { norm_ver "$v"; return; }
  if [ "$h" = "$me" ]; then
    for b in "$HOME/.orca/cli/bin/orca" orca; do
      command -v "$b" >/dev/null 2>&1 && { norm_ver "$("$b" --version 2>/dev/null | head -1)"; return; }
    done
  else
    v=$("$run" -o BatchMode=yes -o ConnectTimeout=8 "$h" \
      'export PATH="$HOME/.orca/cli/bin:$HOME/.local/bin:$PATH"; o=$HOME/.orca/cli/bin/orca; [ -x "$o" ] && "$o" --version 2>/dev/null || orca --version 2>/dev/null' 2>/dev/null | head -1)
    [ -n "$v" ] && norm_ver "$v"
  fi
}

host_bun() { # <host>
  local h=$1 v
  v=$(version_from_json "$h" bun) || true
  [ -n "$v" ] && { norm_ver "$v"; return; }
  if [ "$h" = "$me" ]; then bun --version 2>/dev/null | tr -d '[:space:]v'
  else "$run" -o BatchMode=yes -o ConnectTimeout=8 "$h" 'export PATH="$HOME/.bun/bin:$HOME/.asdf/shims:$PATH"; bun --version 2>/dev/null' 2>/dev/null | tr -d '[:space:]v'
  fi
}

host_node() { # <host>
  local h=$1 v
  v=$(version_from_json "$h" node) || true
  [ -n "$v" ] && { norm_ver "$v"; return; }
  if [ "$h" = "$me" ]; then node --version 2>/dev/null | tr -d '[:space:]v'
  else "$run" -o BatchMode=yes -o ConnectTimeout=8 "$h" 'export PATH="$HOME/.asdf/shims:/opt/homebrew/bin:/usr/local/bin:$PATH"; node --version 2>/dev/null' 2>/dev/null | tr -d '[:space:]v'
  fi
}

want_orca=$(latest_orca)
want_bun=$(latest_bun)
want_node=$(latest_node)

floor_orca=$(host_orca "$baseline_host")
floor_bun=$(host_bun "$baseline_host")
floor_node=$(host_node "$baseline_host")

check_host() { # <host>
  local h=$1 have need floor min t
  for t in orca bun node; do
    case $t in
      orca) have=$(host_orca "$h"); need="$want_orca"; floor="$floor_orca" ;;
      bun) have=$(host_bun "$h"); need="$want_bun"; floor="$floor_bun" ;;
      node) have=$(host_node "$h"); need="$want_node"; floor="$floor_node" ;;
    esac
    [ -n "$have" ] || { echo "fleet-toolchain-check: $h $t version unreadable" >&2; continue; }
    min="$need"
    [ -n "$floor" ] && older "$floor" "$min" && min="$floor"
    if older "$have" "$min"; then
      echo "fleet-toolchain-check: $h $t $have is below latest $need${floor:+, mini6 runs $floor}"
    fi
  done
}

hosts=$(jq -r '.hosts[]?' "$cfg")
for h in $hosts; do
  [ -n "$h" ] || continue
  check_host "$h"
done

if [ "$apply" -eq 1 ]; then
  for h in $hosts; do
    [ -n "$h" ] || continue
    [ "$h" = "$me" ] && bash "$dotfiles/script/bootstrap-asdf-tools.sh" --dotfiles "$dotfiles" >/dev/null 2>&1 || true
    [ "$h" = "$me" ] || "$run" -o BatchMode=yes -o ConnectTimeout=8 "$h" \
      "bash '$dotfiles/script/bootstrap-asdf-tools.sh' --dotfiles '$dotfiles'" >/dev/null 2>&1 || true
  done
fi

exit 0
