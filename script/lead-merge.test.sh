#!/usr/bin/env bash
# Test the real extraction helper without running merge commands or calling GitHub.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
eval "$(sed -n '/^issue_from_branch() {$/,/^}$/p' "$here/lead-merge.sh")"

check() {
  local actual
  actual=$(issue_from_branch "$1")
  [ "$actual" = "$2" ] || { echo "FAIL: $1: expected '$2', got '$actual'" >&2; exit 1; }
  echo "ok $1 -> '$actual'"
}

check mingster/fullstack-dev-s4a-4105 4105
check mingster/fullstack-dev-c4145 4145
check mingster/dev-project-q13-audit ''
check mingster/d4146b-hooks-prompt 4146
check mingster/4105-fix-4146 4146
check mingster/4105-fix-13 4105
check mingster/no-digits ''
echo 'PASS: 7 branch issue extraction cases'

# Verdict carry across a merge of main, in a throwaway repo with origin/main as a local ref.
eval "$(sed -n '/^carry_why=""$/,/^verdict_carry() {/p' "$here/lead-merge.sh" | sed '$d')"
eval "$(sed -n '/^verdict_carry() {/,/^}$/p' "$here/lead-merge.sh")"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q -b main . && git commit -q --allow-empty -m base
git checkout -q -b pr && echo feature > feature.txt && git add feature.txt && git commit -q -m feature
V=$(git rev-parse HEAD)
git checkout -q main && echo m1 > m1.txt && git add m1.txt && git commit -q -m main1
git update-ref refs/remotes/origin/main main

carry() { # name expect(0|1) V H [why-substring]
  local rc=0
  verdict_carry "$3" "$4" || rc=$?
  [ "$rc" = "$2" ] || { echo "FAIL: $1: expected rc $2, got $rc ($carry_why)" >&2; exit 1; }
  if [ -n "${5:-}" ]; then
    case "$carry_why" in *"$5"*) ;; *) echo "FAIL: $1: reason '$carry_why' lacks '$5'" >&2; exit 1 ;; esac
  fi
  echo "ok $1"
}
advance_main() { git update-ref refs/remotes/origin/main main; }

# 1. clean merge of main: carried
git checkout -q pr && git merge -q --no-ff -m "merge main" main
H1=$(git rev-parse HEAD)
carry "clean merge of main is carried" 0 "$V" "$H1"

# 2. authored commit after the merge: refused (check a)
echo more > extra.txt && git add extra.txt && git commit -q -m extra
carry "authored commit after V is refused" 1 "$V" "$(git rev-parse HEAD)" "check a"

# 3. merge of main with a hand edit to the PR's file: refused (check b)
git checkout -q -b pr3 "$V" && git merge -q --no-ff --no-commit main
echo sneaky >> feature.txt && git add feature.txt && git commit -q -m "merge main (edited)"
carry "merge that edits the PR's change is refused" 1 "$V" "$(git rev-parse HEAD)" "differs from a clean replay"

# 4. verdict head not an ancestor of the PR head: refused
git checkout -q -b other main && echo o > o.txt && git add o.txt && git commit -q -m other
carry "V not an ancestor is refused" 1 "$(git rev-parse HEAD)" "$H1" "not an ancestor"

# 5. whitespace-only evil merge: refused
git checkout -q main && printf 'x\n' > ws.txt && git add ws.txt && git commit -q -m ws && advance_main
git checkout -q -b prws "$V" && printf 'def f():\n    return 1\n' > f.py && git add f.py && git commit -q -m f
VW=$(git rev-parse HEAD)
git merge -q --no-ff --no-commit main && printf 'def f():\n    return 1 \n' > f.py && git add f.py && git commit -q -m "merge main (whitespace)"
carry "whitespace-only evil merge is refused" 1 "$VW" "$(git rev-parse HEAD)" "differs from a clean replay"

# 6. main edits another part of a file the PR also touches: carried
git checkout -q main && seq 1 20 > big.txt && git add big.txt && git commit -q -m big && advance_main
git checkout -q -b prsame main && sed -i.bak 's/^15$/fifteen/' big.txt && rm -f big.txt.bak && git commit -q -am "pr edits line 15"
VS=$(git rev-parse HEAD)
git checkout -q main && sed -i.bak 's/^2$/two/' big.txt && rm -f big.txt.bak && git commit -q -am "main edits line 2" && advance_main
git checkout -q prsame && git merge -q --no-ff -m "merge main" main
carry "same-file merge of main elsewhere is carried" 0 "$VS" "$(git rev-parse HEAD)"

# 7. relocated edit in a file of repeated lines: refused
git checkout -q main && printf 'x\nx\nx\nx\nx\nx\n' > rep.txt && git add rep.txt && git commit -q -m rep && advance_main
git checkout -q -b prrep main && sed -i.bak '2s/x/y/' rep.txt && rm -f rep.txt.bak && git commit -q -am "pr edits line 2"
VR=$(git rev-parse HEAD)
git checkout -q main && echo m3 > m3.txt && git add m3.txt && git commit -q -m main3 && advance_main
git checkout -q prrep && git merge -q --no-ff --no-commit main
printf 'x\nx\nx\nx\ny\nx\n' > rep.txt && git add rep.txt && git commit -q -m "merge main (relocated edit)"
carry "relocated edit in repeated lines is refused" 1 "$VR" "$(git rev-parse HEAD)" "differs from a clean replay"

# 8. binary change hidden in a merge of main: refused
git checkout -q -b prbin main && echo pr > prbin.txt && git add prbin.txt && git commit -q -m prbin
VB=$(git rev-parse HEAD)
git checkout -q main && printf '\000\001\002' > blob.bin && git add blob.bin && git commit -q -m "main blob" && advance_main
git checkout -q prbin && git merge -q --no-ff --no-commit main && printf '\000\001\003' > blob.bin && git add blob.bin && git commit -q -m "merge main (binary)"
carry "hidden binary change in a merge is refused" 1 "$VB" "$(git rev-parse HEAD)" "differs from a clean replay"

# 9. conflict-resolved merge: refused
git checkout -q main && echo main > c.txt && git add c.txt && git commit -q -m cmain && advance_main
git checkout -q -b prc "$V" && echo pr > c.txt && git add c.txt && git commit -q -m cpr
VC=$(git rev-parse HEAD)
git merge -q --no-ff main >/dev/null 2>&1 || true
echo resolved > c.txt && git add c.txt && git commit -q -m "merge main (resolved)"
carry "conflict-resolved merge is refused" 1 "$VC" "$(git rev-parse HEAD)" "conflicted merge"

# 10. non-main second parent: refused (check a)
git checkout -q -b prnm "$V" && git checkout -q -b side "$V" && echo side > side.txt && git add side.txt && git commit -q -m side
git checkout -q prnm && git merge -q --no-ff -m "merge side" side
carry "non-main parent is refused" 1 "$V" "$(git rev-parse HEAD)" "not in origin/main"

# 11. git merge-tree failure: refused
git checkout -q pr
# Subshell: the git override stays local to this case.
( git() { if [ "${1:-}" = merge-tree ]; then return 128; fi; command git "$@"; }
  carry "git merge-tree failure is refused" 1 "$V" "$H1" "conflicted merge" ) || exit 1
echo 'PASS: 11 verdict carry cases'
