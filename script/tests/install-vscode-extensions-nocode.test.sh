#!/usr/bin/env bash
# install_vscode_extensions.sh with no `code` on PATH prints one line naming the missing CLI and exits 0
# (like setup-vscode.sh, which skips), before the install loop runs (#1616).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
for t in bash dirname cat; do ln -s "$(command -v "$t")" "$tmp/bin/$t"; done
rc=0
out=$(PATH="$tmp/bin" bash "$ROOT/script/install_vscode_extensions.sh" 2>&1) || rc=$?
lines=$(printf '%s\n' "$out" | grep -c .)
if [ "$rc" -eq 0 ] && [ "$lines" -eq 1 ] && grep -q 'VS Code CLI' <<<"$out" && ! grep -q 'command not found' <<<"$out"; then
  echo "ok   no code: one line, exit 0"
else
  echo "FAIL no code rc=$rc lines=$lines out=$(head -c 200 <<<"$out")"; exit 1
fi
