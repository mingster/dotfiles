#!/usr/bin/env bash
# Coordinator publication: push an explicit engineering branch and open a PR from a body file.
# Usage:
#   coordinator-publication.sh --repo owner/name --branch <name> --body-file <path> [--title <title>] [--worktree <path>]
# Refuses protected branches, force push, tracked secret env files, and invalid PR bodies.
# Retries push and gh pr create at most three times; writes a receipt for idempotent resume.
set -euo pipefail

die() { echo "coordinator-publication: refused: $*" >&2; exit 1; }
fail() { echo "coordinator-publication: failed: $*" >&2; exit 1; }

origin_slug_from_url() {
  local u=$1 host slug
  case "$u" in
    git@github.com:*)
      slug=${u#git@github.com:}
      slug=${slug%.git}
      slug=${slug%/}
      ;;
    ssh://*)
      u=${u#ssh://}
      u=${u#git@}
      case "$u" in
        github.com/*) slug=${u#github.com/} ;;
        github.com:*) slug=${u#github.com:} ;;
        *) return 1 ;;
      esac
      slug=${slug%.git}
      slug=${slug%/}
      ;;
    http://*|https://*)
      u=${u#*://}
      authority=${u%%/*}
      path=${u#*/}
      case "$authority" in
        *@*) authority=${authority#*@} ;;
      esac
      host=${authority%%:*}
      [ "$host" = github.com ] || return 1
      [ -n "$path" ] || return 1
      slug=$path
      slug=${slug%.git}
      slug=${slug%/}
      ;;
    *)
      return 1
      ;;
  esac
  [ -n "$slug" ] && [[ "$slug" == */* ]] || return 1
  printf '%s' "$slug"
}

remote_is_disposable_file() {
  case "$1" in
    file:*|/*) return 0 ;;
    *) return 1 ;;
  esac
}

canonical_file_remote() {
  local u=$1 dir base
  case "$u" in
    file:*) u=${u#file:} ;;
    /*) ;;
    *) return 1 ;;
  esac
  dir=$(cd -P "$(dirname "$u")" 2>/dev/null && pwd -P) || return 1
  base=$(basename "$u")
  printf '%s/%s' "$dir" "$base"
}

validate_resolved_remote_url() {
  local u=$1 fetch_url=$2 disposable=$3 slug canon_fetch canon_u
  case "$u" in
    file:*|/*)
      if [ "$disposable" != 1 ] || [ "${COORDINATOR_PUBLICATION_FIXTURE_ORIGIN:-}" != 1 ]; then
        die "origin remote is not a GitHub repository (fixture seam disabled)"
      fi
      canon_fetch=$(canonical_file_remote "$fetch_url") || die "cannot canonicalize origin fetch URL"
      canon_u=$(canonical_file_remote "$u") || die "cannot canonicalize origin remote URL"
      [ "$canon_u" = "$canon_fetch" ] \
        || die "origin push URL does not match fetch URL for disposable remotes"
      ;;
    *)
      slug=$(origin_slug_from_url "$u") || die "cannot derive owner/name from origin remote (URL redacted)"
      [ "$slug" = "$want_repo" ] || die "origin remote owner/name ($slug) does not match --repo $want_repo"
      ;;
  esac
}

assert_repo_matches_origin() {
  local fetch_url disposable=0 u push_urls_tmp push_ec
  fetch_url=$(git -C "$worktree" remote get-url origin 2>/dev/null) || die "worktree has no origin remote"
  remote_is_disposable_file "$fetch_url" && disposable=1
  validate_resolved_remote_url "$fetch_url" "$fetch_url" "$disposable"
  push_urls_tmp=$(mktemp "${TMPDIR:-/tmp}/cp-push-urls.XXXXXX")
  push_ec=0
  git -C "$worktree" remote get-url --push --all origin >"$push_urls_tmp" 2>/dev/null || push_ec=$?
  if [ "$push_ec" -ne 0 ] || [ ! -s "$push_urls_tmp" ]; then
    rm -f "$push_urls_tmp"
    die "cannot resolve effective origin push URLs"
  fi
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    validate_resolved_remote_url "$u" "$fetch_url" "$disposable"
  done < "$push_urls_tmp"
  rm -f "$push_urls_tmp"
}

receipt_scalar_ok() {
  local field=$1 val=$2
  case "$field" in
    repo) [[ "$val" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ;;
    branch)
      [[ "$val" =~ ^[A-Za-z0-9._/@+-]+$ ]] && [[ "$val" != *'$('* ]] && [[ "$val" != *'`'* ]] \
        && [[ "$val" != *'@{'* ]]
      ;;
    head_sha) [[ "$val" =~ ^[0-9a-f]{40}$ ]] ;;
    push_ok) [ "$val" = 0 ] || [ "$val" = 1 ] ;;
    pr_url) [ -z "$val" ] || [[ "$val" =~ ^https://[^[:space:]]+$ ]] ;;
    pr_number) [ -z "$val" ] || [[ "$val" =~ ^[0-9]+$ ]] ;;
    *) return 1 ;;
  esac
}

read_receipt_file() {
  rec_repo="" rec_branch="" rec_head_sha="" rec_push_ok="" rec_pr_url="" rec_pr_number=""
  local line key val seen_repo=0 seen_branch=0 seen_head=0 seen_push=0 seen_purl=0 seen_pnum=0
  [ -f "$receipt" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      repo=*)
        [ "$seen_repo" = 0 ] || die "duplicate receipt field repo"
        seen_repo=1
        val=${line#repo=}
        receipt_scalar_ok repo "$val" || die "malformed receipt field repo"
        rec_repo=$val
        ;;
      branch=*)
        [ "$seen_branch" = 0 ] || die "duplicate receipt field branch"
        seen_branch=1
        val=${line#branch=}
        receipt_scalar_ok branch "$val" || die "malformed receipt field branch"
        rec_branch=$val
        ;;
      head_sha=*)
        [ "$seen_head" = 0 ] || die "duplicate receipt field head_sha"
        seen_head=1
        val=${line#head_sha=}
        receipt_scalar_ok head_sha "$val" || die "malformed receipt field head_sha"
        rec_head_sha=$val
        ;;
      push_ok=*)
        [ "$seen_push" = 0 ] || die "duplicate receipt field push_ok"
        seen_push=1
        val=${line#push_ok=}
        receipt_scalar_ok push_ok "$val" || die "malformed receipt field push_ok"
        rec_push_ok=$val
        ;;
      pr_url=*)
        [ "$seen_purl" = 0 ] || die "duplicate receipt field pr_url"
        seen_purl=1
        val=${line#pr_url=}
        receipt_scalar_ok pr_url "$val" || die "malformed receipt field pr_url"
        rec_pr_url=$val
        ;;
      pr_number=*)
        [ "$seen_pnum" = 0 ] || die "duplicate receipt field pr_number"
        seen_pnum=1
        val=${line#pr_number=}
        receipt_scalar_ok pr_number "$val" || die "malformed receipt field pr_number"
        rec_pr_number=$val
        ;;
      *) die "unexpected receipt content; remove $receipt before publishing" ;;
    esac
  done < "$receipt"
  if [ "$seen_repo$seen_branch$seen_head$seen_push$seen_purl$seen_pnum" != 111111 ]; then
    die "incomplete receipt; remove $receipt before publishing"
  fi
}

fetch_verified_destination_main() {
  local fetch_ec=0 fetched_sha
  git -C "$worktree" fetch -q --no-tags --refmap= origin refs/heads/main 2>/dev/null || fetch_ec=$?
  if [ "$fetch_ec" -ne 0 ]; then
    die "cannot fetch destination main for environment file inspection"
  fi
  fetched_sha=$(git -C "$worktree" rev-parse --verify FETCH_HEAD 2>/dev/null) \
    || die "cannot verify fetched destination main"
  printf '%s' "$fetched_sha"
}

inspect_env_paths_in_publish_range() {
  local range=$1 path base history_tmp log_ec
  if ! git -C "$worktree" rev-parse "$range" >/dev/null 2>&1; then
    die "cannot inspect branch commits for environment files"
  fi
  history_tmp=$(mktemp "${TMPDIR:-/tmp}/cp-env-history.XXXXXX")
  log_ec=0
  git -C "$worktree" log --format= --name-only -z --diff-merges=combined "$range" >"$history_tmp" 2>/dev/null || log_ec=$?
  if [ "$log_ec" -ne 0 ]; then
    rm -f "$history_tmp"
    die "cannot inspect branch history for environment files"
  fi
  while IFS= read -r -d '' path || [ -n "${path:-}" ]; do
    [ -n "$path" ] || continue
    base=${path##*/}
    case "$base" in
      .env|.env.*)
        case "$base" in
          .env.example|.env.sample|.env.template|.env.dist) continue ;;
          .env.*.example) continue ;;
        esac
        die "tracked environment file in branch diff: $path"
        ;;
    esac
  done < "$history_tmp"
  rm -f "$history_tmp"
}

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/validate-publication-body.sh"
[ -f "$lib" ] || die "missing validate-publication-body.sh"

