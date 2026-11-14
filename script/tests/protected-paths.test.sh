#!/usr/bin/env bash
# Owner receipt on owner-gated paths and accepted intents.
# A commit with two Owner-approved trailers counts as approved. An empty or whitespace value does not.
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
n=0

reset_branch() { git -C "$repo" checkout -q -B feat "$base"; }

commit_path() { # <path>
  n=$((n + 1))
  mkdir -p "$repo/$(dirname "$1")"
  printf '%s %s\n' "$1" "$n" > "$repo/$1"
  git -C "$repo" add -- "$1"
  git -C "$repo" commit -q -F "$tmp/msg" -- "$1"
}

run_gate() { # <head> <path> <diff>
  local head_sha=$1 path=$2 diff_text=$3
  # The sourced gate reads these names. Shellcheck cannot see across the source.
  # shellcheck disable=SC2034,SC2329
  (
    set -euo pipefail
    cd "$repo"
    head=$head_sha
    files=$(jq -n --arg p "$path" '[$p]')
    diff=$diff_text
    info=$(jq -n --arg b "$base" '{baseRefOid:$b,comments:[]}')
    field() { jq -r "$1" <<<"$info"; }
    refuse() { printf 'REFUSED:%s\n' "$*"; exit 7; }
    die() { printf 'DIE:%s\n' "$*"; exit 8; }
    verdict_carry() { return 1; }
    check_protected_paths
    printf 'ALLOWED\n'
  )
}

expect_allow() { # <name> <head> <path> <diff>
  local out rc
  out=$(run_gate "$2" "$3" "$4" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = ALLOWED ]; then
    ok "$1"
  else
    bad "$1" "rc=$rc out=$out"
  fi
}

expect_refuse() { # <name> <head> <path> <diff> <needle>
  local out rc
  out=$(run_gate "$2" "$3" "$4" 2>&1)
  rc=$?
  if [ "$rc" -eq 7 ] && [[ "$out" == *"$5"* ]]; then
    ok "$1"
  else
    bad "$1" "rc=$rc out=$out"
  fi
}

owner_msg_two='touch path

Owner-approved: mingster 2026-11-13 (chat)
Owner-approved: mingster 2026-11-14 (chat)
'
owner_msg_one='touch path

Owner-approved: mingster 2026-11-13 (chat)
'
owner_needle='touches owner-gated paths without Owner-approved trailer'
intent_diff=$(printf '%s\n' '+++ b/docs/intent/example.md' '+Status: Accepted')
intent_needle='without an Owner-approved: trailer on every commit'

reset_branch
printf '%s' "$owner_msg_two" > "$tmp/msg"
commit_path AGENTS.md
expect_allow "two trailers on an owner-gated path pass" "$(git -C "$repo" rev-parse HEAD)" AGENTS.md ""

reset_branch
printf '%s' "$owner_msg_one" > "$tmp/msg"
commit_path AGENTS.md
expect_allow "one trailer on an owner-gated path passes" "$(git -C "$repo" rev-parse HEAD)" AGENTS.md ""

reset_branch
printf 'touch path\n' > "$tmp/msg"
commit_path AGENTS.md
expect_refuse "no trailer on an owner-gated path is refused" "$(git -C "$repo" rev-parse HEAD)" AGENTS.md "" "$owner_needle"

reset_branch
printf 'touch path\n\nOwner-approved:\n' > "$tmp/msg"
commit_path AGENTS.md
expect_refuse "an empty trailer is refused" "$(git -C "$repo" rev-parse HEAD)" AGENTS.md "" "$owner_needle"

reset_branch
printf 'touch path\n\nOwner-approved:   \n' > "$tmp/msg"
commit_path AGENTS.md
expect_refuse "a whitespace trailer is refused" "$(git -C "$repo" rev-parse HEAD)" AGENTS.md "" "$owner_needle"

reset_branch
printf 'touch path\n' > "$tmp/msg"
commit_path AGENTS.md
missing=$(git -C "$repo" rev-parse HEAD)
printf '%s' "$owner_msg_two" > "$tmp/msg"
commit_path AGENTS.md
expect_refuse "a later approved commit still refuses an earlier commit with no trailer" "$(git -C "$repo" rev-parse HEAD)" AGENTS.md "" "commit ${missing:0:12} $owner_needle"

reset_branch
printf '%s' "$owner_msg_two" > "$tmp/msg"
commit_path docs/intent/example.md
expect_allow "two trailers on an accepted intent pass" "$(git -C "$repo" rev-parse HEAD)" docs/intent/example.md "$intent_diff"

reset_branch
printf 'touch path\n' > "$tmp/msg"
commit_path docs/intent/example.md
expect_refuse "an accepted intent with no trailer is refused" "$(git -C "$repo" rev-parse HEAD)" docs/intent/example.md "$intent_diff" "$intent_needle"

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
