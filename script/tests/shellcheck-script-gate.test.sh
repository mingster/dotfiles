#!/usr/bin/env bash
# script/shellcheck-dotfiles.sh must gate script/*.sh and script/lib/*.sh at error level (#1420).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
fail=0

if grep -qE 'script/\*\.sh' script/shellcheck-dotfiles.sh && grep -qE 'script/lib/\*\.sh' script/shellcheck-dotfiles.sh; then
  echo "ok   wrapper names script/*.sh and script/lib/*.sh"
else
  echo "FAIL wrapper does not check script/*.sh and script/lib/*.sh"
  fail=1
fi

if awk '/^exec /{e=1;next} e&&/echo/{f=1} END{exit !f}' script/shellcheck-dotfiles.sh; then
  echo "FAIL unreachable line after exec in shellcheck-dotfiles.sh"
  fail=1
else
  echo "ok   nothing after exec"
fi

if out="$(shellcheck -x --severity=error script/install_vscode_extensions.sh 2>&1)" && [ -z "$out" ]; then
  echo "ok   install_vscode_extensions.sh clean at error severity"
else
  echo "FAIL install_vscode_extensions.sh: $out"
  fail=1
fi

if bash script/shellcheck-dotfiles.sh >/dev/null 2>&1; then
  echo "ok   shellcheck-dotfiles.sh exits 0"
else
  echo "FAIL shellcheck-dotfiles.sh exits non-zero"
  fail=1
fi
exit "$fail"
