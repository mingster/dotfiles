#!/usr/bin/env bash
# One entry for daily host health and for starting supervised workers after the host is ready.
# Config: FLEET_PULL_CONFIG or script/fleet-pull.config.json (copy from fleet-pull.config.example.json).
# Usage:
#   worker-startup.sh --host-check
#   worker-startup.sh --pick-host-only --spec FILE
#   worker-startup.sh --run ID --spec FILE --title TEXT --agent NAME --model ID [--from HANDLE] [--on ENV]
#         [--route-override REASON]
#         (--worktree-path PATH | --name NAME --repo SELECTOR [--base-branch REF])
# A fullstack-dev or light-tier title ("<role> - <job>") started with --agent claude is refused while
# usage-gate.py pick still allows Cursor. --route-override REASON logs the reason and allows that start.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/lib/pr-review-gates.sh"
# shellcheck source=lib/automation-path.sh
. "$here/lib/automation-path.sh"
# shellcheck source=lib/board-status.sh
. "$here/lib/board-status.sh"
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
  if ! command -v node >/dev/null 2>&1; then
    PATH="$(automation_tool_path):${PATH}"
    export PATH
  fi
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

resolve_placement_config() {
  if [ -n "${FLEET_WATCH_CONFIG:-}" ]; then
    printf '%s\n' "${FLEET_WATCH_CONFIG/#\~/$HOME}"
    return
  fi
  if [ -n "${FLEET_PLACEMENT_CONFIG:-}" ]; then
    printf '%s\n' "${FLEET_PLACEMENT_CONFIG/#\~/$HOME}"
    return
  fi
  printf '%s\n' "${HOME}/.config/fleet-watch/config.json"
}

placement_line_from_json() { # <json>
  "$python3" -c '
import json, sys
r = json.load(sys.stdin)
if r.get("ok"):
    print("worker-placement: host=%s load_1m=%s" % (r["host"], r["load_1m"]))
else:
    reason = r.get("reason") or "unknown"
    loads = r.get("loads") or {}
    if loads and "repo mapping" not in reason:
        parts = " ".join("%s=%s" % (h, loads[h]) for h in sorted(loads))
        print("worker-placement: refused %s" % parts)
    elif loads:
        parts = " ".join("%s=%s" % (h, loads[h]) for h in sorted(loads))
        print("worker-placement: refused (%s) %s" % (reason, parts))
    else:
        print("worker-placement: refused (%s)" % reason)
' <<<"$1"
}

apply_worker_placement() { # <spec_file> [repo_selector] -> WORKER_STARTUP_PLACED_ENV, WORKER_STARTUP_PLACED_REPO
  local spec_file=$1 repo_sel=${2:-} json line env_name placed_repo pick_args=() cfg
  WORKER_STARTUP_PLACED_ENV=
  WORKER_STARTUP_PLACED_REPO=
  cfg=$(resolve_placement_config)
  if [ ! -f "$cfg" ]; then
    echo 'worker-placement: skipped (no fleet config)' >&2
    return 0
  fi
  pick_args=(pick --spec "$spec_file" --json --config "$cfg")
  [ -z "$repo_sel" ] || pick_args+=(--repo "$repo_sel")
  set +e
  json=$("$python3" "$here/worker-placement.py" "${pick_args[@]}")
  local ec=$?
  set -e
  [ "$ec" -eq 2 ] && die "worker-placement failed (fleet config unreadable or malformed)"
  [ -n "$json" ] || die "worker-placement failed"
  if [ "$(printf '%s' "$json" | jq -r '.skipped // false')" = true ]; then
    return 0
  fi
  line=$(placement_line_from_json "$json")
  if [ "$(printf '%s' "$json" | jq -r '.ok')" != true ]; then
    echo "$line" >&2
    exit 4
  fi
  printf '%s\n' "$line"
  env_name=$(printf '%s' "$json" | jq -r '.environment // empty')
  WORKER_STARTUP_PLACED_ENV=$env_name
  placed_repo=$(printf '%s' "$json" | jq -r '.repo // empty')
  WORKER_STARTUP_PLACED_REPO=$placed_repo
}

pick_host_only() {
  local spec='' repo=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --spec)
        [ $# -ge 2 ] || die "need --spec FILE"
        spec=$2
        shift 2 ;;
      --repo)
        [ $# -ge 2 ] || die "need --repo SELECTOR"
        repo=$2
        shift 2 ;;
      *) die "usage: worker-startup.sh --pick-host-only --spec FILE [--repo SELECTOR]" ;;
    esac
  done
  [ -f "$spec" ] || die "spec file not found: $spec"
  apply_worker_placement "$spec" "$repo"
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

