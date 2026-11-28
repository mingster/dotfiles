#!/usr/bin/env bash
# Ship one verified PR with squash merge and read-back confirmation (pstack Shipping run).
# Usage: ship.sh --repo <owner/name> --pr <n> [--dry-run] [--environment ENV] [--mechanical | --verdict-from <owner/dotfiles#N>]
#        -h and --help print this text.
# Lanes: code and script PRs need a verifier Verdict: PASS whose agent and model differ from the builder's
# (PR body line "Builder: agent=<a> model=<m>"). The same model family is refused unless the Verdict
# comment is tagged same-family-different-model. The body also needs checked Acceptance and a
# ## Self-check with a command and its output. A Review: FAIL at the merge head refuses the merge
# unless a later Review: PASS for that head from the model that posted the FAIL, a Countersign, or a Verdict
# quoting the FAIL line as "> <line>" with a "Does not hold: <why>" line (verdict lane only) covers it (#1770).
# Every FAIL at the head needs covering, not only the newest.
# A docs only PR needs a cold "Review: PASS head=<head>"
# or a Verdict PASS or PASS+NOTES at that exact head (same author and builder checks as the verdict lane);
# a tier 0 PR (script/pr-tier.py: test files and docs only, 150 changed lines or fewer, no protected path) takes the same lane (#1730);
# --mechanical lands a pure substitution or deletion diff with no Verdict; --verdict-from lands generated team
# copies on the Verdict of the matching MERGED dotfiles PR. That lane also accepts a pure deletion of a path
# agent-team.sh check flags as a canonical role file or an unkept shared hook copy. The verdict lane accepts
# a generated copy whose blob at the PR head equals the template render at the head's .claude/agent-team-pin
# (dotfiles origin/main when the head has no pin; the same {{PROJECT_NAME}} substitution agent-team.sh uses),
# and a deletion of a generated copy that check demands. Any other generated copy still needs --verdict-from.
# A pin must be an ancestor of dotfiles origin/main and must not move behind the base's pin.
# A PR whose base is not the default branch merges only while an open PR still has that base as its head (a live
# stack). Otherwise it refuses and asks for a retarget to the default branch and a rebase (#1952). No auto retarget.
# After a dotfiles merge that touched the team template, template-sync-pr.sh opens the pin bump PRs (#1247).
set -euo pipefail
print_usage() { sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}"; }
for a in ${1+"$@"}; do case "$a" in -h|--help) print_usage; exit 0 ;; --) break ;; esac; done

ship_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/dotfiles-fresh.sh
. "$ship_dir/lib/dotfiles-fresh.sh"
refuse() { echo "ship: refused: $*" >&2; exit 1; }
die() { refuse "$*"; }

