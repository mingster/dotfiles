#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
# trunk_check against a real git fixture: origin/main is a local ref, base/head come from commits.
eval "$(sed -n '/^locale_additive() {/,/^}$/p;/^trunk_check() {/,/^}$/p' "$here/lead-merge.sh")"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
refusals_file="$tmp/.refusals"
refuse() { echo "$*" >>"$refusals_file"; }
die() { echo "die: $*" >>"$refusals_file"; return 1; }
field() { echo "$base"; }

# Each case starts from the same base: a locale file, a plain file and a non locale json file.
new_case() {
  rm -rf repo && mkdir repo && cd repo
  git init -q -b main .
  mkdir -p web/locales
  printf '{\n  "a": "A",\n  "b": "B",\n  "c": "C",\n  "d": "D",\n  "e": "E",\n  "f": "F"\n}\n' >web/locales/en.json
  printf '{\n  "a": 1,\n  "b": 2,\n  "c": 3,\n  "d": 4,\n  "e": 5,\n  "f": 6\n}\n' >config.json
  seq 1 20 >notes.txt
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
run_check() { # name expect(0|1) [refusal substring]
  local rc=0
  (trunk_check) || rc=$?
  local got=0; [ ! -s "$refusals_file" ] || got=1
  [ "$got" = "$2" ] || { echo "FAIL: $1: expected refused=$2, got $got ($(cat "$refusals_file"))" >&2; exit 1; }
  if [ -n "${3:-}" ]; then grep -Fq -- "$3" "$refusals_file" || { echo "FAIL: $1: refusal lacks '$3'" >&2; exit 1; }; fi
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
run_check "main changing an existing key is refused" 1 "trunk changed web/locales/en.json"

# 4. PR changes an existing value, main adds a key: refused
new_case
git checkout -q main && sed -i.bak 's/"f": "F"/"f": "F",\n  "m": "M"/' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all main
on_pr && sed -i.bak 's/"a": "A"/"a": "changed"/' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "PR changing an existing key is refused" 1 "trunk changed web/locales/en.json"

# 5. main removes an existing key, PR adds a key: refused
new_case
git checkout -q main && sed -i.bak '/"c": "C",/d' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all main
on_pr && sed -i.bak 's/"f": "F"/"f": "F",\n  "p": "P"/' web/locales/en.json && rm -f web/locales/en.json.bak && commit_all pr
finish '["web/locales/en.json"]'
run_check "main removing an existing key is refused" 1 "trunk changed web/locales/en.json"

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

echo "all trunk tests passed"
