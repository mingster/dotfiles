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

add_if_exists() {
  local candidate=$1
  if [ -f "$ROOT/$candidate" ]; then
    add_test "$candidate"
  fi
}

add_glob_under_root() {
  local pattern=$1 f rel
  shopt -s nullglob
  # shellcheck disable=SC2086
  for f in $ROOT/$pattern; do
    [ -f "$f" ] || continue
    rel=${f#"$ROOT/"}
    add_test "$rel"
  done
  shopt -u nullglob
}

map_script_sh_base() {
  local base=$1 py
  py=${base//-/_}
  add_if_exists "script/tests/${base}.test.sh"
  add_glob_under_root "script/tests/${base}-*.test.sh"
  add_if_exists "script/${base}.test.sh"
  add_glob_under_root "script/${base}-*.test.sh"
  add_if_exists "script/tests/${base}.test.py"
  add_if_exists "script/tests/test_${py}.py"
  add_glob_under_root "script/tests/test_${py}_*.py"
}

map_script_py_base() {
  local base=$1 py
  py=${base//-/_}
  add_if_exists "script/tests/${base}.test.sh"
  add_glob_under_root "script/tests/${base}-*.test.sh"
  add_if_exists "script/tests/${base}.test.py"
  add_if_exists "script/tests/test_${py}.py"
  add_glob_under_root "script/tests/test_${py}_*.py"
}

add_full_suite() {
  add_glob_under_root "script/*.test.sh"
  add_glob_under_root "script/tests/*.test.sh"
  add_glob_under_root "script/tests/*.test.py"
  add_glob_under_root "script/tests/test_*.py"
  add_if_exists ".agents/skills/orca-team/worker-state.test.sh"
}

fallback_eligible() {
  local path=$1
  case "$path" in
    script/README*|script/*.md) return 1 ;;
    script/*) return 0 ;;
    .agents/head-checks.conf|.agents/head-checks-docs.conf) return 0 ;;
    templates/agent-team/*) return 0 ;;
    *) return 1 ;;
  esac
}

map_file() {
  local path=$1 base py before=${#selected[@]}
  case "$path" in
    script/tests/*.test.sh|script/tests/*.test.py|script/tests/test_*.py|script/*.test.sh)
      add_test "$path"
      ;;
    script/*.sh)
      base=${path#script/}
      base=${base%.sh}
      map_script_sh_base "$base"
      ;;
    script/*.py)
      base=${path#script/}
      base=${base%.py}
      map_script_py_base "$base"
      ;;
    .agents/skills/orca-team/*)
      add_if_exists ".agents/skills/orca-team/worker-state.test.sh"
      ;;
    templates/agent-team/*|script/sync-team-skills.sh)
      add_if_exists "script/agent-team.test.sh"
      add_if_exists "script/tests/release-guard-rules.test.sh"
      ;;
  esac
  if fallback_eligible "$path" && [ "${#selected[@]}" -eq "$before" ]; then
    printf 'Fallback: %s -> full suite\n' "$path"
    add_full_suite
  fi
}

skip_reason() {
  local target=$1 line path reason
  [ "$SKIP_FILE" = /dev/null ] && return 1
  [ -f "$SKIP_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    [ -n "$line" ] || continue
    path=${line%%[[:space:]]*}
    reason=${line#"$path"}
    reason=${reason#"${reason%%[![:space:]]*}"}
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
    script/tests/*.test.py) python3 "$ROOT/$test_path" ;;
    script/tests/test_*.py)
      pattern=$(basename "$test_path")
      python3 -m unittest "discover" -s "$ROOT/script/tests" -p "$pattern"
      ;;
    *) echo "unsupported test type: $test_path" >&2; exit 2 ;;
  esac
done
