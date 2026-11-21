#!/usr/bin/env bash
# One entry for daily host health and for starting supervised workers after the host is ready.
# Config: FLEET_PULL_CONFIG or script/fleet-pull.config.json (copy from fleet-pull.config.example.json).
# Usage:
#   worker-startup.sh --host-check
#   worker-startup.sh --pick-host-only --spec FILE
#   worker-startup.sh --run ID --spec FILE --title TEXT --agent NAME --model ID [--from HANDLE] [--on ENV]
#         [--route-override REASON] [--allow-delivered REASON] [--skip-dotfiles-first REASON]
#         (--worktree-path PATH | --name NAME --repo SELECTOR [--base-branch REF])
# --title must be "#<issue>|<role>" (for example "#123|qa-sdet"; a verifier uses its PR number), else exit 2.
# After start the title is also set on the worker terminal and pane.
# A fullstack-dev or light-tier title ("#<issue>|<role>") started on antigravity, grok or cursor is refused
# while usage-gate.py pick still returns claude (provider priority: claude, antigravity, grok, cursor).
# --on ENV over its load limit, or naming the coordinator host, exits 4 unless --force-host REASON
# is given (the coordinator host accepts only chrome-dev, line-desktop or host-file).
# A fullstack-dev brief whose Refs issue a merged PR already closed (Closes, Fixes, Resolves, Delivers) is refused
# unless --allow-delivered REASON is given (#1158).
# A builder start for another repo is refused while a dotfiles issue labeled ready-for-agent (no hold label) waits, unless
# --skip-dotfiles-first REASON is given; the reason is logged (docs/agents/labels.md, Start order). A failed gh call lets it go on.
# --route-override REASON logs the reason and allows that start. --agent grok --on ENV needs ENV listed under
# grok_hosts in the fleet config (the hosts that have the Grok CLI).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/dotfiles-fresh.sh
. "$here/lib/dotfiles-fresh.sh"
# shellcheck disable=SC1091
. "$here/lib/pr-review-gates.sh"
# shellcheck source=lib/automation-path.sh
. "$here/lib/automation-path.sh"
# shellcheck source=lib/board-status.sh
. "$here/lib/board-status.sh"
# shellcheck source=lib/worker-role.sh
. "$here/lib/worker-role.sh"
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

this_host_name() {
  local name
  name=$(hostname -s 2>/dev/null || true)
  printf '%s' "$name" | tr '[:upper:]' '[:lower:]'
}

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
    line = "worker-placement: host=%s load_1m=%s" % (r["host"], r["load_1m"])
    if r.get("workers") is not None:
        line += " workers=%s/%s" % (r["workers"], r["cap"])
    print(line)
else:
    reason = r.get("reason") or "unknown"
    loads = r.get("loads") or {}
    if "worker cap" in reason and not loads:
        parts = " ".join("%s=%s" % (h, v) for h, v in sorted((r.get("workers") or {}).items()))
        print("worker-placement: refused (%s) %s" % (reason, parts))
    elif loads and "repo mapping" not in reason:
        parts = " ".join("%s=%s" % (h, loads[h]) for h in sorted(loads))
        print("worker-placement: refused %s" % parts)
    elif loads:
        parts = " ".join("%s=%s" % (h, loads[h]) for h in sorted(loads))
        print("worker-placement: refused (%s) %s" % (reason, parts))
    else:
        print("worker-placement: refused (%s)" % reason)
' <<<"$1"
}

