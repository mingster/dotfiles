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
check mingster/dev-riben-q13-audit ''
check mingster/d4146b-hooks-prompt 4146
check mingster/4105-fix-4146 4146
check mingster/4105-fix-13 4105
check mingster/no-digits ''
echo 'PASS: 7 branch issue extraction cases'

# Verdict carry across a merge of main, in a throwaway repo with origin/main as a local ref.
eval "$(sed -n '/^diff_fingerprint() {/,/^}$/p' "$here/lead-merge.sh")"
eval "$(sed -n '/^carry_why=""$/,/^verdict_carry() {/p' "$here/lead-merge.sh" | sed '$d')"
eval "$(sed -n '/^verdict_carry() {/,/^}$/p' "$here/lead-merge.sh")"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q -b main . && git commit -q --allow-empty -m base
printf 'a\nb\nc\n' > shared.txt && git add shared.txt && git commit -q -m shared
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

# 1. merge of main only, same diff: carried
git checkout -q pr && git merge -q --no-ff -m "merge main" main
H1=$(git rev-parse HEAD)
carry "merge of main only is carried" 0 "$V" "$H1"

# 2. an authored commit after the merge: refused (check a)
echo more > extra.txt && git add extra.txt && git commit -q -m extra
H2=$(git rev-parse HEAD)
carry "extra authored commit is refused" 1 "$V" "$H2" "check a"

# 3. a merge that also edits the PR's change (conflict resolution): refused (check b)
git checkout -q -b pr3 "$V"
git merge -q --no-ff --no-commit main
echo sneaky >> feature.txt && git add feature.txt && git commit -q -m "merge main (edited)"
H3=$(git rev-parse HEAD)
carry "merge that changes the diff is refused" 1 "$V" "$H3" "check b"

# 4. verdict head not an ancestor of the PR head: refused
git checkout -q -b other main && echo o > o.txt && git add o.txt && git commit -q -m other
carry "verdict head not an ancestor is refused" 1 "$(git rev-parse HEAD)" "$H1" "not an ancestor"

# 5. whitespace-only edit hidden in a merge of main: refused (check b)
printf 'a\nb\nc\n' > ws.py && git checkout -q main && git add ws.py && git commit -q -m ws && git update-ref refs/remotes/origin/main main
git checkout -q -b prws "$V" && printf 'def f():\n    return 1\n' > f.py && git add f.py && git commit -q -m f
VW=$(git rev-parse HEAD)
git merge -q --no-ff --no-commit main && printf 'def f():\n    return 1 \n' > f.py && git add f.py && git commit -q -m "merge main (whitespace)"
carry "whitespace-only edit in a merge of main is refused" 1 "$VW" "$(git rev-parse HEAD)" "check b"

# 6. whitespace-only authored change after V: the equal-patch shortcut compares fingerprints, so they differ
git checkout -q -b prws2 "$VW" && printf 'def f():\n    return 1 \n' > f.py && git commit -q -am "trailing space"
[ "$(diff_fingerprint "main...$VW")" != "$(diff_fingerprint "main...$(git rev-parse HEAD)")" ] \
  || { echo "FAIL: whitespace-only change keeps the same fingerprint" >&2; exit 1; }
echo "ok whitespace-only authored change is refused by the shortcut"

# 7. same change rebased onto newer main with identical bytes: same fingerprint
git checkout -q main && echo m2 > m2.txt && git add m2.txt && git commit -q -m main2
git checkout -q -b prrb "$VW" && git rebase -q main
[ "$(diff_fingerprint "main...$VW")" = "$(diff_fingerprint "main...$(git rev-parse HEAD)")" ] \
  || { echo "FAIL: rebase changed the fingerprint" >&2; exit 1; }
echo "ok rebase onto newer main is accepted"
echo 'PASS: 7 verdict carry cases'
