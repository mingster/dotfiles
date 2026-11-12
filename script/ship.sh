#!/usr/bin/env bash
# Ship one verified PR with squash merge and read-back confirmation (pstack Shipping run).
# Usage: ship.sh --repo <owner/name> --pr <n> [--dry-run] [--mechanical | --verdict-from <owner/dotfiles#N>]
# Lanes: code and script PRs need a verifier Verdict: PASS whose agent and model differ from the builder's
# (PR body line "Builder: agent=<a> model=<m>"); a docs only PR needs a cold "Review: PASS head=<head>"
# or a Verdict PASS or PASS+NOTES at that exact head (same author and builder checks as the verdict lane);
# --mechanical lands a pure substitution or deletion diff with no Verdict; --verdict-from lands generated team
# copies on the Verdict of the matching MERGED dotfiles PR. That lane also accepts a pure deletion of a path
# agent-team.sh check flags as a canonical role file or an unkept shared hook copy. The verdict lane accepts
# a generated copy whose blob at the PR head equals the template render at dotfiles origin/main (the same
# {{PROJECT_NAME}} substitution agent-team.sh uses), and a deletion of a generated copy that check demands.
# Any other generated copy still needs --verdict-from.
set -euo pipefail

ship_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
refuse() { echo "ship: refused: $*" >&2; exit 1; }
die() { refuse "$*"; }

# shellcheck disable=SC1091
. "$ship_dir/lib/protected-paths.sh"
# shellcheck disable=SC1091
. "$ship_dir/lib/board-status.sh"

repo="" pr="" dry_run=false mechanical=false verdict_from=""
sync_dir=""
trap '[ -z "$sync_dir" ] || rm -rf "$sync_dir"' EXIT
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || refuse "--repo needs a value"; repo=$2; shift 2 ;;
    --pr) [ $# -ge 2 ] || refuse "--pr needs a value"; pr=$2; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --mechanical) mechanical=true; shift ;;
    --verdict-from) [ $# -ge 2 ] || refuse "--verdict-from needs owner/dotfiles#N"; verdict_from=$2; shift 2 ;;
    *) refuse "unknown argument: $1" ;;
  esac
done
[ -n "$repo" ] && [[ "$pr" =~ ^[0-9]+$ ]] || refuse "usage: ship.sh --repo <owner/name> --pr <n> [--dry-run] [--mechanical | --verdict-from <owner/dotfiles#N>]"
[ "$mechanical" = false ] || [ -z "$verdict_from" ] || refuse "--verdict-from and --mechanical are exclusive"

info=$(gh pr view "$pr" --repo "$repo" --json state,isDraft,mergeable,headRefName,headRefOid,baseRefOid,body,comments,statusCheckRollup) \
  || refuse "cannot read PR $pr"
field() { jq -r "$1" <<<"$info"; }

# 1. PR is open, not draft, mergeable (not CONFLICTING).
[ "$(field .state)" = OPEN ] || refuse "PR $pr is not open (state=$(field .state))"
[ "$(field '.isDraft // false')" = false ] || refuse "PR $pr is a draft"
[ "$(field .mergeable)" = MERGEABLE ] || refuse "PR $pr is not mergeable (mergeable=$(field .mergeable))"
head=$(field .headRefOid)
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || refuse "PR $pr has invalid headRefOid"

# 2. Every required check at the current head is SUCCESS (statusCheckRollup; pending counts as not yet).
jq -e '((.statusCheckRollup // []) | length) > 0' <<<"$info" >/dev/null \
  || refuse "no checks reported at head $head"