# The fixed Finish steps are not the author's to write (#968). A brief with no "## Finish" heading gets the
# standard block appended in a copy; the original is untouched. Prints the spec path to use.
with_finish_block() { # <spec_file> <run_id>
  local spec_file=$1 run_id=$2 out
  if grep -qE '^## Finish([[:space:]]|$)' "$spec_file"; then
    printf '%s\n' "$spec_file"
    return 0
  fi
  out=$(mktemp "${TMPDIR:-/tmp}/worker-startup-spec.XXXXXX") || die "cannot write the spec copy"
  cp "$spec_file" "$out"
  {
    printf '\n## Finish\n'
    printf -- '- Self-review the diff before you hand off.\n'
    if grep -qi 'fullstack-dev' "$spec_file"; then
      printf -- '- Open a PR with the issue closing line, a line `Builder: agent=<agent> model=<model>`.\n'
      printf -- '- Wait until `gh pr checks <n> --watch --fail-fast` (or `gh run list --branch <branch> --limit 3`) shows the checks passing at your final head. Never send worker_done with red or pending checks.\n'
    fi
    printf -- '- When this work has a pull request, run `orca worktree set --worktree active --workspace-status in-review` before `worker_done`. When it has no pull request, run `orca worktree set --worktree active --workspace-status completed` before `worker_done`. Then send `worker_done` to run %s. Never wait for a reply. Never contact the user.\n' "$run_id"
  } >>"$out"
  printf '%s\n' "$out"
}

usage_run() {
  echo "usage: worker-startup.sh --run ID --spec FILE --title TEXT --agent NAME --model ID [--from HANDLE] [--on ENV] [--route-override REASON]" >&2
  echo "          (--worktree-path PATH | --name NAME --repo SELECTOR [--base-branch REF])" >&2
  echo "       worker-startup.sh --run ID --task ID --retry-of DISPATCH_ID --worktree SELECTOR --agent NAME --from HANDLE [--model ID]" >&2
  exit 2
}

# Resolved poteto-mode, ORCA-ADAPTER, and role-file paths, ahead of the brief. Idempotent.
prepend_role_preamble() { # <spec_file> <title>
  local spec_file=$1 title=$2 role out
  role=$(role_from_title "$title" || true)
  if [ -z "$role" ]; then
    role=$(sed -n 's/^Role:[[:space:]]*\([a-z0-9-]*\).*/\1/p' "$spec_file" | head -n 1)
  fi
  [ -n "$role" ] || role=fullstack-dev
  if grep -q 'poteto-mode/SKILL.md' "$spec_file" && grep -q 'ORCA-ADAPTER.md' "$spec_file"; then
    printf '%s\n' "$spec_file"
    return 0
  fi
  out=$(mktemp "${TMPDIR:-/tmp}/worker-startup-preamble.XXXXXX") || die "cannot write the spec copy"
  {
    "$python3" "$here/worker-preamble.py" --role "$role"
    printf '\n'
    cat "$spec_file"
  } >"$out"
  printf '%s\n' "$out"
}

role_from_title() { # "<role> - <job>" -> role; anything else prints nothing
  local title=$1 role
  case "$title" in
    *" - "*) role=${title%% - *} ;;
    *) return 0 ;;
  esac
  case "$role" in
    *[!a-z0-9-]*) return 0 ;;
    [a-z]*) printf '%s\n' "$role" ;;
  esac
}

