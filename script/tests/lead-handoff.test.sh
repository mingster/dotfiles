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

printf 'PASS: %s tests\n' "$tests"
