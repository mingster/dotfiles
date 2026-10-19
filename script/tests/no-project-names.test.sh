#!/usr/bin/env bash
# Guard: the public dotfiles repo must not name our projects, hosts or company ids.
# Project values live in untracked *.local.* overlays (see script/apply-local-overlay.py).
# Scans tracked text files (binary files skipped). Run from anywhere.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$root" || exit 1
# The account name is written with a bracket so this file does not contain it literally.
pattern='riben|pstv|stm3[689]|tvcdn|63\.141|ht3|09702642|mtsa[i]'
hits=$(git grep -IiE "$pattern" -- . ':!script/tests/no-project-names.test.sh' || true)
if [ -n "$hits" ]; then
  echo "FAIL: project names found in tracked files:"; echo "$hits" | cut -c1-160 | head -30
  exit 1
fi
echo "ok: no project names in tracked text files"
