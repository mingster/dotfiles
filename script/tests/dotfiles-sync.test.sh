#!/usr/bin/env bash
# dotfiles-sync.sh against local bare origins (no network).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$here/tests/lib/asdf-pin.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$tmp/gitconfig" user.name test
git config --file "$tmp/gitconfig" user.email test@example.invalid
git config --file "$tmp/gitconfig" init.defaultBranch main
unset CLAUDE_PROJECT_DIR GIT_SSH_COMMAND
export HOME="$tmp/home" AGENT_STATE_DIR="$tmp/state"
mkdir -p "$HOME" "$AGENT_STATE_DIR"
export DOTFILES_DIR="$tmp/dots"

# fresh: a bare origin plus a clean clone at $DOTFILES_DIR one commit behind it
fresh() {
  rm -rf "$tmp/o.git" "$DOTFILES_DIR" "$tmp/up"
  git init -q --bare "$tmp/o.git"
  git clone -q "$tmp/o.git" "$DOTFILES_DIR" 2>/dev/null
  git -C "$DOTFILES_DIR" commit -q --allow-empty -m one
  git -C "$DOTFILES_DIR" push -q origin main
  git clone -q "$tmp/o.git" "$tmp/up"
  git -C "$tmp/up" commit -q --allow-empty -m two
  git -C "$tmp/up" push -q origin main
}
tip() { git --git-dir="$tmp/o.git" rev-parse main; }
head_of() { git -C "$DOTFILES_DIR" rev-parse HEAD; }
run() { (cd "$DOTFILES_DIR" && bash "$here/dotfiles-sync.sh" 2>&1); }
one_line() { [ "$(printf '%s\n' "$1" | wc -l | tr -d ' ')" = 1 ] && grep -q "$2" <<<"$1"; }

fresh
out=$(run); ec=$?
check "clean behind checkout fast-forwards" "$([ "$(head_of)" = "$(tip)" ] && echo 0 || echo 1)"
check "exits 0 after fast-forward" "$ec"

fresh
echo x >"$DOTFILES_DIR/f"; git -C "$DOTFILES_DIR" add f
before=$(head_of); out=$(run); ec=$?
check "dirty checkout is left alone" "$([ "$(head_of)" = "$before" ] && echo 0 || echo 1)"
check "dirty prints one warning" "$(one_line "$out" dirty; echo $?)"
check "dirty exits 0" "$ec"

fresh
git -C "$DOTFILES_DIR" commit -q --allow-empty -m local
before=$(head_of); out=$(run); ec=$?
check "diverged checkout is left alone" "$([ "$(head_of)" = "$before" ] && echo 0 || echo 1)"
check "diverged prints one warning" "$(one_line "$out" diverged; echo $?)"
check "diverged exits 0" "$ec"

fresh
git -C "$DOTFILES_DIR" remote set-url origin "$tmp/missing.git"
before=$(head_of); out=$(run); ec=$?
check "offline checkout is left alone" "$([ "$(head_of)" = "$before" ] && echo 0 || echo 1)"
check "offline prints one warning" "$(one_line "$out" 'fetch failed'; echo $?)"
check "offline exits 0" "$ec"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
