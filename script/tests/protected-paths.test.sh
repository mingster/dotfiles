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

# Owner decision 2026-11-28: role files, model-routing.md and docs/agents/ pass with no trailer.
for p in AGENTS.md .claude/agents/elon.md .claude/model-routing.md model-routing.md docs/agents/team.md \
  docs/agents/team-facts.md templates/agent-team/docs/agents/team.md templates/agent-team/.claude/agents/elon.md; do
  reset_branch
  printf 'touch path\n' > "$tmp/msg"
  commit_path "$p"
  expect_allow "$p passes with no trailer" "$(git -C "$repo" rev-parse HEAD)" "$p" ""
done

reset_branch
printf '%s' "$owner_msg_two" > "$tmp/msg"
commit_path docs/intent/example.md
expect_allow "two trailers on an accepted intent pass" "$(git -C "$repo" rev-parse HEAD)" docs/intent/example.md "$intent_diff"

reset_branch
printf 'touch path\n' > "$tmp/msg"
commit_path docs/intent/example.md
expect_refuse "an accepted intent with no trailer is refused" "$(git -C "$repo" rev-parse HEAD)" docs/intent/example.md "$intent_diff" "$intent_needle"

reset_branch
printf 'touch path\n\nOwner-approved:\n' > "$tmp/msg"
commit_path docs/intent/example.md
expect_refuse "an empty trailer on an accepted intent is refused" "$(git -C "$repo" rev-parse HEAD)" docs/intent/example.md "$intent_diff" "$intent_needle"

reset_branch
printf 'touch path\n\nOwner-approved:   \n' > "$tmp/msg"
commit_path docs/intent/example.md
expect_refuse "a whitespace trailer on an accepted intent is refused" "$(git -C "$repo" rev-parse HEAD)" docs/intent/example.md "$intent_diff" "$intent_needle"

reset_branch
printf 'touch path\n' > "$tmp/msg"
commit_path docs/intent/example.md
printf '%s' "$owner_msg_two" > "$tmp/msg"
commit_path docs/intent/example.md
expect_refuse "a later approved commit still refuses an earlier intent commit with no trailer" "$(git -C "$repo" rev-parse HEAD)" docs/intent/example.md "$intent_diff" "$intent_needle"

# Unfetched PR head (under refs/pull/<pr>/head on origin) and unfetched base (on origin/main) are fetched before checking receipts.
remote=$tmp/remote.git
git init -q --bare "$remote"
clone=$tmp/clone
git clone -q "$remote" "$clone" 2>/dev/null || { git init -q -b main "$clone"; git -C "$clone" remote add origin "$remote"; }
git -C "$clone" config core.hooksPath "$tmp/hooks"
git -C "$repo" checkout -q main
printf 'base2\n' > "$repo/base2.txt"
git -C "$repo" add base2.txt
git -C "$repo" commit -q -m "advance main"
remote_base=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" push -q "$remote" main:refs/heads/main
git -C "$repo" checkout -q -B pr-intent "$remote_base"
printf '%s' "$owner_msg_one" > "$tmp/msg"
commit_path docs/intent/example.md
remote_head=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" push -q "$remote" "$remote_head:refs/pull/42/head"

out=$(
  set -euo pipefail
  cd "$clone"
  pr=42
  head=$remote_head
  files='["docs/intent/example.md"]'
  diff=$intent_diff
  info=$(jq -n --arg b "$remote_base" '{baseRefOid:$b,comments:[]}')
  field() { jq -r "$1" <<<"$info"; }
  refuse() { printf 'REFUSED:%s\n' "$*"; exit 7; }
  die() { printf 'DIE:%s\n' "$*"; exit 8; }
  verdict_carry() { return 1; }
  check_protected_paths
  printf 'ALLOWED\n'
)
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = ALLOWED ]; then
  ok "unfetched pull/<pr>/head and origin/main base are fetched before checking intent acceptance receipt"
else
  bad "unfetched pull/<pr>/head and origin/main base are fetched before checking intent acceptance receipt" "rc=$rc out=$out"
fi

# Intent trailer form: Owner-approved: intent <owner/repo>#<pr> accepted <date>.
# A fake gh serves the cited PR and the cited repo's default branch files from $tmp/gh.
mkdir -p "$tmp/gh/files/docs/intent/2026-11-27-example"
printf '{"state":"MERGED","files":[{"path":"docs/intent/2026-11-27-example/intent.md"}]}\n' > "$tmp/gh/pr-77.json"
printf '{"state":"OPEN","files":[{"path":"docs/intent/2026-11-27-example/intent.md"}]}\n' > "$tmp/gh/pr-78.json"
printf '# Example\n\nStatus: Proposed 2026-11-26 · Accepted 2026-11-27\n' > "$tmp/gh/files/docs/intent/2026-11-27-example/intent.md"
# shellcheck disable=SC2016 # literal Markdown backticks
printf '# Example: spec\n\n## Owner steps\n- `AGENTS.md`: add the new rule.\n- `.claude/hooks/guard-bash.py`: add the guard.\n- `.claude/settings.json`: wire the guard.\n\n## Rollout\n- `docs/agents/team.md` is named here, outside Owner steps.\n' \
  > "$tmp/gh/files/docs/intent/2026-11-27-example/spec.md"

