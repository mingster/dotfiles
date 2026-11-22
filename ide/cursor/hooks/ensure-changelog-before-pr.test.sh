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

r="$(new_repo secret-md "$FRAG_CFG")"
SECRET='postgres://u:hunter2@host/db'
echo "DATABASE=$SECRET" >"$r/notes.md"
commit_all "$r"
input="$(jq -nc --arg cwd "$r" '{command:"gh pr create", cwd:$cwd}')"
out="$(cd "$r" && PR_BASE_BRANCH=main CURSOR_PROJECT_DIR="$r" bash "$HOOK" <<<"$input" 2>"$TMP/secret.err")"
code=$?
err="$(cat "$TMP/secret.err")"
if [[ "$code" -ne 2 ]]; then
	echo "FAIL secret in md: exit $code, expected 2 ($out)"; FAILS=$((FAILS + 1))
elif [[ "$out" == *hunter2* || "$err" == *hunter2* ]]; then
	echo "FAIL secret in md: secret leaked (stdout: $out) (stderr: $err)"; FAILS=$((FAILS + 1))
elif ! jq -se 'length == 1 and .[0].permission == "deny"' <<<"$out" >/dev/null 2>&1; then
	echo "FAIL secret in md: stdout is not exactly one deny JSON object ($out)"; FAILS=$((FAILS + 1))
else
	echo "ok   secret in md denies with one JSON object and no secret"
fi

# Zero-Env scan reads only added lines and skips placeholder passwords.
r="$(new_repo placeholder-old-line "$FRAG_CFG")"
echo 'DATABASE_URL=postgresql://user:hunter2@localhost:5432/db' >"$r/README.md"
git -C "$r" add -A && git -C "$r" commit -q -m readme && git -C "$r" branch -f main HEAD
echo 'a typo fix' >>"$r/README.md"
commit_all "$r"
check "old secret line in a touched doc passes" 0 "$r"

for ph in password changeme '<password>' '${DB_PASS}' '[Omitted/Configured via Env]'; do
	r="$(new_repo "placeholder-$RANDOM" "$FRAG_CFG")"
	echo "DATABASE_URL=postgresql://user:${ph}@localhost:5432/db" >"$r/README.md"
	commit_all "$r"
	check "placeholder $ph passes" 0 "$r"
done

r="$(new_repo secret-added-later "$FRAG_CFG")"
echo 'intro' >"$r/README.md"
git -C "$r" add -A && git -C "$r" commit -q -m readme && git -C "$r" branch -f main HEAD
echo 'DATABASE_URL=postgres://u:hunter2@host/db' >>"$r/README.md"
commit_all "$r"
check "real secret added to a touched doc denies" 2 "$r" "Zero-Env"

r="$(new_repo secret-uncommitted "$FRAG_CFG")"
echo 'DATABASE_URL=postgres://u:hunter2@host/db' >"$r/notes.md"
git -C "$r" add notes.md
check "staged real secret denies" 2 "$r" "Zero-Env"

# Separator coverage: the command string decides whether the gate runs.
cmd_check() { # <label> <expected exit> <repo> <command>
	local out code input
	input="$(jq -nc --arg cwd "$3" --arg c "$4" '{command:$c, cwd:$cwd}')"
	out="$(cd "$3" && PR_BASE_BRANCH=main CURSOR_PROJECT_DIR="$3" bash "$HOOK" <<<"$input")"
	code=$?
	if [[ "$code" -eq "$2" ]]; then echo "ok   $1"; else echo "FAIL $1: exit $code, expected $2 ($out)"; FAILS=$((FAILS + 1)); fi
}

r="$(new_repo sep "$FRAG_CFG")"
echo b >"$r/src/a.txt"
commit_all "$r"
cmd_check "pipe without spaces denies" 2 "$r" 'git push 2>&1|gh pr create -t x'
cmd_check "a|gh pr create denies" 2 "$r" 'a|gh pr create'
cmd_check "subshell denies" 2 "$r" '(gh pr create)'
cmd_check "semicolon no space denies" 2 "$r" 'x;gh pr create'
cmd_check "semicolon with space denies" 2 "$r" 'x; gh pr create -t y'
cmd_check "and-and denies" 2 "$r" 'x && gh pr create'
cmd_check "mention in quotes passes" 0 "$r" "echo 'gh pr create'"

# hooks.json matcher and the script regex must be the same string.
script_re="$(sed -n "s/^GH_PR_CREATE_RE='\(.*\)'\$/\1/p" "$HOOK")"
json_re="$(jq -r '.hooks.beforeShellExecution[] | select(.command | endswith("ensure-changelog-before-pr.sh")) | .matcher' "$(dirname "$HOOK")/../hooks.json")"
if [[ -n "$script_re" && "$script_re" == "$json_re" ]]; then echo "ok   hooks.json matcher equals script regex"; else echo "FAIL matcher differs: script='$script_re' json='$json_re'"; FAILS=$((FAILS + 1)); fi

[[ "$FAILS" -eq 0 ]] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