apply_worker_placement() { # <spec_file> [repo_selector] [--record] -> WORKER_STARTUP_PLACED_ENV, WORKER_STARTUP_PLACED_REPO
  local spec_file=$1 repo_sel=${2:-} record=${3:-} json line env_name placed_repo pick_args=() cfg
  WORKER_STARTUP_PLACED_ENV=
  WORKER_STARTUP_PLACED_REPO=
  WORKER_STARTUP_PLACED_HOST=
  WORKER_STARTUP_PLACED_CFG=
  cfg=$(resolve_placement_config)
  if [ ! -f "$cfg" ]; then
    echo 'worker-placement: skipped (no fleet config)' >&2
    return 0
  fi
  if [[ "$repo_sel" == path:* ]]; then
    local repo_dir=${repo_sel#path:} repo_json repo_id
    if repo_json=$("$orca" repo list --json 2>/dev/null) && jq -e '.result.repos | type == "array"' >/dev/null 2>&1 <<<"$repo_json"; then
      repo_id=$(jq -r --arg p "${repo_dir%/}" '.result.repos[] | select((.path | rtrimstr("/")) == $p) | .id // empty' <<<"$repo_json" | head -1)
      [ -n "$repo_id" ] || die "refused: no Orca repo id for $repo_sel (add it in Orca, or pass --repo id:<id>)"
      repo_sel="id:$repo_id"
    fi
  fi
  pick_args=(pick --spec "$spec_file" --json --config "$cfg")
  [ -z "$repo_sel" ] || pick_args+=(--repo "$repo_sel")
  # A real start records itself so the next pick counts it before its load shows.
  [ "$record" != --record ] || pick_args+=(--record)
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
  if [ "$record" = --record ]; then
    WORKER_STARTUP_PLACED_HOST=$(printf '%s' "$json" | jq -r '.host // empty')
    WORKER_STARTUP_PLACED_CFG=$cfg
  fi
}

# --on skips placement, so judge the named host by the same load rule (worker-placement.py owns it).
# Over its limit: exit 4 naming the host placement would pick, unless --force-host gave a reason.
# The coordinator host (the host this script runs on, read from hostname) needs an allowed reason under any load.
FORCE_COORDINATOR_REASONS='chrome-dev line-desktop host-file'
check_forced_host() { # <host> <spec_file> <repo_selector> <force_reason>
  local host=$1 spec_file=$2 repo_sel=$3 reason=$4 cfg json ec check_args=() me ok_reason r
  me=$(this_host_name)
  if [ -n "$me" ] && [ "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" = "$me" ]; then
    ok_reason=
    for r in $FORCE_COORDINATOR_REASONS; do [ "$reason" != "$r" ] || ok_reason=1; done
    if [ -z "$ok_reason" ]; then
      echo "worker-placement: refused forced host=$host (the coordinator host); --force-host must be one of: ${FORCE_COORDINATOR_REASONS// /, }${reason:+ (got: $reason)}" >&2
      exit 4
    fi
    echo "worker-startup: force-host: $reason (coordinator host $host)" >&2
    return 0
  fi
  cfg=$(resolve_placement_config)
  [ -f "$cfg" ] || return 0
  check_args=(check-host --host "$host" --spec "$spec_file" --config "$cfg")
  [ -z "$repo_sel" ] || check_args+=(--repo "$repo_sel")
  set +e
  json=$("$python3" "$here/worker-placement.py" "${check_args[@]}")
  ec=$?
  set -e
  [ "$ec" -eq 2 ] && die "worker-placement failed (fleet config unreadable or malformed)"
  [ -n "$json" ] || die "worker-placement failed"
  [ "$(printf '%s' "$json" | jq -r '.ok')" != true ] || return 0
  if [ -n "$reason" ]; then
    echo "worker-startup: force-host: $reason ($(printf '%s' "$json" | jq -r '.line'))" >&2
    return 0
  fi
  printf '%s\n' "$(printf '%s' "$json" | jq -r '.line')" >&2
  echo 'worker-startup: pass --force-host REASON to start there anyway' >&2
  exit 4
}

# One line per start: live workers per host, so the coordinator sees the spread. Never blocks a start.
print_worker_spread() {
  local me out
  me=$(this_host_name)
  out=$("$orca" orchestration worker-list --include-remote --terminal-state active --json --limit 100 2>/dev/null \
    | jq -r --arg me "${me:-local}" '[.result.workers[]? | select(.liveness == "live") | (if .host == "local" then $me else .host end)]
        | group_by(.) | map("\(.[0])=\(length)") | join(" ")' 2>/dev/null) || out=
  echo "worker-startup: live workers ${out:-none}" >&2
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
with_finish_block() { # <spec_file> <run_id> <agent> <model>
  local spec_file=$1 run_id=$2 agent=${3:-} model=${4:-} out
  local builder_line=""
  if [ -n "$agent" ] && [ -n "$model" ]; then
    builder_line="Builder: agent=$agent model=$model"
  fi
  if grep -qE '^## Finish([[:space:]]|$)' "$spec_file"; then
    if [ -n "$builder_line" ] && grep -qi 'fullstack-dev' "$spec_file" && ! grep -qF "$builder_line" "$spec_file"; then
      out=$(mktemp "${TMPDIR:-/tmp}/worker-startup-spec.XXXXXX") || die "cannot write the spec copy"
      cp "$spec_file" "$out"
      printf -- '- Put the line `%s` in the PR body.\n' "$builder_line" >>"$out"
      printf '%s\n' "$out"
      return 0
    fi
    printf '%s\n' "$spec_file"
    return 0
  fi
  out=$(mktemp "${TMPDIR:-/tmp}/worker-startup-spec.XXXXXX") || die "cannot write the spec copy"
  cp "$spec_file" "$out"
  {
    printf '\n## Finish\n'
    printf -- '- Self-review the diff before you hand off.\n'
    if grep -qi 'fullstack-dev' "$spec_file"; then
      printf -- '- Open a PR with the issue closing line, a line `%s`.\n' "${builder_line:-Builder: agent=<agent> model=<model>}"
      printf -- '- Wait until `gh pr checks <n> --watch --fail-fast` (or `gh run list --branch <branch> --limit 3`) shows the checks passing at your final head. Never send worker_done with red or pending checks.\n'
    fi
    printf -- '- When this work has a pull request, run `orca worktree set --worktree active --workspace-status in-review` before `worker_done`. When it has no pull request, run `orca worktree set --worktree active --workspace-status completed` before `worker_done`. Then send `worker_done` with the send command from your preamble, without a `--run` flag. Never wait for a reply. Never contact the user.\n'
  } >>"$out"
  printf '%s\n' "$out"
}

# A title "#<issue>|<role>" already names the issue, so a brief without a Refs line gets "Refs #<issue>" in a copy (#1201).
# Prints the spec path to use.
with_refs_line() { # <spec_file> <title>
  local spec_file=$1 issue out
  case "$2" in "#"[0-9]*"|"*) issue=${2#\#}; issue=${issue%%|*} ;; *) printf '%s\n' "$spec_file"; return 0 ;; esac
  if grep -qE '(Refs|Closes|Fixes|Resolves):?[[:space:]]+[A-Za-z0-9_./-]*#[0-9]+' "$spec_file"; then
    printf '%s\n' "$spec_file"
    return 0
  fi
  out=$(mktemp "${TMPDIR:-/tmp}/worker-startup-spec.XXXXXX") || die "cannot write the spec copy"
  { printf 'Refs #%s\n' "$issue"; cat "$spec_file"; } >"$out"
  printf '%s\n' "$out"
}

usage_run() {
  echo "usage: worker-startup.sh --run ID --spec FILE --title TEXT --agent NAME --model ID [--from HANDLE] [--on ENV [--force-host REASON]] [--route-override REASON] [--skip-dotfiles-first REASON]" >&2
  echo "          (--worktree-path PATH | --name NAME --repo SELECTOR [--base-branch REF])" >&2
  echo "       worker-startup.sh --run ID --task ID --retry-of DISPATCH_ID --worktree SELECTOR --agent NAME --from HANDLE [--model ID]" >&2
  exit 2
}

# Owner rule 2026-11-18: every worker title is "#<issue>|<role>".
require_title_form() { # <title> [<spec_file>]
  if ! [[ $1 =~ ^#[0-9]+\|[a-z][a-z-]*(\|.+)?$ ]]; then
    local issue='' role='' hint=''
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
      issue=$(grep -m1 -oE '^#+[[:space:]].*#[0-9]+|^(Refs|Closes|Fixes|Resolves):?[[:space:]]+[A-Za-z0-9_./-]*#[0-9]+' "$2" | grep -oE '#[0-9]+$' | head -n 1 | tr -d '#' || true)
      role=$(sed -n 's/^Role:[[:space:]]*\([a-z][a-z-]*\).*/\1/p' "$2" | head -n 1)
    fi
    [ -n "$role" ] || role=$(grep -oE '[a-z]+(-[a-z]+)+' <<<"$1" | head -n 1 || true)
    [ -n "$role" ] || role=fullstack-dev
    [ -z "$issue" ] || hint="; did you mean '#$issue|$role'?"
    echo "worker-startup: refused: --title '$1' must look like '#<issue>|<role>', for example '#123|qa-sdet' (a verifier uses its PR number)$hint" >&2
    exit 2
  fi
}

# Set the worker terminal and pane title (best effort; the task title is already set).
apply_terminal_title() { # <title> <worker-start json> [environment]
  local title=$1 start_json=$2 env=${3:-} handle
  handle=$(jq -r '.result.terminal | if type == "object" then .handle else . end // empty' <<<"$start_json" 2>/dev/null || true)
  [ -n "$handle" ] || return 0
  "$orca" terminal rename --terminal "$handle" --title "$title" ${env:+--environment "$env"} >/dev/null 2>&1 \
    || echo "worker-startup: could not rename terminal $handle" >&2
  "$orca" terminal set-pane-title --terminal "$handle" --title "$title" ${env:+--environment "$env"} >/dev/null 2>&1 \
    || echo "worker-startup: could not set pane title on $handle" >&2
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

role_class() { # <role> -> builder|other; exit 2 when presets cannot be read
  "$python3" - "$here/usage-gate.py" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("usage_gate_route", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
try:
    builder = sys.argv[2] == "builder" or mod.is_builder_role(sys.argv[2])
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

# A worker that vanishes at startup (terminal_exited at agent_readiness, agent_not_in_foreground at dispatch_input)
# is started once more in the same worktree before the start counts as failed (#1221).
STARTUP_EXIT_RE='terminal_exited|agent_not_in_foreground|agent_readiness|dispatch_input'

# True when the dispatch failed at startup. Orca reports state=ready from the first second, before agent_readiness and
# dispatch_input finish, so keep reading worker-show through the readiness wait while the stage is still a startup
# stage (#1270). A failed state matches the startup errors, or a timeout at a startup stage.
startup_exit_failure() { # <dispatch id>
  local d=$1 end out state stage
  end=$((SECONDS + ${WORKER_STARTUP_READINESS_WAIT:-6}))
  while :; do
    out=$("$orca" orchestration worker-show --dispatch "$d" --json 2>/dev/null) || out=
    state=$(jq -r '.result.state // .result.dispatch.state // empty' <<<"$out" 2>/dev/null || true)
    stage=$(jq -r '(.result.stage // .result.projection.stage // .result.dispatch.stage) | if type == "object" then (.detail // .name // "") else (. // "") end' <<<"$out" 2>/dev/null || true)
    case "$state" in
      failed|stopped|abandoned|rejected)
        grep -Eq "$STARTUP_EXIT_RE" <<<"$out" && return 0
        case "$stage" in agent_readiness|dispatch_input) grep -q 'timeout' <<<"$out" && return 0 ;; esac
        return 1 ;;
      running|succeeded|completed) return 1 ;;
      ready|accepted|pending|'')
        case "$stage" in agent_readiness|dispatch_input|server_record) ;; *) return 1 ;; esac ;;
      *) return 1 ;;
    esac
    [ "$SECONDS" -lt "$end" ] || return 1
    sleep 1
  done
}

# The same worker-start command, aimed at the task that already exists: no new task is created (#1270).
same_task_retry_command() { # <task id> <failed dispatch id> command... ; sets retry_cmd
  local task_id=$1 failed=$2 skip=0 arg
  shift 2
  retry_cmd=()
  for arg in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$arg" in
      --spec|--task-title) skip=1 ;;
      *) retry_cmd+=("$arg") ;;
    esac
  done
  retry_cmd+=(--task "$task_id" --retry-of "$failed")
}

