#!/usr/bin/env bash
# weekly-update.sh: Matt Pocock and pstack upstream, bun and Node LTS, on three tested PRs and one summary.
# Preflight on configured projects: check-skill-collisions.sh, sync-team-skills.sh --check, adopt-agent-team.sh
# --check-paths. Optional sync-team-skills.sh apply only when WEEKLY_UPDATE_SYNC_PROJECTS=1.
# Never merges, deploys, runs secrets-*, fleet-pull, or production hooks unattended.
# Never edits role or team agent files; skill-impact output is report-only under docs/agents/drafts/.
# Brew and agent CLIs are report-only in the stdout summary (no brew upgrade here).
#
# Usage: ~/dotfiles/script/weekly-update.sh [--dry-run]
#
# Env: DOTFILES, WEEKLY_UPDATE_DOTFILES (override repo root), WEEKLY_UPDATE_PROJECTS (colon-separated roots),
#      WEEKLY_UPDATE_PROJECTS_CONF (default $DOTFILES/script/weekly-update.projects.conf, untracked),
#      WEEKLY_UPDATE_TESTS_<id> (override per-PR test command), WEEKLY_UPDATE_SKIP_APPLY=1,
#      WEEKLY_UPDATE_NO_PUSH=1, PLUGINS_REPO, MP_REPO, WEEKLY_UPDATE_NODE_LTS (test override),
#      WEEKLY_UPDATE_NODE_INDEX (index.json URL or absolute fixture path; default nodejs.org dist index),
#      WEEKLY_UPDATE_BUN_UPGRADE, WEEKLY_UPDATE_BUN_UPDATE (shell commands; default bun upgrade / bun update),
#      WEEKLY_UPDATE_SYNC_PROJECTS=1 (apply sync-team-skills.sh after gates; default check-only).
set -euo pipefail

declare -a TOOLCHAIN_SUMMARY_LINES=()

DOTFILES="${WEEKLY_UPDATE_DOTFILES:-${DOTFILES:-$HOME/dotfiles}}"
DOTFILES=$(cd "$DOTFILES" && pwd -P)
DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
  "") ;;
  *) echo "weekly-update: unknown flag $1" >&2; exit 2 ;;
esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MP_REPO="${MP_REPO:-https://github.com/mattpocock/skills}"
PLUGINS_REPO="${PLUGINS_REPO:-https://github.com/cursor/plugins}"
PSTACK_STATE="$DOTFILES/script/.pstack-template-upstream"
TEMPLATE_SKILLS="$DOTFILES/templates/agent-team/.agents/skills"
BASE_BRANCH="${WEEKLY_UPDATE_BASE:-main}"
DATE_TAG="$(date '+%Y%m%d')"
PROJECTS_CONF="$DOTFILES/script/weekly-update.projects.conf"

die() { echo "weekly-update: $*" >&2; exit 1; }

apply_fail() { echo "weekly-update: $*" >&2; return 1; }

