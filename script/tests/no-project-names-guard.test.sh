#!/usr/bin/env bash
# Behavioral tests for no-project-names.test.sh (fixture tokens only; temp repos).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
guard_src="$here/no-project-names.test.sh"
token=xyzzymatch001
fails=0
cleanup=()

check() {
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1 (got $2, want $3)"
    fails=$((fails + 1))
  fi
}

run_guard() {
  local tmp=$1 pattern_file=$2
  NO_PROJECT_NAMES_FILE=$pattern_file bash "$tmp/script/tests/no-project-names.test.sh"
}

new_fixture_repo() {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/script/tests"
  cp "$guard_src" "$tmp/script/tests/no-project-names.test.sh"
  (
    cd "$tmp" || exit 1
    git init -q .
    git config user.email fixture@example.invalid
    git config user.name Fixture
  )
  printf '%s\n' "$tmp"
}

trap '[ "${#cleanup[@]}" -gt 0 ] && rm -rf "${cleanup[@]}"' EXIT

tmp=$(new_fixture_repo)
cleanup+=("$tmp")
printf '%s\n' "$token" > "$tmp/leak.txt"
(
  cd "$tmp" || exit 1
  git add leak.txt
  git commit -qm init
)
printf '%s\n' "$token" > "$tmp/pattern.hit"
set +e
out=$(run_guard "$tmp" "$tmp/pattern.hit" 2>&1)
ec=$?
set -e
check "pattern hit fails guard" "$ec" 1
check "pattern hit mentions FAIL" "$(echo "$out" | grep -c '^FAIL:')" 1
check "pattern hit names the file" "$(echo "$out" | grep -c '^leak.txt$')" 1
check "pattern hit hides the matched text" "$(echo "$out" | grep -c "$token")" 0

tmp2=$(new_fixture_repo)
cleanup+=("$tmp2")
printf 'plain public text only\n' > "$tmp2/leak.txt"
(
  cd "$tmp2" || exit 1
  git add leak.txt
  git commit -qm init
)
printf '%s\n' "$token" > "$tmp2/pattern.hit"
set +e
out=$(run_guard "$tmp2" "$tmp2/pattern.hit" 2>&1)
ec=$?
set -e
check "clean tree passes" "$ec" 0
check "pass prints ok line" "$(echo "$out" | grep -c '^ok:')" 1

tmp3=$(new_fixture_repo)
cleanup+=("$tmp3")
printf 'nothing sensitive\n' > "$tmp3/leak.txt"
(
  cd "$tmp3" || exit 1
  git add leak.txt
  git commit -qm init
)
set +e
out=$(run_guard "$tmp3" "$tmp3/missing.pattern" 2>&1)
ec=$?
set -e
check "missing pattern file exits 0" "$ec" 0
check "missing pattern prints SKIPPED" "$(echo "$out" | grep -cxF 'SKIPPED (no pattern file; CI runs this)')" 1

tmp4=$(new_fixture_repo)
cleanup+=("$tmp4")
printf 'nothing sensitive\n' > "$tmp4/leak.txt"
(
  cd "$tmp4" || exit 1
  git add leak.txt
  git commit -qm init
)
: > "$tmp4/pattern.empty"
set +e
out=$(run_guard "$tmp4" "$tmp4/pattern.empty" 2>&1)
ec=$?
set -e
check "empty pattern file exits 0" "$ec" 0
check "empty pattern prints skip" "$(echo "$out" | grep -c '^skip:')" 1

tmp5=$(new_fixture_repo)
cleanup+=("$tmp5")
printf 'plain public text only\n' > "$tmp5/leak.txt"
(
  cd "$tmp5" || exit 1
  git add leak.txt
  git commit -qm init
)
printf 'xyzzybroken(\n' > "$tmp5/pattern.bad"
set +e
out=$(run_guard "$tmp5" "$tmp5/pattern.bad" 2>&1)
ec=$?
set -e
check "invalid pattern fails guard" "$ec" 1
check "invalid pattern does not print ok" "$(echo "$out" | grep -c '^ok:')" 0
check "invalid pattern hides the pattern text" "$(echo "$out" | grep -c xyzzybroken)" 0

tmp6=$(new_fixture_repo)
cleanup+=("$tmp6")
token_a=xyzzyalpha001
token_b=xyzzybeta002
printf '%s\n' "$token_b" > "$tmp6/leak.txt"
(
  cd "$tmp6" || exit 1
  git add leak.txt
  git commit -qm init
)
printf '%s\n%s\n' "$token_a" "$token_b" > "$tmp6/pattern.lines"
set +e
out=$(run_guard "$tmp6" "$tmp6/pattern.lines" 2>&1)
ec=$?
set -e
check "multiline pattern hits second term" "$ec" 1
check "multiline pattern hit mentions FAIL" "$(echo "$out" | grep -c '^FAIL:')" 1

tmp7=$(new_fixture_repo)
cleanup+=("$tmp7")
host=xyzzyhost003
mkdir -p "$tmp7/templates/agent-team/docs/agents"
printf 'Place the worker on %s first.\n' "$host" > "$tmp7/templates/agent-team/docs/agents/dispatch.md"
(
  cd "$tmp7" || exit 1
  git add templates
  git commit -qm init
)
printf '%s\n' "$host" > "$tmp7/pattern.host"
set +e
out=$(run_guard "$tmp7" "$tmp7/pattern.host" 2>&1)
ec=$?
set -e
check "machine name in a template doc fails guard" "$ec" 1
check "machine name hit names the template doc" "$(echo "$out" | grep -c '^templates/agent-team/docs/agents/dispatch.md$')" 1
check "machine name hit hides the name" "$(echo "$out" | grep -c "$host")" 0

echo "$fails failed"
[ "$fails" -eq 0 ]
