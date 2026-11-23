#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# A doc that writes `usage-gate.py --flag` names a flag that `usage-gate.py --help` lists (#1626).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
listed=$(python3 script/usage-gate.py --help 2>&1 | grep -oE -- '--[a-z][a-z-]*' | sort -u)
[ -n "$listed" ] || { echo "FAIL: usage-gate.py --help listed no flags"; exit 1; }
FAIL=0
while IFS= read -r flag; do
  [ -n "$flag" ] || continue
  if ! grep -qxF -- "$flag" <<<"$listed"; then
    FAIL=$((FAIL + 1)); echo "FAIL: a doc names usage-gate.py $flag, which --help does not list"
  fi
done < <(grep -rhoE 'usage-gate\.py( +[-A-Za-z0-9_=<>.]+)*' docs templates README.md AGENTS.md 2>/dev/null | grep -oE -- '--[a-z][a-z-]*' | sort -u)
echo "fail=$FAIL"
[ "$FAIL" -eq 0 ]