role_class() { # <role> -> builder|other; exit 2 when presets cannot be read
  "$python3" - "$here/usage-gate.py" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("usage_gate_route", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
try:
    builder = mod.is_builder_role(sys.argv[2])
except Exception as exc:
    print("worker-startup: cannot classify role:", type(exc).__name__, file=sys.stderr)
    sys.exit(2)
print("builder" if builder else "other")
PY
}

log_route_override() { # <role> <agent> <reason>
  mkdir -p "$state_dir"
  "$python3" - "$state_dir/route-override.log" "$1" "$2" "$3" <<'PY'
import json, sys
from datetime import datetime, timezone
path, role, agent, reason = sys.argv[1:]
with open(path, "a") as handle:
    handle.write(json.dumps({
        "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "role": role,
        "agent": agent,
        "reason": reason,
    }) + "\n")
PY
  echo "worker-startup: route override for $1: $3" >&2
}

run_captured() { # command... ; print its stdout, return its status. start_out is the caller's variable.
  local ec=0
  start_out=$("$@") || ec=$?
  printf '%s\n' "$start_out"
  return "$ec"
}

surface_antigravity_screen() { # <agent> <worker-start json>
  local agent=$1 start_json=$2 dispatch msg ec check
  [ "$agent" = antigravity ] || return 0
  dispatch=$(jq -r '.result.dispatchId // empty' <<<"$start_json" 2>/dev/null || true)
  [ -n "$dispatch" ] || die "antigravity start returned no dispatch"
  check=$here/../.agents/skills/orca-team/worker-start-check.sh
  [ -f "$check" ] || die "missing worker-start-check.sh"
  set +e
  msg=$(bash "$check" --screen-only "$dispatch" 15 2>&1)
  ec=$?
  set -e
  if [ "$ec" -ne 0 ]; then
    printf '%s\n' "$msg" >&2
    exit "$ec"
  fi
}

enforce_builder_cursor() { # <title> <agent> <override>
  local title=$1 agent=$2 override=$3 role kind pick_py pick_out pick_err flags
  [ "$agent" = claude ] || return 0
  role=$(role_from_title "$title")
  [ -n "$role" ] || return 0
  kind=$(role_class "$role") || die "cannot classify role $role"
  [ "$kind" = builder ] || return 0
  if [ -n "$override" ]; then
    log_route_override "$role" "$agent" "$override"
    return 0
  fi
  pick_py=${USAGE_GATE_PICK:-${USAGE_GATE_CLI:-$here/usage-gate.py}}
  pick_err="$state_dir/pick-route.err"
  pick_out=$("$python3" "$pick_py" pick --role "$role" 2>"$pick_err" || true)
  flags=$(printf '%s\n' "$pick_out" | awk '/^--agent /{line=$0} END{print line}')
  case "$flags" in
    "--agent cursor"*)
      echo "worker-startup: refused $role on claude while Cursor is allowed: $flags" >&2
      [ ! -s "$pick_err" ] || cat "$pick_err" >&2
      exit 1
      ;;
  esac
}

