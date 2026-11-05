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
  cleanup+=("$tmp")
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

trap 'rm -rf "${cleanup[@]}"' EXIT

tmp=$(new_fixture_repo)
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

tmp2=$(new_fixture_repo)
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
check "missing pattern prints skip" "$(echo "$out" | grep -c '^skip:')" 1

tmp4=$(new_fixture_repo)
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

echo "$fails failed"
[ "$fails" -eq 0 ]
