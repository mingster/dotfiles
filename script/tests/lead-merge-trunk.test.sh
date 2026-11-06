#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
# trunk_check against a real git fixture: origin/main is a local ref, base/head come from commits.
eval "$(sed -n '/^locale_additive() {/,/^}$/p;/^locale_independent() {/,/^}$/p;/^locale_step() {/,/^}$/p;/^trunk_check() {/,/^}$/p' "$here/lead-merge.sh")"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
refusals_file="$tmp/.refusals"
refuse() { echo "$*" >>"$refusals_file"; }
die() { echo "die: $*" >>"$refusals_file"; return 1; }
field() { echo "$base"; }
export WT_LOG="$tmp/wt.log" LEAD_MERGE_LOCALE_TIMEOUT=2

# Each case starts from the same base: a locale file, a nested locale file, a plain file and a non locale json file.
# An optional argument is the one line locale step, committed as .agents/locale-merge-check.conf.
new_case() {
  rm -rf repo && mkdir repo && cd repo
  git init -q -b main .
  mkdir -p web/locales
  printf '{\n  "a": "A",\n  "b": "B",\n  "c": "C",\n  "d": "D",\n  "e": "E",\n  "f": "F"\n}\n' >web/locales/en.json
  printf '{\n  "a": 1,\n  "b": 2,\n  "c": 3,\n  "d": 4,\n  "e": 5,\n  "f": 6\n}\n' >config.json
  printf '{\n  "nav": {\n    "home": "Home",\n    "about": "About"\n  },\n  "form": {\n    "ok": "OK",\n    "cancel": "Cancel"\n  }\n}\n' >web/locales/nested.json
  seq 1 20 >notes.txt
  if [ -n "${1:-}" ]; then mkdir -p .agents && printf '# locale step\n%s\n' "$1" >.agents/locale-merge-check.conf; fi
  git add -A && git commit -q -m base
  base=$(git rev-parse HEAD)
  : >"$refusals_file"
}
# edit <file> <sed expr> on a branch; main edits are committed on main, then origin/main is moved.
on_pr() { git checkout -q -b pr "$base"; }
commit_all() { git add -A && git commit -q -m "$1"; }
finish() { # files-json
  head=$(git rev-parse HEAD)
  git update-ref refs/remotes/origin/main main
  files="$1"
}
run_check() { # name expect(0|1) [refusal substring] [ran|skipped]
  local rc=0
  : >"$WT_LOG"
  (trunk_check) || rc=$?
  local got=0; [ ! -s "$refusals_file" ] || got=1
  [ "$got" = "$2" ] || { echo "FAIL: $1: expected refused=$2, got $got ($(cat "$refusals_file"))" >&2; exit 1; }
  if [ -n "${3:-}" ]; then grep -Fq -- "$3" "$refusals_file" || { echo "FAIL: $1: refusal lacks '$3'" >&2; exit 1; }; fi
  case "${4:-}" in
    ran) [ -s "$WT_LOG" ] || { echo "FAIL: $1: locale step did not run" >&2; exit 1; } ;;
    skipped) [ ! -s "$WT_LOG" ] || { echo "FAIL: $1: locale step ran" >&2; exit 1; } ;;
  esac
  [ "$(git worktree list | wc -l | tr -d ' ')" = 1 ] || { echo "FAIL: $1: temporary worktree left registered" >&2; exit 1; }
  if [ -s "$WT_LOG" ]; then [ ! -e "$(cat "$WT_LOG")" ] || { echo "FAIL: $1: temporary worktree directory left behind" >&2; exit 1; }; fi
  echo "ok $1"
}

# 1. distinct keys added on both sides of one locale file: accepted
new_case
git checkout -q main && sed -i.bak 's/"a": "A",/"a": "A",\n  "m": "M",/' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all main
on_pr && sed -i.bak 's/"f": "F"/"f": "F",\n  "p": "P"/' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "distinct added keys in a shared locale file are accepted" 0

# 2. both sides add the same key with different values: refused
new_case
git checkout -q main && sed -i.bak 's/"f": "F"/"f": "F",\n  "z": "main"/' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all main
on_pr && sed -i.bak 's/"a": "A",/"a": "A",\n  "z": "pr",/' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "same key added with different values is refused" 1 "trunk changed web/locales/en.json"

# 3. main changes an existing value, PR adds another key: refused
new_case
git checkout -q main && sed -i.bak 's/"c": "C"/"c": "changed"/' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all main
on_pr && sed -i.bak 's/"f": "F"/"f": "F",\n  "p": "P"/' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "main changing an existing key is refused without a locale step" 1 "trunk changed web/locales/en.json" skipped

# 4. PR changes an existing value, main adds a key: refused
new_case
git checkout -q main && sed -i.bak 's/"f": "F"/"f": "F",\n  "m": "M"/' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all main
on_pr && sed -i.bak 's/"a": "A"/"a": "changed"/' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "PR changing an existing key is refused without a locale step" 1 "trunk changed web/locales/en.json" skipped