start_with_startup_retry() { # worker-start wrapper args...; sets start_out like run_captured
  local ec=0 errf dispatch task_id
  local -a retry_cmd=()
  errf=$(mktemp)
  run_captured "$@" 2>"$errf" || ec=$?
  cat "$errf" >&2
  if [ "$ec" -ne 0 ] && grep -Eq "$STARTUP_EXIT_RE" <<<"$start_out"$'\n'"$(cat "$errf")"; then
    echo "worker-startup: worker-start failed at startup, retrying once" >&2
    ec=0
    run_captured "$@" || ec=$?
  elif [ "$ec" -eq 0 ]; then
    dispatch=$(jq -r '.result.dispatchId // empty' <<<"$start_out" 2>/dev/null || true)
    task_id=$(jq -r '.result.taskId // empty' <<<"$start_out" 2>/dev/null || true)
    if [ -n "$dispatch" ] && startup_exit_failure "$dispatch"; then
      echo "worker-startup: $dispatch failed at startup, retrying once" >&2
      ec=0
      if [ -n "$task_id" ]; then
        "$orca" orchestration worker-release --dispatch "$dispatch" ${environment:+--environment "$environment"} >/dev/null 2>&1 \
          || echo "worker-startup: could not release $dispatch before the retry" >&2
        same_task_retry_command "$task_id" "$dispatch" "$@"
        run_captured "${retry_cmd[@]}" || ec=$?
      else
        run_captured "$@" || ec=$?
      fi
    fi
  fi
  rm -f "$errf"
  return "$ec"
}