run_mode() {
  local run='' spec='' title='' agent='' model='' environment='' from=${ORCA_TERMINAL_HANDLE:-}
  local wt='' worktree_sel='' name='' repo='' base='' task='' retry_of='' route_override='' start_out=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --run|--spec|--title|--agent|--model|--from|--on|--worktree-path|--worktree|--name|--repo|--base-branch|--task|--retry-of|--route-override)
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
          --route-override) route_override=$2; [ -n "$route_override" ] || die "route override needs a reason" ;;
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
    local wt_retry=""
    case "$worktree_sel" in
      path:*)
        wt_retry="${worktree_sel#path:}"
        if [ -n "$model" ]; then
          pr_review_gates_launch_record_worktree "$wt_retry" "$agent" "$model"
        fi
        ;;
    esac
    run_captured pr_review_gates_orchestration_worker_start "$agent" "${model:-}" "$wt_retry" -- \
      --run "$run" --task "$task" --retry-of "$retry_of" \
      --worktree "$worktree_sel" --agent "$agent" --from "$from" ${model:+--model "$model"} || exit $?
    surface_antigravity_screen "$agent" "$start_out"
    return 0
  fi
  [ -n "$run" ] && [ -n "$spec" ] && [ -n "$title" ] && [ -n "$agent" ] && [ -n "$model" ] || usage_run
  [ -f "$spec" ] || die "spec file not found: $spec"
  [ -n "$(tr -d '[:space:]' <"$spec" || true)" ] || die "spec file is empty: $spec"
  local lint_out dispatch_log
  spec=$(with_finish_block "$spec" "$run")
  spec=$(prepend_role_preamble "$spec" "$title")
  lint_out=$(bash "$here/brief-lint.sh" "$spec" 2>&1) || die "$lint_out"
  [ -n "$from" ] || die "need --from or ORCA_TERMINAL_HANDLE"
  enforce_builder_cursor "$title" "$agent" "$route_override"

  # A merge worker reads the local Orca run list, so it runs on the coordinator host, never on an overflow host.
  local merge_worker=''
  case "$title" in
    "release-manager: merge"*)
      [ -z "$environment" ] || die "refused: a 'release-manager: merge' worker runs on the coordinator host only, not --on $environment"
      merge_worker=1 ;;
  esac

  host_check

  if [ -z "$environment" ] && [ -z "$wt" ] && [ -z "$merge_worker" ]; then
    apply_worker_placement "$spec" "$repo"
    [ -n "${WORKER_STARTUP_PLACED_ENV:-}" ] && environment=$WORKER_STARTUP_PLACED_ENV
  fi

  if [ -n "$repo" ]; then
    case "$repo" in
      id:*) ;;
      path:*) export REMOTE_REPO="${repo#path:}" ;;
      *) export REMOTE_REPO="$repo" ;;
    esac
  fi

  "$python3" "${USAGE_GATE_CLI:-$here/usage-gate.py}" check --provider "$agent" ${model:+--model "$model"} >&2 \
    || { echo "worker-startup: refused by the usage gate" >&2; exit 3; }

  # Dispatch point for team-audit-metrics.ts stage times (issue<TAB>dispatched_at<TAB>owner/repo); never blocks a start.
  dispatch_log=${TEAM_AUDIT_DISPATCHES:-$agent_state_dir/team-dispatches.tsv}
  [ -s "$dispatch_log" ] || printf 'issue\tdispatched_at\trepo\n' 2>/dev/null >"$dispatch_log" || true
  local ref ref_issue ref_repo dir origin
  ref=$(grep -oE 'Refs ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+' "$spec" | head -1 | sed 's/^Refs //') || true
  ref_issue=${ref##*#}
  ref_repo=${ref%%#*}
  if [ -z "$ref_repo" ]; then
    dir=${wt:-}
    if [ -z "$dir" ]; then
      case "$repo" in
        id:*) dir=$("$orca" repo list --json 2>/dev/null | jq -r --arg id "${repo#id:}" '.result.repos[]? | select(.id == $id) | .path // empty' 2>/dev/null | head -1) || dir= ;;
        path:*) dir=${repo#path:} ;;
        /*|.*|~*) dir=$repo ;;
        */*) ref_repo=$repo ;;
        *) dir=$repo ;;
      esac
    fi
    if [ -z "$ref_repo" ] && [ -n "$dir" ]; then
      origin=$(git -C "$dir" remote get-url origin 2>/dev/null) || origin=
      # Only remote URLs (git@host:o/r, scheme://host/o/r) name a repo; a local path origin does not.
      ref_repo=$(printf '%s' "$origin" | sed -nE 's#^(git@[^:/]+:|[A-Za-z+]+://[^/]+/)([^/]+/[^/]+)$#\2#p; ' | sed -E 's#\.git$##')
    fi
  fi
  [ -z "$ref_issue" ] || printf '%s\t%s\t%s\n' "$ref_issue" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ref_repo" 2>/dev/null >>"$dispatch_log" || true

  if [ "$agent" = cursor ]; then
    # Placement's remote repo selector is the one Cursor must create. The caller's local id is not on that host.
    cursor_repo=$repo
    if [ -n "${WORKER_STARTUP_PLACED_REPO:-}" ]; then
      cursor_repo=$WORKER_STARTUP_PLACED_REPO
    fi
    exec bash "$here/start-cursor-worker.sh" --run "$run" --spec "$spec" --title "$title" --model "$model" \
      --from "$from" ${environment:+--on "$environment"} \
      ${wt:+--worktree-path "$wt"} ${name:+--name "$name"} ${cursor_repo:+--repo "$cursor_repo"} ${base:+--base-branch "$base"}
  fi

  if [ -z "$wt" ]; then
    [ -n "$name" ] && [ -n "$repo" ] || usage_run
    case "$repo" in
      id:*|path:*) repo_selector=$repo ;;
      *) repo_selector="path:$repo" ;;
    esac
    if [ -n "${WORKER_STARTUP_PLACED_REPO:-}" ]; then
      repo_selector=$WORKER_STARTUP_PLACED_REPO
    fi
    repo_selector=$(pr_review_gates_canonicalize_repo "$repo_selector")
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
  pr_review_gates_launch_record_worktree "$wt" "$agent" "$model"
  board_status_set "path:$wt" in-progress "$environment"
  if [ -n "$environment" ]; then
    run_captured bash "$here/start-remote-worker.sh" --run "$run" --spec "$brief" --agent "$agent" --model "$model" \
      --on "$environment" --worktree "path:$wt" --task-title "$title" --from "$from" --json || exit $?
    surface_antigravity_screen "$agent" "$start_out"
    return 0
  fi
  run_captured pr_review_gates_orchestration_worker_start "$agent" "$model" "$wt" -- \
    --run "$run" --spec "$brief" --agent "$agent" --model "$model" \
    --worktree "path:$wt" --task-title "$title" --from "$from" || exit $?
  surface_antigravity_screen "$agent" "$start_out"
  return 0
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
