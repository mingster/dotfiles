#!/usr/bin/env bash
# Tests for worker-done-relay.sh: route a builder worker_done to the owning lead, release the committer once.
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../worker-done-relay.sh"
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin" "$tmp/owners"
cat > "$tmp/bin/orca" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
echo '{"ok":true}'
EOS
chmod +x "$tmp/bin/orca"
export ORCA_LOG="$tmp/orca.log" ORCA_CLI_COMMAND="$tmp/bin/orca" WORKER_DONE_OWNER_DIR="$tmp/owners"
sha=0123456789abcdef0123456789abcdef01234567
printf 'term_lead_L\n' > "$tmp/owners/disp_owned"
run() { : > "$ORCA_LOG"; bash "$script" "$@" >"$tmp/out" 2>"$tmp/err"; echo $? >"$tmp/rc"; }

# 1. owned dispatch: message goes to the lead with branch, sha and payload, and to no one else
run relay --dispatch disp_owned --branch mingster/x-1 --sha "$sha" --payload /tmp/p.md --coordinator term_coord
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "owned relay exit 0"
grep -q -- "orchestration send --to term_lead_L .*--body .*mingster/x-1.*$sha.*/tmp/p.md" "$ORCA_LOG" && ok || bad "lead gets branch, sha, payload"
grep -q -- "terminal send --terminal term_lead_L " "$ORCA_LOG" && ok || bad "lead is nudged"
grep -q term_coord "$ORCA_LOG" && bad "coordinator must not be contacted when owned" || ok

# 2. no recorded owner: coordinator gets it
run relay --dispatch disp_orphan --branch b --sha "$sha" --payload /tmp/p.md --coordinator term_coord
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "orphan relay exit 0"
grep -q -- "orchestration send --to term_coord .*disp_orphan" "$ORCA_LOG" && ok || bad "orphan reaches coordinator"
grep -q term_lead_L "$ORCA_LOG" && bad "orphan must not reach a lead" || ok

# 3. empty owner file counts as no owner
: > "$tmp/owners/disp_empty"
run relay --dispatch disp_empty --branch b --sha "$sha" --payload /tmp/p.md --coordinator term_coord
grep -q -- "orchestration send --to term_coord " "$ORCA_LOG" && ok || bad "empty owner file goes to coordinator"

# 4. committer release happens once; second is a no-op
run release --dispatch disp_owned
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "release exit 0"
[ "$(grep -c -- 'orchestration worker-release --dispatch disp_owned' "$ORCA_LOG")" = 1 ] && ok || bad "first release calls worker-release once"
run release --dispatch disp_owned
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "second release exit 0"
[ ! -s "$ORCA_LOG" ] && ok || bad "second release calls nothing"

# 5. failed release is not marked, so it can be retried
cat > "$tmp/bin/orca" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
exit 1
EOS
run release --dispatch disp_retry
[ "$(cat "$tmp/rc")" != 0 ] && ok || bad "failed release exits nonzero"
run release --dispatch disp_retry
grep -q "worker-release --dispatch disp_retry" "$ORCA_LOG" && ok || bad "failed release is retried"

# 6. bad input refuses
run relay --dispatch "../x" --branch b --sha "$sha" --payload p --coordinator c
[ "$(cat "$tmp/rc")" = 2 ] && ok || bad "unsafe dispatch id exits 2"
run relay --dispatch disp_owned --branch b --sha "$sha" --payload p
[ "$(cat "$tmp/rc")" = 2 ] && ok || bad "missing coordinator exits 2"

echo "worker-done-relay: $pass passed, $fail failed"
[ "$fail" = 0 ]