# 5. main removes an existing key, PR adds a key: refused
new_case
git checkout -q main && sed -i.bak '/"c": "C",/d' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all main
on_pr && sed -i.bak 's/"f": "F"/"f": "F",\n  "p": "P"/' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "main removing an existing key is refused without a locale step" 1 "trunk changed web/locales/en.json" skipped

# 6. textual conflict in the same lines of a locale file: refused
new_case
git checkout -q main && sed -i.bak 's/"f": "F"/"f": "F",\n  "m": "M"/' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all main
on_pr && sed -i.bak 's/"f": "F"/"f": "F",\n  "p": "P"/' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "textual conflict in a locale file is refused" 1 "trunk changed web/locales/en.json"

# 7. shared non locale json file with a clean merge: refused
new_case
git checkout -q main && sed -i.bak 's/"a": 1,/"a": 1,\n  "m": 7,/' config.json && rm -f config.json.bak && commit_all main
on_pr && sed -i.bak 's/"f": 6/"f": 6,\n  "p": 8/' config.json && rm -f config.json.bak && commit_all pr
finish '["config.json"]'
run_check "clean merge of a non locale json file is refused" 1 "trunk changed config.json"

# 8. shared plain text file with a clean merge: refused
new_case
git checkout -q main && sed -i.bak 's/^2$/two/' notes.txt && rm -f notes.txt.bak && commit_all main
on_pr && sed -i.bak 's/^15$/fifteen/' notes.txt && rm -f notes.txt.bak && commit_all pr
finish '["notes.txt"]'
run_check "clean merge of a text file is refused" 1 "trunk changed notes.txt"

# 9. one accepted locale overlap does not hide a refused non locale overlap
new_case
git checkout -q main && sed -i.bak 's/"a": "A",/"a": "A",\n  "m": "M",/' web/locales/en.json && sed -i.bak 's/^2$/two/' notes.txt && rm -f web/locales/en.json.bak notes.txt.bak && commit_all main
on_pr && sed -i.bak 's/"f": "F"/"f": "F",\n  "p": "P"/' web/locales/en.json && sed -i.bak 's/^15$/fifteen/' notes.txt && rm -f web/locales/en.json.bak notes.txt.bak && commit_all pr
finish '["web/locales/en.json","notes.txt"]'
run_check "accepted locale overlap still refuses a text file overlap" 1 "trunk changed notes.txt"

# 10. disjoint files: accepted (existing behaviour)
new_case
git checkout -q main && sed -i.bak 's/^2$/two/' notes.txt && rm -f notes.txt.bak && commit_all main
on_pr && sed -i.bak 's/"f": "F"/"f": "F",\n  "p": "P"/' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "disjoint files are accepted" 0

# 11. fail closed: invalid JSON on a side is refused
new_case
git checkout -q main && sed -i.bak 's/"a": "A",/"a": "A",\n  "m": "M",/' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all main
on_pr && sed -i.bak 's/"f": "F"/"f": "F",\n  "p": "P",/' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "unparseable locale json is refused" 1 "trunk changed web/locales/en.json"

# Locale step cases: a non additive merge is accepted only when the project's step passes on the merged tree.
EN='web/locales/en.json'
SEEN='pwd >"$WT_LOG"; '

# 12. main changes a value, PR adds a key, passing step sees the merged result: accepted
new_case "${SEEN}grep -q '\"c\": \"changed\"' $EN && grep -q '\"p\": \"P\"' $EN"
git checkout -q main && sed -i.bak 's/"c": "C"/"c": "changed"/' $EN && rm -f $EN.bak && commit_all main
on_pr && sed -i.bak 's/"f": "F"/"f": "F",\n  "p": "P"/' $EN && rm -f $EN.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "main changing a key is accepted when the step passes on the merged file" 0 "" ran

# 13. PR changes a value, main adds a key: accepted
new_case "${SEEN}true"
git checkout -q main && sed -i.bak 's/"f": "F"/"f": "F",\n  "m": "M"/' $EN && rm -f $EN.bak && commit_all main
on_pr && sed -i.bak 's/"a": "A"/"a": "changed"/' $EN && rm -f $EN.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "PR changing a key is accepted when the step passes" 0 "" ran

# 14. main removes a key, PR adds a key: accepted
new_case "${SEEN}true"
git checkout -q main && sed -i.bak '/"c": "C",/d' $EN && rm -f $EN.bak && commit_all main
on_pr && sed -i.bak 's/"f": "F"/"f": "F",\n  "p": "P"/' $EN && rm -f $EN.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "main removing a key is accepted when the step passes" 0 "" ran

