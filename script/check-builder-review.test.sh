#!/usr/bin/env bash
# Tests for script/check-builder-review.sh (#1675). A fake gh answers `pr view` from $FAKE_PR_JSON.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/asdf-pin.sh
. "$ROOT/script/tests/lib/asdf-pin.sh"
SCRIPT="$ROOT/script/check-builder-review.sh"
TMP="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME" "$TMP/bin"
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

cat >"$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
[ "$1 $2" = "pr view" ] || exit 1
[ -f "$FAKE_PR_JSON" ] || exit 1
cat "$FAKE_PR_JSON"
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" FAKE_PR_JSON="$TMP/pr.json"
HEAD=1111111111111111111111111111111111111111
OLD=2222222222222222222222222222222222222222

pr_json() { # <comment body>...
  jq -n --arg h "$HEAD" '{number: 7, headRefOid: $h, comments: [$ARGS.positional[] | {body: .}]}' --args "$@" >"$FAKE_PR_JSON"
}
run() { out=$(bash "$SCRIPT" "$@" 2>&1); rc=$?; }

pr_json "looks fine to me"
run 7 "$HEAD"
if [ "$rc" -ne 0 ] && grep -qF "bash ~/dotfiles/script/pr-review.sh 7 $HEAD" <<<"$out"; then ok "no Review comment fails and prints the fix command"; else bad "no comment (rc=$rc, $out)"; fi

pr_json "Review: PASS head=$OLD model=sonnet"
run 7 "$HEAD"
[ "$rc" -ne 0 ] && ok "PASS for an older head fails" || bad "older head passed"

pr_json "Review: FAIL head=$HEAD model=sonnet"
run 7 "$HEAD"
[ "$rc" -ne 0 ] && ok "FAIL at the head fails" || bad "FAIL passed"

pr_json "> Review: PASS head=$HEAD model=sonnet quoted"
run 7 "$HEAD"
[ "$rc" -ne 0 ] && ok "a quoted PASS line fails" || bad "quoted passed"

pr_json "Review: PASS head=$HEAD model=sonnet
Findings: none"
run 7 "$HEAD"
[ "$rc" -eq 0 ] && ok "PASS at the head passes" || bad "PASS at head (rc=$rc, $out)"

pr_json "Review: PASS head=$HEAD model=sonnet"
run 7 "${HEAD:0:12}"
[ "$rc" -eq 0 ] && ok "a short sha prefix of the head passes" || bad "short sha (rc=$rc, $out)"

pr_json "Review: PASS head=$HEAD model=sonnet"
run --worktree "$TMP"
[ "$rc" -eq 0 ] && ok "worktree mode resolves the PR and head" || bad "worktree mode (rc=$rc, $out)"

pr_json "nothing"
run --worktree "$TMP"
if [ "$rc" -ne 0 ] && grep -qF "pr-review.sh 7 $HEAD" <<<"$out"; then ok "worktree mode without a Review fails with the fix command"; else bad "worktree fail (rc=$rc, $out)"; fi

rm -f "$FAKE_PR_JSON"
run --worktree "$TMP"
[ "$rc" -eq 0 ] && ok "worktree with no PR passes (nothing to review)" || bad "no PR (rc=$rc, $out)"

run
[ "$rc" -eq 2 ] && ok "no arguments is a usage error" || bad "usage (rc=$rc)"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
