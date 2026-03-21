#!/usr/bin/env bash
# Run ShellCheck on main install entrypoints (same set as CI).
# Uses --severity=error so info/style (e.g. SC2086 quoting) does not fail the run;
# run `shellcheck -x <file>` without that flag for full diagnostics.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not found. Install: https://github.com/koalaman/shellcheck#installing" >&2
  exit 1
fi

exec shellcheck -x --severity=error \
  install.sh \
  mac/stowall \
  mac/system_setup.sh \
  arch/system_setup.sh \
  debian/system_setup.sh
