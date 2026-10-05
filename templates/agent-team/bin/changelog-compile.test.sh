#!/usr/bin/env bash
# Tests for changelog-compile.sh. Run: bash bin/changelog-compile.test.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/changelog-compile.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0

# new_fixture <name> <changelog-text>: a repo layout with the script copied in.
new_fixture() {
	local dir="$TMP/$1"
	mkdir -p "$dir/bin" "$dir/changelog.d"
	cp "$SCRIPT" "$dir/bin/changelog-compile.sh"
	printf '%s' "$2" >"$dir/CHANGELOG.md"
	echo "$dir"
}

assert_eq() { # <label> <expected> <actual> (command substitution drops the final newline)
	local expected="${2%$'\n'}"
	if [[ "$expected" == "$3" ]]; then
		echo "ok   $1"
	else
		echo "FAIL $1"
		echo "  expected: $(printf '%q' "$2")"
		echo "  actual:   $(printf '%q' "$3")"
		FAILS=$((FAILS + 1))
	fi
}

BASE=$'# Changelog\n\n## [Unreleased]\n- old\n\n## [1.0.0]\n- first\n'

# no fragments: unchanged, exit 0
d="$(new_fixture none "$BASE")"
printf 'readme\n' >"$d/changelog.d/README.md"
(cd "$d" && bash bin/changelog-compile.sh >/dev/null 2>&1)
assert_eq "no fragments: exit 0" 0 $?
assert_eq "no fragments: changelog unchanged" "$BASE" "$(cat "$d/CHANGELOG.md")"

# two fragments: sorted by file name, directly under the heading, fragments deleted
d="$(new_fixture two "$BASE")"
printf -- '- b entry\n' >"$d/changelog.d/20-b.md"
printf -- '- a entry\n' >"$d/changelog.d/10-a.md"
(cd "$d" && bash bin/changelog-compile.sh >/dev/null 2>&1)
assert_eq "two fragments: exit 0" 0 $?
assert_eq "two fragments: order and placement" \
	$'# Changelog\n\n## [Unreleased]\n- a entry\n- b entry\n- old\n\n## [1.0.0]\n- first\n' \
	"$(cat "$d/CHANGELOG.md")"
assert_eq "two fragments: deleted" 0 "$(ls "$d/changelog.d" | wc -l | tr -d ' ')"

# idempotent: second run changes nothing
before="$(cat "$d/CHANGELOG.md")"
(cd "$d" && bash bin/changelog-compile.sh >/dev/null 2>&1)
assert_eq "idempotent: exit 0" 0 $?
assert_eq "idempotent: unchanged" "$before" "$(cat "$d/CHANGELOG.md")"

# heading with a date suffix still matches; fragment without trailing newline is handled
d="$(new_fixture dated $'# Changelog\n\n## [Unreleased] 2026-10-06\n\n### Added\n')"
printf -- '- no newline' >"$d/changelog.d/1-x.md"
(cd "$d" && bash bin/changelog-compile.sh >/dev/null 2>&1)
assert_eq "dated heading: result" \
	$'# Changelog\n\n## [Unreleased] 2026-10-06\n- no newline\n\n### Added\n' \
	"$(cat "$d/CHANGELOG.md")"

# missing heading: exit 1, clear message, fragment kept, changelog untouched
d="$(new_fixture nohead $'# Changelog\n\n## [1.0.0]\n- first\n')"
printf -- '- x\n' >"$d/changelog.d/1-x.md"
msg="$(cd "$d" && bash bin/changelog-compile.sh 2>&1)"
code=$?
assert_eq "missing heading: exit 1" 1 "$code"
[[ "$msg" == *"## [Unreleased]"* ]] && assert_eq "missing heading: message names heading" 1 1 || assert_eq "missing heading: message names heading" 1 0
assert_eq "missing heading: fragment kept" 1 "$(ls "$d/changelog.d" | grep -c '1-x.md')"

# README skipped even when it is the only file with .md extension next to fragments
d="$(new_fixture readme "$BASE")"
printf 'do not compile me\n' >"$d/changelog.d/README.md"
printf -- '- real\n' >"$d/changelog.d/5-real.md"
(cd "$d" && bash bin/changelog-compile.sh >/dev/null 2>&1)
assert_eq "README skipped: content" \
	$'# Changelog\n\n## [Unreleased]\n- real\n- old\n\n## [1.0.0]\n- first\n' \
	"$(cat "$d/CHANGELOG.md")"
assert_eq "README skipped: README kept" 1 "$(ls "$d/changelog.d" | grep -c README.md)"

[[ "$FAILS" -eq 0 ]] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
