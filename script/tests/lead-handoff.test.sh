#!/usr/bin/env bash
# lead-handoff.sh appends one line per handoff and refuses incomplete entries.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export LEAD_HANDOFFS_FILE="$tmp/lead-handoffs"
tests=0

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
run() { "$root/script/lead-handoff.sh" "$@" 2>/dev/null; }

full=(--branch feature-a --head abc123 --remainder 'two tickets left' --dispatch-ids 'd1,d2')

run "${full[@]}" || fail 'good entry exited nonzero'
[[ $(wc -l <"$LEAD_HANDOFFS_FILE") -eq 1 ]] || fail 'good entry did not write one line'
for want in feature-a abc123 'two tickets left' 'd1,d2'; do
  grep -qF -- "$want" "$LEAD_HANDOFFS_FILE" || fail "good entry missing $want"
done
tests=$((tests + 1))

for field in branch head remainder dispatch-ids; do
  for mode in missing empty; do
    rm -f "$LEAD_HANDOFFS_FILE"
    args=()
    for f in branch head remainder dispatch-ids; do
      if [[ $f != "$field" ]]; then
        case $f in
          branch) v=feature-a ;; head) v=abc123 ;; remainder) v=left ;; *) v=d1 ;;
        esac
        args+=(--"$f" "$v")
      elif [[ $mode == empty ]]; then
        args+=(--"$f" '')
      fi
    done
    if run "${args[@]}"; then fail "$mode $field exited zero"; fi
    [[ ! -s $LEAD_HANDOFFS_FILE ]] || fail "$mode $field wrote output"
    tests=$((tests + 1))
  done
done

rm -f "$LEAD_HANDOFFS_FILE"
run --branch first --head h1 --remainder r1 --dispatch-ids d1
run --branch second --head h2 --remainder r2 --dispatch-ids d2
[[ $(wc -l <"$LEAD_HANDOFFS_FILE") -eq 2 ]] || fail 'two entries are not two lines'
[[ $(sed -n 1p "$LEAD_HANDOFFS_FILE") == *first* && $(sed -n 2p "$LEAD_HANDOFFS_FILE") == *second* ]] || fail 'entries out of order'
tests=$((tests + 1))

# The log path can be an existing directory: write inside it, leave what is there alone.
export LEAD_HANDOFFS_FILE="$tmp/handoffs-dir"
mkdir "$LEAD_HANDOFFS_FILE"
echo keep >"$LEAD_HANDOFFS_FILE/old-entry"
run --branch dir-branch --head h3 --remainder r3 --dispatch-ids d3 || fail 'directory log path exited nonzero'
[[ -d $LEAD_HANDOFFS_FILE && $(cat "$LEAD_HANDOFFS_FILE/old-entry") == keep ]] || fail 'directory contents changed'
grep -qF dir-branch "$LEAD_HANDOFFS_FILE/handoffs.log" || fail 'entry not written inside the directory'
tests=$((tests + 1))

# The default path (no LEAD_HANDOFFS_FILE) is created as a directory on a fresh home, so it never
# blocks the handoff folder; running from another folder still works.
unset LEAD_HANDOFFS_FILE
fresh=$(mktemp -d)
(cd "$fresh" && HOME=$fresh "$root/script/lead-handoff.sh" --branch def-branch --head h4 --remainder r4 --dispatch-ids d4 2>/dev/null) \
  || fail 'default path on a fresh home exited nonzero'
[[ -d $fresh/.claude/state/lead-handoffs ]] || fail 'default path was not created as a directory'
grep -qF def-branch "$fresh/.claude/state/lead-handoffs/handoffs.log" || fail 'default entry not in the directory'
(cd "$fresh" && HOME=$fresh "$root/script/lead-handoff.sh" --branch def-two --head h5 --remainder r5 --dispatch-ids d5 2>/dev/null) \
  || fail 'second default entry exited nonzero'
[[ $(wc -l <"$fresh/.claude/state/lead-handoffs/handoffs.log") -eq 2 ]] || fail 'default directory did not append'
rm -rf "$fresh"
tests=$((tests + 1))

# LEAD_HANDOFFS_FILE keeps today's behaviour: a missing path stays a plain file.
export LEAD_HANDOFFS_FILE="$tmp/plain-file"
run --branch file-branch --head h6 --remainder r6 --dispatch-ids d6 || fail 'explicit file path exited nonzero'
[[ -f $LEAD_HANDOFFS_FILE ]] || fail 'explicit path is not a plain file'
tests=$((tests + 1))

printf 'PASS: %s tests\n' "$tests"
