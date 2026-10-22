#!/usr/bin/env bash
# Start the cross family reviewer for a coding worker_done.
# on-worker-done.sh --repo owner/name --pr N --head SHA --author-family claude|cursor|antigravity
#                   --worktree PATH --run RUN [--author-dispatch ID] [--dry-run]
# Prints the worker-start command (runs it unless --dry-run). Writes the reviewer brief to a temp file.
# Env: ON_WORKER_DONE_USAGE_GATE overrides the usage-gate.py path (tests).
set -u
usage() { echo "usage: ${0##*/} --repo owner/name --pr N --head SHA --author-family claude|cursor|antigravity --worktree PATH --run RUN [--author-dispatch ID] [--dry-run]" >&2; exit 2; }
repo="" pr="" head="" fam="" wt="" run="" author_dispatch=unknown dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --repo|--pr|--head|--author-family|--worktree|--run|--author-dispatch)
      [ $# -ge 2 ] || usage
      case "$1" in
        --repo) repo=$2 ;; --pr) pr=$2 ;; --head) head=$2 ;; --author-family) fam=$2 ;;
        --worktree) wt=$2 ;; --run) run=$2 ;; --author-dispatch) author_dispatch=$2 ;;
      esac; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$repo" ] && [ -n "$pr" ] && [ -n "$head" ] && [ -n "$fam" ] && [ -n "$wt" ] && [ -n "$run" ] || usage
[[ "$pr" =~ ^[0-9]+$ ]] || usage
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$author_dispatch" =~ ^[a-zA-Z0-9_-]+$ ]] || usage
case "$fam" in claude|cursor|antigravity) ;; *) usage ;; esac

gate=${ON_WORKER_DONE_USAGE_GATE:-$HOME/dotfiles/script/usage-gate.py}
# usage-gate knows two families. Cursor authors run GPT models; Antigravity has no single family, so no avoid flag.
case "$fam" in claude) avoid="--avoid-family claude" ;; cursor) avoid="--avoid-family gpt" ;; *) avoid="" ;; esac
flags=""
if [ -x "$gate" ] || [ -f "$gate" ]; then
  # shellcheck disable=SC2086
  flags=$("$gate" pick --role reviewer $avoid 2>/dev/null) || flags=""
fi
if [ -z "$flags" ]; then
  echo "cross-family unavailable" >&2
  flags="--agent claude --model opus --effort high"
fi

brief=$(mktemp "${TMPDIR:-/tmp}/reviewer-brief.XXXXXX")
cat > "$brief" <<EOF
Review PR #$pr in $repo at head $head. You did not write this code, so review it cold.
Check the diff against the PR's spec and the repo's standards. Run the tests.
Post exactly one PR comment whose first line is:
Verdict: PASS|PASS+NOTES|FAIL head=$head verifier=<your dispatch id> author=$author_dispatch
Use one of PASS, PASS+NOTES or FAIL. Put findings on the lines after it. Do not edit the PR.
EOF

cmd="orca orchestration worker-start --run $run --spec \"\$(cat $brief)\" --worktree path:$wt --task-title \"reviewer - PR $pr\" $flags --json"
echo "$cmd"
[ "$dry" = 1 ] && exit 0
# shellcheck disable=SC2086
exec orca orchestration worker-start --run "$run" --spec "$(cat "$brief")" --worktree "path:$wt" --task-title "reviewer - PR $pr" $flags --json
