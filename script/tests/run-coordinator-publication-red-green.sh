#!/usr/bin/env bash
# Sequential isolated RED (420ce69 helper tree) then GREEN (worktree helper); every run through heavy-gate.
set -euo pipefail

OLD_SHA=${1:-${COORDINATOR_PUBLICATION_OLD_SHA:-420ce69cdf61cc06f2160006f349c0e686edeae6}}
here=$(cd "$(dirname "$0")/.." && pwd)
repo_root=$(cd "$here/.." && pwd)
gate=${HEAVY_GATE:-$HOME/dotfiles/script/heavy-gate.sh}
test_sh="$here/tests/coordinator-publication.test.sh"
green_pub="$here/coordinator-publication.sh"

RED_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cp-red.XXXXXX")
trap 'rm -rf "$RED_ROOT"' EXIT
mkdir -p "$RED_ROOT/lib"
cp "$here/lib/validate-publication-body.sh" "$RED_ROOT/lib/"
git -C "$repo_root" show "${OLD_SHA}:script/coordinator-publication.sh" > "$RED_ROOT/coordinator-publication.sh"
chmod +x "$RED_ROOT/coordinator-publication.sh"

run_fixture() {
  local label=$1 pub=$2 log=$3 ec
  set +e
  "$gate" --weight 1 -- env GIT_ALLOW_PROTOCOL=file COORDINATOR_PUBLICATION_HELPER="$pub" bash "$test_sh" >"$log" 2>&1
  ec=$?
  echo "=== $label (exit=$ec) ==="
  grep -Fq "coordinator-publication-fixture-helper=$pub" "$log" \
    || { echo "run-coordinator-publication-red-green: helper path not recorded in log" >&2; return 2; }
  { grep -E '^(passed|FAIL )' "$log" | tail -20; } || true
  { tail -3 "$log"; } || true
  return "$ec"
}

red_log="$RED_ROOT/red.log"
green_log="$RED_ROOT/green.log"

set +e
if run_fixture "RED old=$OLD_SHA" "$RED_ROOT/coordinator-publication.sh" "$red_log"; then
  red_ec=0
else
  red_ec=$?
fi
if run_fixture "GREEN worktree" "$green_pub" "$green_log"; then
  green_ec=0
else
  green_ec=$?
fi
set -e

set +e
red_summary=$(grep '^passed ' "$red_log" | tail -1)
green_summary=$(grep '^passed ' "$green_log" | tail -1)
set -e

echo "RED summary: ${red_summary:-missing} exit=$red_ec"
echo "GREEN summary: ${green_summary:-missing} exit=$green_ec"

if [ "$red_ec" -eq 0 ]; then
  echo "run-coordinator-publication-red-green: expected RED exit nonzero" >&2
  exit 1
fi
if [ "$green_ec" -ne 0 ]; then
  echo "run-coordinator-publication-red-green: expected GREEN exit 0" >&2
  exit 1
fi

echo "run-coordinator-publication-red-green: OK"
