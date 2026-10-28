#!/usr/bin/env bash
# Exercise the launch boundary without starting an agent or writing to the real HOME.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=tests/lib/asdf-pin.sh
. "$root/script/tests/lib/asdf-pin.sh"
# Resolve python before HOME changes; the asdf shim otherwise loses its installs.
if command -v asdf >/dev/null 2>&1; then PATH="$(dirname "$(asdf which python3)"):$PATH"; fi
mkdir -p "$tmp/home" "$tmp/bin"
export HOME="$tmp/home" CURSOR_TEST_LOG="$tmp/calls" ORCA_CLI_COMMAND="$tmp/bin/orca"
cat > "$ORCA_CLI_COMMAND" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CURSOR_TEST_LOG"
case "$*" in
  'worktree create '*) printf '%s\n' '{"result":{"worktree":{"path":"/tmp/example.repo/work tree.v1"}}}' ;;
  'orchestration worker-start '*)
    python3 - <<'PY'
import json, os
from datetime import datetime
with open(os.environ['HOME'] + '/.cursor/projects/tmp-example-repo-work tree-v1/.workspace-trusted') as f:
    marker = json.load(f)
assert marker['workspacePath'] == '/tmp/example.repo/work tree.v1'
datetime.strptime(marker['trustedAt'], '%Y-%m-%dT%H:%M:%SZ')
PY
    printf '%s\n' '{"result":{"state":"dispatched"}}' ;;
  *) exit 99 ;;
esac
STUB
chmod +x "$ORCA_CLI_COMMAND"
printf 'Do the fixture task.\n' > "$tmp/spec"
launch() { bash "$root/script/start-cursor-worker.sh" --run run_fixture --spec "$tmp/spec" --title 'fullstack-dev - fixture' --model composer-2.5 --from term_fixture "$@"; }
launch --name fixture --repo /tmp/example.repo --base-branch origin/main > "$tmp/result"
grep -q 'worktree create.*--base-branch origin/main' "$CURSOR_TEST_LOG"
grep -q 'worker-start.*--agent cursor.*--model composer-2.5' "$CURSOR_TEST_LOG"
grep -q -- '--worktree path:/tmp/example.repo/work tree.v1' "$CURSOR_TEST_LOG"
echo 'PASS: new worktree is trusted at the encoded path before dispatch'
: > "$CURSOR_TEST_LOG"
launch --worktree-path '/tmp/example.repo/work tree.v1' > "$tmp/result"
! grep -q 'worktree create' "$CURSOR_TEST_LOG"
echo 'PASS: existing worktree can be trusted and dispatched again'
for option in --on --host; do
  : > "$CURSOR_TEST_LOG"
  if launch --worktree-path /tmp/fixture "$option" remote > "$tmp/result" 2>&1; then
    echo 'FAIL: remote placement was accepted' >&2; exit 1
  fi
  grep -q 'main Mac only' "$tmp/result"
  test ! -s "$CURSOR_TEST_LOG"
done
echo 'PASS: remote placement is refused before any Orca call'
printf ' \n' > "$tmp/spec"; : > "$CURSOR_TEST_LOG"
if launch --worktree-path /tmp/fixture > "$tmp/result" 2>&1; then
  echo 'FAIL: blank spec was accepted' >&2; exit 1
fi
grep -q 'spec file is empty' "$tmp/result"
test ! -s "$CURSOR_TEST_LOG"
echo 'PASS: blank spec is refused before any Orca call'
echo 'PASS: 4 tests'
