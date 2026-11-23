#!/usr/bin/env bash
# check-pr-body-issues.sh (#1688): the PR body must close or refer to the issues its title names, and
# must not close numbers that are missing from this repo.
set -u
here=$(cd "$(dirname "$0")" && pwd)
pass=0 fail=0
ok() { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
# Fake gh: 'api' answers 404 for numbers in FAKE_MISSING, fails without a 404 for FAKE_DOWN, else succeeds.
cat >"$tmp/bin/gh" <<'F'
#!/usr/bin/env bash
n=${2##*/}
case " ${FAKE_MISSING:-} " in *" $n "*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;; esac
case " ${FAKE_DOWN:-} " in *" $n "*) echo "gh: connection reset" >&2; exit 1 ;; esac
echo "$n"
F
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
body() { printf '%s\n' "$1" > "$tmp/body.md"; }
run() { out=$(bash "$here/check-pr-body-issues.sh" --body-file "$tmp/body.md" "$@" 2>&1); rc=$?; }

body $'Closes #1677\nRefs #1679\n'
run --title 'feat(fleet-watch): pasted body check (#1677 #1679)'
[ "$rc" -eq 0 ] && ok "matching body passes" || bad "matching body refused (rc=$rc, $out)"

body $'Closes #1677\n'
run --title 'fix(x): one issue (#1677) (#1688)' --pr 1688
[ "$rc" -eq 0 ] && ok "the PR's own number in the title is skipped" || bad "own PR number counted (rc=$rc, $out)"

body $'Closes #1677\n'
run --title 'feat(x): two issues (#1677 #1679)'
if [ "$rc" -eq 1 ] && grep -q 'title names #1679' <<<"$out" && ! grep -q '#1677' <<<"$out"; then
  ok "a title number the body does not mention is refused and named"
else
  bad "unreferenced title number (rc=$rc, $out)"
fi

body $'Closes #1677 #9851\n'
FAKE_MISSING="9851" run --title 'fix(x): one issue (#1677)'
if [ "$rc" -eq 1 ] && grep -q 'closes #9851, which is not an issue or PR' <<<"$out"; then
  ok "a closed number missing from this repo is refused and named"
else
  bad "missing closed number (rc=$rc, $out)"
fi

# The #1681 case: a body pasted from another repo, closing 9874 and 9851, for a title naming 1677 and 1679.
body $'Closes #9874 #9851\n'
FAKE_MISSING="9874 9851" run --title 'feat(fleet-watch): main red fixer (#1677 #1679) (#1681)' --pr 1681
if [ "$rc" -eq 1 ] && grep -q 'title names #1677' <<<"$out" && grep -q 'title names #1679' <<<"$out" \
  && grep -q 'closes #9874' <<<"$out" && grep -q 'closes #9851' <<<"$out"; then
  ok "the #1681 pasted body is refused on both reasons"
else
  bad "#1681 pasted body passed or reason missing (rc=$rc, $out)"
fi

body $'Closes #1677 #5\n'
FAKE_DOWN="5" run --title 'fix(x): one issue (#1677)'
if [ "$rc" -eq 0 ] && grep -q 'could not look up #5' <<<"$out"; then
  ok "a lookup that is not a 404 warns and does not refuse"
else
  bad "lookup failure (rc=$rc, $out)"
fi

run --title 'x' --body-file "$tmp/missing.md"
[ "$rc" -eq 2 ] && ok "a missing body file is a usage error" || bad "missing body file (rc=$rc)"
out=$(bash "$here/check-pr-body-issues.sh" --help 2>&1); [ $? -eq 0 ] && grep -q Usage <<<"$out" && ok "--help prints usage" || bad "--help"
echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
