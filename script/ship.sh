#!/usr/bin/env bash
# Ship one verified PR with squash merge and read-back confirmation (pstack Shipping run).
# Usage: ship.sh --repo <owner/name> --pr <n> [--dry-run]
set -euo pipefail

ship_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
refuse() { echo "ship: refused: $*" >&2; exit 1; }
die() { refuse "$*"; }

# shellcheck disable=SC1091
. "$ship_dir/lib/protected-paths.sh"

repo="" pr="" dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || refuse "--repo needs a value"; repo=$2; shift 2 ;;
    --pr) [ $# -ge 2 ] || refuse "--pr needs a value"; pr=$2; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) refuse "unknown argument: $1" ;;
  esac
done
[ -n "$repo" ] && [[ "$pr" =~ ^[0-9]+$ ]] || refuse "usage: ship.sh --repo <owner/name> --pr <n> [--dry-run]"

info=$(gh pr view "$pr" --repo "$repo" --json state,isDraft,mergeable,headRefOid,baseRefOid,comments,statusCheckRollup) \
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

# 3. Newest Verdict comment (exact post-verdict.sh first-line shape) is PASS or PASS+NOTES.
verdict_status="" verdict_head=""
while IFS= read -r flagged && IFS= read -r line; do
  if [[ "$line" =~ ^Verdict:\ (PASS\+NOTES|PASS|FAIL)\ head=([0-9a-f]{40})\ verifier=([a-zA-Z0-9_-]+)\ author=([a-zA-Z0-9_-]+)$ ]]; then
    if [ "$flagged" = true ] && [ "${BASH_REMATCH[1]}" != FAIL ]; then continue; fi
    verifier="${BASH_REMATCH[3]}"
    [ "$verifier" != "${BASH_REMATCH[4]}" ] || refuse "author cannot supply verifier verdict"
    if ! worker_out=$("${ORCA_CLI_COMMAND:-orca}" orchestration worker-show --dispatch "$verifier" --json 2>/dev/null) \
      || ! jq -e '.ok == true' <<<"$worker_out" >/dev/null 2>&1; then
      refuse "verdict verifier $verifier is not a known dispatch"
    fi
    verdict_status="${BASH_REMATCH[1]}"
    verdict_head="${BASH_REMATCH[2]}"
    break
  fi
done < <(jq -r '[.comments[]? | {f: ((.includesCreatedEdit // false) or (.isMinimized // false)), l: (.body // "" | split("\n")[0])}] | reverse[] | .f, .l' <<<"$info")
[ -n "$verdict_status" ] || refuse "missing Verdict comment on PR $pr"
case "$verdict_status" in
  PASS|PASS+NOTES) ;;
  *) refuse "newest Verdict on PR $pr is $verdict_status" ;;
esac

# 4. Verdict head equals current head, or git patch-id --stable of merge-base(origin/main, head)..head matches.
main_fetched=false
patch_id() { # <sha>
  local sha=$1 base
  [ "$main_fetched" = true ] || { git fetch origin main >&2 2>/dev/null || true; main_fetched=true; }
  git cat-file -e "$sha^{commit}" 2>/dev/null || git fetch origin "$sha" >&2 || return 1
  base=$(git merge-base origin/main "$sha" 2>/dev/null) || return 1
  git diff "$base..$sha" | git patch-id --stable | awk '{print $1}'
}
verdict_carry() { # <verdict_head> <current_head>
  local pid_v pid_h
  pid_v=$(patch_id "$1") || return 1
  pid_h=$(patch_id "$2") || return 1
  [ -n "$pid_v" ] && [ "$pid_v" = "$pid_h" ]
}
if [ "$verdict_head" != "$head" ]; then
  verdict_carry "$verdict_head" "$head" \
    || refuse "verdict head ${verdict_head:0:12} patch-id does not match current head ${head:0:12}"
fi

# 5. Protected paths (shared with lead-merge.sh: owner-only, Owner-approved trailer, Countersign).
file_pages=$(gh api --paginate "repos/$repo/pulls/$pr/files") || refuse "cannot read PR $pr files"
# shellcheck disable=SC2034
files=$(jq -s '[.[][] | (.filename // .path)]' <<<"$file_pages") || refuse "invalid PR $pr file list"
# shellcheck disable=SC2034
diff=$(gh pr diff "$pr" --repo "$repo") || refuse "cannot read diff of PR $pr"
PROTECTED_PATHS_QUIET_TRIGGERS=1 check_protected_paths

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
