#!/usr/bin/env bash
# Run ShellCheck on main install entrypoints (same set as CI).
# Uses --severity=error so info/style (e.g. SC2086 quoting) does not fail the run;
# run `shellcheck -x <file>` without that flag for full diagnostics.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not found. Installing..." >&2
  case "${OSTYPE:-}" in
    darwin*)  brew install shellcheck ;;
    linux*)
      if command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm shellcheck
      elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y shellcheck
      else
        echo "shellcheck: cannot install automatically. See https://github.com/koalaman/shellcheck#installing" >&2
        exit 1
      fi
      ;;
    *)
      echo "shellcheck: unsupported OS. See https://github.com/koalaman/shellcheck#installing" >&2
      exit 1
      ;;
  esac
fi

exec shellcheck -x --severity=error \
  install.sh \
  mac/stowall \
  mac/system_setup.sh \
  arch/system_setup.sh \
  debian/system_setup.sh

echo "done."
