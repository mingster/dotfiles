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
info=$(gh pr view "$pr" --repo "$repo" --json state,baseRefName,headRefName,headRefOid,mergeable,url,changedFiles,body,comments,baseRefOid) \
  || die "cannot read PR $pr"
field() { jq -r "$1" <<<"$info"; }
[ "$(field .state)" = OPEN ] || die "PR $pr is not open"
[ "$(field .baseRefName)" = main ] || die "PR $pr base is not main"
[ "$(field .headRefOid)" = "$head" ] || die "PR $pr head is $(field .headRefOid), not $head"
[ "$(field .mergeable)" = MERGEABLE ] || die "PR $pr is not MERGEABLE"

# 4. Head branch
case "$(field .headRefName)" in main|staging|production) die "head branch $(field .headRefName) is not mergeable here" ;; esac

# gh pr view truncates files at 100; every path gate shares this complete list.
file_pages=$(gh api --paginate "repos/$repo/pulls/$pr/files") || die "cannot read complete PR files"
files=$(jq -s '[.[][] | .filename]' <<<"$file_pages") || die "invalid PR file inventory"
[ "$(jq length <<<"$files")" = "$(field .changedFiles)" ] || die "PR file count differs from changed_files"

# 3. Owner only paths
while IFS= read -r f; do
  case "$f" in
    .claude/hooks/*|.claude/settings.json|bin/owner-approve.sh|.codex/*|*/.codex/*|*.rules)
      die "PR touches $f, which waits for the owner through Elon" ;;
  esac
done < <(jq -r '.[]' <<<"$files")
diff=$(gh pr diff "$pr" --repo "$repo") || die "cannot read diff of PR $pr"
if awk '/^\+\+\+ /{intent = ($2 ~ /^b\/docs\/intent\//)} intent && /^\+Status:.*Accepted/{found=1} END{exit !found}' <<<"$diff"; then
  die "PR accepts an intent under docs/intent/, which waits for the owner through Elon"
fi

# 5. Verification is required even for documentation changes.
# Normalize heading case, spacing and trailing punctuation once for both gates.
normalized_body=$(field .body | awk '
/^[[:blank:]]*#+[[:space:]]/ {
  heading=$0; sub(/^[[:blank:]]*/, "", heading)
  hashes=heading; sub(/[[:space:]].*$/, "", hashes)
  title=heading; sub(/^#+[[:space:]]+/, "", title)
  gsub(/[[:space:]]+/, " ", title)
  sub(/[[:space:][:punct:]]+$/, "", title)
  print hashes " " tolower(title); next
}
{print}')
grep -qE '^## verification$' <<<"$normalized_body" || die "missing ## Verification heading"
if grep -qiE '^#{1,6} test plan$' <<<"$normalized_body"; then die "Test plan heading is forbidden"; fi
bullet_count=$(awk '/^## verification$/ {inside=1; next} inside && /^#+ / {inside=0} inside && /^[[:space:]]*[-*+] / {n++} END {print n+0}' <<<"$normalized_body")
[ "$bullet_count" -ge 1 ] && [ "$bullet_count" -le 3 ] || die "Verification needs 1 to 3 run and outcome bullets"
check_body=$(jq -r --arg head "$head" '[.comments[].body | select((split("\n")[0]) == ("Checks: PASS head="+$head) or (split("\n")[0]) == ("Checks: FAIL head="+$head))] | last // ""' <<<"$info")
checks=${check_body%%$'\n'*}
[ "$checks" = "Checks: PASS head=$head" ] || die "missing current-head Checks: PASS"
unchecked=false
if grep -q '^Unchecked paths: .' <<<"$check_body"; then unchecked=true; fi
docs_only=true
while IFS= read -r f; do
  case "$f" in
    .claude/agents/*|*/.claude/agents/*|.agents/skills/*|*/.agents/skills/*) docs_only=false ;;
    docs/*|*.md|changelog.d/*) ;;
    *) docs_only=false ;;
  esac
done < <(jq -r '.[]' <<<"$files")

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
verdict_head="$head"
if [ "$docs_only" = false ] || [ "$unchecked" = true ]; then
  verified=false
  current_patch=""
  # Newest applicable verdict wins, including a FAIL after an earlier PASS.
  while IFS= read -r encoded; do
    comment=$(jq -r '@base64d' <<<"\"$encoded\"")
    line=${comment%%$'\n'*}
    if [[ "$line" =~ ^Verdict:\ (PASS\+NOTES|PASS|FAIL)\ head=([0-9a-f]{40})\ verifier=([a-zA-Z0-9_-]+)\ author=([a-zA-Z0-9_-]+)$ ]]; then
      verdict="${BASH_REMATCH[1]}"; candidate_head="${BASH_REMATCH[2]}"
      [ "${BASH_REMATCH[3]}" != "${BASH_REMATCH[4]}" ] || die "author cannot supply verifier verdict"
      applies=false
      if [ "$candidate_head" = "$head" ]; then
        applies=true
      else
        current_patch="${current_patch:-$(patch_id "$head")}" || die "cannot compute head patch-id for verdict"
        old_patch=$(patch_id "$candidate_head") || continue
        [ "$old_patch" != "$current_patch" ] || applies=true
      fi
      if [ "$applies" = true ]; then
        verdict_head="$candidate_head"
        if [ "$unchecked" = true ] && ! grep -qi 'unchecked' <<<"$comment"; then
          die "verdict must cover unchecked paths in its live lane"
        fi
        [ "$verdict" = FAIL ] || verified=true
        break
      fi
    fi
  done < <(jq -r '.comments | reverse[] | .body | @base64' <<<"$info")
  [ "$verified" = true ] || die "missing passing verifier verdict for current head or stable patch-id"
fi

# Gate changes need a fresh, head-bound countersign from Elon.
triggers=$(awk '/^\+[^+]/ && /\.skip\(|\.only\(|test\.todo|(^|[^A-Za-z0-9_.])xit\(|eslint-disable|biome-ignore|@ts-ignore|@ts-expect-error/ {print}' <<<"$diff")
while IFS= read -r f; do
  case "$f" in
    .agents/head-checks.conf|*/.agents/head-checks.conf|script/lead-merge.sh|*/script/lead-merge.sh)
      gate_lines=$(awk -v path="$f" '/^\+\+\+ / {active=($0 == "+++ b/" path)} active && /^[+-]/ && !/^\+\+\+ / && !/^--- / {print path ":" $0}' <<<"$diff")
      triggers="${triggers}${triggers:+$'\n'}${gate_lines:-gate definition changed: $f}" ;;
  esac
