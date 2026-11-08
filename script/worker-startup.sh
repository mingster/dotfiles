#!/usr/bin/env bash
# One entry for daily host health and for starting supervised workers after the host is ready.
# Config: FLEET_PULL_CONFIG or script/fleet-pull.config.json (copy from fleet-pull.config.example.json).
# Usage:
#   worker-startup.sh --host-check
#   worker-startup.sh --pick-host-only --spec FILE
#   worker-startup.sh --run ID --spec FILE --title TEXT --agent NAME --model ID [--from HANDLE] [--on ENV]
#         (--worktree-path PATH | --name NAME --repo SELECTOR [--base-branch REF])
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
orca=${ORCA_CLI_COMMAND:-orca}
python3=${PYTHON:-python3}
agent_state_dir=${AGENT_STATE_DIR:-$HOME/agent-state}
state_dir=${WORKER_STARTUP_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/worker-startup}
mkdir -p "$state_dir"

resolve_fleet_pull_config() {
  if [ -n "${FLEET_PULL_CONFIG:-}" ]; then
    printf '%s\n' "$FLEET_PULL_CONFIG"
    return
  fi
  if [ -f "$agent_state_dir/fleet-pull.json" ]; then
    printf '%s\n' "$agent_state_dir/fleet-pull.json"
    return
  fi
  if [ -f "$agent_state_dir/fleet-config.json" ] && jq -e 'has("repos") or has("hosts")' "$agent_state_dir/fleet-config.json" >/dev/null 2>&1; then
    printf '%s\n' "$agent_state_dir/fleet-config.json"
    return
  fi
  printf '%s\n' "$here/fleet-pull.config.json"
}

die() { echo "worker-startup: $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# --- pins (node via asdf in repo .tool-versions, bun via packageManager / engines.bun) ---

nodejs_pin_from_tool_versions() { # <file>
  awk '$1 == "nodejs" { print $2; exit }' "$1"
}

repo_node_tool_versions() { # <repo_dir> : prints first path or nothing
  find "$1" -maxdepth 2 -name .tool-versions -not -path "*/node_modules/*" 2>/dev/null | head -1
}

ensure_node_matches_pin() { # <repo_dir>
  [ -d "$1" ] || return 0
  local tv want have
  tv=$(repo_node_tool_versions "$1") || true
  [ -n "$tv" ] || return 0
  want=$(nodejs_pin_from_tool_versions "$tv")
  [ -n "$want" ] || return 0
  have=$(cd "$(dirname "$tv")" && node --version 2>/dev/null | tr -d v || true)
  have=${have:-}
  [ "$want" = "$have" ] && return 0
  if ! command -v asdf >/dev/null 2>&1; then
    die "asdf not on PATH; cannot align node with pin $want in $tv"
  fi
  if ! asdf list nodejs 2>/dev/null | tr -d ' *' | grep -qx "$want"; then
    asdf install nodejs "$want" >/dev/null || die "asdf install nodejs $want failed"
  fi
  (cd "$(dirname "$tv")" && asdf set nodejs "$want") || die "asdf set nodejs $want failed in $(dirname "$tv")"
  have=$(cd "$(dirname "$tv")" && node --version 2>/dev/null | tr -d v || true)
  [ "$want" = "$have" ] || die "node still ${have:-none} after pin fix, want $want in $1"
}

bun_pin_from_package_json() { # <path>
  python3 -c '
import json, re, sys
path = sys.argv[1]
d = json.load(open(path))
s = d.get("packageManager", "") if isinstance(d.get("packageManager"), str) else ""
s = s[4:] if s.startswith("bun@") else (d.get("engines") or {}).get("bun", "")
m = re.search(r"\d+(\.\d+){0,2}", s if isinstance(s, str) else "")
print(m.group(0) if m else "")
' "$1" 2>/dev/null || true
}

ensure_bun_matches_pin() { # <repo_dir>
  [ -d "$1" ] || return 0
  local pin f have
  pin=
  for f in "$1/package.json" "$1/web/package.json"; do
    [ -f "$f" ] || continue
    pin=$(bun_pin_from_package_json "$f")
    [ -n "$pin" ] && break
  done
  [ -n "$pin" ] || return 0
  export PATH="$HOME/.bun/bin:$PATH"
  have=$(bun --version 2>/dev/null | tr -d '[:space:]v' || true)
  [ -n "$have" ] || die "bun not on PATH; need pinned bun $pin (install bun or fix PATH)"
  [ "$have" = "$pin" ] && return 0
  need_cmd curl
  need_cmd unzip
  local tag="bun-v${pin}"
  if [[ "$pin" != *.* ]]; then
    die "unusable bun pin format: $pin"
  fi
  script_tmp=$(mktemp) || die "mktemp failed"
  curl_cmd=${CURL:-curl}
  "$curl_cmd" -fsSL https://bun.sh/install -o "$script_tmp" || {
    rm -f "$script_tmp"
    die "bun install fetch failed"
  }
  bash -s "$tag" <"$script_tmp" >/dev/null || {
    rm -f "$script_tmp"
    die "bun install $tag failed"
  }
  rm -f "$script_tmp"
  have=$(bun --version 2>/dev/null | tr -d '[:space:]v' || true)
  [ "$have" = "$pin" ] || die "bun still $have after install, want $pin"
}