node_lts_from_index() {
  local pin="$1" idx="${WEEKLY_UPDATE_NODE_INDEX:-https://nodejs.org/dist/index.json}"
  local tmp json err rc lts
  tmp=$(mktemp)
  json=$(mktemp)
  err=$(mktemp)
  if [[ "$idx" == /* ]]; then
    cp "$idx" "$json" || { rm -f "$tmp" "$json" "$err"; return 1; }
  elif [[ "$idx" == file://* ]]; then
    cp "${idx#file://}" "$json" || { rm -f "$tmp" "$json" "$err"; return 1; }
  else
    if ! curl -fsSL --connect-timeout 10 "$idx" -o "$json" 2>"$tmp"; then
      rm -f "$tmp" "$json" "$err"
      cat "$tmp" >&2 2>/dev/null || true
      return 1
    fi
  fi
  python3 - "$pin" "$json" >"$tmp" 2>"$err" <<'PY' || {
import json
import sys


def ver_tuple(s):
    s = s.lstrip("v")
    parts = s.split(".")
    while len(parts) < 3:
        parts.append("0")
    return tuple(int(x) for x in parts[:3])


pin = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as f:
    data = json.load(f)

pin_t = ver_tuple(pin)
pin_major = pin_t[0]
lts_on_major = []
newer_majors = set()

for entry in data:
    lts = entry.get("lts")
    if not lts:
        continue
    vt = ver_tuple(entry["version"])
    if vt[0] == pin_major:
        lts_on_major.append(vt)
    elif vt[0] > pin_major:
        newer_majors.add(vt[0])

if not lts_on_major:
    sys.exit(3)

newest = max(lts_on_major)
chosen = max(newest, pin_t)
print(".".join(str(x) for x in chosen))
if newer_majors:
    joined = ", ".join(str(m) for m in sorted(newer_majors))
    print(f"Node LTS major {joined} available (pin stays on {pin_major})", file=sys.stderr)
PY
    rc=$?
    rm -f "$tmp" "$json" "$err"
    return "$rc"
  }
  lts=$(cat "$tmp")
  if [ -z "$lts" ]; then
    rm -f "$tmp" "$json" "$err"
    return 1
  fi
  rm -f "$tmp" "$json"
  if [ -s "$err" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] && TOOLCHAIN_SUMMARY_LINES+=("$line")
    done <"$err"
  fi
  rm -f "$err"
  printf '%s' "$lts"
}

read_projects() {
  PROJECTS=()
  if [ -n "${WEEKLY_UPDATE_PROJECTS:-}" ]; then
    local _p _rest="$WEEKLY_UPDATE_PROJECTS"
    while [ -n "$_rest" ]; do
      _p="${_rest%%:*}"
      _rest="${_rest#*:}"
      [ "$_p" = "$_rest" ] && _rest=""
      PROJECTS+=("${_p/#\~/$HOME}")
    done
    return 0
  fi
  local conf="${WEEKLY_UPDATE_PROJECTS_CONF:-$PROJECTS_CONF}"
  [ -f "$conf" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    PROJECTS+=("${line/#\~/$HOME}")
  done <"$conf"
}

project_gates() {
  [ "$DRY" -eq 1 ] && return 0
  [ ${#PROJECTS[@]} -eq 0 ] && return 0
  "$DOTFILES/script/check-skill-collisions.sh" "${PROJECTS[@]}"
  "$DOTFILES/script/sync-team-skills.sh" --check "${PROJECTS[@]}"
  local p
  for p in "${PROJECTS[@]}"; do
    "$DOTFILES/script/adopt-agent-team.sh" --check-paths "$p"
  done
  if [ "${WEEKLY_UPDATE_SYNC_PROJECTS:-0}" = 1 ]; then
    "$DOTFILES/script/sync-team-skills.sh" "${PROJECTS[@]}"
  fi
}

default_tests() {
  case "$1" in
    mattpocock) printf '%s\n' 'bash script/tests/sync-mattpocock-skills.test.sh' ;;
    pstack) printf '%s\n' 'bash script/tests/sync-pstack-template-skills.test.sh' ;;
    toolchain) printf '%s\n' 'bash script/tests/install_node.test.sh && bash -n script/install_node.sh' ;;
    *) die "unknown PR id $1" ;;
  esac
}

pr_tests() {
  local id="$1" var cmd
  var="WEEKLY_UPDATE_TESTS_${id}"
  cmd=$(default_tests "$id")
  if [ -n "${!var:-}" ]; then
    cmd=${!var}
  fi
  printf '%s' "$cmd"
}

run_tests() {
  local id="$1" cmd
  cmd=$(pr_tests "$id")
  if [ "$DRY" -eq 1 ]; then
    return 0
  fi
  (cd "$DOTFILES" && bash -c "$cmd")
}

apply_mattpocock() {
  [ "${WEEKLY_UPDATE_SKIP_APPLY:-0}" = 1 ] && return 0
  if [ "$DRY" -eq 1 ]; then
    return 0
  fi
  local log
  log=$(MP_REPO="$MP_REPO" DOTFILES="$DOTFILES" "$DOTFILES/script/sync-mattpocock-skills.sh") || return 1
  printf '%s\n' "$log"
}

apply_pstack() {
  [ "${WEEKLY_UPDATE_SKIP_APPLY:-0}" = 1 ] && return 0
  [ "$DRY" -eq 1 ] && return 0
  local log
  log=$(DOTFILES="$DOTFILES" PLUGINS_REPO="$PLUGINS_REPO" \
    "$DOTFILES/script/sync-pstack-template-skills.sh") || return 1
  printf '%s\n' "$log"
  echo "weekly-update: pstack upstream $(sed -n 's/^sha=//p' "$PSTACK_STATE")"
}

write_skill_impact() {
  local id="$1"
  case "$id" in
    mattpocock|pstack) ;;
    *) return 0 ;;
  esac
  [ "$DRY" -eq 1 ] && return 0
  [ "${WEEKLY_UPDATE_SKIP_APPLY:-0}" = 1 ] && return 0
  DATE_TAG="$DATE_TAG" DOTFILES="$DOTFILES" WEEKLY_SKILL_IMPACT_SLICE="$id" \
    bash "$DOTFILES/script/weekly-skill-impact.sh"
}

append_toolchain_report_lines() {
  [ "$DRY" -eq 1 ] && return 0
  if command -v bun >/dev/null 2>&1; then
    TOOLCHAIN_SUMMARY_LINES+=("toolchain report: bun $(bun --version 2>/dev/null || echo unknown)")
  fi
  if command -v brew >/dev/null 2>&1; then
    local brew_sample
    brew_sample=$(brew outdated --greedy 2>/dev/null | head -5 | paste -sd '; ' - || true)
    if [ -n "$brew_sample" ]; then
      TOOLCHAIN_SUMMARY_LINES+=("toolchain report: brew outdated sample: $brew_sample")
    fi
  fi
  local cli
  for cli in gh claude orca cursor-agent; do
    if command -v "$cli" >/dev/null 2>&1; then
      TOOLCHAIN_SUMMARY_LINES+=("toolchain report: $cli $( ($cli --version 2>/dev/null || true) | head -1)")
    fi
  done
}

apply_toolchain() {
  [ "${WEEKLY_UPDATE_SKIP_APPLY:-0}" = 1 ] && return 0
  [ "$DRY" -eq 1 ] && return 0
  local lts tv pin_file="$DOTFILES/.tool-versions"
  if [ -n "${WEEKLY_UPDATE_NODE_LTS:-}" ]; then
    lts=$WEEKLY_UPDATE_NODE_LTS
  else
    tv=$(awk '$1=="nodejs" { print $2; exit }' "$pin_file" 2>/dev/null || true)
    [ -n "${tv:-}" ] || { apply_fail "missing nodejs pin in .tool-versions"; return 1; }
    local lts_file
    lts_file=$(mktemp)
    if ! node_lts_from_index "$tv" >"$lts_file"; then
      rm -f "$lts_file"
      apply_fail "could not resolve Node LTS from index"
      return 1
    fi
    lts=$(cat "$lts_file")
    rm -f "$lts_file"
    [ -n "$lts" ] || { apply_fail "empty Node LTS from index"; return 1; }
  fi
  if [ -f "$pin_file" ]; then
    if grep -q '^nodejs ' "$pin_file"; then
      sed -i.bak "s/^nodejs .*/nodejs $lts/" "$pin_file"
      rm -f "$pin_file.bak"
    else
      printf 'nodejs %s\n' "$lts" >>"$pin_file"
    fi
  fi
  local bun_up="${WEEKLY_UPDATE_BUN_UPGRADE:-bun upgrade}"
  local bun_upd="${WEEKLY_UPDATE_BUN_UPDATE:-bun update}"
  (cd "$DOTFILES" && bash -c "$bun_up") 2>/dev/null || true
  local root
  for root in ${WEEKLY_UPDATE_BUN_ROOTS:-}; do
    [ -f "$root/package.json" ] || continue
    (cd "$root" && bash -c "$bun_upd") || return 1
  done
  echo "weekly-update: toolchain nodejs $lts"
}

declare -a PR_ID=(mattpocock pstack toolchain)
declare -a PR_TITLE=(
  'Weekly: sync Matt Pocock skills'
  'Weekly: sync pstack template skills'
  'Weekly: refresh bun and Node LTS pins'
)

branch_for() {
  printf 'mingster/weekly-%s-%s' "$1" "$DATE_TAG"
}

apply_for() {
  case "$1" in
    mattpocock) apply_mattpocock ;;
    pstack) apply_pstack ;;
    toolchain) apply_toolchain ;;
  esac
}

