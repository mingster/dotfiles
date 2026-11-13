#!/usr/bin/env bash
# Post a Verdict comment in the exact form ship.sh parses, so nobody types the first line by hand.
# Usage: post-verdict.sh --repo owner/name --pr N --result PASS|PASS+NOTES|FAIL --head <40 hex sha>
#        --verifier <dispatch id> --author <dispatch id|unknown|coordinator id> [--command "<cmd>"]
#        [--agent <agent> --model <model>] [--correction "<comment url|id>"] [--notes "<text>"] [--print]
# --agent and --model record the verifier's own agent and model on the Verdict line (together, or neither).
# ship.sh needs them and refuses a verifier whose agent and model match the builder's.
# --author other than ctx_* or unknown must be listed in coordinator_ids of script/ship.local.json.
# --print shows the comment body and posts nothing. The comment is always new: an edit never counts.
# A FAIL needs --command and at least one "- [ ]" fix line in --notes. PASS does not.
set -euo pipefail

die() { echo "post-verdict: $*" >&2; exit 1; }

repo="" pr="" result="" head="" verifier="" author="" command="" notes="" correction="" agent="" model="" print_only=false
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--pr|--result|--head|--verifier|--author|--command|--notes|--agent|--model|--correction|--corrects|--supersedes)
      [ $# -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --repo) repo=$2 ;; --pr) pr=$2 ;; --result) result=$2 ;; --head) head=$2 ;;
        --verifier) verifier=$2 ;; --author) author=$2 ;; --command) command=$2 ;; --notes) notes=$2 ;; --agent) agent=$2 ;; --model) model=$2 ;;
        --correction|--corrects|--supersedes) correction=$2 ;;
      esac
      shift 2 ;;
    --print) print_only=true; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$print_only" = true ] || { [ -n "$repo" ] && [[ "$pr" =~ ^[0-9]+$ ]]; } || die "--repo and a numeric --pr are required"
[[ "$result" =~ ^(PASS\+NOTES|PASS|FAIL)$ ]] || die "--result must be PASS, PASS+NOTES or FAIL"
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || die "--head must be a full 40 character sha"
[[ "$verifier" =~ ^[a-zA-Z0-9_-]+$ ]] || die "--verifier must be a dispatch or coordinator id"
if [[ "$verifier" != ctx_* ]]; then
  dir=$(cd "$(dirname "$0")" && pwd)
  cfg=$(python3 "$dir/apply-local-overlay.py" "$dir/ship.config.example.json" "$dir/ship.local.json") \
    || die "cannot read local coordinator config"
  jq -e --arg v "$verifier" '(.coordinator_ids // []) | index($v) != null' <<<"$cfg" >/dev/null \
    || die "--verifier $verifier is not a dispatch id or a configured coordinator id"
fi
[[ "$author" =~ ^[a-zA-Z0-9_-]+$ ]] || die "--author must be a dispatch id, unknown, or a configured coordinator id"
if [ "$author" != unknown ] && [[ "$author" != ctx_* ]]; then
  dir=$(cd "$(dirname "$0")" && pwd)
  cfg=$(python3 "$dir/apply-local-overlay.py" "$dir/ship.config.example.json" "$dir/ship.local.json") \
    || die "cannot read local coordinator config"
  jq -e --arg a "$author" '(.coordinator_ids // []) | index($a) != null' <<<"$cfg" >/dev/null \
    || die "--author $author is not a dispatch id, unknown, or a configured coordinator id (set coordinator_ids in script/ship.local.json)"
fi
[ "$verifier" != "$author" ] || die "the author cannot supply the verifier verdict"
[ -z "$agent$model" ] || { [[ "$agent" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$model" =~ ^[A-Za-z0-9._:-]+$ ]]; } \
  || die "--agent and --model go together and may hold only letters, digits and . _ : -"
[[ "$command" != *$'\n'* ]] || die "--command must be one line"
[[ "$correction" != *$'\n'* ]] || die "--correction must be one line"
if [ "$result" = FAIL ]; then
  [ -n "${command//[[:space:]]/}" ] || die "FAIL needs --command"
  has_fix=false
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [[ "$line" =~ ^[[:space:]]*-[[:space:]]\[[[:space:]]\][[:space:]]+[^[:space:]] ]] && has_fix=true
  done <<<"$notes"
  [ "$has_fix" = true ] || die "FAIL needs a - [ ] fix line"
fi

body="Verdict: $result head=$head verifier=$verifier author=$author"
[ -z "$agent" ] || body+=" agent=$agent model=$model"
[ -z "$command" ] || body+=$'\n'"Command: $command"
[ -z "$correction" ] || body+=$'\n'"Correction: $correction"
[ -z "$notes" ] || body+=$'\n\n'"$notes"

if [ "$print_only" = true ]; then printf '%s\n' "$body"; exit 0; fi
printf '%s\n' "$body" | gh pr comment "$pr" --repo "$repo" --body-file - >/dev/null
status_state=failure; [ "$result" = FAIL ] || status_state=success
gh api -X POST "repos/$repo/statuses/$head" -f state="$status_state" -f context=review -f description="Verdict: $result ($verifier)" >/dev/null
echo "post-verdict: posted $result for PR $pr at ${head:0:12}"