# About a minute after an antigravity start, read the worker screen. The sign-in screen stops the dispatch and
# returns 10 so the caller restarts the same brief on claude (#1240). Fleet watch marks the host and tells the owner.
AGY_SIGNIN_EXIT=10
surface_antigravity_screen() { # <agent> <worker-start json> [environment]
  local agent=$1 start_json=$2 env=${3:-} dispatch handle shown screen
  [ "$agent" = antigravity ] || return 0
  dispatch=$(jq -r '.result.dispatchId // empty' <<<"$start_json" 2>/dev/null || true)
  [ -n "$dispatch" ] || die "antigravity start returned no dispatch"
  sleep "${WORKER_STARTUP_AGY_WAIT:-60}"
  handle=$(jq -r '.result.terminal | if type == "object" then (.handle // .id // empty) else (. // empty) end' <<<"$start_json" 2>/dev/null || true)
  if [ -z "$handle" ]; then
    shown=$("$orca" orchestration worker-show --dispatch "$dispatch" --json ${env:+--environment "$env"} 2>/dev/null) || shown=
    handle=$(jq -r '.result.terminal | if type == "object" then (.handle // .id // empty) else (. // empty) end' <<<"$shown" 2>/dev/null || true)
  fi
  [ -n "$handle" ] || return 0
  screen=$("$orca" terminal read --terminal "$handle" --screen --json ${env:+--environment "$env"} 2>/dev/null) || return 0
  "$python3" "$here/agy-signin.py" match <<<"$screen" || return 0
  "$orca" orchestration worker-stop --dispatch "$dispatch" ${env:+--environment "$env"} >/dev/null 2>&1 \
    || echo "worker-startup: could not stop $dispatch after the agy sign-in screen" >&2
  return "$AGY_SIGNIN_EXIT"
}

agy_host_label() { # <environment> -> the host the worker runs on
  local h=${1:-}
  [ -n "$h" ] || h=$(this_host_name)
  printf '%s\n' "${h:-local}"
}

# The brief copy a worker gets: finish block and Builder line for this agent and model, refs line, role preamble.
build_brief_spec() { # <orig_spec> <run> <title> <agent> <model>
  local s
  s=$(with_finish_block "$1" "$2" "$4" "$5")
  s=$(with_refs_line "$s" "$3")
  s=$(prepend_role_preamble "$s" "$3")
  stamp_worker_role "$s" "$3"
}