done < <(jq -r '.[]' <<<"$files")
if [ -n "$triggers" ]; then
  echo "lead-merge: countersign triggers:" >&2
  printf '%s\n' "$triggers" >&2
  jq -e --arg prefix "Countersign: Elon head=$head reason=" \
    'any(.comments[].body; startswith($prefix) and (.[($prefix|length):] | test("[^[:space:]]")))' <<<"$info" >/dev/null \
    || die "missing Countersign: Elon for current head"
fi

# Fetch immediately before merge; any shared changed path needs a new exact-head run.
git fetch origin main >&2 || die "cannot fetch main; rebase and rerun head-checks"
ancestor=$(git merge-base "$(field .baseRefOid)" "$verdict_head") || die "cannot find merge base; rebase and rerun head-checks"
trunk_files=$(git diff --name-only "$ancestor" origin/main --) || die "cannot inspect trunk drift"
while IFS= read -r f; do
  if grep -Fxq -- "$f" <<<"$trunk_files"; then die "trunk changed $f; rebase and rerun head-checks"; fi
done < <(jq -r '.[]' <<<"$files")

merge() { gh pr merge "$pr" --repo "$repo" --merge --match-head-commit "$head"; }
if ! out=$(merge 2>&1); then
  out=$(merge 2>&1) || { echo "lead-merge: merge failed: $out" >&2; exit 1; }
fi

final=$(gh pr view "$pr" --repo "$repo" --json state,mergeCommit,url) || { echo "lead-merge: cannot confirm merge of PR $pr" >&2; exit 1; }
[ "$(jq -r .state <<<"$final")" = MERGED ] || { echo "lead-merge: PR $pr is not MERGED after merge" >&2; exit 1; }
merge_sha=$(jq -r '.mergeCommit.oid // empty' <<<"$final")
[ -n "$merge_sha" ] || die "MERGED read-back has no merge commit"
echo "MERGED $(jq -r .url <<<"$final") $merge_sha"
