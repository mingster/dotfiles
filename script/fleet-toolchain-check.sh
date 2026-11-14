#!/usr/bin/env bash
# Report fleet hosts whose tools are missing or differ from the coordinator, and the coordinator
# when it is below the latest release. Peers follow the coordinator, never the fleet maximum.
# Reuses .tool-versions via bootstrap-asdf-tools for node and python.
# --apply upgrades Orca to the coordinator's version (latest on the coordinator) on a host with no live
# claude, agent or agy process, because the upgrade restarts Orca; a busy host is reported as skipped.
# --apply also runs `orca skills install --all` on each host, which installs and updates the bundled Orca skills.
# Usage: fleet-toolchain-check.sh [--apply]
# Config: FLEET_PULL_CONFIG or fleet-pull.config.json (same hosts as fleet-pull).
# Tests: FLEET_ORCA_APP (Orca.app path), FLEET_TOOLCHAIN_RUN, FLEET_TOOLCHAIN_LATEST_{ORCA,BUN,NODE,PYTHON3}, FLEET_TOOLCHAIN_NODE_INDEX (path), FLEET_TOOLCHAIN_VERSIONS (json).
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
  # Newest LTS on the pinned major; a newer LTS major never raises the target.
  pin=$(read_pin nodejs)
  latest=$(python3 -c '
import json, sys, urllib.request
src, major = sys.argv[1], sys.argv[2].split(".")[0]
try:
    if src.startswith("/"):
        rows = json.load(open(src))
    else:
        req = urllib.request.Request(src, headers={"User-Agent": "dotfiles"})
        with urllib.request.urlopen(req, timeout=15) as r:
            rows = json.load(r)
    for row in rows:
        if row.get("lts") and row["version"].lstrip("v").split(".")[0] == major:
            print(row["version"].lstrip("v")); break
except (OSError, ValueError):
    pass
' "${FLEET_TOOLCHAIN_NODE_INDEX:-https://nodejs.org/dist/index.json}" "${pin:-0}" 2>/dev/null)
  norm_ver "${latest:-$pin}"
}

latest_python3() {
  if [ -n "${FLEET_TOOLCHAIN_LATEST_PYTHON3:-}" ]; then
    norm_ver "$FLEET_TOOLCHAIN_LATEST_PYTHON3"
    return
  fi
  norm_ver "$(read_pin python)"
}

probe_shell() { cat "$here/lib/toolchain-probe.sh"; }

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

# On the coordinator, record its versions as the fleet floor. sync.sh push carries the file to the
# other hosts, where session-sync.sh compares local tools against it at session start.
write_floor() {
  local t v tools='{}'
  same_host "$me" "$baseline_host" && [ -d "$state_dir" ] || return 0
  [ "$(host_tool_state "$baseline_host" git)" = unreachable ] && return 0
  for t in $TOOLS; do
    v=$(host_tool_ver "$baseline_host" "$t")
    [ -n "$v" ] && tools=$(jq -c --arg t "$t" --arg v "$v" '.[$t] = $v' <<<"$tools")
  done
  jq -n --arg h "$baseline_host" --argjson tools "$tools" '{host: $h, tools: $tools}' >"$state_dir/fleet-floor.json.tmp" &&
    mv "$state_dir/fleet-floor.json.tmp" "$state_dir/fleet-floor.json"
}
write_floor

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

rc=0

check_host() { # <host>
  local h=$1 st have need floor t
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
        continue
        ;;
      unreadable | "")
        echo "fleet-toolchain-check: $h $t version unreadable" >&2
        rc=1
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
    # The coordinator is measured against latest; peers only against the coordinator,
    # falling back to latest when the coordinator has no version for this tool.
    if same_host "$h" "$baseline_host" || [ -z "$floor" ]; then
      if [ -n "$need" ] && older "$have" "$need"; then
        echo "fleet-toolchain-check: $h $t $have is below latest $need"
      fi
    elif older "$have" "$floor"; then
      echo "fleet-toolchain-check: $h $t $have is below $baseline_host $floor"
    elif older "$floor" "$have"; then
      echo "fleet-toolchain-check: $h $t $have is above $baseline_host $floor"
    fi
  done
}

for h in $hosts; do
  [ -n "$h" ] || continue
  check_host "$h"
done

peer_pin() { # <host> <tool> -> coordinator version for a peer below it, "keep" for a peer level or above, empty to update to latest
  local h=$1 t=$2 floor have
  same_host "$h" "$baseline_host" && return 0
  floor=$(floor_for "$t")
  [ -n "$floor" ] || return 0
  have=$(host_tool_ver "$h" "$t")
  if [ -n "$have" ] && ! older "$have" "$floor"; then
    echo keep
  else
    echo "$floor"
  fi
}

