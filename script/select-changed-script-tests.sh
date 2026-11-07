#!/usr/bin/env bash
# Map changed dotfiles script paths to co-located tests and run them on hosted runners.
# Usage: select-changed-script-tests.sh [--list-only] <changed-path>...
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ROOT="${SELECT_SCRIPT_TESTS_ROOT:-$(cd "$here/.." && pwd)}"
SKIP_FILE="${SELECT_SCRIPT_TESTS_SKIP:-$ROOT/script/script-test-skip.list}"
list_only=false
files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --list-only) list_only=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--list-only] <changed-path>..." >&2
      exit 0
      ;;
    *) files+=("$1"); shift ;;
  esac
done

selected=()
add_test() {
  local candidate=$1 existing
  [ -f "$ROOT/$candidate" ] || return 0
  for existing in "${selected[@]+"${selected[@]}"}"; do
    [ "$existing" = "$candidate" ] && return 0
  done
  selected+=("$candidate")
}

map_file() {
  local path=$1 base py
  case "$path" in
    script/tests/*.test.sh|script/tests/test_*.py|script/*.test.sh)
      add_test "$path"
      ;;
    script/*.sh)
      base=${path#script/}
      base=${base%.sh}
      add_test "script/tests/${base}.test.sh"
      ;;
    script/*.py)
      base=${path#script/}
      base=${base%.py}
      add_test "script/tests/${base}.test.sh"
      py=${base//-/_}
      add_test "script/tests/test_${py}.py"
      ;;
  esac
}

skip_reason() {
  local target=$1 line path reason
  [ -f "$SKIP_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    [ -n "$line" ] || continue
    path=${line%%[[:space:]]*}
    reason=${line#"$path"}
    reason=${reason#"${reason%%[![:space:]]*}"}}
    [ "$path" = "$target" ] || continue
    [ -n "$reason" ] || reason="skipped on hosted runner"
    printf '%s' "$reason"
    return 0
  done < "$SKIP_FILE"
  return 1
}

for path in "${files[@]+"${files[@]}"}"; do
  map_file "$path"
done

IFS=$'\n'
sorted=$(printf '%s\n' ${selected+"${selected[@]}"} | LC_ALL=C sort -u)
unset IFS

run_list=()
while IFS= read -r test_path || [ -n "$test_path" ]; do
  [ -n "$test_path" ] || continue
  if reason=$(skip_reason "$test_path"); then
    printf 'UNCHECKED: %s %s\n' "$test_path" "$reason"
    printf 'Skipped: %s\n' "$test_path"
  else
    printf 'Selected: %s\n' "$test_path"
    run_list+=("$test_path")
  fi
done <<<"$sorted"

printf 'Script tests: %d\n' "${#run_list[@]}"
[ "$list_only" = true ] && exit 0
[ "${#run_list[@]}" -eq 0 ] && exit 0

for test_path in "${run_list[@]}"; do
  case "$test_path" in
    *.test.sh) bash "$ROOT/$test_path" ;;
    script/tests/test_*.py)
      pattern=$(basename "$test_path")
      python3 -m unittest "discover" -s "$ROOT/script/tests" -p "$pattern"
      ;;
    *) echo "unsupported test type: $test_path" >&2; exit 2 ;;
  esac
done
