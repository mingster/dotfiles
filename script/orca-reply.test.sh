#!/usr/bin/env bash
# Tests for orca-reply.sh with a fake orca CLI (no Orca server). bash 3.2 compatible.
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/calls"\n' "$tmp" > "$tmp/orca"
chmod +x "$tmp/orca"
export ORCA_CLI_COMMAND="$tmp/orca"
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

rm -f "$tmp/calls"; "$here/orca-reply.sh" --to term_a --id msg_1 --body hi > /dev/null; rc=$?
check "reply: replies to the id, then nudges the terminal" "$([ $rc = 0 ] && sed -n 1p "$tmp/calls" | grep -q 'orchestration reply --id msg_1 --body hi' && sed -n 2p "$tmp/calls" | grep -q 'terminal send --terminal term_a --text check your inbox --enter'; echo $?)"

rm -f "$tmp/calls"; "$here/orca-reply.sh" --to term_b --subject "batch ready" --body hi --from term_me > /dev/null; rc=$?
check "send: a new message to the terminal, then the nudge" "$([ $rc = 0 ] && sed -n 1p "$tmp/calls" | grep -q 'orchestration send --to term_b --subject batch ready --body hi --json --from term_me' && sed -n 2p "$tmp/calls" | grep -q 'terminal send --terminal term_b'; echo $?)"

rm -f "$tmp/calls"; "$here/orca-reply.sh" --to term_b --body hi > /dev/null 2>&1; rc=$?
check "neither --id nor --subject: refuses and calls nothing" "$([ $rc = 2 ] && [ ! -e "$tmp/calls" ]; echo $?)"

rm -f "$tmp/calls"; "$here/orca-reply.sh" --to term_b --id msg_1 --subject x --body hi > /dev/null 2>&1; rc=$?
check "both --id and --subject: refuses" "$([ $rc = 2 ] && [ ! -e "$tmp/calls" ]; echo $?)"

rm -f "$tmp/calls"; "$here/orca-reply.sh" --to "" --subject x --body hi > /dev/null 2>&1; rc=$?
check "empty recipient: refuses" "$([ $rc = 2 ] && [ ! -e "$tmp/calls" ]; echo $?)"

echo "orca-reply: $pass passed, $fail failed"
[ "$fail" = 0 ]