orca_target() { # <host> -> the Orca version to install, empty when the host is current or has no Orca
  local h=$1 have pin
  have=$(host_tool_ver "$h" orca)
  [ -n "$have" ] || return 0
  pin=$(peer_pin "$h" orca)
  case "$pin" in
    keep) ;;
    '') [ -n "$want_orca" ] && older "$have" "$want_orca" && printf '%s\n' "$want_orca" ;;
    *) printf '%s\n' "$pin" ;;
  esac
}

apply_shell() { # <claude pin> <bun pin> <dotfiles path on the target> <orca target>
  local claude_pin=$1 bun_pin=$2 dot=$3 orca_to=$4
  cat <<EOS
[ -n "\${ZSH_VERSION:-}" ] && emulate -L sh
export PATH="\${FLEET_TOOLCHAIN_PATH:-\$HOME/.local/bin:\$HOME/.bun/bin:\${ASDF_DATA_DIR:-\$HOME/.asdf}/shims:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\$PATH}"
try() { # <label> <command...>: print the label and the last output line when the command fails
  label=\$1
  shift
  if ! err=\$("\$@" 2>&1); then
    last=\$(printf '%s\n' "\$err" | sed '/^[[:space:]]*\$/d' | tail -1)
    echo "__apply_failed__ \$label failed: \${last:-no output}"
    return 1
  fi
}
if command -v brew >/dev/null 2>&1; then
  case "\$(jq --version 2>/dev/null)" in
    *apple*) try "brew install jq" brew install jq ;;
  esac
  try "brew upgrade" brew upgrade git gh jq shellcheck
fi
try bootstrap-asdf-tools bash "$dot/script/bootstrap-asdf-tools.sh" --dotfiles "$dot"
if command -v bun >/dev/null 2>&1; then
  case '$bun_pin' in
    keep) ;;
    '') try "bun upgrade" bun upgrade ;;
    *) try "bun install $bun_pin" bash -c 'set -o pipefail; curl -fsSL https://bun.sh/install | bash -s bun-v$bun_pin' ;;
  esac
fi
if command -v claude >/dev/null 2>&1; then
  case '$claude_pin' in
    keep) ;;
    '') try "claude update" claude update ;;
    *) try "claude install $claude_pin" claude install '$claude_pin' ;;
  esac
fi
if command -v agent >/dev/null 2>&1; then
  try "agent update" env AGENT_CLI_CREDENTIAL_STORE=file agent update
elif command -v cursor-agent >/dev/null 2>&1; then
  try "cursor-agent update" env AGENT_CLI_CREDENTIAL_STORE=file cursor-agent update