# Host that holds the worktree for this PR head, or empty when it is on the local Orca.
# Reads the dispatch record (projection.host.id) and confirms the branch with worktree list.
# An unreachable host is skipped. A miss falls back to the local Orca, which warns if the card is not there.
board_environment_for_branch() { # <branch>
  local branch=$1 orca page cursor hosts_file hosts host pages=0
  orca=${ORCA_CLI_COMMAND:-orca}
  branch_on_host() { # <host> <branch> -> 0 when that Orca lists the branch
    local args=(worktree list --json) listed
    [ -z "$1" ] || args=(worktree list --environment "$1" --json)
    listed=$("$orca" "${args[@]}" 2>/dev/null) || return 1
    printf '%s' "$listed" | jq -e --arg b "$2" '
      [.result.worktrees[]? | (.branch // "") | sub("^refs/heads/"; "")] | index($b) != null' >/dev/null 2>&1
  }
  # The branch is on the local Orca: no remote lookup (#1200).
  if branch_on_host "" "$branch"; then
    return 0
  fi
  hosts_file=$(mktemp)
  cursor=""
  while [ "$pages" -lt 10 ]; do
    pages=$((pages + 1))
    if [ -n "$cursor" ]; then
      page=$("$orca" orchestration worker-list --full --include-remote --limit 100 --cursor "$cursor" --json 2>/dev/null) || break
    else
      page=$("$orca" orchestration worker-list --full --include-remote --limit 100 --json 2>/dev/null) || break
    fi
    [ -n "$page" ] || break
    printf '%s' "$page" | jq -r '
      [.result.workers[]?
        | (.projection.host.id // .host.id // (if (.host | type) == "string" then .host else empty end) // empty)
        | select(type == "string" and length > 0 and . != "local")]
      | unique[]' >>"$hosts_file" 2>/dev/null || break
    cursor=$(printf '%s' "$page" | jq -r '.result.nextCursor // .result.page.nextCursor // empty' 2>/dev/null) || cursor=""
    [ -n "$cursor" ] || break
  done
  # No remote host in the dispatch record: the local set is the whole lookup.
  if [ ! -s "$hosts_file" ]; then
    rm -f "$hosts_file"
    return 0
  fi
  hosts=$(sort -u "$hosts_file")
  rm -f "$hosts_file"
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    if branch_on_host "$host" "$branch"; then
      printf '%s\n' "$host"
      return 0
    fi
  done <<<"$hosts"
  return 0
}

# shellcheck disable=SC1091
. "$ship_dir/lib/protected-paths.sh"
# shellcheck disable=SC1091
. "$ship_dir/lib/board-status.sh"

# After a dotfiles merge, pull latest dotfiles to every fleet host (#1173). Runs detached, so the merge never waits
# on it and a failure never reaches ship's exit code. One block per run lands in the log fleet-watch reads:
# "fleet-pull <utc> pr=<n> sha=<sha> exit=<rc> duration_s=<n>" then the ok/fail line per host. exit=124 means the
# timeout cut it off. team-audit.sh --report reads duration_s.
# fleet-pull.sh pulls every host and repo in the fleet config, so only a dotfiles merge triggers it, not a project repo.
fleet_pull_after_merge() { # <pr> <merge sha>
  local pr_n=$1 sha=$2
  local log=${SHIP_FLEET_PULL_LOG:-$HOME/.claude/state/fleet-pull-after-ship.log}
  local cmd=${SHIP_FLEET_PULL:-$ship_dir/fleet-pull.sh} limit=${SHIP_FLEET_PULL_TIMEOUT:-300}
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=300
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 0
  (
    trap - EXIT
    tmp=$(mktemp) || exit 0
    began=$SECONDS
    bash "$cmd" >"$tmp" 2>&1 &
    pid=$!
    # Take the children first: killing only a child lets fleet-pull carry on to the next host.
    ( sleep "$limit"; kids=$(pgrep -P "$pid" 2>/dev/null || true); kill "$pid" $kids 2>/dev/null ) >/dev/null 2>&1 &
    dog=$!
    rc=0
    wait "$pid" || rc=$?
    kill "$dog" 2>/dev/null || true
    [ "$rc" -lt 128 ] || rc=124
    { printf 'fleet-pull %s pr=%s sha=%s exit=%s duration_s=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr_n" "$sha" "$rc" "$((SECONDS - began))"; cat "$tmp"; } >>"$log" 2>/dev/null || true
    rm -f "$tmp"
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# After a dotfiles merge that touched the team template, open one pin bump PR per project (#1247). Detached like
# fleet-pull: a failure never reaches ship's exit code; fleet-watch reports a pin that lags or a red bump PR.
template_sync_after_merge() { # <pr> <merge sha>
  local pr_n=$1 sha=$2
  local log=${SHIP_TEMPLATE_SYNC_LOG:-$HOME/.claude/state/template-sync-after-ship.log}
  local cmd=${SHIP_TEMPLATE_SYNC:-$ship_dir/template-sync-pr.sh}
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 0
  (
    trap - EXIT
    rc=0
    out=$(bash "$cmd" --verdict-from "$repo#$pr_n" 2>&1) || rc=$?
    { printf 'template-sync %s pr=%s sha=%s exit=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr_n" "$sha" "$rc"; printf '%s\n' "$out"; } >>"$log" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# After a merge, run the project's post-merge schema hook when the merged diff touches a watched path (#1745).
# .agents/head-checks.conf at the PR head names it: "# post-merge-schema: <command>" and "# schema-paths: <glob> ..."
# (space separated, bash globs on repo relative paths). It runs in this checkout with SHIP_PR and SHIP_MERGE_SHA set,
# cut off after SHIP_POST_MERGE_TIMEOUT seconds (default 900). One result line goes to the ship output. A failure files
# or updates the "red gate: test-database" issue and never undoes the merge or changes ship's exit code.
post_merge_schema_hook() { # <pr> <merge sha> <head sha> <changed files json>
  local pr_n=$1 sha=$2 head_sha=$3 changed=$4 conf cmd globs path glob hit="" tmp rc=0 limit pid dog issue last
  conf=$(git -C "$top" show "$head_sha:.agents/head-checks.conf" 2>/dev/null || cat "$top/.agents/head-checks.conf" 2>/dev/null || true)
  cmd=$(sed -n 's/^#[[:space:]]*post-merge-schema:[[:space:]]*//p' <<<"$conf" | head -1)
  [ -n "$cmd" ] || return 0
  globs=$(sed -n 's/^#[[:space:]]*schema-paths:[[:space:]]*//p' <<<"$conf" | head -1)
  [ -n "$globs" ] || return 0
  # No file name expansion: a glob must match the changed path, not the files on this disk.
  set -f
  while IFS= read -r path; do
    for glob in $globs; do
      # shellcheck disable=SC2254
      case "$path" in $glob) hit=$path; break 2 ;; esac
    done
  done < <(jq -r '.[]' <<<"$changed")
  set +f
  [ -n "$hit" ] || return 0
  limit=${SHIP_POST_MERGE_TIMEOUT:-900}
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=900
  tmp=$(mktemp) || return 0
  ( cd "$top" && SHIP_PR=$pr_n SHIP_MERGE_SHA=$sha bash -c "$cmd" ) >"$tmp" 2>&1 &
  pid=$!
  ( sleep "$limit"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  dog=$!
  wait "$pid" || rc=$?
  kill "$dog" 2>/dev/null || true
  [ "$rc" -lt 128 ] || rc=124
  last=$(grep -v '^[[:space:]]*$' "$tmp" | tail -1 | cut -c1-200) || true
  if [ "$rc" -eq 0 ]; then
    echo "post-merge schema: ok (${last:-no output})"
  else
    issue=$({ printf 'Post-merge schema hook failed after PR %s merged as %s.\nCommand: %s\nExit: %s\n' "$pr_n" "$sha" "$cmd" "$rc"; tail -40 "$tmp"; } \
      | python3 "$ship_dir/red-gate.py" file --tool test-database --repo "$repo" 2>/dev/null) || issue=""
    [ -z "$issue" ] || issue="red gate #$issue"
    echo "post-merge schema: FAILED exit $rc, the merge stands, ${issue:-no red gate issue filed}"
  fi
  rm -f "$tmp"
}
repo="" pr="" dry_run=false mechanical=false verdict_from="" ship_environment=""
sync_dir=""
trap '[ -z "$sync_dir" ] || rm -rf "$sync_dir"' EXIT
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || refuse "--repo needs a value"; repo=$2; shift 2 ;;
    --pr) [ $# -ge 2 ] || refuse "--pr needs a value"; pr=$2; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --mechanical) mechanical=true; shift ;;
    --verdict-from) [ $# -ge 2 ] || refuse "--verdict-from needs owner/dotfiles#N"; verdict_from=$2; shift 2 ;;
    --environment) [ $# -ge 2 ] || refuse "--environment needs a value"; ship_environment=$2; shift 2 ;;
    *) refuse "unknown argument: $1" ;;
  esac
done
[ -n "$repo" ] && [[ "$pr" =~ ^[0-9]+$ ]] || refuse "usage: ship.sh --repo <owner/name> --pr <n> [--dry-run] [--environment ENV] [--mechanical | --verdict-from <owner/dotfiles#N>]"
[ "$mechanical" = false ] || [ -z "$verdict_from" ] || refuse "--verdict-from and --mechanical are exclusive"
# Run from the repo checkout: a wrong cwd otherwise surfaces later as "cannot read head" (#1326).
top=$(git rev-parse --show-toplevel 2>/dev/null) || refuse "run from inside the ${repo##*/} checkout (cwd is not a git repo)"
origin_url=$(git -C "$top" remote get-url origin 2>/dev/null || true)
if [[ "$origin_url" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
  origin_repo=${BASH_REMATCH[1]%.git}
  [ "$origin_repo" = "$repo" ] || refuse "run from inside the ${repo##*/} checkout (cwd origin is $origin_repo)"
fi

read_pr() {
  info=$(gh pr view "$pr" --repo "$repo" --json state,title,isDraft,mergeable,headRefName,headRefOid,baseRefOid,baseRefName,body,comments,statusCheckRollup) \
    || refuse "cannot read PR $pr"
}
read_pr
field() { jq -r "$1" <<<"$info"; }

# Public repo only: a private project or host name in the PR title or body stays on GitHub after merge.
# A private or internal repo may name its own project. Visibility is read once; unreadable refuses.
visibility=$(gh repo view "$repo" --json visibility -q .visibility 2>/dev/null) || refuse "cannot read visibility of $repo"
case "$visibility" in
  PRIVATE|INTERNAL) ;;
  PUBLIC)
    name_dir=$(mktemp -d)
    field .title >"$name_dir/pr-$pr-title.txt"
    field .body >"$name_dir/pr-$pr-body.txt"
    name_out=$(bash "$ship_dir/check-project-names.sh" --show-match --file "$name_dir/pr-$pr-title.txt" --file "$name_dir/pr-$pr-body.txt" 2>&1) && name_rc=0 || name_rc=$?
    rm -rf "$name_dir"
    [ "$name_rc" -eq 0 ] || refuse "PR $pr text names a private project or host: ${name_out//$'\n'/; }"
    ;;
  *) refuse "unexpected visibility '$visibility' for $repo" ;;
esac

# A trailer git does not parse (a blank line before Co-Authored-By) makes the guard and fleet-watch see the commit as unapproved.
trailer_dir=$(mktemp -d)
trailer_args=()
commit_pages=$(gh api --paginate "repos/$repo/pulls/$pr/commits") || { rm -rf "$trailer_dir"; refuse "cannot read PR $pr commits"; }
while IFS=$'\t' read -r sha msg; do
  [ -n "$sha" ] || continue
  base64 --decode <<<"$msg" >"$trailer_dir/$sha"
  trailer_args+=(--file "$trailer_dir/$sha")
done < <(jq -r '.[] | [.sha[0:12], (.commit.message | @base64)] | @tsv' <<<"$commit_pages")
trailer_rc=0 trailer_out=""
if [ "${#trailer_args[@]}" -gt 0 ]; then
  trailer_out=$(bash "$ship_dir/check-commit-trailers.sh" "${trailer_args[@]}" 2>&1) || trailer_rc=$?
fi
rm -rf "$trailer_dir"
[ "$trailer_rc" -eq 0 ] || refuse "PR $pr has a commit trailer git does not parse: ${trailer_out//$'\n'/; }"

# 1. PR is open, not draft, mergeable (not CONFLICTING).
# GitHub leaves mergeable UNKNOWN until it has calculated the merge. PRs 801 and 802
# were MERGEABLE about 20s later, so reread a few times, then refuse.
[ "$(field .state)" = OPEN ] || refuse "PR $pr is not open (state=$(field .state))"
[ "$(field '.isDraft // false')" = false ] || refuse "PR $pr is a draft"
# 1b. A stacked PR (base is another branch) merges only while an open PR still has that base as its head (a live stack).
# Once the base PR has merged, the change would land in a dead branch and never reach the default branch (#1952).
base_ref=$(field .baseRefName)
default_branch=$(gh repo view "$repo" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null) \
  || refuse "cannot read the default branch of $repo"
[ -n "$default_branch" ] || refuse "cannot read the default branch of $repo"
if [ "$base_ref" != "$default_branch" ]; then
  open_on_base=$(gh pr list --repo "$repo" --state open --head "$base_ref" --json number) \
    || refuse "cannot list open PRs on base $base_ref"
  jq -e 'length > 0' <<<"$open_on_base" >/dev/null \
    || refuse "base $base_ref is merged; retarget to $default_branch and rebase"
fi
mergeable_wait=${SHIP_MERGEABLE_WAIT:-4}
mergeable_rereads=${SHIP_MERGEABLE_REREADS:-15}
[[ "$mergeable_wait" =~ ^[0-9]+$ ]] || mergeable_wait=4
[[ "$mergeable_rereads" =~ ^[0-9]+$ ]] || mergeable_rereads=15
reread=0
while [ "$(field .mergeable)" = UNKNOWN ] && [ "$reread" -lt "$mergeable_rereads" ]; do
  reread=$((reread + 1))
  sleep "$mergeable_wait"
  read_pr
done
[ "$(field .mergeable)" = MERGEABLE ] || refuse "PR $pr is not mergeable (mergeable=$(field .mergeable))"
head=$(field .headRefOid)
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || refuse "PR $pr has invalid headRefOid"

# 2. Every required check at the current head is SUCCESS (statusCheckRollup; pending counts as not yet).
jq -e '((.statusCheckRollup // []) | length) > 0' <<<"$info" >/dev/null \
  || refuse "no checks reported at head $head"
# A name is judged by its newest run. A SKIPPED run is dropped when the same name has a SUCCESS run at this head
# (GitHub keeps the superseded trigger's SKIPPED run in the rollup, sometimes with a later timestamp).
jq -e '[(.statusCheckRollup // [])[] | select((.isRequired // true) != false)
    | . + {key: (.name // .context // ""), at: (if (.status // "COMPLETED") != "COMPLETED" then "9999" else (.completedAt // .startedAt // "") end)}]
  | group_by(.key)
  | map(if any(.[]; (.conclusion // .state // "") == "SUCCESS") then map(select((.conclusion // "") != "SKIPPED")) else . end
    | sort_by(.at) | last)
  | all(.[]; ((.status // "COMPLETED") == "COMPLETED") and ((.conclusion // .state // "") == "SUCCESS"))' <<<"$info" >/dev/null \
  || refuse "required checks are not all SUCCESS at head ${head:0:12}"

# 2b. The latest finished push Checks run on main is SUCCESS, unless this PR names that run as the one it fixes
# and touches what that run tested, in any commit since the last green run (a push to main only runs the tests for the files it changed).
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
  # Every commit since the last green push run counts, not only the failed head: the break may sit in an earlier
  # commit of that range (#1670). With no green run to start from, the head commit alone.
  base_run=$(gh run list --repo "$repo" --workflow Checks --branch main --event push --status success --limit 1 \
    --json headSha) || refuse "cannot read the last green Checks run on main"
  base_sha=$(jq -r '.[0].headSha // empty' <<<"$base_run")
  if [[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] && [ "$base_sha" != "$main_sha" ]; then
    main_files=$(gh api "repos/$repo/compare/$base_sha...$main_sha" --jq '.files[].filename') \
      || refuse "cannot read the files of main commits ${base_sha:0:12}...${main_sha:0:12}"
  else
    main_files=$(gh api "repos/$repo/commits/$main_sha" --jq '.files[].filename') \
      || refuse "cannot read the files of main commit ${main_sha:0:12}"
  fi
  fix_files=$(gh api --paginate "repos/$repo/pulls/$pr/files" --jq '.[] | (.filename // .path)') \
    || refuse "cannot read PR $pr files"
  # Tests a file list selects, minus the always-run guards the selector adds for every PR (a path no test maps to
  # selects only those).
  select_tests() {
    bash "${SHIP_SELECT_TESTS:-$ship_dir/select-changed-script-tests.sh}" --list-only "$@" | sed -n 's/^Selected: //p' | LC_ALL=C sort -u
  }
  always_tests=$(select_tests ship-no-such-path.txt) || true
  selected_tests() {
    local -a paths=()
    local line
    while IFS= read -r line; do [ -n "$line" ] && paths+=("$line"); done
    comm -23 <(select_tests "${paths[@]+"${paths[@]}"}") <(printf '%s\n' "$always_tests")
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

# True when the diff of <file> changes, deletes or inserts into a line of a code fence in the old version (delimiters included).
edits_inside_fence() { # <old> <new> <file>
  git cat-file -e "$1:$3" 2>/dev/null || return 1
  awk '
    FNR == NR {
      n++
      if ($0 ~ /^ *(```|~~~)/) { delim = 1; infence = !infence } else delim = 0
      cover[n] = delim || infence
      after[n] = infence
      next
    }
    /^@@ / {
      split($2, a, ","); s = substr(a[1], 2) + 0; c = (a[2] == "" ? 1 : a[2] + 0)
      if (c == 0) { if (after[s]) hit = 1 }
      else for (i = s; i < s + c; i++) if (cover[i]) hit = 1
    }
    END { exit hit ? 0 : 1 }
  ' <(git show "$1:$3") <(git diff -U0 --no-renames "$1" "$2" -- "$3")
}

# Wording only since the Verdict head (#940): every changed file is .md under docs/ or changelog.d/ or at the top level,
# the diff adds no code fence and edits no line inside an existing one (#956), no top level CLAUDE.md changes, and no changed path is protected. Such a change merges on green checks with no new Verdict.
wording_only_carry() { # <verdict_head> <current_head>
  local f out
  git cat-file -e "$1^{commit}" 2>/dev/null || git fetch origin "$1" >&2 || return 1
  git merge-base --is-ancestor "$1" "$2" 2>/dev/null || return 1
  out=$(git diff --no-renames --name-only "$1" "$2") || return 1
  [ -n "$out" ] || return 1
  while IFS= read -r f; do
    case "$f" in
      CLAUDE.md) return 1 ;;
      docs/*.md|changelog.d/*.md) ;;
      */*) return 1 ;;
      *.md) ;;
      *) return 1 ;;
    esac
    protected_path "$f" && return 1
    edits_inside_fence "$1" "$2" "$f" && return 1
  done <<<"$out"
  ! git diff "$1" "$2" | grep -qE '^\+.*(```|~~~)'
}

# Files and diff of the PR, read once: the lane choice and the protected path check both use them.
file_pages=$(gh api --paginate "repos/$repo/pulls/$pr/files") || refuse "cannot read PR $pr files"
# shellcheck disable=SC2034
files=$(jq -s '[.[][] | (.filename // .path)]' <<<"$file_pages") || refuse "invalid PR $pr file list"
# shellcheck disable=SC2034
# GitHub refuses a very large diff (PullRequest.diff too_large). Then build the same diff locally from the base and head commits, so every lane check still reads the same content (#1162).
diff_err=$(mktemp) || refuse "cannot create a temp file"
if ! diff=$(gh pr diff "$pr" --repo "$repo" 2>"$diff_err"); then
  if grep -q 'too_large' "$diff_err"; then
    diff_base=$(field .baseRefOid)
    [[ "$diff_base" =~ ^[0-9a-f]{40}$ ]] || refuse "PR $pr diff is too large for GitHub and baseRefOid is invalid"
    git fetch origin "$diff_base" "$head" >&2 || refuse "PR $pr diff is too large for GitHub and the base and head cannot be fetched"
    diff=$(git diff "$diff_base...$head") || refuse "cannot build the diff of PR $pr locally"
  else
    rm -f "$diff_err"; refuse "cannot read diff of PR $pr"
  fi
fi
rm -f "$diff_err"

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
model_family() { # <agent> <model>
  python3 "$ship_dir/usage-gate.py" family --agent "$1" --model "$2"
}
same_pair_gate() { # <body> <verifier agent> <verifier model> <where> [same-family tag] [PR diff]
  builder_record "$1"
  [ -n "$builder_agent" ] || refuse "$4 has no 'Builder: agent=<agent> model=<model>' line, so the verifier cannot be compared with the builder"
  [ "$(tr '[:upper:]' '[:lower:]' <<<"$2/$3")" != "$(tr '[:upper:]' '[:lower:]' <<<"$builder_agent/$builder_model")" ] \
    || refuse "verifier $2/$3 is the same agent and model as the builder; verify with a different agent or model"
  local verifier_family builder_family body_reason
  verifier_family=$(model_family "$2" "$3")
  builder_family=$(model_family "$builder_agent" "$builder_model")
  if [ -n "$verifier_family" ] && [ "$verifier_family" != unknown ] && [ "$verifier_family" = "$builder_family" ] \
      && [ "${5:-}" != same-family-different-model ]; then
    refuse "verifier $2/$3 is the same model family as the builder; verify with a different family or tag the Verdict same-family-different-model"
  fi
  # #1882: a sixth argument (the PR's own diff) turns on the Readers: rule. --verdict-from checks a merged
  # source PR's body, which never saw this diff, so it passes none.
  local gate_diff="" gate_conf="" gate_target=() gate_err=""
  if [ -n "${6:-}" ]; then
    gate_diff=$(mktemp) || refuse "cannot create a temp file"
    printf '%s\n' "$6" >"$gate_diff"
    # #2070: the Perf: rule reads the --repo target's .agents/head-checks.conf, as pr-review.sh does: this checkout when
    # its origin is $repo, else the file on GitHub. #2079: a 404 means the target has no conf (the rule is off); any other
    # fetch error (network, auth, 5xx) refuses the ship, so the Perf: rule is never skipped by accident.
    shopt -s nocasematch
    if [[ "${origin_url%.git}" == *[:/]"$repo" ]]; then
      gate_target=(--repo-dir "$top")
    else
      gate_conf=$(mktemp) || refuse "cannot create a temp file"
      if ! gate_err=$(gh api "repos/$repo/contents/.agents/head-checks.conf" -H 'Accept: application/vnd.github.raw' 2>&1 >"$gate_conf"); then
        grep -q 'HTTP 404' <<<"$gate_err" \
          || { rm -f "$gate_diff" "$gate_conf"; refuse "cannot read $repo .agents/head-checks.conf to check the Perf: rule: $(head -n 1 <<<"$gate_err")"; }
        : >"$gate_conf"
      fi
      gate_target=(--conf "$gate_conf")
    fi
    shopt -u nocasematch
  fi
  body_reason=$(python3 "$ship_dir/pr-body-gate.py" ${gate_diff:+--diff "$gate_diff"} ${gate_target[@]+"${gate_target[@]}"} <<<"$1") \
    || { rm -f "$gate_diff" ${gate_conf:+"$gate_conf"}; refuse "$4 $body_reason"; }
  rm -f "$gate_diff" ${gate_conf:+"$gate_conf"}
}
verdict_re='^Verdict: (PASS\+NOTES|PASS|FAIL) head=([0-9a-f]{40}) verifier=([a-zA-Z0-9_-]+) author=([a-zA-Z0-9_-]+)( agent=([A-Za-z0-9._-]+) model=([A-Za-z0-9._:-]+))?$'

# Newest Verdict comment (exact post-verdict.sh first-line shape) into verdict_status, verdict_head, v_agent, v_model.
# A flagged (edited or minimized) comment counts only when it is a FAIL. Empty verdict_status means none.
load_newest_verdict() {
  verdict_status="" verdict_head="" v_agent="" v_model="" v_tag=""
  while IFS= read -r flagged && IFS= read -r line && IFS= read -r tag; do
    if [[ "$line" =~ $verdict_re ]]; then
      if [ "$flagged" = true ] && [ "${BASH_REMATCH[1]}" != FAIL ]; then continue; fi
      [ "${BASH_REMATCH[3]}" != "${BASH_REMATCH[4]}" ] || refuse "author cannot supply verifier verdict"
      verdict_status="${BASH_REMATCH[1]}"
      verdict_head="${BASH_REMATCH[2]}"
      v_agent="${BASH_REMATCH[6]}" v_model="${BASH_REMATCH[7]}"
      v_tag=$tag
      break
    fi
  done < <(jq -r '[.comments[]? | {f: ((.includesCreatedEdit // false) or (.isMinimized // false)), l: (.body // "" | split("\n")[0]), tag: (if ((.body // "") | test("same-family-different-model")) then "same-family-different-model" else "" end)}] | reverse[] | .f, .l, .tag' <<<"$info")
}

# Every Review: FAIL at the merge head must be covered (#1770). A FAIL is covered by a later cold Review: PASS
# from the model that posted it, by a Countersign (all FAILs), or, in the verdict lane, when the newest Verdict
# comment is a PASS or PASS+NOTES at the head, posted after that FAIL, that quotes the FAIL's first line as
# "> <line>" with a "Does not hold: <reason>" line right after the quote. The newest Verdict already passed the gates of its lane.
# Another model's PASS does not cover a FAIL. An edited or minimized PASS or Verdict does not count. An edited FAIL
# still blocks. Comments are oldest first.
review_fail_blocks_merge() {
  local uncovered
  uncovered=$(jq -r --arg h "$head" --arg lane "$lane" '
    [ .comments[]? | {body: (.body // ""), flagged: ((.includesCreatedEdit // false) or (.isMinimized // false))} ]
    | to_entries | map(.value + {idx: .key}) as $cs
    | [ $cs[] | (.body | split("\n")) as $ls | ($ls[0]) as $line
        | select($line | test("^Review: (PASS|FAIL) head=" + $h + "( main=[0-9a-f]{40})?($| )"))
        | {
            idx: .idx,
            r: ($line | capture("^Review: (?<r>PASS|FAIL)").r),
            m: ([$line | capture("(^| )model=(?<m>[^ ]+)") | .m][0] // ""),
            line: $line,
            cold: (.flagged | not)
          }
        | select(.r == "FAIL" or .cold)
      ] as $rows
    | ([ $cs[] | (.body | split("\n")) as $ls
         | ($ls[0] | capture("^Verdict: (?<res>PASS\\+NOTES|PASS|FAIL) head=[0-9a-f]{40} verifier=[a-zA-Z0-9_-]+ author=[a-zA-Z0-9_-]+( agent=[A-Za-z0-9._-]+ model=[A-Za-z0-9._:-]+)?$")?) as $m
         | select($m != null and (.flagged | not or $m.res == "FAIL"))
         | . + {ls: $ls}] | last) as $v
    | ($v != null and $lane == "verdict" and ($v.flagged | not)
        and ($v.ls[0] | test("^Verdict: (PASS\\+NOTES|PASS) head=" + $h + " "))) as $verdict_answers
    | [ $rows[] | select(.r == "FAIL") as $f
        | select(
            (any($rows[]; .idx > $f.idx and .r == "PASS" and .m != "" and .m == $f.m) | not)
            and (($verdict_answers and $v.idx > $f.idx
                  and (($v.ls | index("> " + $f.line)) as $k
                       | $k != null and (($v.ls[$k + 1] // "") | test("^Does not hold: [^ ]")))) | not)
          ) ] | if length == 0 then "" else "Review: FAIL" end
  ' <<<"$info") || refuse "cannot read Review comments on PR $pr"
  [ -n "$uncovered" ] || return 0
  countersigned "$head" && return 0
  refuse "Review: FAIL at head ${head:0:12} is not covered by a later Review: PASS from the same model, a Countersign, or a Verdict that quotes it and says 'Does not hold: <why>'"
}

# Generated team copies change only through the dotfiles template. A copy that is not the origin/main
# render, and not a deletion check demands, lands with --verdict-from.
is_generated_copy() { # <path>
  local skill_names=$2
  case "$1" in
    .claude/model-routing.md|docs/agents/team.md|docs/agents/elon-dispatch.md|docs/agents/release-manager-work.md|bin/changelog-compile.sh|bin/changelog-compile.test.sh|bin/check-commit-trailers.sh|.githooks/commit-msg|changelog.d/README.md)
      return 0 ;;
  esac
  [[ "$1" =~ ^\.(agents|claude|cursor)/skills/([^/]+)(/|$) ]] && grep -Fxq -- "${BASH_REMATCH[2]}" <<<"$skill_names"
}
# Template path relative to templates/agent-team for a generated copy. Same files agent-team.sh syncs.
template_rel_for() { # <path>
  case "$1" in
    .claude/model-routing.md|docs/agents/team.md|docs/agents/elon-dispatch.md|docs/agents/release-manager-work.md|bin/changelog-compile.sh|bin/changelog-compile.test.sh|bin/check-commit-trailers.sh|.githooks/commit-msg|changelog.d/README.md)
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
# The dotfiles commit generated copies at the PR head render from: the head's .claude/agent-team-pin, else
# origin/main. A pin outside origin/main, or behind the base's pin, is refused (#1247).
PIN_REL=.claude/agent-team-pin
render_ref=""
resolve_render_ref() {
  [ -z "$render_ref" ] || return 0
  local pin base_pin base
  git -C "$dotfiles_root" rev-parse --verify -q origin/main >/dev/null || refuse "cannot resolve origin/main in the dotfiles tree"
  if ! git cat-file -e "$head:$PIN_REL" 2>/dev/null; then
    render_ref=origin/main
    return 0
  fi
  pin=$(git cat-file blob "$head:$PIN_REL" | sed -n '1p' | tr -d '\r')
  [[ "$pin" =~ ^[0-9a-f]{40}$ ]] || refuse "$PIN_REL at head is not a commit sha"
  git -C "$dotfiles_root" merge-base --is-ancestor "$pin" origin/main 2>/dev/null \
    || refuse "$PIN_REL names ${pin:0:12}, which is not an ancestor of dotfiles origin/main"
  base=$(field .baseRefOid)
  git cat-file -e "$base^{commit}" 2>/dev/null || git fetch origin "$base" >&2 || true
  if git cat-file -e "$base:$PIN_REL" 2>/dev/null; then
    base_pin=$(git cat-file blob "$base:$PIN_REL" | sed -n '1p' | tr -d '\r')
    if [[ "$base_pin" =~ ^[0-9a-f]{40}$ ]] && ! git -C "$dotfiles_root" merge-base --is-ancestor "$base_pin" "$pin" 2>/dev/null; then
      refuse "$PIN_REL moves from ${base_pin:0:12} to ${pin:0:12}, which is not newer"
    fi
  fi
  render_ref=$pin
}
# Blob at head equals the template at the head's pin after {{PROJECT_NAME}} substitution.
# agent-team.sh project sync does that with str.replace, not the user-level "this project" render.
render_matches_head() { # <path>
  local rel name tmp rc=0
  rel=$(template_rel_for "$1") || return 1
  if [ "$copy_project_name_ready" = false ]; then
    copy_project_name=$(detect_copy_project_name "$head") || return 1
    copy_project_name_ready=true
  fi
  name=$copy_project_name
  resolve_render_ref
  if ! git -C "$dotfiles_root" cat-file -e "$render_ref:templates/agent-team/${rel}" 2>/dev/null; then
    return 1
  fi
  tmp=$(mktemp -d)
  git -C "$dotfiles_root" cat-file blob "$render_ref:templates/agent-team/${rel}" >"$tmp/raw" || { rm -rf "$tmp"; return 1; }
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
# Project files the sync merges into rather than copies (project keys kept, template defaults filled in or
# recompiled): not a byte render. They count as generated only when the head equals what `agent-team.sh sync`
# produces from the BASE file at the render ref (#1374). A changed, removed or new project key is a real edit
# and is refused. Adding a file here is the only change a new merged file needs.
# A kept guard-bash.py and its test follow the template only while they equal an older release (#1392).
MERGED_FILES=(.claude/hooks/guard-config.json .claude/settings.json .claude/hooks/guard-bash.py .claude/hooks/tests/test_guard_bash.py)
is_merged_file() { # <path>
  local m
  for m in "${MERGED_FILES[@]}"; do [ "$m" = "$1" ] && return 0; done
  return 1
}
merge_expected_dir="" merge_expected_failed=""
# Runs the real sync once on the base tree, against the dotfiles tree at the render ref.
merge_expected_prepare() {
  if [ -n "$merge_expected_dir" ] || [ -n "$merge_expected_failed" ]; then return 0; fi
  local base_oid dot name
  resolve_render_ref
  base_oid=$(field .baseRefOid)
  if [ "$copy_project_name_ready" = false ]; then
    copy_project_name=$(detect_copy_project_name "$head") || { merge_expected_failed=1; return 0; }
    copy_project_name_ready=true
  fi
  name=$copy_project_name
  dot=$(mktemp -d) merge_expected_dir=$(mktemp -d)
  if ! git -C "$dotfiles_root" archive "$render_ref" templates script .agents 2>/dev/null | tar -x -C "$dot" 2>/dev/null \
    || ! git archive "$base_oid" 2>/dev/null | tar -x -C "$merge_expected_dir" 2>/dev/null; then
    rm -rf "$dot" "$merge_expected_dir"; merge_expected_dir="" merge_expected_failed=1; return 0
  fi
  git -C "$merge_expected_dir" init -q 2>/dev/null || true
  # The archive has no history; the stale-copy check reads releases from the real repo up to the render ref.
  if ! (export DOTFILES="$dot" AGENT_TEAM_HISTORY_REPO="$dotfiles_root" AGENT_TEAM_HISTORY_REV="$render_ref"; bash "$dot/script/agent-team.sh" sync "$merge_expected_dir" --project-name "$name" >/dev/null 2>&1); then
    merge_expected_failed=1
  fi
  rm -rf "$dot"
}
merged_file_is_expected() { # <path>; 0 when head's blob == the sync result for the base file
  merge_expected_prepare
  [ -z "$merge_expected_failed" ] && [ -n "$merge_expected_dir" ] || return 1
  local tmp rc=0
  tmp=$(mktemp -d)
  git cat-file blob "$head:$1" >"$tmp/head" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  cmp -s "$tmp/head" "$merge_expected_dir/$1" || rc=$?
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
# 0 when this generated copy is the render at the head's pin, or a deletion check demands.
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
if jq -e --arg p "$PIN_REL" 'index($p) != null' <<<"$files" >/dev/null; then
  git cat-file -e "$head^{commit}" 2>/dev/null || git fetch origin "$head" >&2 || refuse "cannot read head $head"
  pr_head_ready=true
  resolve_render_ref
fi
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
  # Tier 0 (#1730): only test files and docs, 150 changed lines or fewer, no protected path. It takes the docs lane:
  # a cold Review: PASS at the head (or a Verdict) plus the green Checks read above, no separate verifier.
  if [ "$lane" = verdict ]; then
    tier=$(jq -s . <<<"$file_pages" | python3 "$ship_dir/pr-tier.py") || tier=2
    if [ "$tier" = 0 ]; then lane=docs; echo "ship: tier 0 (tests and docs only), Review PASS and green Checks at the head"; fi
  fi
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
    # Generated copies, the pin, or a pure deletion of a path check flags on the base. check --pinned below
    # byte-verifies the head against the template at its pin.
    if [ "$f" = "$PIN_REL" ]; then
      :
    elif is_generated_copy "$f" "$skill_names"; then
      mode=$(git ls-tree "$head" -- "$f" 2>/dev/null | awk 'NR == 1 {print $1}')
      [ "$mode" != 120000 ] || refuse "--verdict-from refuses symlink $f"
    elif is_merged_file "$f" && ! grep -Fxq -- "$f" <<<"$deleted_paths" && merged_file_is_expected "$f"; then
      # The sync result the template PR already passed; the owner-only rule skips this verified merge.
      lane_deletions="${lane_deletions}${f}"$'\n'
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
  (export DOTFILES="$dotfiles_root"; bash "$dotfiles_root/script/agent-team.sh" check --pinned "$sync_dir" >&2) \
    || refuse "agent-team.sh check fails at head $head"
  src=$(gh pr view "$src_pr" --repo "$src_repo" --json state,headRefOid,body,comments) || refuse "cannot read $verdict_from"
  [ "$(jq -r .state <<<"$src")" = MERGED ] || refuse "$verdict_from is not MERGED"
  src_head=$(jq -r .headRefOid <<<"$src")
  src_pass_agent="" src_pass_model="" src_pass_tag="" src_fail=false src_edited=0
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
        case "$c" in *same-family-different-model*) src_pass_tag=same-family-different-model ;; esac
      fi
    fi
  done < <(jq -r '.comments | reverse[] | @json | @base64' <<<"$src")
  [ -n "$src_pass_agent" ] || refuse "$verdict_from has no passing Verdict for its merged head $src_head$([ "$src_edited" -eq 0 ] || echo "; $src_edited edited or minimized PASS ignored, post a fresh Verdict")"
  [ "$src_fail" = false ] || refuse "$verdict_from has a FAIL Verdict for its merged head"
  same_pair_gate "$(jq -r .body <<<"$src")" "$src_pass_agent" "$src_pass_model" "$verdict_from" "$src_pass_tag"
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
  # A PASS with model=none (or no model) is not a cold review: it reads as none, so the Verdict branch below decides (#1730 follow-up).
  review=$(jq -r --arg h "$head" '
    [.comments[]? | (.body // "" | split("\n")[0]) as $line
      | select($line | test("^Review: (PASS|FAIL) head=" + $h + "( main=[0-9a-f]{40})?($| )"))
      | {r: ($line | capture("^Review: (?<r>PASS|FAIL)").r), m: ([$line | capture("(^| )model=(?<m>[^ ]+)") | .m][0] // ""), f: ((.includesCreatedEdit // false) or (.isMinimized // false))}
      | select(.r == "FAIL" or .f == false)] | last // {r: "none", m: ""}
    | if .r == "PASS" and (.m == "" or .m == "none") then "none" else .r end' <<<"$info")
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
          same_pair_gate "$pr_body" "$v_agent" "$v_model" "PR $pr" "$v_tag" "$diff" ;;
        *) refuse "docs only PR $pr needs a cold 'Review: PASS head=$head model=<name>' comment or a Verdict: PASS at that head (no Verdict: PASS found there; Review: PASS model=none is not a cold review)" ;;
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
  same_pair_gate "$pr_body" "$v_agent" "$v_model" "PR $pr" "$v_tag" "$diff"

  # Verdict head equals current head, or git patch-id --stable of merge-base(origin/main, head)..head matches.
  if [ "$verdict_head" != "$head" ] && ! verdict_carry "$verdict_head" "$head" && ! wording_only_carry "$verdict_head" "$head"; then
    blank=$(blank_commit "$verdict_head" "$head") \
      && refuse "commit ${blank:0:12} after verdict head ${verdict_head:0:12} is empty or whitespace only; post a new Verdict"
    refuse "verdict head ${verdict_head:0:12} patch-id does not match current head ${head:0:12}"
  fi
  ;;
esac

review_fail_blocks_merge

# 5. Protected paths (shared lib: owner-only, Owner-approved trailer, Countersign).
if [ "$lane" = generated ]; then
  # Generated copies of role files carry no Owner-approved trailer by design; the template PR already passed that gate.
  # A pure deletion of a shared hook check flags, or a verified sync merge (guard-config.json, settings.json), skips the owner-only hook rule.
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
post_merge_schema_hook "$pr" "$merge_sha" "$head" "$files"
if [ "$repo" = "${SHIP_FLEET_PULL_REPO:-mingster/dotfiles}" ]; then
  fleet_pull_after_merge "$pr" "$merge_sha"
  if jq -e 'any(.[]; startswith("templates/agent-team/") or . == "script/agent-team.sh")' <<<"$files" >/dev/null; then
    template_sync_after_merge "$pr" "$merge_sha"
  fi
fi
# The merge is done; a board failure only warns. A failed merge refused above and never reaches this line.
# The card lives on the host that holds the worktree. --environment wins; otherwise the dispatch record's host does.
board_env=$ship_environment
if [ -z "$board_env" ]; then
  board_env=$(board_environment_for_branch "$(field .headRefName)") || board_env=""
fi
issue_n=$(field .body | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) +([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+' | head -1 | grep -oE '[0-9]+$') || issue_n=""
board_status_complete_issue "$board_env" "$(field .headRefName)" "$issue_n" "$pr"
