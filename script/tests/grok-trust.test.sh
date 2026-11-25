#!/usr/bin/env bash
# grok-trust.sh writes a trusted folder entry once (#1312), and trusts a linked worktree's main checkout too (#1908).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/wt1" "$tmp/wt2"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

export GROK_HOME=$tmp/grok
bash "$here/../grok-trust.sh" "$tmp/wt1" >/dev/null || bad "first run failed"
real=$(cd "$tmp/wt1" && pwd -P)
grep -qxF "[folders.\"$real\"]" "$GROK_HOME/trusted_folders.toml" && ok "entry written" || bad "entry missing"
bash "$here/../grok-trust.sh" "$tmp/wt1" "$tmp/wt2" >/dev/null || bad "second run failed"
[ "$(grep -c "^\[folders" "$GROK_HOME/trusted_folders.toml")" = 2 ] && ok "idempotent, second folder added" || bad "duplicate or missing entry"
bash "$here/../grok-trust.sh" "$tmp/nope" >/dev/null 2>&1 && bad "missing dir accepted" || ok "missing dir refused"
mkdir -p "$tmp/we\"ird\\dir"
weird=$(cd "$tmp/we\"ird\\dir" && pwd -P)
bash "$here/../grok-trust.sh" "$weird" >/dev/null || bad "weird path run failed"
bash "$here/../grok-trust.sh" "$weird" >/dev/null || bad "weird path second run failed"
python3 - "$GROK_HOME/trusted_folders.toml" "$weird" <<'PY' && ok "quote and backslash path parses as TOML, listed once" || bad "invalid TOML or wrong entry"
import sys, tomllib
d = tomllib.load(open(sys.argv[1], 'rb'))
assert sys.argv[2] in d['folders'], d
assert d['folders'][sys.argv[2]]['trusted'] is True
PY
[ "$(grep -c "^\[folders" "$GROK_HOME/trusted_folders.toml")" = 3 ] && ok "weird path idempotent" || bad "weird path duplicated"

export GROK_HOME=$tmp/grok-git GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q "$tmp/main"
git -C "$tmp/main" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$tmp/main" worktree add -q "$tmp/linked" 2>/dev/null
main=$(cd "$tmp/main" && pwd -P)
linked=$(cd "$tmp/linked" && pwd -P)
bash "$here/../grok-trust.sh" "$tmp/linked" >/dev/null || bad "linked worktree run failed"
store=$GROK_HOME/trusted_folders.toml
grep -qxF "[folders.\"$linked\"]" "$store" && ok "linked worktree trusted" || bad "linked worktree missing"
grep -qxF "[folders.\"$main\"]" "$store" && ok "main checkout of linked worktree trusted" || bad "main checkout missing"
bash "$here/../grok-trust.sh" "$tmp/linked" "$tmp/main" >/dev/null || bad "linked second run failed"
[ "$(grep -c "^\[folders" "$store")" = 2 ] && ok "linked worktree second run adds nothing" || bad "linked worktree duplicated"
mkdir -p "$tmp/linked/sub"
bash "$here/../grok-trust.sh" "$tmp/linked/sub" >/dev/null || bad "subfolder run failed"
[ "$(grep -c "^\[folders" "$store")" = 3 ] && ok "subfolder of a worktree trusts only itself" || bad "subfolder added extra entries"
exit $fail
