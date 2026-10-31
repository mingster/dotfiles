#!/usr/bin/env bash
# Post a Verdict comment in the exact form lead-merge.sh parses, so nobody types the first line by hand.
# Usage: post-verdict.sh --repo owner/name --pr N --result PASS|PASS+NOTES|FAIL --head <40 hex sha>
#        --verifier <dispatch id> --author <dispatch id|unknown|coordinator id> [--command "<cmd>"]
#        [--correction "<comment url|id>"] [--notes "<text>"] [--print]
# --print shows the comment body and posts nothing. The comment is always new: an edit never counts.
set -euo pipefail

die() { echo "post-verdict: $*" >&2; exit 1; }

repo="" pr="" result="" head="" verifier="" author="" command="" notes="" correction="" print_only=false
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--pr|--result|--head|--verifier|--author|--command|--notes|--correction|--corrects|--supersedes)
      [ $# -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --repo) repo=$2 ;; --pr) pr=$2 ;; --result) result=$2 ;; --head) head=$2 ;;
        --verifier) verifier=$2 ;; --author) author=$2 ;; --command) command=$2 ;; --notes) notes=$2 ;;
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
[[ "$verifier" =~ ^[a-zA-Z0-9_-]+$ ]] || die "--verifier must be a dispatch id"
[[ "$author" =~ ^[a-zA-Z0-9_-]+$ ]] || die "--author must be a dispatch id, unknown, or a configured coordinator id"
[ "$verifier" != "$author" ] || die "the author cannot supply the verifier verdict"
[[ "$command" != *$'\n'* ]] || die "--command must be one line"
[[ "$correction" != *$'\n'* ]] || die "--correction must be one line"

body="Verdict: $result head=$head verifier=$verifier author=$author"
[ -z "$command" ] || body+=$'\n'"Command: $command"
[ -z "$correction" ] || body+=$'\n'"Correction: $correction"
[ -z "$notes" ] || body+=$'\n\n'"$notes"

if [ "$print_only" = true ]; then printf '%s\n' "$body"; exit 0; fi
printf '%s\n' "$body" | gh pr comment "$pr" --repo "$repo" --body-file - >/dev/null
echo "post-verdict: posted $result for PR $pr at ${head:0:12}"
