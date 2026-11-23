#!/usr/bin/env bash
# check-skill-collisions.sh: empty or missing project roots, flags, and each failure class.
# Runs the script under /bin/bash (3.2 on macOS) with no orca on PATH and a temp HOME.
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/asdf-pin.sh
. "$(dirname "$0")/lib/asdf-pin.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home"
D="$tmp/dotfiles"
mkdir -p "$D/.agents/skills/alpha"
printf 'alpha\n' >"$D/.agents/skills/alpha/SKILL.md"

pass=0
fail=0
t() { if eval "$2"; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }
run() { HOME="$tmp/home" PATH=/usr/bin:/bin DOTFILES="$D" /bin/bash "$here/check-skill-collisions.sh" "$@" 2>&1; }

# project <name> <skill> [nomd]: .claude/skills/<skill> with a SKILL.md unless nomd.
project() {
  mkdir -p "$tmp/$1/.claude/skills/$2"
  [ "${3:-}" = nomd ] || printf '%s\n' "$2" >"$tmp/$1/.claude/skills/$2/SKILL.md"
}

mkdir -p "$tmp/empty"
out=$(run "$tmp/empty"); code=$?
t "empty root: exit 0" '[ "$code" = 0 ]'
t "empty root: prints Project skill directories: 0" 'echo "$out" | grep -qx "Project skill directories: 0"'
t "empty root: prints the summary line" 'echo "$out" | grep -q "problem(s)"'
t "empty root: no unbound variable" '! echo "$out" | grep -q unbound'

out=$(run "$tmp/does-not-exist"); code=$?
t "missing root: exit 0" '[ "$code" = 0 ]'
t "missing root: warns and counts 0" 'echo "$out" | grep -q "root does not exist" && echo "$out" | grep -qx "Project skill directories: 0"'
t "missing root: no unbound variable" '! echo "$out" | grep -q unbound'

out=$(run -h); code=$?
t "-h prints usage, exit 0" '[ "$code" = 0 ] && echo "$out" | grep -q "^Usage:"'
out=$(run --help); code=$?
t "--help prints usage, exit 0" '[ "$code" = 0 ] && echo "$out" | grep -q "^Usage:"'
out=$(run --bogus); code=$?
t "other flag: usage, exit 2" '[ "$code" = 2 ] && echo "$out" | grep -q "^Usage:"'

project clean beta
out=$(run "$tmp/clean"); code=$?
t "clean tree: exit 0, no problems" '[ "$code" = 0 ] && echo "$out" | grep -q "^0 problem(s)"'

project shadow alpha
out=$(run "$tmp/shadow"); code=$?
t "shadowing a central skill: exit 1" '[ "$code" = 1 ] && echo "$out" | grep -q "alpha shadows"'

project broken gamma
ln -s "$tmp/nowhere" "$tmp/broken/.claude/skills/dead"
out=$(run "$tmp/broken"); code=$?
t "broken symlink: exit 1" '[ "$code" = 1 ] && echo "$out" | grep -q "broken symlink"'

project nomd delta nomd
out=$(run "$tmp/nomd"); code=$?
t "directory without SKILL.md: exit 1" '[ "$code" = 1 ] && echo "$out" | grep -q "delta has no SKILL.md"'

project one same
project two same
out=$(run "$tmp/one" "$tmp/two"); code=$?
t "same name in two projects: warns, exit 0" '[ "$code" = 0 ] && echo "$out" | grep -q "same also exists at"'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