# A builder brief for a backlog line ("#<issue> L<n>" in the title or the brief's first heading) is refused
# when a merged PR title already carries that line. Skipped when gh is missing or the lookup fails.
refuse_merged_backlog_line() { # <spec_file> <title>
  local spec_file=$1 title=$2 role kind key repo merged
  role=$(role_from_title "$title")
  [ -n "$role" ] || return 0
  [ "$role" = qa-sdet ] && return 0 # a verifier start never edits the issue labels (#1271)
  kind=$(role_class "$role") || return 0
  [ "$kind" = builder ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  key=$({ printf '%s\n' "$title"; grep -m1 '^# ' "$spec_file"; } | grep -oE '#[0-9]+ L[0-9]+' | head -1 || true)
  [ -n "$key" ] || return 0
  repo=$(grep -m1 -oE '^Refs [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#' "$spec_file" | sed -e 's/^Refs //' -e 's/#$//' || true)
  merged=$(gh pr list ${repo:+-R "$repo"} --state merged --search "${key#\#} in:title" --json number,title \
    --jq "[.[] | select(.title | test(\"$key\\\\b\"))][0].number // empty" 2>/dev/null || true)
  [ -z "$merged" ] || die "refused: $key already merged in PR #$merged; check the backlog before building it again"
}

# A builder brief whose Refs issue a merged PR already closed or referenced is refused (#1158). A failed gh call lets the start go on.
refuse_delivered_issue() { # <spec_file> <title> <allow_reason>
  local spec_file=$1 title=$2 allow=$3 role kind ref repo num prs btype
  role=$(role_from_title "$title")
  [ -n "$role" ] || return 0
  [ "$role" = qa-sdet ] && return 0 # a verifier start never edits the issue labels (#1271)
  kind=$(role_class "$role") || return 0
  [ "$kind" = builder ] || return 0
  btype=$(sed -n 's/^Type:[[:space:]]*//p' "$spec_file" | head -1)
  case "$btype" in rework|verify) return 0 ;; esac
  ref=$(grep -m1 -oE '^Refs ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+' "$spec_file" | sed 's/^Refs //' || true)
  [ -n "$ref" ] || return 0
  num=${ref##*#}
  repo=${ref%%#*}
  command -v gh >/dev/null 2>&1 || return 0
  prs=$(gh pr list ${repo:+-R "$repo"} --state merged --search "$num in:body" --limit 30 --json number,body \
    --jq "[.[] | select(.body // \"\" | test(\"(?i)(closes|fixes|resolves|delivers|refs)\\\\s+([A-Za-z0-9_./-]+)?#$num\\\\b\")) | .number] | map(\"#\" + tostring) | join(\", \")" 2>/dev/null) || {
    echo "worker-startup: delivered-issue check skipped: gh failed" >&2
    return 0
  }
  [ -n "$prs" ] || return 0
  if [ -n "$allow" ]; then
    echo "worker-startup: --allow-delivered: $ref already delivered by $prs ($allow)" >&2
    return 0
  fi
  die "refused: $ref already delivered by merged PR $prs; close the issue, or pass --allow-delivered REASON"
}

enforce_builder_provider() { # <title> <agent> <override>
  local title=$1 agent=$2 override=$3 role kind pick_py pick_out pick_err flags
  [ "$agent" != claude ] || return 0
  role=$(role_from_title "$title")
  [ -n "$role" ] || return 0
  [ "$role" = qa-sdet ] && return 0 # a verifier start never edits the issue labels (#1271)
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
    "--agent claude"*)
      echo "worker-startup: refused $role on $agent while claude is allowed: $flags" >&2
      [ ! -s "$pick_err" ] || cat "$pick_err" >&2
      exit 1
      ;;
  esac
}

# A grok start --on a host runs only where the fleet config lists the Grok CLI under grok_hosts.
require_grok_host() { # <environment>
  [ -n "$1" ] || return 0
  local cfg want
  cfg=$(resolve_fleet_pull_config)
  want=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [ -f "$cfg" ] && jq -e --arg h "$want" '(.grok_hosts // []) | map(ascii_downcase) | index($h)' "$cfg" >/dev/null 2>&1 \
    || die "refused: $1 has no grok CLI (list it under grok_hosts in $cfg)"
}

# A started worker of any role takes the ready-for-agent label off its issue, so the issue scan does not start a second worker (#1192, #1216).
# Best effort: a missing gh or a failed edit never fails a start that already succeeded.
release_ready_label() { # <spec_file> <title>
  local spec_file=$1 title=$2 role btype ref repo num
  role=$(role_from_title "$title")
  [ -n "$role" ] || return 0
  [ "$role" = qa-sdet ] && return 0 # a verifier start never edits the issue labels (#1271)
  [ "$role" != qa-sdet ] || return 0
  btype=$(sed -n 's/^Type:[[:space:]]*//p' "$spec_file" | head -1)
  case "$btype" in rework|verify) return 0 ;; esac
  ref=$(grep -m1 -oE '^Refs ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+' "$spec_file" | sed 's/^Refs //' || true)
  [ -n "$ref" ] || return 0
  num=${ref##*#}
  repo=${ref%%#*}
  command -v gh >/dev/null 2>&1 || return 0
  gh issue edit "$num" ${repo:+-R "$repo"} --remove-label ready-for-agent >/dev/null 2>&1 \
    || echo "worker-startup: could not remove ready-for-agent from $ref" >&2
}

# Owner rule 2026-11-20: every dotfiles issue starts before any other repo's. The hand dispatch path obeys it too.
# A builder brief that Refs another repo is refused while a ready dotfiles issue waits. Rework and verify briefs, a brief
# with no explicit repo, and a failed gh call go on. A start takes the free seat, so a ready issue plus a start request is the seat test.
refuse_before_dotfiles() { # <spec_file> <title> <skip_reason>
  local spec_file=$1 title=$2 skip=$3 role kind btype ref repo dot waiting
  role=$(role_from_title "$title")
  [ -n "$role" ] || return 0
  [ "$role" = qa-sdet ] && return 0 # a verifier start never edits the issue labels (#1271)
  kind=$(role_class "$role") || return 0
  [ "$kind" = builder ] || return 0
  btype=$(sed -n 's/^Type:[[:space:]]*//p' "$spec_file" | head -1)
  case "$btype" in rework|verify) return 0 ;; esac
  ref=$(grep -m1 -oE '^Refs [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+' "$spec_file" | sed 's/^Refs //' || true)
  [ -n "$ref" ] || return 0
  repo=${ref%%#*}
  dot=${DOTFILES_REPO:-}
  if [ -z "$dot" ]; then
    dot=$(git -C "$here/.." remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##' || true)
  fi
  [ -n "$dot" ] && [ "$dot" != off ] || return 0
  [ "$repo" != "$dot" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  waiting=$(gh issue list --repo "$dot" --label ready-for-agent --state open --limit 100 --json number,labels 2>/dev/null \
    | jq -r '[.[] | select((.labels | map(.name)) as $l | ($l | index("ready-for-agent") != null) and (["blocked","owner","deferred","tracking","needs-redesign","needs-elon","status:進行中"] | map(. as $h | $l | index($h) != null) | any | not)) | "#\(.number)"] | join(", ")' 2>/dev/null) || waiting=
  [ -n "$waiting" ] || return 0
  if [ -n "$skip" ]; then
    echo "worker-startup: --skip-dotfiles-first: $ref starts while dotfiles $waiting wait ($skip)" >&2
    return 0
  fi
  die "refused: dotfiles issue $waiting is ready and not started; start it first, or pass --skip-dotfiles-first REASON"
}

# The hand dispatch path knows an issue is in flight, so it sets the board label (docs/agents/labels.md, Status).
mark_issue_in_flight() { # <spec_file> <title>
  local spec_file=$1 title=$2 role btype ref repo num
  role=$(role_from_title "$title")
  [ -n "$role" ] || return 0
  [ "$role" = qa-sdet ] && return 0 # a verifier start never edits the issue labels (#1271)
  btype=$(sed -n 's/^Type:[[:space:]]*//p' "$spec_file" | head -1)
  case "$btype" in rework|verify) return 0 ;; esac
  ref=$(grep -m1 -oE '^Refs ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+' "$spec_file" | sed 's/^Refs //' || true)
  [ -n "$ref" ] || return 0
  num=${ref##*#}
  repo=${ref%%#*}
  command -v gh >/dev/null 2>&1 || return 0
  gh issue edit "$num" ${repo:+-R "$repo"} --add-label "status:進行中" --remove-label needs-triage >/dev/null 2>&1 \
    || echo "worker-startup: could not set status:進行中 on $ref" >&2
}

# Keep every open issue of the host repo carrying a state and a P label. Best effort.
run_label_gate() {
  [ -z "${WORKER_STARTUP_NO_LABEL_GATE:-}" ] && [ "${DOTFILES_REPO:-}" != off ] || return 0
  bash "$here/issue-label-gate.sh" --apply >/dev/null 2>&1 || true
}

# A qa-sdet start for a PR that already has a live verifier dispatch warns on stderr and goes on (#1222).
# Best effort: a failed orca call or a missing jq never blocks a start.
warn_live_verifier() { # <spec_file> <title> <name> <run>
  local spec_file=$1 title=$2 name=$3 run=$4 role btype prs pr workers tasks
  role=$(role_from_title "$title")
  btype=$(sed -n 's/^Type:[[:space:]]*//p' "$spec_file" | head -1)
  [ "$role" = qa-sdet ] || [ "$btype" = verify ] || return 0
  [ -n "$run" ] || return 0
  prs=$({
    printf '%s\n' "${title#*|qa-sdet}" | grep -oE '(^|[^0-9A-Za-z#/.-])#?[0-9]{1,6}($|[^0-9A-Za-z.-])' | grep -oE '[0-9]+'
    if [[ $title == *"|qa-sdet" ]]; then printf '%s\n' "${title%%|qa-sdet}" | grep -oE '[0-9]+'; fi
    printf '%s\n' "$name" | sed -nE 's/^(verify|vd|v)-?([0-9]+)(-[a-z0-9]+)?$/\2/p'
    grep -oE '(^Refs [A-Za-z0-9_./-]*#|pull/)[0-9]+' "$spec_file" | grep -oE '[0-9]+$'
  } | sort -un) || prs=
  [ -n "$prs" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  workers=$("$orca" orchestration worker-list --run "$run" --include-remote --json 2>/dev/null) || return 0
  tasks=$("$orca" orchestration task-list --run "$run" --json 2>/dev/null) || tasks='{}'
  for pr in $prs; do
    printf '%s\n%s\n' "$workers" "$tasks" | jq -rs --arg pr "$pr" '
      (.[0].result.workers // .[0].workers // []) as $w
      | ((.[1].result.tasks // .[1].tasks // []) | map({(.id): .title}) | add // {}) as $t
      | $w[]
      | select(((.dispatchStatus // .workerState // .state // "") | ascii_downcase | test("^(completed|succeeded|failed|stopped|cancelled|abandoned|released)$")) | not)
      | select(((.liveness // .projection.liveness.verdict // "live") | tostring) as $l | ($l | test("^(exited|sleep|settled)$")) | not)
      | select((.terminalState // "active") | test("^(released|release_unknown)$") | not)
      | {id: .dispatchId, title: ($t[.taskId] // .title // "")}
      | select(.title | test("^(#[0-9]+\\|)?qa-sdet"))
      | select((.title | sub("^#[0-9]+\\|qa-sdet"; "") | test("(^|[^0-9A-Za-z/.-])(#|PRs? #?)?" + $pr + "([^0-9A-Za-z.-]|$)")) or (.title | test("^#" + $pr + "\\|qa-sdet(\\|[^0-9]*)?$")) or (.title | test("verify-?" + $pr + "([^0-9]|$)")))
      | "worker-startup: warning: live verifier \(.id) (\(.title)) is already running for PR #" + $pr' >&2 2>/dev/null || true
  done
}

run_mode() {
  local run='' spec='' title='' agent='' model='' environment='' from=${ORCA_TERMINAL_HANDLE:-}
  local wt='' worktree_sel='' name='' repo='' base='' task='' retry_of='' route_override='' start_out=''
  local explicit_on=0 force_host='' on_raw='' allow_delivered='' skip_dotfiles=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --run|--spec|--title|--agent|--model|--from|--on|--worktree-path|--worktree|--name|--repo|--base-branch|--task|--retry-of|--route-override|--force-host|--allow-delivered|--skip-dotfiles-first)
        [ $# -ge 2 ] || usage_run
        case "$1" in
          --run) run=$2 ;;
          --spec) spec=$2 ;;
          --title) title=$2 ;;
          --agent) agent=$2 ;;
          --model) model=$2 ;;
          --from) from=$2 ;;
          --on) environment=$2; on_raw=$2; explicit_on=1 ;;
          --worktree-path) wt=$2 ;;
          --worktree) worktree_sel=$2 ;;
          --name) name=$2 ;;
          --repo) repo=$2 ;;
          --base-branch) base=$2 ;;
          --task) task=$2 ;;
          --retry-of) retry_of=$2 ;;
          --route-override) route_override=$2; [ -n "$route_override" ] || die "route override needs a reason" ;;
          --force-host) force_host=$2; [ -n "$force_host" ] || die "force-host needs a reason" ;;
          --allow-delivered) allow_delivered=$2; [ -n "$allow_delivered" ] || die "allow-delivered needs a reason" ;;
          --skip-dotfiles-first) skip_dotfiles=$2; [ -n "$skip_dotfiles" ] || die "skip-dotfiles-first needs a reason" ;;
        esac
        shift 2 ;;
      *) usage_run ;;
    esac
  done
  if [ -n "$environment" ]; then
    local me want
    me=$(this_host_name)
    want=$(printf '%s' "$environment" | tr '[:upper:]' '[:lower:]')
    if [ -n "$me" ] && [ "$want" = "$me" ]; then
      environment=
    fi
  fi
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
    local agy_ec=0
    surface_antigravity_screen "$agent" "$start_out" || agy_ec=$?
    [ "$agy_ec" -ne 0 ] || return 0
    [ "$agy_ec" -eq "$AGY_SIGNIN_EXIT" ] || exit "$agy_ec"
    echo "agy-signin: host=$(agy_host_label '') fell back to claude"
    agent=claude model=sonnet
    "$python3" "${USAGE_GATE_CLI:-$here/usage-gate.py}" check --provider "$agent" --model "$model" >&2 \
      || { echo "worker-startup: refused by the usage gate" >&2; exit 3; }
    run_captured pr_review_gates_orchestration_worker_start "$agent" "$model" "$wt_retry" -- \
      --run "$run" --task "$task" --retry-of "$retry_of" \
      --worktree "$worktree_sel" --agent "$agent" --from "$from" --model "$model" || exit $?
    return 0
  fi
  [ -n "$run" ] && [ -n "$spec" ] && [ -n "$title" ] && [ -n "$agent" ] && [ -n "$model" ] || usage_run
  require_title_form "$title" "$spec"
  [ -f "$spec" ] || die "spec file not found: $spec"
  [ -n "$(tr -d '[:space:]' <"$spec" || true)" ] || die "spec file is empty: $spec"
  local lint_out lint_dir dispatch_log orig_spec=$spec
  refuse_merged_backlog_line "$spec" "$title"
  refuse_delivered_issue "$spec" "$title" "$allow_delivered"
  run_label_gate
  refuse_before_dotfiles "$spec" "$title" "$skip_dotfiles"
  warn_live_verifier "$spec" "$title" "$name" "$run"
  spec=$(build_brief_spec "$orig_spec" "$run" "$title" "$agent" "$model")
  lint_dir=${wt:-}
  if [ -z "$lint_dir" ] && [ "$agent" != cursor ]; then
    case "$repo" in
      id:*) lint_dir=$("$orca" repo list --json 2>/dev/null | jq -r --arg id "${repo#id:}" '.result.repos[]? | select(.id == $id) | .path // empty' 2>/dev/null | head -1) || lint_dir= ;;
      path:*) lint_dir=${repo#path:} ;;
      /*|.*|~*) lint_dir=$repo ;;
    esac
  fi
  lint_out=$(bash "$here/brief-lint.sh" "$spec" "$lint_dir" 2>&1) || die "$lint_out"
  [ -z "$lint_out" ] || printf '%s\n' "$lint_out" >&2
  [ -n "$from" ] || die "need --from or ORCA_TERMINAL_HANDLE"
  enforce_builder_provider "$title" "$agent" "$route_override"

  # A merge worker reads the local Orca run list, so it runs on the coordinator host, never on an overflow host.
  local merge_worker=''
  case "$title" in
    "release-manager: merge"*)
      [ -z "$environment" ] || die "refused: a 'release-manager: merge' worker runs on the coordinator host only, not --on $environment"
      merge_worker=1 ;;
    "#"[0-9]*"|release-manager"|"#"[0-9]*"|release-manager|"*)
      # The new title form carries no job, so a merge brief is the one whose first heading names a merge.
      if grep -m1 '^# ' "$spec" | grep -qi 'merge'; then
        [ -z "$environment" ] || die "refused: a release-manager merge worker runs on the coordinator host only, not --on $environment"
        merge_worker=1
      fi ;;
  esac

  host_check
  print_worker_spread

  # --force-host REASON names its host in worker_placement.reasons (fleet config), so --on is not needed.
  if [ -z "$on_raw" ] && [ -n "$force_host" ] && [ -z "$merge_worker" ] && [ -z "$wt" ]; then
    local reason_cfg reason_target
    reason_cfg=$(resolve_placement_config)
    if [ -f "$reason_cfg" ] && reason_target=$("$python3" "$here/worker-placement.py" reason-host --reason "$force_host" --config "$reason_cfg"); then
      on_raw=$reason_target
      explicit_on=1
      echo "worker-placement: reason $force_host -> host=$reason_target" >&2
      if [ "$(printf '%s' "$reason_target" | tr '[:upper:]' '[:lower:]')" != "$(this_host_name)" ]; then
        environment=$reason_target
      fi
    fi
  fi

  if [ -n "$on_raw" ] && [ -z "$merge_worker" ]; then
    check_forced_host "$on_raw" "$spec" "$repo" "$force_host"
  fi

  # An explicit remote host (--on or a --force-host reason) maps a local repo id through
  # worker_placement.repos like auto placement does. An id with no mapping passes as given.
  if [ "$explicit_on" = 1 ] && [ -n "$environment" ] && [ -n "$repo" ] && [ -z "$merge_worker" ]; then
    local on_cfg mapped_repo
    on_cfg=$(resolve_placement_config)
    if [ -f "$on_cfg" ] && mapped_repo=$("$python3" "$here/worker-placement.py" translate-repo --environment "$environment" --repo "$repo" --config "$on_cfg" 2>/dev/null); then
      repo=$mapped_repo
    fi
  fi

  if [ "$explicit_on" != 1 ] && [ -z "$environment" ] && [ -z "$wt" ] && [ -z "$merge_worker" ]; then
    apply_worker_placement "$spec" "$repo" --record
    [ -n "${WORKER_STARTUP_PLACED_ENV:-}" ] && environment=$WORKER_STARTUP_PLACED_ENV
  fi

  # A host marked agy-unavailable (signed out) gets claude instead of antigravity (#1240).
  if [ "$agent" = antigravity ] && "$python3" "$here/agy-signin.py" unavailable "$(agy_host_label "$environment")"; then
    echo "agy-signin: host=$(agy_host_label "$environment") is agy-unavailable, using claude"
    agent=claude model=sonnet
    spec=$(build_brief_spec "$orig_spec" "$run" "$title" "$agent" "$model")
  fi

  if [ -n "$repo" ]; then
    case "$repo" in
      id:*) ;;
      path:*) export REMOTE_REPO="${repo#path:}" ;;
      *) export REMOTE_REPO="$repo" ;;
    esac
  fi

  [ "$agent" != grok ] || require_grok_host "$environment"

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
    run_captured bash "$here/start-cursor-worker.sh" --run "$run" --spec "$spec" --title "$title" --model "$model" \
      --from "$from" ${environment:+--on "$environment"} \
      ${wt:+--worktree-path "$wt"} ${name:+--name "$name"} ${cursor_repo:+--repo "$cursor_repo"} ${base:+--base-branch "$base"} || exit $?
    apply_terminal_title "$title" "$start_out" "$environment"
    release_ready_label "$spec" "$title"
    mark_issue_in_flight "$spec" "$title"
    return 0
  fi

  created_wt=0
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
    # `Setup: none` briefs never run bun/node: skip the install hook, keep the fresh-main fast-forward.
    # On a remote host the same git-only step runs there in a terminal, before the worker starts.
    setup_mode=run
    if grep -q '^Setup: none' "$spec"; then setup_mode=skip; fi
    create_args+=(--setup "$setup_mode" --json)
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
    [ -z "$wt" ] || created_wt=1
  fi
  remote_git_only() { # <remote worktree path>: fetch and fast-forward there, no install
    # The terminal is an interactive shell that never exits, and a remote `terminal wait --for exit` reports
    # exitCode 0 whatever the command did (host_status_unavailable). So the command prints its own result line
    # and this reads the terminal until that line shows up.
    local term_json term_handle read_json rc="" tries=0
    term_json=$("$orca" terminal create --environment "$environment" --worktree "path:$1" --json \
      --command "cd $(printf '%q' "$1") && bash \"\$HOME/dotfiles/script/worktree-setup.sh\" --git-only; echo GIT_ONLY_RC=\$?") || return 1
    term_handle=$(printf '%s' "$term_json" | jq -r '.result.terminal.handle // empty')
    [ -n "$term_handle" ] || return 1
    while [ "$tries" -lt "${WORKER_STARTUP_GIT_ONLY_TRIES:-60}" ]; do
      read_json=$("$orca" terminal read --environment "$environment" --terminal "$term_handle" --json 2>/dev/null) || read_json=""
      rc=$(printf '%s' "$read_json" | jq -r '[.result.terminal.tail[]? | capture("^GIT_ONLY_RC=(?<rc>[0-9]+)$").rc] | first // empty' 2>/dev/null)
      [ -z "$rc" ] || break
      tries=$((tries + 1))
      sleep 2
    done
    "$orca" terminal close --environment "$environment" --terminal "$term_handle" --json >/dev/null 2>&1 || true
    [ "$rc" = 0 ]
  }
  grok_trust_worktree() { # <worktree path>: Grok blocks on its folder-trust question in a new worktree (#1312)
    bash "$here/grok-trust.sh" "$1" >&2
  }
  # A failed start removes the worktree this run created, so a retry does not leave a -2, -3 copy behind.
  start_failed() { # <exit code>
    local ec=$1 rm_args
    if [ -n "${WORKER_STARTUP_PLACED_HOST:-}" ]; then
      "$python3" "$here/worker-placement.py" unrecord --host "$WORKER_STARTUP_PLACED_HOST" \
        ${WORKER_STARTUP_PLACED_CFG:+--config "$WORKER_STARTUP_PLACED_CFG"} >/dev/null 2>&1 || true
    fi
    if [ "$created_wt" = 1 ]; then
      rm_args=(worktree rm --worktree "path:$wt" --force)
      [ -z "$environment" ] || rm_args+=(--environment "$environment")
      "$orca" "${rm_args[@]}" >/dev/null 2>&1 || echo "worker-startup: could not remove the worktree $wt after a failed start" >&2
    fi
    exit "$ec"
  }
  case "$wt" in /*) ;; *) die "worktree path must be absolute" ;; esac
  if [ "${setup_mode:-}" = skip ]; then
    if [ -z "$environment" ]; then
      (cd "$wt" && bash "$here/worktree-setup.sh" --git-only) || { echo "worker-startup: git-only setup failed in $wt" >&2; start_failed 1; }
    else
      remote_git_only "$wt" || { echo "worker-startup: git-only setup failed in $wt on $environment" >&2; start_failed 1; }
    fi
  fi

  local brief
  brief=$(cat "$spec")
  pr_review_gates_launch_record_worktree "$wt" "$agent" "$model"
  board_status_set "path:$wt" in-progress "$environment"
  board_display_name_set "path:$wt" "$title" "$environment"
  start_agent_worker() { # starts the worker for the current agent, model and brief
    if [ "$agent" = grok ] && [ -z "$environment" ]; then
      grok_trust_worktree "$wt" || { echo "worker-startup: could not pre-trust $wt for grok (#1312)" >&2; start_failed 1; }
    fi
    if [ -n "$environment" ]; then
      start_with_startup_retry bash "$here/start-remote-worker.sh" --run "$run" --spec "$brief" --agent "$agent" --model "$model" \
        --on "$environment" --worktree "path:$wt" --task-title "$title" --from "$from" --json || start_failed $?
    else
      start_with_startup_retry pr_review_gates_orchestration_worker_start "$agent" "$model" "$wt" -- \
        --run "$run" --spec "$brief" --agent "$agent" --model "$model" \
        --worktree "path:$wt" --task-title "$title" --from "$from" || start_failed $?
    fi
  }
  start_agent_worker
  local agy_ec=0
  surface_antigravity_screen "$agent" "$start_out" "$environment" || agy_ec=$?
  if [ "$agy_ec" -eq "$AGY_SIGNIN_EXIT" ]; then
    echo "agy-signin: host=$(agy_host_label "$environment") fell back to claude"
    agent=claude model=sonnet
    "$python3" "${USAGE_GATE_CLI:-$here/usage-gate.py}" check --provider "$agent" --model "$model" >&2 \
      || { echo "worker-startup: refused by the usage gate" >&2; start_failed 3; }
    brief=$(cat "$(build_brief_spec "$orig_spec" "$run" "$title" "$agent" "$model")")
    pr_review_gates_launch_record_worktree "$wt" "$agent" "$model"
    start_agent_worker
  elif [ "$agy_ec" -ne 0 ]; then
    exit "$agy_ec"
  fi
  apply_terminal_title "$title" "$start_out" "$environment"
  release_ready_label "$spec" "$title"
  mark_issue_in_flight "$spec" "$title"
  return 0
}

# One line per successful start: duration_s feeds team-audit.sh --report (#1330).
log_startup_duration() { # <run id> <seconds>
  local line
  line="worker-startup run=$1 duration_s=$2"
  echo "$line" >&2
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >>"$state_dir/durations.log" 2>/dev/null || true
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
    startup_began=$SECONDS
    startup_rc=0
    run_mode "$@" || startup_rc=$?
    [ "$startup_rc" -ne 0 ] || log_startup_duration "${2:-}" "$((SECONDS - startup_began))"
    exit "$startup_rc"
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