# 15. same key changed on both sides with different values: refused
new_case "${SEEN}true"
git checkout -q main && sed -i.bak 's/"c": "C"/"c": "main"/' $EN && rm -f $EN.bak && commit_all main
on_pr && sed -i.bak 's/"c": "C"/"c": "pr"/' $EN && rm -f $EN.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "same key changed on both sides is refused" 1 "trunk changed web/locales/en.json" skipped

# 16. same key changed to the same value on both sides: still refused
new_case "${SEEN}true"
git checkout -q main && sed -i.bak 's/"c": "C"/"c": "same"/' $EN && rm -f $EN.bak && commit_all main
on_pr && sed -i.bak 's/"c": "C"/"c": "same"/' $EN && rm -f $EN.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "same key changed to the same value on both sides is refused" 1 "trunk changed web/locales/en.json" skipped

# 17. failing step: refused with the old message
new_case "${SEEN}false"
git checkout -q main && sed -i.bak 's/"c": "C"/"c": "changed"/' $EN && rm -f $EN.bak && commit_all main
on_pr && sed -i.bak 's/"f": "F"/"f": "F",\n  "p": "P"/' $EN && rm -f $EN.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "failing locale step is refused" 1 "trunk changed web/locales/en.json; rebase and rerun head-checks" ran

# 18. timed out step: refused
new_case "${SEEN}sleep 30"
git checkout -q main && sed -i.bak 's/"c": "C"/"c": "changed"/' $EN && rm -f $EN.bak && commit_all main
on_pr && sed -i.bak 's/"f": "F"/"f": "F",\n  "p": "P"/' $EN && rm -f $EN.bak && commit_all pr
finish '["web/locales/en.json"]'
start=$SECONDS
run_check "timed out locale step is refused" 1 "trunk changed web/locales/en.json" ran
[ $((SECONDS - start)) -lt 15 ] || { echo "FAIL: timeout did not stop the step" >&2; exit 1; }

# 19. nested keys changed under different parents: accepted
NEST='web/locales/nested.json'
new_case "${SEEN}jq -e '.nav.home == \"Start\" and .form.ok == \"Okay\"' $NEST"
git checkout -q main && sed -i.bak 's/"home": "Home"/"home": "Start"/' $NEST && rm -f $NEST.bak && commit_all main
on_pr && sed -i.bak 's/"ok": "OK"/"ok": "Okay"/' $NEST && rm -f $NEST.bak && commit_all pr
finish '["web/locales/nested.json"]'
run_check "nested keys changed on different leaves are accepted" 0 "" ran

# 20. nested same leaf changed on both sides: refused
new_case "${SEEN}true"
git checkout -q main && sed -i.bak 's/"home": "Home"/"home": "Start"/' $NEST && rm -f $NEST.bak && commit_all main
on_pr && sed -i.bak 's/"home": "Home"/"home": "Begin"/' $NEST && rm -f $NEST.bak && commit_all pr
finish '["web/locales/nested.json"]'
run_check "nested leaf changed on both sides is refused" 1 "trunk changed web/locales/nested.json" skipped

# 21. clean text merge whose merged value is not the expected one (duplicate key wins last): refused
new_case "${SEEN}true"
git checkout -q main && sed -i.bak 's/"f": "F"/"f": "F",\n  "c": "C"/' $EN && rm -f $EN.bak && commit_all main
on_pr && sed -i.bak 's/"c": "C"/"c": "pr"/' $EN && rm -f $EN.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "merged value that differs from the expected side is refused" 1 "trunk changed web/locales/en.json" skipped

# 22. add only overlap passes with no step even when the step would fail
new_case "${SEEN}false"
git checkout -q main && sed -i.bak 's/"a": "A",/"a": "A",\n  "m": "M",/' $EN && rm -f $EN.bak && commit_all main
on_pr && sed -i.bak 's/"f": "F"/"f": "F",\n  "p": "P"/' $EN && rm -f $EN.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "add only overlap needs no locale step" 0 "" skipped

# 23. a conf file never loosens non locale files
new_case "${SEEN}true"
git checkout -q main && sed -i.bak 's/"a": 1,/"a": 1,\n  "m": 7,/' config.json && rm -f config.json.bak && commit_all main
on_pr && sed -i.bak 's/"f": 6/"f": 6,\n  "p": 8/' config.json && rm -f config.json.bak && commit_all pr
finish '["config.json"]'
run_check "non locale json is refused even with a locale step" 1 "trunk changed config.json" skipped

# 24. a PR cannot add its own conf: the step comes from trunk
new_case
git checkout -q main && sed -i.bak 's/"c": "C"/"c": "changed"/' $EN && rm -f $EN.bak && commit_all main
on_pr && mkdir -p .agents && printf 'true\n' >.agents/locale-merge-check.conf && sed -i.bak 's/"f": "F"/"f": "F",\n  "p": "P"/' $EN && rm -f $EN.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "a conf file added by the PR is not trusted" 1 "trunk changed web/locales/en.json" skipped

echo "all trunk tests passed"