run_gate_gh() { # <head> <path> <diff>
  local head_sha=$1 path=$2 diff_text=$3
  # shellcheck disable=SC2034,SC2329
  (
    set -euo pipefail
    cd "$repo"
    gh() {
      case "$1 $2" in
        "pr view") cat "$tmp/gh/pr-$3.json" ;;
        "api -H") local p=${4#repos/*/*/contents/}; cat "$tmp/gh/files/$p" ;;
        *) return 1 ;;
      esac
    }
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

expect_gh() { # <name> <allow|refuse> <head> <path> <diff> [needle]
  local out rc
  out=$(run_gate_gh "$3" "$4" "$5" 2>&1)
  rc=$?
  if [ "$2" = allow ] && [ "$rc" -eq 0 ] && [ "$out" = ALLOWED ]; then ok "$1"
  elif [ "$2" = refuse ] && [ "$rc" -eq 7 ] && [[ "$out" == *"$6"* ]]; then ok "$1"
  else bad "$1" "rc=$rc out=$out"; fi
}

intent_msg() { printf 'touch path\n\nOwner-approved: intent example/repo#%s accepted %s\n' "$1" "$2"; }

reset_branch
intent_msg 77 2026-11-27 > "$tmp/msg"
commit_path docs/intent/example.md
expect_gh "an intent trailer does not accept an intent" refuse "$(git -C "$repo" rev-parse HEAD)" docs/intent/example.md "$intent_diff" "$intent_needle"

# Pre go-live waiver fixture: the gate must reach load_owner_receipts owner. A plain Owner-approved trailer
# passes under it, so an intent trailer that is refused under the same fixture is refused by owner mode.
run_gate_waiver() { # <head> <path>
  local head_sha=$1 path=$2
  # shellcheck disable=SC2034,SC2329
  (
    set -euo pipefail
    cd "$repo"
    gh() {
      case "$1 $2" in
        "pr view") cat "$tmp/gh/pr-$3.json" ;;
        "api -H") local p=${4#repos/*/*/contents/}; cat "$tmp/gh/files/$p" ;;
        *) return 1 ;;
      esac
    }
    head=$head_sha
    files=$(jq -n --arg p "$path" '[$p]')
    diff=""
    export SHIP_TODAY=2026-11-19
    info=$(jq -n --arg b "$base" --arg h "$head_sha" '{
      baseRefOid: $b,
      body: "Builder: agent=claude model=sonnet\n",
      comments: [
        {body: ("Review: PASS head=" + $h)},
        {body: ("Verdict: PASS head=" + $h + " verifier=qa author=dev agent=codex model=gpt-5")}
      ]}')
    field() { jq -r "$1" <<<"$info"; }
    refuse() { printf 'REFUSED:%s\n' "$*"; exit 7; }
    die() { printf 'DIE:%s\n' "$*"; exit 8; }
    check_protected_paths
    printf 'ALLOWED\n'
  ) 2>&1
}

expect_waiver() { # <name> <allow|refuse> <head> <path> [needle]
  local out rc
  out=$(run_gate_waiver "$3" "$4")
  rc=$?
  if [ "$2" = allow ] && [ "$rc" -eq 0 ] && [[ "$out" == *"owner-only path waived until "* && "$out" == *ALLOWED ]]; then ok "$1"
  elif [ "$2" = refuse ] && [ "$rc" -eq 7 ] && [[ "$out" == *"$5"* ]]; then ok "$1"
  else bad "$1" "rc=$rc out=$out"; fi
}

for p in .claude/hooks/guard-bash.py .claude/settings.json script/lib/protected-paths.sh templates/agent-team/.claude/hooks/guard-bash.py; do
  reset_branch
  intent_msg 77 2026-11-27 > "$tmp/msg"
  commit_path "$p"
  expect_waiver "an intent trailer does not open owner only $p under the pre go-live waiver" refuse "$(git -C "$repo" rev-parse HEAD)" "$p" "waits for the owner"
  reset_branch
  printf '%s' "$owner_msg_one" > "$tmp/msg"
  commit_path "$p"
  expect_waiver "a plain Owner-approved trailer passes $p under the pre go-live waiver" allow "$(git -C "$repo" rev-parse HEAD)" "$p"
done

for p in .claude/hooks/guard-bash.py templates/agent-team/.claude/hooks/guard-bash.py script/lib/protected-paths.sh docs/intent/a/intent.md; do
  if owner_only_path "$p" || protected_path "$p"; then ok "$p is owner-gated"; else bad "$p is owner-gated" "not matched"; fi
done
for p in .claude/model-routing.md templates/agent-team/.claude/model-routing.md model-routing.md web/AGENTS.md AGENTS.md \
  .claude/agents/elon.md docs/agents/team.md docs/agents/elon-dispatch.md docs/agents/issue-tracker.md templates/agent-team/docs/agents/team.md; do
  if owner_only_path "$p" || protected_path "$p"; then bad "$p is not owner-gated" "matched"; else ok "$p is not owner-gated"; fi
done

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