open_pr() {
  local branch="$1" title="$2" body_file="$3"
  gh pr create --base "$BASE_BRANCH" --head "$branch" --title "$title" --body-file "$body_file"
}

print_planned() {
  local id="$1" title="$2" branch tests
  branch=$(branch_for "$id")
  tests=$(pr_tests "$id")
  echo "PLANNED PR $id: $title (branch $branch, tests: $tests)"
}

ensure_origin_main() {
  [ "$DRY" -eq 1 ] && return 0
  git -C "$DOTFILES" fetch -q origin "$BASE_BRANCH" 2>/dev/null || true
  git -C "$DOTFILES" show-ref -q "refs/remotes/origin/$BASE_BRANCH" \
    || git -C "$DOTFILES" show-ref -q "refs/heads/$BASE_BRANCH" \
    || die "missing $BASE_BRANCH"
}

require_clean_start() {
  [ "$DRY" -eq 1 ] && return 0
  if ! git -C "$DOTFILES" diff --quiet || ! git -C "$DOTFILES" diff --cached --quiet; then
    die "refusing to start on a dirty tree"
  fi
  local untracked
  untracked=$(git -C "$DOTFILES" ls-files --others --exclude-standard | head -1)
  if [ -n "$untracked" ]; then
    die "refusing to start: untracked file $untracked"
  fi
}