repo="" branch="" body_file="" title="" worktree=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --branch) branch="${2:-}"; shift 2 ;;
    --body-file) body_file="${2:-}"; shift 2 ;;
    --title) title="${2:-}"; shift 2 ;;
    --worktree) worktree="${2:-}"; shift 2 ;;
    --force) echo "coordinator-publication: refused: force push is forbidden" >&2; exit 1 ;;
    *) echo "coordinator-publication: refused: unknown argument $1" >&2; exit 1 ;;
  esac
done

[ -n "$repo" ] && [ -n "$branch" ] && [ -n "$body_file" ] || die "usage: coordinator-publication.sh --repo owner/name --branch <name> --body-file <path> [--title <title>] [--worktree <path>]"

case "$repo" in */*) ;; *) die "--repo must be owner/name" ;; esac

case "$branch" in
  main|master|staging|production) die "protected branch $branch cannot be published" ;;
esac
[[ "$branch" =~ ^refs/ ]] && die "pass a branch name, not a ref ($branch)"

bash "$lib" "$body_file" || exit 1

if [ -z "$worktree" ]; then
  worktree=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git worktree; pass --worktree"
fi
worktree=$(cd -P "$worktree" && pwd) || die "worktree not found: $worktree"

cur_branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null) || die "cannot read branch in $worktree"
[ "$cur_branch" = "$branch" ] || die "worktree is on $cur_branch but --branch $branch was given (never derive from upstream)"

if ! git -C "$worktree" check-ref-format --branch "refs/heads/$branch" >/dev/null 2>&1; then
  die "branch name is not a valid Git ref ($branch)"
fi
receipt_scalar_ok branch "$branch" || die "branch name is not receipt-safe ($branch)"

want_repo=$repo
want_branch=$branch
gh_qualified_repo="github.com/$want_repo"
want_head_sha=$(git -C "$worktree" rev-parse HEAD) || die "cannot read HEAD in $worktree"
head_sha=$want_head_sha

assert_repo_matches_origin

destination_main_sha=$(fetch_verified_destination_main)
publish_range="${destination_main_sha}..HEAD"
inspect_env_paths_in_publish_range "$publish_range"

git_path=$(git -C "$worktree" rev-parse --git-path coordinator-publication)
if [[ "$git_path" != /* ]]; then
  git_path="$worktree/$git_path"
fi
receipt_dir="$git_path"
mkdir -p "$receipt_dir"
receipt="$receipt_dir/receipt.env"
write_receipt() {
  local tmp="$receipt_dir/receipt.env.tmp.$$"
  receipt_scalar_ok repo "$want_repo" || die "internal receipt repo"
  receipt_scalar_ok branch "$want_branch" || die "internal receipt branch"
  receipt_scalar_ok head_sha "$want_head_sha" || die "internal receipt head_sha"
  {
    printf 'repo=%s\n' "$want_repo"
    printf 'branch=%s\n' "$want_branch"
    printf 'head_sha=%s\n' "$want_head_sha"
    receipt_scalar_ok push_ok "${push_ok:-0}" || die "internal receipt push_ok"
    receipt_scalar_ok pr_url "${pr_url:-}" || die "internal receipt pr_url"
    receipt_scalar_ok pr_number "${pr_number:-}" || die "internal receipt pr_number"
    printf 'push_ok=%s\n' "${push_ok:-0}"
    printf 'pr_url=%s\n' "${pr_url:-}"
    printf 'pr_number=%s\n' "${pr_number:-}"
  } > "$tmp"
  if [ "${COORDINATOR_PUBLICATION_TEST_STOP_BEFORE_MV:-}" = 1 ]; then
    die "test stop before receipt rename"
  fi
  mv "$tmp" "$receipt"
}

push_ok=0 pr_url="" pr_number=""
if [ -f "$receipt" ]; then
  read_receipt_file
  [ "$rec_repo" = "$want_repo" ] && [ "$rec_branch" = "$want_branch" ] && [ "$rec_head_sha" = "$want_head_sha" ] \
    || die "receipt head mismatch; remove $receipt before publishing a new head"
  push_ok=$rec_push_ok
  pr_url=$rec_pr_url
  pr_number=$rec_pr_number
fi

attempt=0
max_attempts=3

resolve_pr_from_github() {
  local json num url oid
  pr_url="" pr_number=""
  if find_existing_pr; then
    return 0
  fi
  json=$(gh pr view "$branch" --repo "$gh_qualified_repo" --json number,url,headRefOid,state 2>/dev/null) || return 1
  num=$(jq -r '.number // empty' <<<"$json")
  url=$(jq -r '.url // empty' <<<"$json")
  oid=$(jq -r '.headRefOid // empty' <<<"$json")
  state=$(jq -r '.state // empty' <<<"$json")
  [ "$state" = "OPEN" ] && [ "$oid" = "$head_sha" ] || return 1
  receipt_scalar_ok pr_number "$num" || return 1
  receipt_scalar_ok pr_url "$url" || return 1
  pr_number=$num
  pr_url=$url
  return 0
}

push_branch() {
  fetch_verified_destination_main >/dev/null

  local remote_sha
  git -C "$worktree" fetch -q origin "$branch" 2>/dev/null || true
  remote_sha=$(git -C "$worktree" rev-parse --verify "refs/remotes/origin/$branch" 2>/dev/null || true)
  if [ -n "$remote_sha" ] && [ "$remote_sha" = "$head_sha" ]; then
    push_ok=1
    write_receipt
    return 0
  fi
  if [ "$push_ok" = 1 ]; then
    if [ -z "$remote_sha" ] || [ "$remote_sha" != "$head_sha" ]; then
      push_ok=0
    else
      echo "coordinator-publication: push already recorded for $head_sha" >&2
      return 0
    fi
  fi
  if [ -n "$remote_sha" ] && [[ "$remote_sha" =~ ^[0-9a-f]{40}$ ]] \
    && ! git -C "$worktree" merge-base --is-ancestor "$remote_sha" "$head_sha" 2>/dev/null; then
    die "non-fast-forward push required; force push is forbidden"
  fi
  attempt=0
  while [ "$attempt" -lt "$max_attempts" ]; do
    attempt=$((attempt + 1))
    if git -C "$worktree" push -q origin "HEAD:refs/heads/$branch" 2>&1; then
      push_ok=1
      write_receipt
      return 0
    fi
    sleep 1
  done
  fail "git push failed after $max_attempts attempts"
}

find_existing_pr() {
  local json line num url oid
  json=$(gh pr list --repo "$gh_qualified_repo" --head "$branch" --base main --state open \
    --json number,url,headRefOid 2>/dev/null) || return 1
  [ -n "$json" ] && [ "$json" != "[]" ] || return 1
  while IFS= read -r line; do
    num=$(jq -r '.number // empty' <<<"$line")
    url=$(jq -r '.url // empty' <<<"$line")
    oid=$(jq -r '.headRefOid // empty' <<<"$line")
    [ -n "$num" ] && [ "$oid" = "$head_sha" ] || continue
    receipt_scalar_ok pr_number "$num" || continue
    receipt_scalar_ok pr_url "$url" || continue
    pr_number=$num
    pr_url=$url
    return 0
  done < <(jq -c '.[]' <<<"$json" 2>/dev/null)
  return 1
}

open_pr() {
  if find_existing_pr; then
    write_receipt
    echo "PUBLISHED $pr_url"
    return 0
  fi
  if [ -n "$pr_number" ] && [ -n "$pr_url" ]; then
    if gh pr view "$pr_number" --repo "$gh_qualified_repo" --json headRefOid,state --jq '.state + " " + .headRefOid' 2>/dev/null | grep -q "^OPEN $head_sha\$"; then
      echo "PUBLISHED $pr_url"
      return 0
    fi
  fi
  local pr_attempt=0 t
  [ -n "$title" ] || title="$branch"
  pr_attempt=0
  while [ "$pr_attempt" -lt "$max_attempts" ]; do
    pr_attempt=$((pr_attempt + 1))
    if gh pr create --repo "$gh_qualified_repo" --head "$branch" --base main --title "$title" --body-file "$body_file" >/dev/null 2>&1; then
      if ! resolve_pr_from_github; then
        fail "gh pr create succeeded but PR could not be resolved"
      fi
      write_receipt
      echo "PUBLISHED $pr_url"
      return 0
    fi
    if find_existing_pr; then
      receipt_scalar_ok pr_url "$pr_url" || fail "gh pr create left malformed PR URL in listing"
      write_receipt
      echo "PUBLISHED $pr_url"
      return 0
    fi
    sleep 1
  done
  fail "gh pr create failed after $max_attempts attempts (push_ok=$push_ok; resume with the same command)"
}

push_branch
open_pr
