#!/usr/bin/env bash
# Tests for agent-project-autoinit.sh using temp repos with fake origin URLs.
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export AUTOINIT_NO_LABELS=1 DOTFILES="${DOTFILES:-$(cd "$here/.." && pwd)}"
pass=0; fail=0
check() { # name, condition result
  if [ "$2" = ok ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi
}
mkrepo() { git init -q "$tmp/$1"; [ -n "$2" ] && git -C "$tmp/$1" remote add origin "$2"; }
run() { (cd "$1" && bash "$here/agent-project-autoinit.sh" </dev/null 2>&1); echo "exit=$?"; }

mkdir "$tmp/plain"
out=$(run "$tmp/plain"); [ "$out" = "exit=0" ] && check "non-git dir is a no-op" ok || check "non-git dir is a no-op" bad

mkrepo other https://github.com/someone/else.git
out=$(run "$tmp/other"); { [ "$out" = "exit=0" ] && [ ! -d "$tmp/other/docs" ]; } && check "non-mingster remote is a no-op" ok || check "non-mingster remote is a no-op" bad

mkrepo done git@github.com:mingster/done.git
mkdir -p "$tmp/done/docs/agents"; echo x > "$tmp/done/docs/agents/issue-tracker.md"
out=$(run "$tmp/done"); { [ "$out" = "exit=0" ] && [ ! -f "$tmp/done/AGENTS.md" ]; } && check "set-up repo is a no-op" ok || check "set-up repo is a no-op" bad

mkrepo fresh https://github.com/mingster/fresh.git
out=$(run "$tmp/fresh")
{ echo "$out" | grep -q "seeded" && [ -f "$tmp/fresh/docs/agents/issue-tracker.md" ] && [ -f "$tmp/fresh/docs/agents/triage-labels.md" ] && [ -f "$tmp/fresh/docs/agents/domain.md" ] && grep -q "Agent skills" "$tmp/fresh/AGENTS.md" && echo "$out" | grep -q "exit=0"; } && check "mingster repo without files seeds them" ok || { check "mingster repo without files seeds them" bad; echo "$out"; }
[ -z "$(git -C "$tmp/fresh" log --oneline 2>/dev/null)" ] && check "never commits" ok || check "never commits" bad

echo "passed $pass, failed $fail"; [ "$fail" = 0 ]
