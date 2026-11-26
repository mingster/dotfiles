#!/usr/bin/env bash
# Pre go-live waiver for owner-only paths (check_owner_only_paths in script/lib/protected-paths.sh).
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck disable=SC1091
. "$root/script/tests/lib/git-identity.sh"
# shellcheck disable=SC1091
. "$root/script/lib/protected-paths.sh"

pass=0
fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
use_test_git_identity "$tmp"

repo=$tmp/repo
mkdir -p "$tmp/hooks"
git init -q -b main "$repo"
git -C "$repo" config core.hooksPath "$tmp/hooks"
printf 'base\n' > "$repo/base.txt"
git -C "$repo" add base.txt
git -C "$repo" commit -q -m init
base=$(git -C "$repo" rev-parse HEAD)

commit_path() { # <path> <message>
  git -C "$repo" checkout -q -B feat "$base"
  mkdir -p "$repo/$(dirname "$1")"
  printf '%s\n' "$1" > "$repo/$1"
  git -C "$repo" add -- "$1"
  git -C "$repo" commit -q -m "$2" -- "$1"
  git -C "$repo" rev-parse HEAD
}

trailer_msg='fix guard

Owner-approved: mingster 2026-11-19 (owner: "no approval until go live")'

run_gate() { # <head> <path> <today> <verifier model> <review line prefix>
  local head_sha=$1 path=$2 today=$3 vmodel=$4 review=$5
  # The sourced gate reads these names. Shellcheck cannot see across the source.
  # shellcheck disable=SC2034,SC2329
  (
    set -euo pipefail
    cd "$repo"
    head=$head_sha
    files=$(jq -n --arg p "$path" '[$p]')
    diff=""
    export SHIP_TODAY=$today
    info=$(jq -n --arg b "$base" --arg h "$head_sha" --arg vm "$vmodel" --arg r "$review" '{
      baseRefOid: $b,
      body: "Builder: agent=claude model=sonnet\n",
      comments: [
        {body: ("Review: " + $r + " head=" + $h)},
        {body: ("Verdict: PASS head=" + $h + " verifier=qa author=dev agent=codex model=" + $vm)}
      ]}')
    field() { jq -r "$1" <<<"$info"; }
    refuse() { printf 'REFUSED:%s\n' "$*"; exit 7; }
    die() { printf 'DIE:%s\n' "$*"; exit 8; }
    check_owner_only_paths
    printf 'ALLOWED\n'
  ) 2>&1
}

needle='waits for the owner through Elon'
line_re='ship: owner-only path waived until 2026-11-30 (pre go-live rule)'

h=$(commit_path .claude/hooks/guard.py "$trailer_msg")
out=$(run_gate "$h" .claude/hooks/guard.py 2026-11-19 gpt-5 PASS)
if [[ "$out" == *"$line_re"* && "$out" == *ALLOWED ]]; then ok "before date with receipts passes and prints the waiver line"; else bad "before date with receipts passes" "$out"; fi

out=$(run_gate "$h" templates/agent-team/.claude/settings.json 2026-11-19 gpt-5 PASS)
if [[ "$out" == *REFUSED:*"$needle"* ]]; then ok "path with no receipt commit is refused"; else bad "path with no receipt commit is refused" "$out"; fi

h2=$(commit_path .claude/hooks/guard.py "fix guard")
out=$(run_gate "$h2" .claude/hooks/guard.py 2026-11-19 gpt-5 PASS)
if [[ "$out" == *REFUSED:*"$needle"* ]]; then ok "before date without a trailer refuses"; else bad "before date without a trailer refuses" "$out"; fi

out=$(run_gate "$h" .claude/hooks/guard.py 2026-11-30 gpt-5 PASS)
if [[ "$out" == *REFUSED:*"$needle"* ]]; then ok "on the date refuses"; else bad "on the date refuses" "$out"; fi
out=$(run_gate "$h" .claude/hooks/guard.py 2027-01-02 gpt-5 PASS)
if [[ "$out" == *REFUSED:*"$needle"* ]]; then ok "after the date refuses"; else bad "after the date refuses" "$out"; fi

out=$(run_gate "$h" .claude/hooks/guard.py 2026-11-19 claude-opus-5 PASS)
if [[ "$out" == *REFUSED:*"$needle"* ]]; then ok "same model family verifier refuses"; else bad "same model family verifier refuses" "$out"; fi

out=$(run_gate "$h" .claude/hooks/guard.py 2026-11-19 gpt-5 FAIL)
if [[ "$out" == *REFUSED:*"$needle"* ]]; then ok "Review FAIL refuses"; else bad "Review FAIL refuses" "$out"; fi

h4=$(commit_path .claude/hooks/guard.py "fix guard

Owner-approved: intent example/repo#77 accepted 2026-11-19")
out=$(run_gate "$h4" .claude/hooks/guard.py 2026-11-19 gpt-5 PASS)
if [[ "$out" == *REFUSED:*"$needle"* ]]; then ok "an intent trailer is no owner receipt for the waiver"; else bad "an intent trailer is no owner receipt for the waiver" "$out"; fi

owner_script=bin/owner-approve.sh
h3=$(commit_path "$owner_script" "$trailer_msg")
out=$(run_gate "$h3" "$owner_script" 2026-11-19 gpt-5 PASS)
if [[ "$out" == *REFUSED:*"$needle"* && "$out" != *ALLOWED* ]]; then ok "the owner approval script is never waived"; else bad "the owner approval script is never waived" "$out"; fi

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
