#!/usr/bin/env bash
# Report fleet hosts whose tools are missing, below the latest release, or below the coordinator.
# Reuses .tool-versions via bootstrap-asdf-tools for node and python; warns on orca (manual install only).
# Usage: fleet-toolchain-check.sh [--apply]
# Config: FLEET_PULL_CONFIG or fleet-pull.config.json (same hosts as fleet-pull).
# Tests: FLEET_TOOLCHAIN_RUN, FLEET_TOOLCHAIN_LATEST_{ORCA,BUN,NODE,PYTHON3}, FLEET_TOOLCHAIN_VERSIONS (json).
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=script/lib/find-orca-dir.sh disable=SC1091
. "$here/lib/find-orca-dir.sh"
dotfiles=${DOTFILES_DIR:-$HOME/dotfiles}
state_dir=${AGENT_STATE_DIR:-$HOME/agent-state}
if [ -n "${FLEET_PULL_CONFIG:-}" ]; then
  cfg=$FLEET_PULL_CONFIG
elif [ -f "$here/fleet-pull.config.json" ]; then
  cfg="$here/fleet-pull.config.json"
elif [ -f "$dotfiles/script/fleet-pull.config.json" ]; then
  cfg="$dotfiles/script/fleet-pull.config.json"
else
  cfg="$here/fleet-pull.config.json"
fi

baseline_host=${FLEET_TOOLCHAIN_BASELINE_HOST:-}
if [ -z "$baseline_host" ] && [ -f "$state_dir/coordinator.conf" ]; then
  baseline_host=$(awk '$1 == "coordinator" { print $2; exit }' "$state_dir/coordinator.conf")
fi
if [ -z "$baseline_host" ]; then
  echo "fleet-toolchain-check: missing coordinator in $state_dir/coordinator.conf" >&2
  exit 2
fi

apply=0
[ "${1:-}" = --apply ] && apply=1
command -v jq >/dev/null 2>&1 || { echo 'fleet-toolchain-check: jq required' >&2; exit 2; }
[ -f "$cfg" ] || { echo "fleet-toolchain-check: missing $cfg" >&2; exit 2; }

run="${FLEET_TOOLCHAIN_RUN:-ssh}"
me=$(hostname -s)
TOOLS="git gh jq python3 shellcheck bun node orca claude agent agy"

norm_ver() { printf '%s' "$1" | sed -E 's/^v//; s/^[[:space:]]+|[[:space:]]+$//g'; }
older() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }
same_host() {
  [ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" ]
}

read_pin() { awk -v t="$1" '$1 == t { print $2; exit }' "$dotfiles/.tool-versions" 2>/dev/null; }

latest_orca() {
  [ -n "${FLEET_TOOLCHAIN_LATEST_ORCA:-}" ] && { norm_ver "$FLEET_TOOLCHAIN_LATEST_ORCA"; return; }
  python3 - <<'PY'
import json, os, time, urllib.request, re
cache = os.path.join(os.environ.get("HOME", "/tmp"), ".cache", "fleet-toolchain-orca-latest.json")
ttl = 6 * 3600
if os.path.isfile(cache):
    try:
        data = json.load(open(cache))
        if time.time() - float(data.get("ts", 0)) < ttl:
            print(re.sub(r"^v", "", data.get("tag", "")))
            raise SystemExit(0)
    except (OSError, ValueError, KeyError, TypeError):
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
json.dump({"tag": tag, "ts": time.time()}, open(cache, "w"))
PY
}

latest_bun() {
  [ -n "${FLEET_TOOLCHAIN_LATEST_BUN:-}" ] && { norm_ver "$FLEET_TOOLCHAIN_LATEST_BUN"; return; }
  curl -fsSL https://bun.sh/latest 2>/dev/null | sed 's/^bun-v//'
}

latest_node() {
  [ -n "${FLEET_TOOLCHAIN_LATEST_NODE:-}" ] && { norm_ver "$FLEET_TOOLCHAIN_LATEST_NODE"; return; }
  pin=$(python3 -c '
import json, urllib.request
try:
    req = urllib.request.Request("https://nodejs.org/dist/index.json", headers={"User-Agent": "dotfiles"})
    with urllib.request.urlopen(req, timeout=15) as r:
        for row in json.load(r):
            if row.get("lts"):
                print(row["version"].lstrip("v")); break
except OSError:
    pass
' 2>/dev/null)
  [ -n "$pin" ] || pin=$(read_pin nodejs)
  norm_ver "$pin"
}

latest_python3() {
  if [ -n "${FLEET_TOOLCHAIN_LATEST_PYTHON3:-}" ]; then
    norm_ver "$FLEET_TOOLCHAIN_LATEST_PYTHON3"
    return
  fi
  norm_ver "$(read_pin python)"
}

probe_shell() {
  cat <<'EOS'
[ -n "${ZSH_VERSION:-}" ] && emulate -L sh
export PATH="${FLEET_TOOLCHAIN_PATH:-$HOME/.local/bin:$HOME/.bun/bin:${ASDF_DATA_DIR:-$HOME/.asdf}/shims:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH}"
stale="$HOME/.orca/cli/bin"
orca_bin=""
list="${FLEET_ORCA_APP_BIN:-${WRAP_UP_ORCA_APP_BIN:-/Applications/_dev/Orca.app/Contents/Resources/bin}}:$PATH:$HOME/.local/bin"
old_ifs=$IFS
IFS=:
for dir in $list; do
  if [ "$dir" != "$stale" ] && [ -x "$dir/orca" ]; then
    orca_bin="$dir/orca"
    break
  fi
done
IFS=$old_ifs
[ -z "$orca_bin" ] && [ -x "$stale/orca" ] && orca_bin="$stale/orca"

ver_token() {
  awk '{
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^v?[0-9]+\.[0-9]+/) {
        sub(/^v/, "", $i)
        print $i
        exit
      }
    }
  }'
}

