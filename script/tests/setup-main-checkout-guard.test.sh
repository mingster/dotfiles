#!/usr/bin/env bash
# The setup and link scripts that wire the live home refuse to run from a linked worktree (#1543).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
PASS=0
FAIL=0
check() {
  if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1"; fi
}

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
MAIN="$TMP/main"
WT="$TMP/worker"
REAL="$TMP/real-home"
mkdir -p "$MAIN" "$REAL"
cp -R "$ROOT/script" "$MAIN/script"
rm -rf "$MAIN/script/tests"
cp -R "$ROOT/ide" "$MAIN/ide"
mkdir -p "$MAIN/.orca"
[ ! -f "$ROOT/.orca/presets.json" ] || cp "$ROOT/.orca/presets.json" "$MAIN/.orca/presets.json"
git init -q "$MAIN"
git -C "$MAIN" add -A
git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -qm seed
git -C "$MAIN" worktree add -q "$WT" -b worker

for name in setup-zed setup-orca setup-grok setup-cursor link-cursor-user link-cursor-hooks setup-vscode setup-antigravity setup-claude-desktop; do
  rc=0
  out="$(HOME="$REAL" DOTFILES_REAL_HOME="$REAL" DOTFILES="$WT" XDG_CONFIG_HOME= bash "$WT/script/$name.sh" 2>&1)" || rc=$?
  check "$name from a worktree exits 1" '[ "$rc" -eq 1 ]'
  check "$name refusal names the main checkout" 'echo "$out" | grep -qF "$name: refusing to wire $REAL from $WT; run it from the main checkout $MAIN"'
  check "$name writes nothing to the home" '[ -z "$(ls -A "$REAL")" ]'
done

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
