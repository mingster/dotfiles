#!/usr/bin/env bash
# #1746: a remote-heavy usage error (exit 64) says `infra:` so head-checks files `red gate: remote-heavy`.
# A command that merely fails says nothing of the kind. No network.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd -P)
err=$(mktemp)
trap 'rm -f "$err"' EXIT
set +e
bash "$here/remote-heavy.sh" --bogus >/dev/null 2>"$err"
rc=$?
set -e
[ "$rc" -eq 64 ] || { echo "FAIL: expected exit 64, got $rc"; cat "$err"; exit 1; }
grep -q '^infra: remote-heavy: usage error (exit 64)' "$err" || { echo "FAIL: no infra line"; cat "$err"; exit 1; }
echo "ok usage error names the gate as infra"
set +e
bash "$here/remote-heavy.sh" --help >/dev/null 2>"$err"
rc=$?
set -e
[ "$rc" -eq 0 ] && ! grep -q '^infra:' "$err" || { echo "FAIL: --help is not an infra failure"; cat "$err"; exit 1; }
echo "ok --help stays quiet"