for t in git gh jq python3 shellcheck bun node orca claude agent agy; do
  case $t in
    orca)
      if [ -z "$orca_bin" ]; then
        echo "orca missing"
      else
        v=$("$orca_bin" --version 2>/dev/null | head -1 | ver_token)
        [ -n "$v" ] && echo "orca ok $v" || echo "orca unreadable"
      fi
      ;;
    agent)
      bin=""
      if command -v agent >/dev/null 2>&1; then bin=agent
      elif command -v cursor-agent >/dev/null 2>&1; then bin=cursor-agent
      fi
      if [ -z "$bin" ]; then
        echo "agent missing"
      else
        v=$(AGENT_CLI_CREDENTIAL_STORE=file "$bin" --version 2>/dev/null | head -1 | ver_token)
        [ -n "$v" ] && echo "agent ok $v" || echo "agent unreadable"
      fi
      ;;
    jq)
      if ! command -v jq >/dev/null 2>&1; then
        echo "jq missing"
      else
        raw=$(jq --version 2>/dev/null | head -1)
        v=$(printf '%s\n' "$raw" | sed -E 's/^jq-//; s/^jq[[:space:]]+(version[[:space:]]+)?//; s/^v//; s/^[[:space:]]+|[[:space:]]+$//g')
        if printf '%s\n' "$v" | grep -qE '^[0-9]+\.[0-9]+'; then
          echo "jq ok $v"
        else
          echo "jq unreadable"
        fi
      fi
      ;;
    *)
      if ! command -v "$t" >/dev/null 2>&1; then
        echo "$t missing"
      else
        v=$("$t" --version 2>/dev/null | ver_token)
        [ -n "$v" ] && echo "$t ok $v" || echo "$t unreadable"
      fi
      ;;
  esac
done
EOS
}

probe_dir=$(mktemp -d)
trap 'rm -rf "$probe_dir"' EXIT

probe_host() { # <host>
  local h=$1 f="$probe_dir/$1" t val out
  [ -f "$f" ] && return 0
  if [ -n "${FLEET_TOOLCHAIN_VERSIONS:-}" ] && jq -e --arg h "$h" 'has($h)' <<<"$FLEET_TOOLCHAIN_VERSIONS" >/dev/null 2>&1; then
    for t in $TOOLS; do
      if jq -e --arg h "$h" --arg t "$t" '.[$h] | has($t)' <<<"$FLEET_TOOLCHAIN_VERSIONS" >/dev/null 2>&1; then
        val=$(jq -r --arg h "$h" --arg t "$t" '.[$h][$t] // ""' <<<"$FLEET_TOOLCHAIN_VERSIONS")
        case "$val" in
          missing) echo "$t missing" ;;
          "" | unreadable) echo "$t unreadable" ;;
          *) echo "$t ok $(norm_ver "$val")" ;;
        esac
      else
        echo "$t missing"
      fi
    done >"$f"
    return 0
  fi
  if same_host "$h" "$me"; then
    bash -c "$(probe_shell)" >"$f"
    return 0
  fi
  if out=$("$run" -o BatchMode=yes -o ConnectTimeout=8 "$h" "$(probe_shell)" 2>/dev/null) && [ -n "$out" ]; then
    printf '%s\n' "$out" >"$f"
  else
    echo "__host__ unreachable" >"$f"
  fi
}

host_tool_state() { # <host> <tool> -> prints "ok <ver>", "missing", "unreadable", or "unreachable"
  local h=$1 t=$2 f="$probe_dir/$1"
  probe_host "$h"
  if grep -q '^__host__ unreachable$' "$f" 2>/dev/null; then
    echo "unreachable"
    return 0
  fi
  awk -v t="$t" '$1 == t { $1 = ""; sub(/^ /, ""); print; exit }' "$f"
}

host_tool_ver() { # <host> <tool>
  local st
  st=$(host_tool_state "$1" "$2")
  case "$st" in
    ok\ *) printf '%s\n' "${st#ok }" ;;
  esac
}

cfg_hosts=$(jq -r '.hosts[]?' "$cfg")
hosts=""
seen_baseline=0
for h in $cfg_hosts; do
  [ -n "$h" ] || continue
  same_host "$h" "$baseline_host" && seen_baseline=1