lockfile_paths() { # <repo_dir>
  local p
  for p in "$1/bun.lockb" "$1/bun.lock" "$1/web/bun.lockb" "$1/web/bun.lock"; do
    [ -f "$p" ] && printf '%s\n' "$p"
  done
}

state_slug() { # path -> safe filename fragment
  printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

lock_sha256() { # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

bun_install_if_lock_changed() { # <repo_dir>
  [ -d "$1" ] || return 0
  export PATH="$HOME/.bun/bin:$PATH"
  local path slug h new pkgdir
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    slug=$(state_slug "$path")
    h=$(lock_sha256 "$path")
    new="$state_dir/bun-lock-${slug}.sha256"
    if [ -f "$new" ] && [ "$(cat "$new")" = "$h" ]; then
      continue
    fi
    pkgdir=$(dirname "$path")
    [ -f "$pkgdir/package.json" ] || die "missing package.json for lockfile $path"
    (cd "$pkgdir" && bun install) || die "bun install failed in $pkgdir"
    printf '%s' "$h" >"$new"
  done < <(lockfile_paths "$1")
}

# --- host check: fast-forward main on configured repos (this host only) ---

fleet_pull_local_repos() {
  local d b strict=${WORKER_STARTUP_STRICT_PULL:-0}
  for d in "$@"; do
    d=${d/#\~/$HOME}
    if [ ! -e "$d/.git" ]; then
      [ "$strict" = 1 ] && die "missing repo $d"
      echo "skip $d (missing)" >&2
      continue
    fi
    b=$(git -C "$d" branch --show-current)
    if [ "$b" != main ]; then
      [ "$strict" = 1 ] && die "repo $d not on main (on ${b:-detached})"
      echo "skip $d (on $b)" >&2
      continue
    fi
    if [ -n "$(git -C "$d" status --porcelain --untracked-files=no)" ]; then
      [ "$strict" = 1 ] && die "repo $d is dirty"
      echo "skip $d (dirty)" >&2
      continue
    fi
    git -C "$d" fetch -q origin || die "fetch failed for $d"
    if git -C "$d" merge --ff-only -q origin/main >/dev/null 2>&1; then
      behind=$(git -C "$d" rev-list --count HEAD..origin/main 2>/dev/null || echo 1)
      [ "${behind:-1}" = 0 ] || die "repo $d still behind origin/main after pull"
      echo "ok   $d $(git -C "$d" rev-parse --short HEAD)"
    else
      die "not fast-forward $d (fix manually; no merge/reset/stash here)"
    fi
  done
}

repo_ready_for_tooling() { # <repo_dir> — same bar as fleet-pull: clean checkout on main
  [ -e "$1/.git" ] || return 1
  [ "$(git -C "$1" branch --show-current)" = main ] || return 1
  [ -z "$(git -C "$1" status --porcelain --untracked-files=no)" ] || return 1
  return 0
}

placement_line_from_json() { # <json>
  "$python3" -c '
import json, sys
r = json.load(sys.stdin)
if r.get("ok"):
    print("worker-placement: host=%s load_1m=%s" % (r["host"], r["load_1m"]))
else:
    loads = r.get("loads") or {}
    if loads:
        parts = " ".join("%s=%s" % (h, loads[h]) for h in sorted(loads))
        print("worker-placement: refused %s" % parts)
    else:
        print("worker-placement: refused (%s)" % (r.get("reason") or "unknown"))
' <<<"$1"
}

apply_worker_placement() { # <spec_file> -> WORKER_STARTUP_PLACED_ENV; prints chosen line to stdout
  local spec_file=$1 json line env_name
  WORKER_STARTUP_PLACED_ENV=
  json=$("$python3" "$here/worker-placement.py" pick --spec "$spec_file" --json) || die "worker-placement failed"
  line=$(placement_line_from_json "$json")
  if [ "$(printf '%s' "$json" | jq -r '.ok')" != true ]; then
    echo "$line" >&2
    exit 4
  fi
  printf '%s\n' "$line"
  env_name=$(printf '%s' "$json" | jq -r '.environment // empty')
  WORKER_STARTUP_PLACED_ENV=$env_name
}

pick_host_only() {
  local spec=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --spec)
        [ $# -ge 2 ] || die "need --spec FILE"
        spec=$2
        shift 2 ;;
      *) die "usage: worker-startup.sh --pick-host-only --spec FILE" ;;
    esac
  done
  [ -f "$spec" ] || die "spec file not found: $spec"
  apply_worker_placement "$spec"
}

host_check() {
  need_cmd jq
  if { [ -z "${FLEET_PULL_CONFIG:-}" ] || [ -n "${AGENT_STATE_DIR:-}" ]; } && [ -e "$agent_state_dir/.git" ]; then
    fleet_pull_local_repos "$agent_state_dir"
  fi
  local cfg
  cfg=$(resolve_fleet_pull_config)
  [ -f "$cfg" ] || die "missing config $cfg (copy fleet-pull.config.example.json)"
  local repos=() r
  while IFS= read -r r; do
    [ -n "$r" ] && repos+=("$r")
  done < <(jq -r '(.repos // [])[]' "$cfg")
  if [ -n "${REMOTE_REPO:-}" ] && [ -e "${REMOTE_REPO/#\~/$HOME}/.git" ]; then
    repos+=("$REMOTE_REPO")
  fi
  [ "${#repos[@]}" -gt 0 ] || die "no repos in $cfg"
  fleet_pull_local_repos "${repos[@]}"
  for r in "${repos[@]}"; do
    r=${r/#\~/$HOME}
    repo_ready_for_tooling "$r" || continue
    ensure_node_matches_pin "$r"
    ensure_bun_matches_pin "$r"
    bun_install_if_lock_changed "$r"
  done
}

# --- --run: optional worktree create (non-cursor), then delegate ---

usage_run() {
  echo "usage: worker-startup.sh --run ID --spec FILE --title TEXT --agent NAME --model ID [--from HANDLE] [--on ENV]" >&2
  echo "          (--worktree-path PATH | --name NAME --repo SELECTOR [--base-branch REF])" >&2
  echo "       worker-startup.sh --run ID --task ID --retry-of DISPATCH_ID --worktree SELECTOR --agent NAME --from HANDLE [--model ID]" >&2
  exit 2
}

run_mode() {
  local run='' spec='' title='' agent='' model='' environment='' from=${ORCA_TERMINAL_HANDLE:-}
  local wt='' worktree_sel='' name='' repo='' base='' task='' retry_of=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --run|--spec|--title|--agent|--model|--from|--on|--worktree-path|--worktree|--name|--repo|--base-branch|--task|--retry-of)
        [ $# -ge 2 ] || usage_run
        case "$1" in
          --run) run=$2 ;;
          --spec) spec=$2 ;;
          --title) title=$2 ;;
          --agent) agent=$2 ;;
          --model) model=$2 ;;
          --from) from=$2 ;;
          --on) environment=$2 ;;
          --worktree-path) wt=$2 ;;
          --worktree) worktree_sel=$2 ;;
          --name) name=$2 ;;
          --repo) repo=$2 ;;
          --base-branch) base=$2 ;;
          --task) task=$2 ;;
          --retry-of) retry_of=$2 ;;
        esac
        shift 2 ;;
      *) usage_run ;;
    esac
  done
  if [ -n "$task" ] || [ -n "$retry_of" ]; then
    [ -n "$run" ] && [ -n "$task" ] && [ -n "$retry_of" ] && [ -n "$agent" ] || usage_run
    if [ -z "$worktree_sel" ] && [ -n "$wt" ]; then
      worktree_sel="path:$wt"
    fi
    [ -n "$worktree_sel" ] || usage_run
    [ -n "$from" ] || die "need --from or ORCA_TERMINAL_HANDLE"
    host_check >&2
    "$python3" "${USAGE_GATE_CLI:-$here/usage-gate.py}" check --provider "$agent" ${model:+--model "$model"} >&2 \
      || { echo "worker-startup: refused by the usage gate" >&2; exit 3; }
    exec "$orca" orchestration worker-start --run "$run" --task "$task" --retry-of "$retry_of" \
      --worktree "$worktree_sel" --agent "$agent" --from "$from" ${model:+--model "$model"} --json
  fi
  [ -n "$run" ] && [ -n "$spec" ] && [ -n "$title" ] && [ -n "$agent" ] && [ -n "$model" ] || usage_run
  [ -f "$spec" ] || die "spec file not found: $spec"
  [ -n "$(tr -d '[:space:]' <"$spec" || true)" ] || die "spec file is empty: $spec"
  local lint_out
  lint_out=$(bash "$here/brief-lint.sh" "$spec" 2>&1) || die "$lint_out"
  [ -n "$from" ] || die "need --from or ORCA_TERMINAL_HANDLE"

  host_check

  if [ -z "$environment" ]; then
    apply_worker_placement "$spec"
    [ -n "${WORKER_STARTUP_PLACED_ENV:-}" ] && environment=$WORKER_STARTUP_PLACED_ENV
  fi

  if [ -n "$repo" ]; then
    case "$repo" in
      id:*) ;;
      path:*) export REMOTE_REPO="${repo#path:}" ;;
      *) export REMOTE_REPO="$repo" ;;
    esac
  fi

  if [ "$agent" = cursor ]; then
    exec bash "$here/start-cursor-worker.sh" --run "$run" --spec "$spec" --title "$title" --model "$model" \
      --from "$from" ${environment:+--on "$environment"} \
      ${wt:+--worktree-path "$wt"} ${name:+--name "$name"} ${repo:+--repo "$repo"} ${base:+--base-branch "$base"}
  fi

  "$python3" "${USAGE_GATE_CLI:-$here/usage-gate.py}" check --provider "$agent" ${model:+--model "$model"} >&2 \
    || { echo "worker-startup: refused by the usage gate" >&2; exit 3; }

  if [ -z "$wt" ]; then
    [ -n "$name" ] && [ -n "$repo" ] || usage_run
    case "$repo" in
      id:*|path:*) repo_selector=$repo ;;
      *) repo_selector="path:$repo" ;;
    esac
    if [ -z "$base" ] && [ -z "$environment" ] && [[ "$repo_selector" == path:* ]]; then
      base=$(git -C "${repo_selector#path:}" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    fi
    create_args=(--name "$name" --repo "$repo_selector")
    [ -z "$base" ] || create_args+=(--base-branch "$base")
    create_args+=(--setup run --json)
    [ -z "$environment" ] || create_args+=(--environment "$environment")
    result=$("$orca" worktree create "${create_args[@]}") || {
      status=$?
      printf 'orca worktree create failed (exit %s)\n%s\n' "$status" "$result" >&2
      exit "$status"
    }
    wt=$(printf '%s' "$result" | jq -r '.result.worktree.path // empty')
    wt=${wt//$'\r'/}
    wt="${wt#"${wt%%[![:space:]]*}"}"
    wt="${wt%"${wt##*[![:space:]]}"}"
  fi
  case "$wt" in /*) ;; *) die "worktree path must be absolute" ;; esac

  local brief
  brief=$(cat "$spec")
  if [ -n "$environment" ]; then
    exec bash "$here/start-remote-worker.sh" --run "$run" --spec "$brief" --agent "$agent" --model "$model" \
      --on "$environment" --worktree "path:$wt" --task-title "$title" --from "$from" --json
  fi
  exec "$orca" orchestration worker-start --run "$run" --spec "$brief" --agent "$agent" --model "$model" \
    --worktree "path:$wt" --task-title "$title" --from "$from" --json
}

case "${1:-}" in
  --host-check)
    host_check
    ;;
  --pick-host-only)
    shift
    pick_host_only "$@"
    ;;
  --run)
    run_mode "$@"
    ;;
  -h|--help)
    echo "Usage: worker-startup.sh --host-check | --run ..." >&2
    exit 0
    ;;
  *)
    echo "usage: worker-startup.sh --host-check | --run ..." >&2
    exit 2
    ;;
esac