checkout_main() {
  git -C "$DOTFILES" checkout -q "$BASE_BRANCH" 2>/dev/null || git -C "$DOTFILES" checkout -q main
}

slice_reset_worktree() {
  checkout_main
  git -C "$DOTFILES" reset --hard HEAD
  git -C "$DOTFILES" clean -fd \
    -e 'script/weekly-update.projects.conf' \
    -e 'weekly-update.projects.conf' 2>/dev/null \
    || git -C "$DOTFILES" clean -fd
}

slice_abort_branch() {
  local branch="$1"
  slice_reset_worktree
  git -C "$DOTFILES" branch -D "$branch" >/dev/null 2>&1 || true
}

impact_draft_glob() {
  printf 'docs/agents/drafts/weekly-skill-impact-%s.md' "$DATE_TAG"
}

stage_slice_changes() {
  local id="$1" draft
  draft=$(impact_draft_glob)
  case "$id" in
    mattpocock)
      git -C "$DOTFILES" add -- .agents/skills
      [ -f "$DOTFILES/$draft" ] && git -C "$DOTFILES" add -- "$draft"
      ;;
    pstack)
      git -C "$DOTFILES" add -- templates/agent-team/.agents/skills script/.pstack-template-upstream
      [ -f "$DOTFILES/$draft" ] && git -C "$DOTFILES" add -- "$draft"
      ;;
    toolchain)
      git -C "$DOTFILES" add -- .tool-versions script/install_node.sh 2>/dev/null || true
      local root
      for root in ${WEEKLY_UPDATE_BUN_ROOTS:-}; do
        [ -f "$root/package.json" ] || continue
        git -C "$root" add -- package.json bun.lockb bun.lock 2>/dev/null || true
      done
      ;;
    *) die "unknown PR id $id" ;;
  esac
}

