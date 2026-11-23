#!/usr/bin/env bash
# Tests for script/check-issue-overlap.sh (#1678). A fake gh answers from files in $FAKE.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/asdf-pin.sh
. "$ROOT/script/tests/lib/asdf-pin.sh"
SCRIPT="$ROOT/script/check-issue-overlap.sh"
TMP="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" FAKE="$TMP/fake"; mkdir -p "$HOME" "$TMP/bin" "$FAKE"
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

cat >"$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue view") cat "$FAKE/issue-$3.md" ;;
  "issue list") cat "$FAKE/inflight.json" ;;
  "pr list") cat "$FAKE/prs.json" ;;
  *) exit 1 ;;
esac
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

cat >"$FAKE/issue-10.md" <<'B'
Do the thing.

## Allowed files
- script/alpha.sh
- `script/tests/alpha.test.sh`

## Verify
bash script/checks-local.sh
B
echo '[]' >"$FAKE/inflight.json"
echo '[]' >"$FAKE/prs.json"
run() { out=$(bash "$SCRIPT" "$@" 2>&1); rc=$?; }

run 10
[ "$rc" -eq 0 ] && ok "no in-flight work: no overlap" || bad "clean (rc=$rc, $out)"

jq -n '[{number: 11, body: "x\n\n## Allowed files\n- script/other.sh\n- script/alpha.sh\n"}]' >"$FAKE/inflight.json"
run 10
if [ "$rc" -eq 1 ] && grep -qF "script/alpha.sh" <<<"$out" && grep -qF "#11" <<<"$out"; then ok "an in-progress issue on the same file overlaps and is named"; else bad "issue overlap (rc=$rc, $out)"; fi

jq -n '[{number: 10, body: "## Allowed files\n- script/alpha.sh\n"}]' >"$FAKE/inflight.json"
run 10
[ "$rc" -eq 0 ] && ok "the issue itself is not an overlap" || bad "self (rc=$rc, $out)"

echo '[]' >"$FAKE/inflight.json"
jq -n '[{number: 20, body: "Closes #99", files: [{path: "script/tests/alpha.test.sh"}]}]' >"$FAKE/prs.json"
run 10
if [ "$rc" -eq 1 ] && grep -qF "script/tests/alpha.test.sh" <<<"$out" && grep -qF "PR #20" <<<"$out"; then ok "an open PR touching an allowed file overlaps and is named"; else bad "PR overlap (rc=$rc, $out)"; fi

jq -n '[{number: 20, body: "Closes #10", files: [{path: "script/alpha.sh"}]}]' >"$FAKE/prs.json"
run 10
[ "$rc" -eq 0 ] && ok "the issue's own PR is not an overlap" || bad "own PR (rc=$rc, $out)"

jq -n '[{number: 21, body: "x", files: [{path: "docs/readme.md"}]}]' >"$FAKE/prs.json"
jq -n '[{number: 12, body: "## Allowed files\n- script/tests/\n"}]' >"$FAKE/inflight.json"
run 10
if [ "$rc" -eq 1 ] && grep -qF "#12" <<<"$out"; then ok "a directory entry covers the files under it"; else bad "dir overlap (rc=$rc, $out)"; fi

echo '[]' >"$FAKE/inflight.json"; echo '[]' >"$FAKE/prs.json"
printf 'Fix.\n\n## Allowed files\n- script/beta.sh\n' >"$TMP/brief.md"
jq -n '[{number: 13, body: "Allowed files: script/beta.sh"}]' >"$FAKE/inflight.json"
run --spec "$TMP/brief.md" 10
if [ "$rc" -eq 1 ] && grep -qF "script/beta.sh" <<<"$out"; then ok "--spec reads the Allowed files of the brief and the inline form of others"; else bad "--spec (rc=$rc, $out)"; fi

printf 'No allowed files here.\n' >"$FAKE/issue-14.md"
run 14
[ "$rc" -eq 0 ] && ok "an issue with no Allowed files cannot overlap" || bad "no allowed (rc=$rc, $out)"

run
[ "$rc" -eq 2 ] && ok "no arguments is a usage error" || bad "usage (rc=$rc)"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