done
if [ "$seen_baseline" -eq 0 ]; then
  hosts="$baseline_host"$'\n'"$cfg_hosts"
else
  hosts="$cfg_hosts"
fi

for h in $hosts; do
  [ -n "$h" ] || continue
  probe_host "$h"
done

want_orca=$(latest_orca)
want_bun=$(latest_bun)
want_node=$(latest_node)
want_python3=$(latest_python3)

want_for() { # <tool>
  case "$1" in
    orca) printf '%s' "$want_orca" ;;
    bun) printf '%s' "$want_bun" ;;
    node) printf '%s' "$want_node" ;;
    python3) printf '%s' "$want_python3" ;;
  esac
}

floor_for() { # <tool>
  host_tool_ver "$baseline_host" "$1"
}

max_for() { # <tool>
  local t=$1 h v best=""
  for h in $hosts; do
    [ -n "$h" ] || continue
    v=$(host_tool_ver "$h" "$t")
    [ -n "$v" ] || continue
    if [ -z "$best" ] || older "$best" "$v"; then
      best="$v"
    fi
  done
  printf '%s' "$best"
}

rc=0
orca_gaps=0

check_host() { # <host>
  local h=$1 st have need floor max t
  if [ "$(host_tool_state "$h" git)" = "unreachable" ]; then
    echo "fleet-toolchain-check: $h unreachable" >&2
    rc=1
    return 0
  fi
  for t in $TOOLS; do
    st=$(host_tool_state "$h" "$t")
    case "$st" in
      missing)
        echo "fleet-toolchain-check: $h $t missing" >&2
        rc=1
        [ "$t" = orca ] && orca_gaps=1
        continue
        ;;
      unreadable | "")
        echo "fleet-toolchain-check: $h $t version unreadable" >&2
        rc=1
        [ "$t" = orca ] && orca_gaps=1
        continue
        ;;
      ok\ *)
        have="${st#ok }"
        ;;
      *)
        echo "fleet-toolchain-check: $h $t version unreadable" >&2
        rc=1
        continue
        ;;
    esac
    need=$(want_for "$t")
    floor=$(floor_for "$t")
    max=$(max_for "$t")
    if [ -n "$need" ] && older "$have" "$need"; then
      echo "fleet-toolchain-check: $h $t $have is below latest $need"
      [ "$t" = orca ] && orca_gaps=1
    elif [ -n "$floor" ] && older "$have" "$floor"; then
      if [ -n "$need" ]; then
        echo "fleet-toolchain-check: $h $t $have is below $baseline_host $floor (latest $need)"
      else
        echo "fleet-toolchain-check: $h $t $have is below $baseline_host $floor"
      fi
      [ "$t" = orca ] && orca_gaps=1
    elif [ -n "$max" ] && older "$have" "$max"; then
      echo "fleet-toolchain-check: $h $t $have is below fleet $max"
      [ "$t" = orca ] && orca_gaps=1
    fi
  done
}

for h in $hosts; do
  [ -n "$h" ] || continue
  check_host "$h"
done

apply_shell() {
  cat <<EOS
[ -n "\${ZSH_VERSION:-}" ] && emulate -L sh
export PATH="\${FLEET_TOOLCHAIN_PATH:-\$HOME/.local/bin:\$HOME/.bun/bin:\${ASDF_DATA_DIR:-\$HOME/.asdf}/shims:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\$PATH}"
if command -v brew >/dev/null 2>&1; then
  brew upgrade git gh jq shellcheck >/dev/null 2>&1 || true
fi
bash '$dotfiles/script/bootstrap-asdf-tools.sh' --dotfiles '$dotfiles' >/dev/null 2>&1 || true
command -v bun >/dev/null 2>&1 && bun upgrade >/dev/null 2>&1 || true
command -v claude >/dev/null 2>&1 && claude update >/dev/null 2>&1 || true
if command -v agent >/dev/null 2>&1; then
  AGENT_CLI_CREDENTIAL_STORE=file agent update >/dev/null 2>&1 || true
elif command -v cursor-agent >/dev/null 2>&1; then
  AGENT_CLI_CREDENTIAL_STORE=file cursor-agent update >/dev/null 2>&1 || true
fi
command -v agy >/dev/null 2>&1 && agy update >/dev/null 2>&1 || true
EOS
}

if [ "$apply" -eq 1 ]; then
  for h in $hosts; do
    [ -n "$h" ] || continue
    [ "$(host_tool_state "$h" git)" = "unreachable" ] && continue
    if same_host "$h" "$me"; then
      bash -c "$(apply_shell)" || true
    else
      "$run" -o BatchMode=yes -o ConnectTimeout=8 "$h" "$(apply_shell)" >/dev/null 2>&1 || true
    fi
  done
  if [ "$orca_gaps" -eq 1 ]; then
    echo "fleet-toolchain-check: orca upgrade is manual"
  else
    echo "fleet-toolchain-check: orca is manual (no self-update CLI)"
  fi
fi

exit "$rc"
