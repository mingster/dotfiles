#!/usr/bin/env bash
# The Tech Lead's only way to merge a reviewed PR.
# Usage: lead-merge.sh --repo owner/name --pr N --head <sha>
set -euo pipefail

die() { echo "lead-merge: refused: $*" >&2; exit 1; }

repo="" pr="" head=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --pr) pr="${2:-}"; shift 2 ;;
    --head) head="${2:-}"; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
[ -n "$repo" ] && [ -n "$pr" ] && [ -n "$head" ] || die "usage: lead-merge.sh --repo owner/name --pr N --head <sha>"
case "$pr" in *[!0-9]*) die "--pr must be a number" ;; esac

# 1. Caller is the lead. Orca sets no role variable (ORCA_TERMINAL_HANDLE and
# ORCA_AGENT_SESSION_ID exist for every agent), so the worktree name is the check.
top=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git worktree"
top=$(cd -P "$top" && pwd)
root=$(cd -P "$HOME/orca/workspaces" 2>/dev/null && pwd) || die "no $HOME/orca/workspaces"
case "$top" in "$root"/*) ;; *) die "worktree is not under $root" ;; esac
case "$(basename "$top")" in lead-*) ;; *) die "only the lead worktree (lead-*) may merge" ;; esac

# 2. PR state
info=$(gh pr view "$pr" --repo "$repo" --json state,baseRefName,headRefName,headRefOid,mergeable,url,files,body,comments,baseRefOid) \
  || die "cannot read PR $pr"
field() { jq -r "$1" <<<"$info"; }
[ "$(field .state)" = OPEN ] || die "PR $pr is not open"
[ "$(field .baseRefName)" = main ] || die "PR $pr base is not main"
[ "$(field .headRefOid)" = "$head" ] || die "PR $pr head is $(field .headRefOid), not $head"
[ "$(field .mergeable)" = MERGEABLE ] || die "PR $pr is not MERGEABLE"

# 4. Head branch
case "$(field .headRefName)" in main|staging|production) die "head branch $(field .headRefName) is not mergeable here" ;; esac

# 3. Owner only paths
while IFS= read -r f; do
  case "$f" in
    .claude/hooks/*|.claude/settings.json|bin/owner-approve.sh|.codex/*|*/.codex/*|*.rules)
      die "PR touches $f, which waits for the owner through Elon" ;;
  esac
done < <(jq -r '.files[].path' <<<"$info")
diff=$(gh pr diff "$pr" --repo "$repo") || die "cannot read diff of PR $pr"
if awk '/^\+\+\+ /{intent = ($2 ~ /^b\/docs\/intent\//)} intent && /^\+Status:.*Accepted/{found=1} END{exit !found}' <<<"$diff"; then
  die "PR accepts an intent under docs/intent/, which waits for the owner through Elon"
fi

# 5. Verification is required even for documentation changes.
field .body | grep -qE '^## Verification[[:space:]]*$' || die "missing ## Verification heading"
docs_only=true
while IFS= read -r f; do
  case "$f" in
    .claude/agents/*|*/.claude/agents/*) docs_only=false ;;
    docs/*|*.md|changelog.d/*) ;;
    *) docs_only=false ;;
  esac
done < <(jq -r '.files[].path' <<<"$info")

# Recompute both patches; never trust a patch-id asserted in a comment.
patch_id() {
  local sha="$1" base patch
  base=$(field .baseRefOid)
  [[ "$base" =~ ^[0-9a-f]{40}$ ]] || return 1
  for ref in "$base" "$sha"; do
    git cat-file -e "$ref^{commit}" 2>/dev/null || git fetch origin "$ref" >&2 || return 1
  done
  patch=$(git diff "$base...$sha" -- | git patch-id --stable) || return 1
  [ -n "$patch" ] || return 1
  awk 'NR == 1 {print $1}' <<<"$patch"
}
if [ "$docs_only" = false ]; then
  verified=false
  current_patch=""
  # Newest applicable verdict wins, including a FAIL after an earlier PASS.
  while IFS= read -r line; do
    if [[ "$line" =~ ^Verdict:\ (PASS\+NOTES|PASS|FAIL)\ head=([0-9a-f]{40})$ ]]; then
      verdict="${BASH_REMATCH[1]}"; verdict_head="${BASH_REMATCH[2]}"
      applies=false
      if [ "$verdict_head" = "$head" ]; then
        applies=true
      else
        current_patch="${current_patch:-$(patch_id "$head")}" || die "cannot compute head patch-id for verdict"
        old_patch=$(patch_id "$verdict_head") || continue
        [ "$old_patch" != "$current_patch" ] || applies=true
      fi
      if [ "$applies" = true ]; then
        [ "$verdict" = FAIL ] || verified=true
        break
      fi
    fi
  done < <(jq -r '.comments | reverse[] | .body | split("\n")[0]' <<<"$info")
  [ "$verified" = true ] || die "missing passing verifier verdict for current head or stable patch-id"
fi

merge() { gh pr merge "$pr" --repo "$repo" --merge --match-head-commit "$head"; }
if ! out=$(merge 2>&1); then
  out=$(merge 2>&1) || { echo "lead-merge: merge failed: $out" >&2; exit 1; }
fi

final=$(gh pr view "$pr" --repo "$repo" --json state,mergeCommit,url) || { echo "lead-merge: cannot confirm merge of PR $pr" >&2; exit 1; }
[ "$(jq -r .state <<<"$final")" = MERGED ] || { echo "lead-merge: PR $pr is not MERGED after merge" >&2; exit 1; }
echo "MERGED $(jq -r .url <<<"$final")"
