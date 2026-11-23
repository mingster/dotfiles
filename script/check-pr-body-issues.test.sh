#!/usr/bin/env bash
# Tests for script/check-pr-body-issues.sh (#1688): the PR body must close or refer to the issues its title names,
# and must not close numbers that do not exist in this repo. gh is a stub on PATH; no network.
set -u
here=$(cd "$(dirname "$0")" && pwd)
pass=0 fail=0
ok() { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
# Repo is mingster/dotfiles. Issues 1677, 1679, 1688 and 1 exist. 9874 and 9851 are another repo's numbers.
# Issue 7 fails with a server error, which must be SKIPPED, not refused.
cat > "$tmp/bin/gh" <<'F'
#!/usr/bin/env bash
case "$*" in
  "repo view"*) echo mingster/dotfiles ;;
  "api repos/mingster/dotfiles/issues/7 "*) echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1 ;;
  "api repos/mingster/dotfiles/issues/"*)
    n=${2##*/}
    case "$n" in
      1|1677|1679|1688) echo "$n" ;;
      *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    esac ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
F
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

body() { printf '%s\n' "$1" > "$tmp/body.md"; }
run() { out=$(bash "$here/check-pr-body-issues.sh" --title "$1" --body-file "$tmp/body.md" 2>&1); rc=$?; }

body $'Closes #1688\n\n## Self-check\n$ bash script/checks-local.sh\nall passed'
run 'fix(agent-team): check the body (#1688)'
[ "$rc" -eq 0 ] && ok "a body that closes the title's issue passes" || bad "matching body refused (rc=$rc, $out)"

body $'Closes #9874 #9851\n'
run 'fix(fleet-watch): stop a bad body (#1677 #1679)'
if [ "$rc" -eq 1 ] && grep -q '#1677' <<<"$out" && grep -q '#1679' <<<"$out" && grep -q 'closes #9874, which does not exist' <<<"$out" && grep -q '#9851' <<<"$out"; then
  ok "the #1681-style pasted body fails on the title and on the foreign numbers"
else
  bad "pasted body (rc=$rc, $out)"
fi

body $'Refs #1677\n'
run 'fix(x): y (#1677 #1679)'
if [ "$rc" -eq 1 ] && grep -q '#1679' <<<"$out" && ! grep -q '#1677' <<<"$out"; then
  ok "a title number the body does not mention is named, a referred one is not"
else
  bad "partial refs (rc=$rc, $out)"
fi

body $'Closes #9874\n'
run 'chore: no issue in the title'
[ "$rc" -eq 1 ] && grep -q 'does not exist in mingster/dotfiles' <<<"$out" && ok "a closed number that does not exist fails with no title numbers" || bad "foreign close alone (rc=$rc, $out)"

body $'Refs other/repo#1688\n'
run 'fix(x): y (#1688)'
[ "$rc" -eq 1 ] && ok "a reference to another repo's same number does not satisfy the title" || bad "other repo ref accepted (rc=$rc, $out)"

body $'Refs mingster/dotfiles#1688\n'
run 'fix(x): y (#1688)'
[ "$rc" -eq 0 ] && ok "a qualified reference to this repo satisfies the title" || bad "own repo qualified ref refused (rc=$rc, $out)"

body $'Closes other/repo#9874\n'
run 'chore: no issue in the title'
[ "$rc" -eq 0 ] && ok "a close qualified to another repo is not checked here" || bad "other repo close refused (rc=$rc, $out)"

body $'This prefix #1688 is prose, not a reference\n'
run 'fix(x): y (#1688)'
[ "$rc" -eq 1 ] && ok "a word ending in fix does not count as a keyword" || bad "prefix counted (rc=$rc, $out)"

body $'Closes #7\n'
run 'chore: no issue in the title'
[ "$rc" -eq 0 ] && grep -q 'SKIPPED #7' <<<"$out" && ok "a lookup that fails for another reason is skipped, named" || bad "skipped lookup (rc=$rc, $out)"

body $'no references at all\n'
run 'chore: plain'
[ "$rc" -eq 0 ] && ok "a title with no numbers and no references passes" || bad "plain title (rc=$rc, $out)"

out=$(bash "$here/check-pr-body-issues.sh" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "no arguments is a usage error" || bad "usage (rc=$rc, $out)"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