jq -e 'all((.statusCheckRollup // [])[] | select((.isRequired // true) != false);
  ((.status // "COMPLETED") == "COMPLETED") and ((.conclusion // .state // "") == "SUCCESS"))' <<<"$info" >/dev/null \
  || refuse "required checks are not all SUCCESS at head ${head:0:12}"

# 2b. The latest finished push Checks run on main is SUCCESS, unless this PR names that run as the one it fixes
# and touches what that run tested (a push to main only runs the tests for the files it changed).
main_run=$(gh run list --repo "$repo" --workflow Checks --branch main --event push --status completed --limit 1 \
  --json databaseId,conclusion,url,headSha) || refuse "cannot read the latest Checks run on main"
main_run=$(jq -c '.[0] // empty' <<<"$main_run")
if [ -n "$main_run" ] && [ "$(jq -r .conclusion <<<"$main_run")" != success ]; then
  main_conclusion=$(jq -r .conclusion <<<"$main_run")
  main_run_id=$(jq -r .databaseId <<<"$main_run")
  main_run_url=$(jq -r .url <<<"$main_run")
  if [ "$main_conclusion" = cancelled ]; then
    fix_hint="rerun or fix main first"
  else
    fix_hint="fix main first"
  fi
  grep -Eq "^Fixes main: $main_run_id\$" <<<"$(field .body)" \
    || refuse "latest Checks run on main is $main_conclusion: $main_run_url; $fix_hint, or put 'Fixes main: $main_run_id' on its own line in the PR body"
  main_sha=$(jq -r '.headSha // empty' <<<"$main_run")
  [[ "$main_sha" =~ ^[0-9a-f]{40}$ ]] || refuse "Checks run $main_run_id on main has no valid head sha"
  main_files=$(gh api "repos/$repo/commits/$main_sha" --jq '.files[].filename') \
    || refuse "cannot read the files of main commit ${main_sha:0:12}"
  fix_files=$(gh api --paginate "repos/$repo/pulls/$pr/files" --jq '.[] | (.filename // .path)') \
    || refuse "cannot read PR $pr files"
  # Tests a file list selects, minus the always-run guard that every PR selects.
  selected_tests() {
    local -a paths=()
    local line
    while IFS= read -r line; do [ -n "$line" ] && paths+=("$line"); done
    bash "$ship_dir/select-changed-script-tests.sh" --list-only "${paths[@]+"${paths[@]}"}" \
      | sed -n 's/^Selected: //p' | grep -v '^script/tests/no-project-names\.test\.sh$' | LC_ALL=C sort -u
  }
  main_tests=$(selected_tests <<<"$main_files") || true
  fix_tests=$(selected_tests <<<"$fix_files") || true
  overlap=$(comm -12 <(printf '%s\n' "$main_tests" | grep . || true) <(printf '%s\n' "$fix_tests" | grep . || true))
  [ -n "$overlap" ] || overlap=$(comm -12 <(printf '%s\n' "$main_files" | LC_ALL=C sort -u) <(printf '%s\n' "$fix_files" | LC_ALL=C sort -u))
  [ -n "$overlap" ] \
    || refuse "PR $pr says 'Fixes main: $main_run_id' but touches neither the files nor the tests of failed main commit ${main_sha:0:12}: $main_run_url"
fi

main_fetched=false
patch_id() { # <sha>
  local sha=$1 base
  [ "$main_fetched" = true ] || { git fetch origin main >&2 2>/dev/null || true; main_fetched=true; }
  git cat-file -e "$sha^{commit}" 2>/dev/null || git fetch origin "$sha" >&2 || return 1
  base=$(git merge-base origin/main "$sha" 2>/dev/null) || return 1
  git diff "$base..$sha" | git patch-id --stable | awk '{print $1}'
}
# Commits the carry would pass unseen: after the verdict head, or the whole branch after a rebase.
# An empty or whitespace-only one leaves the patch-id unchanged, so it needs a new Verdict.
blank_commit() { # <verdict_head> <current_head>; prints the first empty or whitespace-only commit
  local from c
  if git merge-base --is-ancestor "$1" "$2" 2>/dev/null; then
    from=$1
  else
    from=$(git merge-base origin/main "$2" 2>/dev/null) || return 1
  fi
  for c in $(git rev-list --no-merges "$from..$2"); do
    if git diff --quiet --ignore-all-space --ignore-blank-lines "$c^" "$c" 2>/dev/null; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}
verdict_carry() { # <verdict_head> <current_head>
  local pid_v pid_h
  pid_v=$(patch_id "$1") || return 1
  pid_h=$(patch_id "$2") || return 1
  [ -n "$pid_v" ] && [ "$pid_v" = "$pid_h" ] || return 1
  ! blank_commit "$1" "$2" >/dev/null
}

# Files and diff of the PR, read once: the lane choice and the protected path check both use them.
file_pages=$(gh api --paginate "repos/$repo/pulls/$pr/files") || refuse "cannot read PR $pr files"
# shellcheck disable=SC2034
files=$(jq -s '[.[][] | (.filename // .path)]' <<<"$file_pages") || refuse "invalid PR $pr file list"
# shellcheck disable=SC2034
diff=$(gh pr diff "$pr" --repo "$repo") || refuse "cannot read diff of PR $pr"

pr_body=$(field .body)
# Builder record: one line in the PR body, written by the builder. No Orca lookup.
builder_agent="" builder_model=""
builder_record() { # <body>; sets builder_agent and builder_model, or leaves them empty
  builder_agent="" builder_model=""
  local l
  l=$(grep -E '^Builder: agent=[A-Za-z0-9._-]+ model=[A-Za-z0-9._:-]+[[:space:]]*$' <<<"$1" | tail -n 1) || true
  [[ "$l" =~ ^Builder:\ agent=([A-Za-z0-9._-]+)\ model=([A-Za-z0-9._:-]+) ]] || return 0
  builder_agent=${BASH_REMATCH[1]} builder_model=${BASH_REMATCH[2]}
}
same_pair_gate() { # <body> <verifier agent> <verifier model> <where>
  builder_record "$1"
  [ -n "$builder_agent" ] || refuse "$4 has no 'Builder: agent=<agent> model=<model>' line, so the verifier cannot be compared with the builder"
  [ "$(tr '[:upper:]' '[:lower:]' <<<"$2/$3")" != "$(tr '[:upper:]' '[:lower:]' <<<"$builder_agent/$builder_model")" ] \
    || refuse "verifier $2/$3 is the same agent and model as the builder; verify with a different agent or model"
}
verdict_re='^Verdict: (PASS\+NOTES|PASS|FAIL) head=([0-9a-f]{40}) verifier=([a-zA-Z0-9_-]+) author=([a-zA-Z0-9_-]+)( agent=([A-Za-z0-9._-]+) model=([A-Za-z0-9._:-]+))?$'

# Newest Verdict comment (exact post-verdict.sh first-line shape) into verdict_status, verdict_head, v_agent, v_model.
# A flagged (edited or minimized) comment counts only when it is a FAIL. Empty verdict_status means none.
load_newest_verdict() {
  verdict_status="" verdict_head="" v_agent="" v_model=""
  while IFS= read -r flagged && IFS= read -r line; do
    if [[ "$line" =~ $verdict_re ]]; then
      if [ "$flagged" = true ] && [ "${BASH_REMATCH[1]}" != FAIL ]; then continue; fi
      [ "${BASH_REMATCH[3]}" != "${BASH_REMATCH[4]}" ] || refuse "author cannot supply verifier verdict"
      verdict_status="${BASH_REMATCH[1]}"
      verdict_head="${BASH_REMATCH[2]}"
      v_agent="${BASH_REMATCH[6]}" v_model="${BASH_REMATCH[7]}"
      break
    fi
  done < <(jq -r '[.comments[]? | {f: ((.includesCreatedEdit // false) or (.isMinimized // false)), l: (.body // "" | split("\n")[0])}] | reverse[] | .f, .l' <<<"$info")
}

# Generated team copies change only through the dotfiles template. A copy that is not the origin/main
# render, and not a deletion check demands, lands with --verdict-from.
is_generated_copy() { # <path>
  local skill_names=$2
  case "$1" in
    .claude/model-routing.md|docs/agents/team.md|docs/agents/elon-dispatch.md|docs/agents/release-manager-work.md|bin/changelog-compile.sh|bin/changelog-compile.test.sh|changelog.d/README.md)
      return 0 ;;
  esac
  [[ "$1" =~ ^\.(agents|claude|cursor)/skills/([^/]+)(/|$) ]] && grep -Fxq -- "${BASH_REMATCH[2]}" <<<"$skill_names"
}
# Template path relative to templates/agent-team for a generated copy. Same files agent-team.sh syncs.
template_rel_for() { # <path>
  case "$1" in
    .claude/model-routing.md|docs/agents/team.md|docs/agents/elon-dispatch.md|docs/agents/release-manager-work.md|bin/changelog-compile.sh|bin/changelog-compile.test.sh|changelog.d/README.md)
      printf '%s\n' "$1" ;;
    .agents/skills/*)
      printf '%s\n' "$1" ;;
    .claude/skills/*)
      printf '.agents/skills/%s\n' "${1#.claude/skills/}" ;;
    .cursor/skills/*)
      printf '.agents/skills/%s\n' "${1#.cursor/skills/}" ;;
    *) return 1 ;;
  esac
}
# Same order as agent-team.sh detect_project_name, read from the PR head tree.
detect_copy_project_name() { # <sha>
  local sha=$1 name
  if git cat-file -e "$sha:docs/agents/team-facts.md" 2>/dev/null; then
    # shellcheck disable=SC2016 # backticks are the team-facts markup, not command substitution
    name=$(git cat-file blob "$sha:docs/agents/team-facts.md" | sed -n 's/^\* `team \([^`]*\)`\..*/\1/p' || true)
    name=${name%%$'\n'*}
    name=${name%$'\r'}
    if [ -n "$name" ] && [ "$name" != "{{PROJECT_NAME}}" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  fi
  if git cat-file -e "$sha:.claude/agent-team-project-name" 2>/dev/null; then
    name=$(git cat-file blob "$sha:.claude/agent-team-project-name" | sed -n '1p' || true)
    name=${name%$'\r'}
    if [ -n "$name" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  fi
  if git cat-file -e "$sha:AGENTS.md" 2>/dev/null; then
    name=$(git cat-file blob "$sha:AGENTS.md" | sed -n '1{s/^# //p;q}' || true)
    name=${name%$'\r'}
    if [ -n "$name" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  fi
  basename "$PWD"
}
# Blob at head equals the origin/main template after {{PROJECT_NAME}} substitution.
# agent-team.sh project sync does that with str.replace, not the user-level "this project" render.
render_matches_head() { # <path>
  local rel name tmp rc=0
  rel=$(template_rel_for "$1") || return 1
  if [ "$copy_project_name_ready" = false ]; then
    copy_project_name=$(detect_copy_project_name "$head") || return 1
    copy_project_name_ready=true
  fi
  name=$copy_project_name
  if ! git -C "$dotfiles_root" cat-file -e "origin/main:templates/agent-team/${rel}" 2>/dev/null; then
    return 1
  fi
  tmp=$(mktemp -d)
  git -C "$dotfiles_root" cat-file blob "origin/main:templates/agent-team/${rel}" >"$tmp/raw" || { rm -rf "$tmp"; return 1; }
  python3 - "$name" "$tmp/raw" "$tmp/rendered" <<'PY' || { rm -rf "$tmp"; return 1; }
import sys
name, src, dst = sys.argv[1:]
with open(src, encoding="utf-8") as fh:
    data = fh.read()
with open(dst, "w", encoding="utf-8") as fh:
    fh.write(data.replace("{{PROJECT_NAME}}", name))
PY
  git cat-file blob "$head:$1" >"$tmp/head" || { rm -rf "$tmp"; return 1; }
  cmp -s "$tmp/rendered" "$tmp/head" || rc=$?
  rm -rf "$tmp"
  return "$rc"
}
# Paths check would tell this tree to delete. Same messages run_check prints, not a second list of names.
demanded_deletions() { # <sha>; one rel path per line
  local sha=$1 dir out rc=0
  dir=$(mktemp -d)
  git archive "$sha" 2>/dev/null | tar -x -C "$dir" 2>/dev/null || true
  git -C "$dir" init -q 2>/dev/null || true
  out=$(DOTFILES="$dotfiles_root" bash "$dotfiles_root/script/agent-team.sh" check "$dir" 2>&1) || rc=$?
  rm -rf "$dir"
  [ "$rc" -lt 2 ] || refuse "--verdict-from: cannot read deletions agent-team.sh check demands at ${sha:0:12}"
  awk '
    function take(line, key,    i) {
      i = index(line, key)
      if (i) { print substr(line, i + length(key)); return 1 }
      return 0
    }
    { take($0, "canonical role file in project: ") || take($0, "shared hook copy or link in project: ") }
  ' <<<"$out"
}
# Paths check would tell this tree to remove. Broader than demanded_deletions: the verdict lane
# also accepts deletion of a generated skill copy check flags. The generated lane keeps its own list.
check_removal_paths() { # <sha>; one rel path per line. Returns 2 when check cannot run.
  local sha=$1 dir out rc=0
  dir=$(mktemp -d)
  git archive "$sha" 2>/dev/null | tar -x -C "$dir" 2>/dev/null || true
  git -C "$dir" init -q 2>/dev/null || true
  out=$(DOTFILES="$dotfiles_root" bash "$dotfiles_root/script/agent-team.sh" check "$dir" 2>&1) || rc=$?
  rm -rf "$dir"
  [ "$rc" -lt 2 ] || return 2
  awk '
    function take(line, key,    i) {
      i = index(line, key)
      if (i) { print substr(line, i + length(key)); return 1 }
      return 0
    }
    {
      take($0, "canonical role file in project: ") ||
      take($0, "shared hook copy or link in project: ") ||
      take($0, "shared bin copy or link in project: ") ||
      take($0, "Tier 2 skill copy or link in project: ") ||
      take($0, "stale generated Tier 2 skill copy in project: ") ||
      take($0, "legacy baseline directory present: ") ||
      take($0, "per-project metrics script present: ") ||
      take($0, "legacy symlink present: ")
    }
  ' <<<"$out"
}
copy_project_name=""
copy_project_name_ready=false
removal_paths=""
removal_ready=false
pr_head_ready=false
load_removal_paths() {
  [ "$removal_ready" = true ] && return 0
  local base rc=0
  base=$(field .baseRefOid)
  [[ "$base" =~ ^[0-9a-f]{40}$ ]] || return 2
  if ! git cat-file -e "$base^{commit}" 2>/dev/null; then
    git fetch origin "$base" >&2 || return 2
  fi
  removal_paths=$(check_removal_paths "$base") || rc=$?
  [ "$rc" -lt 2 ] || return 2
  removal_ready=true
}
path_removal_demanded() { # <path>; 0 demanded, 1 not, 2 check could not run
  local f=$1 d rc=0
  load_removal_paths || rc=$?
  [ "$rc" -lt 2 ] || return 2
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ "$f" = "$d" ] && return 0
    [[ "$f" == "$d"/* ]] && return 0
  done <<<"$removal_paths"
  return 1
}
# 0 when this generated copy is the origin/main render, or a deletion check demands.
allow_generated_copy() { # <path>
  local f=$1 rc=0
  if [ "$pr_head_ready" = false ]; then
    if ! git cat-file -e "$head^{commit}" 2>/dev/null; then
      git fetch origin "$head" >&2 || refuse "cannot read head $head"
    fi
    pr_head_ready=true
  fi
  if git cat-file -e "$head:$f" 2>/dev/null; then
    render_matches_head "$f" || rc=$?
    return "$rc"
  fi
  path_removal_demanded "$f" || rc=$?
  if [ "$rc" -eq 2 ]; then
    refuse "cannot read deletions agent-team.sh check demands at $(field .baseRefOid | cut -c1-12)"
  fi
  return "$rc"
}
dotfiles_root=$(cd "$ship_dir/.." && pwd)
skill_names=$(cd "$dotfiles_root/templates/agent-team/.agents/skills" 2>/dev/null && for d in */; do [ -f "$d/SKILL.md" ] && echo "${d%/}"; done; true)
if [ -z "$verdict_from" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if is_generated_copy "$f" "$skill_names"; then
      allow_generated_copy "$f" \
        || refuse "PR edits generated team copy $f; edit the dotfiles template, re-sync, then ship with --verdict-from"
    fi
  done < <(jq -r '.[]' <<<"$files")
fi

lane=verdict
lane_deletions=""
if [ -n "$verdict_from" ]; then
  lane=generated
elif [ "$mechanical" = true ]; then
  lane=mechanical
else
  lane=docs
  while IFS= read -r f; do
    case "$f" in changelog.d/*|*/changelog.d/*|*.md) ;; *) lane=verdict ;; esac
  done < <(jq -r '.[]' <<<"$files")
fi

case "$lane" in
generated)
  config_dir=$ship_dir
  verdict_config=$(python3 "$config_dir/apply-local-overlay.py" \
    "$config_dir/ship.config.example.json" "$config_dir/ship.local.json") \
    || refuse "--verdict-from: cannot read local repo config"
  jq -e '.verdict_from_repos | type == "array" and all(.[]; type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))' \
    <<<"$verdict_config" >/dev/null || refuse "--verdict-from: invalid verdict_from_repos config"
  [ "$(jq '.verdict_from_repos | length' <<<"$verdict_config")" -gt 0 ] \
    || refuse "--verdict-from: no configured verdict_from_repos; set $config_dir/ship.local.json"
  jq -e --arg repo "$repo" '.verdict_from_repos | index($repo) != null' \
    <<<"$verdict_config" >/dev/null || refuse "--verdict-from: repo is not configured in ship.local.json"
  [[ "$verdict_from" =~ ^([A-Za-z0-9_.-]+/dotfiles)#([0-9]+)$ ]] || refuse "--verdict-from must look like owner/dotfiles#N"
  src_repo="${BASH_REMATCH[1]}"; src_pr="${BASH_REMATCH[2]}"
  git cat-file -e "$head^{commit}" 2>/dev/null || git fetch origin "$head" >&2 || refuse "cannot read head $head"
  # An unmerged template must not vouch for its own generated copies.
  git -C "$dotfiles_root" rev-parse --verify -q origin/main >/dev/null || refuse "--verdict-from: cannot resolve origin/main in the dotfiles tree"
  git -C "$dotfiles_root" diff --quiet origin/main -- templates/agent-team \
    || refuse "--verdict-from: dotfiles tree is not at origin/main for templates/agent-team; merge and pull dotfiles first"
  [ -z "$(git -C "$dotfiles_root" status --porcelain --ignored -- templates/agent-team)" ] \
    || refuse "--verdict-from: templates/agent-team has local changes, not at origin/main; clean or commit them first"
  base_oid=$(field .baseRefOid)
  [[ "$base_oid" =~ ^[0-9a-f]{40}$ ]] || refuse "--verdict-from: PR base is not a commit"
  git cat-file -e "$base_oid^{commit}" 2>/dev/null || git fetch origin "$base_oid" >&2 \
    || refuse "--verdict-from: cannot read base $base_oid"
  deleted_paths=$(git diff --diff-filter=D --name-only "$base_oid" "$head")
  demanded="" demanded_ready=false lane_deletions=""
  while IFS= read -r f; do
    # Generated copies, or a pure deletion of a path check flags on the base. check below byte-verifies the head.
    if is_generated_copy "$f" "$skill_names"; then
      mode=$(git ls-tree "$head" -- "$f" 2>/dev/null | awk 'NR == 1 {print $1}')
      [ "$mode" != 120000 ] || refuse "--verdict-from refuses symlink $f"
    elif grep -Fxq -- "$f" <<<"$deleted_paths"; then
      if [ "$demanded_ready" = false ]; then
        demanded=$(demanded_deletions "$base_oid")
        demanded_ready=true
      fi
      if grep -Fxq -- "$f" <<<"$demanded"; then
        lane_deletions="${lane_deletions}${f}"$'\n'
      else
        refuse "--verdict-from needs every changed file to be a generated team copy; $f is not"
      fi
    else
      refuse "--verdict-from needs every changed file to be a generated team copy; $f is not"
    fi
  done < <(jq -r '.[]' <<<"$files")
  sync_dir=$(mktemp -d)
  git archive "$head" 2>/dev/null | tar -x -C "$sync_dir" 2>/dev/null || true
  git -C "$sync_dir" init -q 2>/dev/null || true
  (export DOTFILES="$dotfiles_root"; bash "$dotfiles_root/script/agent-team.sh" check "$sync_dir" >&2) \
    || refuse "agent-team.sh check fails at head $head"
  src=$(gh pr view "$src_pr" --repo "$src_repo" --json state,headRefOid,body,comments) || refuse "cannot read $verdict_from"
  [ "$(jq -r .state <<<"$src")" = MERGED ] || refuse "$verdict_from is not MERGED"
  src_head=$(jq -r .headRefOid <<<"$src")
  src_pass_agent="" src_pass_model="" src_fail=false src_edited=0
  while IFS= read -r row; do
    c=$(jq -r '@base64d | fromjson | .body' <<<"\"$row\""); fl=$(jq -r '@base64d | fromjson | ((.includesCreatedEdit // false) or (.isMinimized // false))' <<<"\"$row\"")
    l=${c%%$'\n'*}
    if [[ "$l" =~ $verdict_re ]] && [ "${BASH_REMATCH[2]}" = "$src_head" ]; then
      [ "${BASH_REMATCH[3]}" != "${BASH_REMATCH[4]}" ] || refuse "author cannot supply verifier verdict"
      # An edited or minimized PASS never counts; an edited FAIL still blocks.
      if [ "$fl" = true ] && [ "${BASH_REMATCH[1]}" != FAIL ]; then src_edited=$((src_edited+1)); continue; fi
      if [ "${BASH_REMATCH[1]}" = FAIL ]; then src_fail=true
      elif [ -z "$src_pass_agent" ]; then
        [ -n "${BASH_REMATCH[6]}" ] || refuse "$verdict_from Verdict does not record the verifier agent and model"
        src_pass_agent=${BASH_REMATCH[6]} src_pass_model=${BASH_REMATCH[7]}
      fi
    fi
  done < <(jq -r '.comments | reverse[] | @json | @base64' <<<"$src")
  [ -n "$src_pass_agent" ] || refuse "$verdict_from has no passing Verdict for its merged head $src_head$([ "$src_edited" -eq 0 ] || echo "; $src_edited edited or minimized PASS ignored, post a fresh Verdict")"
  [ "$src_fail" = false ] || refuse "$verdict_from has a FAIL Verdict for its merged head"
  same_pair_gate "$(jq -r .body <<<"$src")" "$src_pass_agent" "$src_pass_model" "$verdict_from"
  echo "ship: generated team copies, Verdict from $verdict_from"
  ;;
mechanical)
  # Pure substitution or deletion: every hunk removes as many lines as it adds (a whole deleted file is fine),
  # the only new files are changelog fragments, no file is renamed, copied or binary. Protected paths still apply below.
  ! grep -qE '^(rename|copy|similarity|Binary files|GIT binary patch)' <<<"$diff" || refuse "--mechanical refuses renames, copies and binary changes"
  # Paths come from the ---/+++ lines (to end of line, so spaces and quoted names work), not from the diff --git line.
  bad=$(awk '
    function flush() { if (file != "" && !deleted && !created && (plus != minus)) print file ": " minus " removed, " plus " added"; plus = minus = 0 }
    function path(l) { sub(/^(\+\+\+|---) /, "", l); sub(/\t.*$/, "", l); gsub(/^"|"$/, "", l); sub(/^[ab]\//, "", l); return l }
    /^diff --git / { flush(); file = "?"; deleted = created = 0; next }
    /^new file mode/ { created = 1; next }
    /^deleted file mode/ { deleted = 1; next }
    /^--- / { if ($0 !~ /^--- \/dev\/null/) file = path($0); next }
    /^\+\+\+ / { if ($0 !~ /^\+\+\+ \/dev\/null/) file = path($0); if (created && file !~ /^changelog\.d\//) print file ": new file"; next }
    /^\+/ { plus++ } /^-/ { minus++ }
    END { flush() }' <<<"$diff")
  [ -z "$bad" ] || refuse "--mechanical needs a pure substitution or deletion diff: $bad"
  echo "ship: mechanical lane, Verdict not required"
  ;;
docs)
  # Docs only (markdown or changelog.d): a cold "Review: PASS head=<head>" at the head, or a Verdict (below). Newest Review at the head decides;
  # an edited or minimized PASS never counts.
  review=$(jq -r --arg h "$head" '
    [.comments[]? | select((.body // "" | split("\n")[0]) | test("^Review: (PASS|FAIL) head=" + $h + "( main=[0-9a-f]{40})?($| )"))
      | {r: (.body | split("\n")[0] | capture("^Review: (?<r>PASS|FAIL)").r), f: ((.includesCreatedEdit // false) or (.isMinimized // false))}
      | select(.r == "FAIL" or .f == false)] | last // {r: "none"} | .r' <<<"$info")
  # A Verdict from post-verdict.sh at the exact head also counts, with the same author and builder checks as the verdict
  # lane. A Verdict at another head does not count; a FAIL Review or FAIL Verdict at the head refuses.
  load_newest_verdict
  [ "$verdict_head" = "$head" ] || verdict_status=""
  [ "$verdict_status" != FAIL ] || refuse "newest Verdict on PR $pr is FAIL at head ${head:0:12}"
  case "$review" in
    PASS) ;;
    FAIL) refuse "newest Review on PR $pr is FAIL at head ${head:0:12}" ;;
    *)
      case "$verdict_status" in
        PASS|PASS+NOTES)
          [ -n "$v_agent" ] || refuse "Verdict on PR $pr does not record the verifier agent and model; post it with post-verdict.sh --agent <agent> --model <model>"
          same_pair_gate "$pr_body" "$v_agent" "$v_model" "PR $pr" ;;
        *) refuse "docs only PR $pr needs a cold 'Review: PASS head=$head' comment or a Verdict: PASS at that head" ;;
      esac ;;
  esac
  ;;
verdict)
  # Newest Verdict comment (exact post-verdict.sh first-line shape) is PASS or PASS+NOTES.
  load_newest_verdict
  [ -n "$verdict_status" ] || refuse "missing Verdict comment on PR $pr"
  case "$verdict_status" in
    PASS|PASS+NOTES) ;;
    *) refuse "newest Verdict on PR $pr is $verdict_status" ;;
  esac
  [ -n "$v_agent" ] || refuse "Verdict on PR $pr does not record the verifier agent and model; post it with post-verdict.sh --agent <agent> --model <model>"
  same_pair_gate "$pr_body" "$v_agent" "$v_model" "PR $pr"

  # Verdict head equals current head, or git patch-id --stable of merge-base(origin/main, head)..head matches.
  if [ "$verdict_head" != "$head" ] && ! verdict_carry "$verdict_head" "$head"; then
    blank=$(blank_commit "$verdict_head" "$head") \
      && refuse "commit ${blank:0:12} after verdict head ${verdict_head:0:12} is empty or whitespace only; post a new Verdict"
    refuse "verdict head ${verdict_head:0:12} patch-id does not match current head ${head:0:12}"
  fi
  ;;
esac

# 5. Protected paths (shared lib: owner-only, Owner-approved trailer, Countersign).
if [ "$lane" = generated ]; then
  # Generated copies of role files carry no Owner-approved trailer by design; the template PR already passed that gate.
  # A pure deletion of a shared hook check flags is the removal check demands, so the owner-only hook rule skips it.
  if [ -n "$lane_deletions" ]; then
    files_saved=$files
    files=$(jq -c --arg del "$lane_deletions" \
      '($del | split("\n") | map(select(length > 0))) as $skip | map(select(. as $p | $skip | index($p) | not))' <<<"$files")
    PROTECTED_PATHS_QUIET_TRIGGERS=1 check_owner_only_paths
    files=$files_saved
  else
    PROTECTED_PATHS_QUIET_TRIGGERS=1 check_owner_only_paths
  fi
  PROTECTED_PATHS_QUIET_TRIGGERS=1 check_countersign_gate
else
  PROTECTED_PATHS_QUIET_TRIGGERS=1 check_protected_paths
fi

if [ "$dry_run" = true ]; then
  echo "[dry-run] would ship PR $pr at head $head"
  exit 0
fi

merge_out=$(gh pr merge "$pr" --repo "$repo" --squash --match-head-commit "$head" 2>&1) \
  || refuse "gh pr merge failed for PR $pr: ${merge_out%%$'\n'*}"
final=$(gh pr view "$pr" --repo "$repo" --json state,mergeCommit) || refuse "cannot read back PR $pr after merge"
[ "$(jq -r .state <<<"$final")" = MERGED ] || refuse "PR $pr is not MERGED after merge"
merge_sha=$(jq -r '.mergeCommit.oid // empty' <<<"$final")
[ -n "$merge_sha" ] || refuse "MERGED read-back for PR $pr has no merge commit"
echo "shipped PR $pr as $merge_sha"
# The merge is done; a board failure only warns. A failed merge refused above and never reaches this line.
board_status_set "branch:$(field .headRefName)" completed