fi
command -v agy >/dev/null 2>&1 && try "agy update" "$dot/bin/agy" update
orca_app="\${FLEET_ORCA_APP:-/Applications/_dev/Orca.app}"
orca_mac() { # <version>: replace Orca.app from the release zip, putting the old one back on failure, and reopen it
  case "\$(uname -m)" in arm64) asset="Orca-\$1-arm64-mac.zip" ;; *) asset="Orca-\$1-mac.zip" ;; esac
  [ -d "\$orca_app" ] || { echo "no \$orca_app"; return 1; }
  dl=\$(mktemp -d) || return 1
  curl -fsSL -o "\$dl/orca.zip" "https://github.com/stablyai/orca/releases/download/v\$1/\$asset" &&
    ditto -x -k "\$dl/orca.zip" "\$dl" || { rm -rf "\$dl"; return 1; }
  [ -d "\$dl/Orca.app" ] || { rm -rf "\$dl"; echo "no Orca.app in \$asset"; return 1; }
  running=0
  pids=\$(pgrep -f "\$orca_app/Contents/MacOS/" || true)
  if pkill -f "\$orca_app/Contents/MacOS/"; then
    running=1
    n=0
    # wait by pid: a pgrep -f loop matches its own command line and never ends
    while [ "\$n" -lt 30 ] && (for pid in \$pids; do kill -0 "\$pid" 2>/dev/null && exit 0; done; exit 1); do sleep 1; n=\$((n + 1)); done
  fi
  rm -rf "\$orca_app.old"
  ok=0
  if ! { mv "\$orca_app" "\$orca_app.old" && mv "\$dl/Orca.app" "\$orca_app"; }; then
    [ -d "\$orca_app" ] || mv "\$orca_app.old" "\$orca_app"
    echo "could not replace \$orca_app"
    ok=1
  fi
  rm -rf "\$orca_app.old" "\$dl"
  [ "\$running" = 0 ] || env -u SSH_CONNECTION -u SSH_TTY -u SSH_CLIENT open -g "\$orca_app"
  return "\$ok"
}
orca_arch() { # <version>: install stably-orca-bin, only when the AUR has exactly this version
  aur=\$(yay -Si stably-orca-bin 2>/dev/null | awk -F': *' '/^Version/ { sub(/-[^-]*\$/, "", \$2); print \$2; exit }')
  [ "\$aur" = "\$1" ] || { echo "AUR has \${aur:-nothing}"; return 1; }
  yay -S --noconfirm --needed stably-orca-bin
}
inside_orca() { # true when this script runs under an Orca process, which the upgrade would kill
  p=\$\$
  while :; do
    case "\$p" in '' | *[!0-9]* | 0 | 1) return 1 ;; esac
    case "\$(ps -o comm= -p "\$p" 2>/dev/null)" in *[Oo]rca*) return 0 ;; esac
    p=\$(ps -o ppid= -p "\$p" 2>/dev/null | tr -d ' ')
  done
}
if [ -n '$orca_to' ]; then
  # Claude renames its process to its version, so match the first word of the command line too
  live=\$({ ps -A -o comm=; ps -A -o args= | awk '{ print \$1 }'; } 2>/dev/null | sed 's#.*/##' |
    grep -xE 'claude|agent|agy' | sort -u | tr '\n' ' ')
  up=
  if [ -n "\$live" ]; then
    echo "__orca_skipped__ live agents: \${live% }"
  elif inside_orca; then
    echo "__orca_skipped__ running inside Orca"
  else
    case "\$(uname -s)" in
      Darwin) up=orca_mac ;;
      Linux) if command -v yay >/dev/null 2>&1; then up=orca_arch; else echo "__orca_skipped__ no yay on this host"; fi ;;
      *) echo "__orca_skipped__ no upgrade path for \$(uname -s)" ;;
    esac
  fi
  [ -n "\$up" ] && try "orca upgrade $orca_to" "\$up" '$orca_to' && echo "__orca_upgraded__ $orca_to"
fi
orca_bin="\${FLEET_ORCA_APP_BIN:-\${WRAP_UP_ORCA_APP_BIN:-\$orca_app/Contents/Resources/bin}}/orca"
[ -x "\$orca_bin" ] || orca_bin=\$(command -v orca 2>/dev/null || true)
[ -n "\$orca_bin" ] && try "orca skills install" "\$orca_bin" skills install --all
true
EOS
}

if [ "$apply" -eq 1 ]; then
  for h in $hosts; do
    [ -n "$h" ] || continue
    [ "$(host_tool_state "$h" git)" = "unreachable" ] && continue
    dot=$dotfiles
    # A peer keeps dotfiles at the same place under its own home, which differs across macOS and Linux
    if ! same_host "$h" "$me"; then
      case "$dotfiles" in
        "$HOME"/*) dot="\$HOME${dotfiles#"$HOME"}" ;;
      esac
    fi
    script=$(apply_shell "$(peer_pin "$h" claude)" "$(peer_pin "$h" bun)" "$dot" "$(orca_target "$h")")
    apply_rc=0
    if same_host "$h" "$me"; then
      out=$(bash -c "$script" 2>"$probe_dir/apply-err") || apply_rc=$?
    else
      out=$("$run" -o BatchMode=yes -o ConnectTimeout=8 "$h" "$script" 2>"$probe_dir/apply-err") || apply_rc=$?
    fi
    # Only marked lines are failures, so a login banner on the host is not one
    while IFS= read -r line; do
      case "$line" in
        __apply_failed__\ *)
          echo "fleet-toolchain-check: $h apply: ${line#__apply_failed__ }"
          rc=1
          ;;
        __orca_skipped__\ *) echo "fleet-toolchain-check: $h apply: orca upgrade skipped, ${line#__orca_skipped__ }" ;;
        __orca_upgraded__\ *) echo "fleet-toolchain-check: $h apply: orca upgraded to ${line#__orca_upgraded__ }" ;;
      esac
    done <<<"$out"
    if [ "$apply_rc" -ne 0 ]; then
      last=$(sed '/^[[:space:]]*$/d' "$probe_dir/apply-err" | tail -1)
      echo "fleet-toolchain-check: $h apply: stopped with exit $apply_rc: ${last:-no output}"
      rc=1
    fi
  done
fi

exit "$rc"
