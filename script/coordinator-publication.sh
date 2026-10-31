#!/usr/bin/env bash
# Coordinator publication: push an explicit engineering branch and open a PR from a body file.
# Usage:
#   coordinator-publication.sh --repo owner/name --branch <name> --body-file <path> [--title <title>] [--worktree <path>]
# Refuses protected branches, force push, tracked secret env files, and invalid PR bodies.
# Retries push and gh pr create at most three times; writes a receipt for idempotent resume.
set -euo pipefail

die() { echo "coordinator-publication: refused: $*" >&2; exit 1; }
fail() { echo "coordinator-publication: failed: $*" >&2; exit 1; }

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

want_repo=$repo
want_branch=$branch
want_head_sha=$(git -C "$worktree" rev-parse HEAD) || die "cannot read HEAD in $worktree"
head_sha=$want_head_sha

base_ref=origin/main
if ! git -C "$worktree" rev-parse "$base_ref" >/dev/null 2>&1; then
  base_ref=main
fi
if ! git -C "$worktree" rev-parse "$base_ref" >/dev/null 2>&1; then
  die "cannot resolve base ref for environment file inspection"
fi

env_diff=$(git -C "$worktree" diff --name-only "$base_ref...HEAD" 2>/dev/null) \
  || env_diff=$(git -C "$worktree" diff --name-only "$base_ref" HEAD 2>/dev/null) \
  || die "cannot inspect branch diff for environment files"

while IFS= read -r path; do
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
done <<<"$env_diff"

git_path=$(git -C "$worktree" rev-parse --git-path coordinator-publication)
if [[ "$git_path" != /* ]]; then
  git_path="$worktree/$git_path"
fi
receipt_dir="$git_path"
mkdir -p "$receipt_dir"
receipt="$receipt_dir/receipt.env"
write_receipt() {
  {
    printf 'repo=%q\n' "$want_repo"
    printf 'branch=%q\n' "$want_branch"
    printf 'head_sha=%q\n' "$want_head_sha"
    printf 'push_ok=%q\n' "${push_ok:-0}"
    printf 'pr_url=%q\n' "${pr_url:-}"
    printf 'pr_number=%q\n' "${pr_number:-}"
  } > "$receipt"
}

push_ok=0 pr_url="" pr_number=""
if [ -f "$receipt" ]; then
  rec_repo="" rec_branch="" rec_head_sha="" rec_push_ok=0 rec_pr_url="" rec_pr_number=""
  # shellcheck disable=SC1090
  . "$receipt" 2>/dev/null || die "malformed receipt; remove $receipt before publishing"
  rec_repo=$repo
  rec_branch=$branch
  rec_head_sha=$head_sha
  rec_push_ok=${push_ok:-0}
  rec_pr_url=${pr_url:-}
  rec_pr_number=${pr_number:-}
  repo=$want_repo
  branch=$want_branch
  head_sha=$want_head_sha
  [ "$rec_repo" = "$want_repo" ] && [ "$rec_branch" = "$want_branch" ] && [ "$rec_head_sha" = "$want_head_sha" ] \
    || die "receipt head mismatch; remove $receipt before publishing a new head"
  push_ok=$rec_push_ok
  pr_url=$rec_pr_url
  pr_number=$rec_pr_number
fi

attempt=0
max_attempts=3

push_branch() {
  git -C "$worktree" fetch -q origin main 2>/dev/null || git -C "$worktree" fetch -q origin 2>/dev/null || true
  base_ref=origin/main
  git -C "$worktree" rev-parse "$base_ref" >/dev/null 2>&1 || base_ref=main

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
  json=$(gh pr list --repo "$repo" --head "$branch" --base main --state open \
    --json number,url,headRefOid 2>/dev/null) || return 1
  [ -n "$json" ] && [ "$json" != "[]" ] || return 1
  while IFS= read -r line; do
    num=$(jq -r '.number // empty' <<<"$line")
    url=$(jq -r '.url // empty' <<<"$line")
    oid=$(jq -r '.headRefOid // empty' <<<"$line")
    [ -n "$num" ] && [ "$oid" = "$head_sha" ] || continue
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
    if gh pr view "$pr_number" --repo "$repo" --json headRefOid,state --jq '.state + " " + .headRefOid' 2>/dev/null | grep -q "^OPEN $head_sha\$"; then
      echo "PUBLISHED $pr_url"
      return 0
    fi
  fi
  local pr_attempt=0 t
  [ -n "$title" ] || title="$branch"
  while [ "$pr_attempt" -lt "$max_attempts" ]; do
    pr_attempt=$((pr_attempt + 1))
    if out=$(gh pr create --repo "$repo" --head "$branch" --base main --title "$title" --body-file "$body_file" 2>&1); then
      pr_url=$out
      find_existing_pr || true
      if [ -z "$pr_number" ]; then
        pr_number=$(gh pr view "$branch" --repo "$repo" --json number --jq .number 2>/dev/null || true)
      fi
      if [ -z "$pr_number" ] || [ -z "$pr_url" ]; then
        fail "gh pr create succeeded but PR could not be resolved"
      fi
      write_receipt
      echo "PUBLISHED $pr_url"
      return 0
    fi
    if find_existing_pr; then
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