run_slice() {
  local id="$1" title="$2" branch status url= body slice_ok=0
  branch=$(branch_for "$id")
  body=$(mktemp)
  if [ "$DRY" -eq 1 ]; then
    print_planned "$id" "$title"
    rm -f "$body"
    return 0
  fi

  _slice_unwind() {
    [ "$slice_ok" = 1 ] && return 0
    slice_abort_branch "$branch"
    return 0
  }
  trap _slice_unwind RETURN

  git -C "$DOTFILES" checkout -q -B "$branch" "origin/$BASE_BRANCH" 2>/dev/null \
    || git -C "$DOTFILES" checkout -q -B "$branch" "$BASE_BRANCH"
  if ! apply_for "$id"; then
    SUMMARY+=("PR $id: failed (apply)")
    rm -f "$body"
    return 0
  fi
  if ! run_tests "$id"; then
    SUMMARY+=("PR $id: failed (tests)")
    rm -f "$body"
    return 0
  fi
  write_skill_impact "$id" || true
  local draft_rel
  draft_rel=$(impact_draft_glob)
  if [ -f "$DOTFILES/$draft_rel" ]; then
    git -C "$DOTFILES" add -- "$draft_rel"
  fi
  local has_tree=0
  if ! git -C "$DOTFILES" diff --quiet || ! git -C "$DOTFILES" diff --cached --quiet; then
    has_tree=1
  fi
  if [ "$has_tree" = 0 ]; then
    if ! git -C "$DOTFILES" commit --allow-empty -qm "weekly-update: $title"; then
      SUMMARY+=("PR $id: failed (commit)")
      rm -f "$body"
      return 0
    fi
  else
    stage_slice_changes "$id"
    if ! git -C "$DOTFILES" commit -qm "weekly-update: $title"; then
      SUMMARY+=("PR $id: failed (commit)")
      rm -f "$body"
      return 0
    fi
  fi
  if [ "${WEEKLY_UPDATE_NO_PUSH:-0}" != 1 ]; then
    if ! git -C "$DOTFILES" push -q -u origin "$branch" 2>&1; then
      SUMMARY+=("PR $id: failed (push)")
      rm -f "$body"
      return 0
    fi
  fi
  {
    printf 'Weekly update slice `%s`.\n\nTests: `%s`\n\nMerged only on the owner'"'"'s yes.\n' "$id" "$(pr_tests "$id")"
  } >"$body"
  if url=$(open_pr "$branch" "$title" "$body" 2>&1); then
    SUMMARY+=("PR $id: opened ${url##*$'\n'}")
  else
    SUMMARY+=("PR $id: failed (publish)")
  fi
  rm -f "$body"
  slice_ok=1
  trap - RETURN
  checkout_main
}

SUMMARY=()
read_projects

if [ "$DRY" -eq 1 ]; then
  echo "weekly-update: dry run"
  local_i=0
  while [ "$local_i" -lt ${#PR_ID[@]} ]; do
    print_planned "${PR_ID[$local_i]}" "${PR_TITLE[$local_i]}"
    local_i=$((local_i + 1))
  done
  exit 0
fi

project_gates
ensure_origin_main
require_clean_start

idx=0
while [ "$idx" -lt ${#PR_ID[@]} ]; do
  run_slice "${PR_ID[$idx]}" "${PR_TITLE[$idx]}"
  idx=$((idx + 1))
done

append_toolchain_report_lines
if [ ${#TOOLCHAIN_SUMMARY_LINES[@]} -gt 0 ]; then
  for line in "${TOOLCHAIN_SUMMARY_LINES[@]}"; do
    SUMMARY+=("$line")
  done
fi

echo "weekly-update: summary"
for line in "${SUMMARY[@]}"; do
  echo "$line"
done
