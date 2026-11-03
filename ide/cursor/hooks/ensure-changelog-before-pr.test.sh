#!/usr/bin/env bash
# Tests for ensure-changelog-before-pr.sh. Run: bash ide/cursor/hooks/ensure-changelog-before-pr.test.sh
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ensure-changelog-before-pr.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0

# new_repo <name> <config-json>: repo on main with one commit, then a feature branch.
new_repo() {
	local dir="$TMP/$1"
	mkdir -p "$dir/.cursor" "$dir/src"
	git -C "$dir" init -q -b main
	git -C "$dir" config user.email t@t
	git -C "$dir" config user.name t
	printf '%s\n' "$2" >"$dir/.cursor/changelog-hook.json"
	printf '# Changelog\n\n## [Unreleased]\n' >"$dir/CHANGELOG.md"
	echo a >"$dir/src/a.txt"
	git -C "$dir" add -A
	git -C "$dir" commit -q -m init
	git -C "$dir" checkout -q -b feature
	echo "$dir"
}

# run_hook <repo>: prints the hook JSON; exit code is the hook's.
run_hook() {
	local input
	input="$(jq -nc --arg cwd "$1" '{command:"gh pr create", cwd:$cwd}')"
	(cd "$1" && PR_BASE_BRANCH=main CURSOR_PROJECT_DIR="$1" bash "$HOOK" <<<"$input")
}

check() { # <label> <expected exit> <repo> [output substring]
	local out code
	out="$(run_hook "$3")"
	code=$?
	if [[ "$code" -ne "$2" ]]; then
		echo "FAIL $1: exit $code, expected $2 ($out)"
		FAILS=$((FAILS + 1))
	elif [[ -n "${4:-}" && "$out" != *"$4"* ]]; then
		echo "FAIL $1: output missing '$4' ($out)"
		FAILS=$((FAILS + 1))
	else
		echo "ok   $1"
	fi
}

commit_all() { git -C "$1" add -A && git -C "$1" commit -q -m change; }

FRAG_CFG='{"changelog":"CHANGELOG.md","shippablePrefixes":["src/"],"fragments":"changelog.d/"}'
OLD_CFG='{"changelog":"CHANGELOG.md","shippablePrefixes":["src/"]}'

r="$(new_repo frag-added "$FRAG_CFG")"
echo b >"$r/src/a.txt"
mkdir -p "$r/changelog.d" && echo "- thing" >"$r/changelog.d/12-thing.md"
commit_all "$r"
check "fragment added passes" 0 "$r"

r="$(new_repo frag-readme-only "$FRAG_CFG")"
echo b >"$r/src/a.txt"
mkdir -p "$r/changelog.d" && echo "readme" >"$r/changelog.d/README.md"
commit_all "$r"
check "README alone does not count as a fragment" 2 "$r" "changelog.d/<issue>-<slug>.md"

r="$(new_repo frag-changelog-edit "$FRAG_CFG")"
echo b >"$r/src/a.txt"
echo "- thing" >>"$r/CHANGELOG.md"
commit_all "$r"
check "CHANGELOG edited passes with fragments key" 0 "$r"

r="$(new_repo frag-neither "$FRAG_CFG")"
echo b >"$r/src/a.txt"
commit_all "$r"
check "neither blocks and names the fragment path" 2 "$r" "changelog.d/<issue>-<slug>.md"

r="$(new_repo old-neither "$OLD_CFG")"
echo b >"$r/src/a.txt"
commit_all "$r"
check "no fragments key still blocks with prepend helper" 2 "$r" "prepend-recent-change"

r="$(new_repo old-changelog "$OLD_CFG")"
echo b >"$r/src/a.txt"
echo "- thing" >>"$r/CHANGELOG.md"
commit_all "$r"
check "no fragments key, CHANGELOG edited passes" 0 "$r"

r="$(new_repo old-fragment-ignored "$OLD_CFG")"
echo b >"$r/src/a.txt"
mkdir -p "$r/changelog.d" && echo "- thing" >"$r/changelog.d/12-thing.md"
commit_all "$r"
check "no fragments key ignores changelog.d" 2 "$r"

r="$(new_repo base-config '{"changelog":"CHANGELOG.md","shippablePrefixes":["src/"],"fragments":"changelog.d/","base":"main"}')"
echo b >"$r/src/a.txt"
commit_all "$r"
input="$(jq -nc --arg cwd "$r" '{command:"gh pr create", cwd:$cwd}')"
out="$(cd "$r" && env -u PR_BASE_BRANCH CURSOR_PROJECT_DIR="$r" bash "$HOOK" <<<"$input")"
code=$?
if [[ "$code" -eq 2 ]]; then echo "ok   base from config blocks without PR_BASE_BRANCH"; else echo "FAIL base from config: exit $code ($out)"; FAILS=$((FAILS + 1)); fi

[[ "$FAILS" -eq 0 ]] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
