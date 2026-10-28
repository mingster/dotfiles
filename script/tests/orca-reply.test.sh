#!/usr/bin/env bash
# Tests for orca-reply.sh: reply to an orchestration message, then nudge the recipient's terminal.
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../orca-reply.sh"
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/orca" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
case "$1 $2" in
  "orchestration reply") [ -z "${FAKE_REPLY_FAIL:-}" ] || exit 1 ;;
  "terminal send") [ -z "${FAKE_SEND_FAIL:-}" ] || exit 1 ;;
esac
echo '{"ok":true}'
EOS
chmod +x "$tmp/bin/orca"
export ORCA_LOG="$tmp/orca.log" PATH="$tmp/bin:$PATH"
run() { : > "$ORCA_LOG"; bash "$script" "$@" >"$tmp/out" 2>"$tmp/err"; echo $? >"$tmp/rc"; }

# 1. replies, then nudges the recipient terminal with Enter
run --to term_a --id msg_1 --body "approved"
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "success exit 0"
[ "$(sed -n 1p "$ORCA_LOG" | cut -d' ' -f1-2)" = "orchestration reply" ] && ok || bad "reply runs first"
grep -q -- "orchestration reply.*--id msg_1.*--body approved" "$ORCA_LOG" && ok || bad "reply carries id and body"
grep -q -- "terminal send --terminal term_a --text .*inbox.* --enter" "$ORCA_LOG" && ok || bad "nudge to recipient with --enter"
[ "$(wc -l < "$ORCA_LOG" | tr -d ' ')" = 2 ] && ok || bad "exactly two orca calls"

# 2. --from is passed to the reply
run --to term_a --id msg_1 --body hi --from term_me
grep -q -- "orchestration reply.*--from term_me" "$ORCA_LOG" && ok || bad "--from forwarded"

# 3. empty or missing recipient refuses, calls nothing
run --to "" --id msg_1 --body hi
[ "$(cat "$tmp/rc")" = 2 ] && ok || bad "empty --to exit 2"
[ ! -s "$ORCA_LOG" ] && ok || bad "empty --to calls nothing"
grep -q "recipient" "$tmp/err" && ok || bad "empty --to message"
run --id msg_1 --body hi
[ "$(cat "$tmp/rc")" = 2 ] && [ ! -s "$ORCA_LOG" ] && ok || bad "missing --to refuses"

# 4. missing id or body refuses
run --to term_a --body hi
[ "$(cat "$tmp/rc")" = 2 ] && [ ! -s "$ORCA_LOG" ] && ok || bad "missing --id refuses"
run --to term_a --id msg_1
[ "$(cat "$tmp/rc")" = 2 ] && [ ! -s "$ORCA_LOG" ] && ok || bad "missing --body refuses"

# 5. failed reply: no nudge, nonzero
FAKE_REPLY_FAIL=1 run --to term_a --id msg_1 --body hi
[ "$(cat "$tmp/rc")" != 0 ] && ok || bad "reply failure exits nonzero"
! grep -q "terminal send" "$ORCA_LOG" && ok || bad "no nudge after failed reply"

# 6. failed nudge: nonzero, reply already sent
FAKE_SEND_FAIL=1 run --to term_a --id msg_1 --body hi
[ "$(cat "$tmp/rc")" = 1 ] && ok || bad "nudge failure exits 1"
grep -q "nudge" "$tmp/err" && ok || bad "nudge failure message"

# 7. --subject sends a new message to the recipient, then nudges
run --to term_b --subject "batch ready" --body hi --from term_me
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "send exit 0"
grep -q -- "orchestration send --to term_b --subject batch ready --body hi --json --from term_me" "$ORCA_LOG" && ok || bad "send carries to, subject, body, from"
grep -q -- "terminal send --terminal term_b" "$ORCA_LOG" && ok || bad "send nudges the recipient"

# 8. both --id and --subject refuse, call nothing
run --to term_b --id msg_1 --subject x --body hi
[ "$(cat "$tmp/rc")" = 2 ] && ok || bad "both id and subject exit 2"
[ ! -s "$ORCA_LOG" ] && ok || bad "both id and subject call nothing"

echo "orca-reply: $pass passed, $fail failed"
[ "$fail" = 0 ]
