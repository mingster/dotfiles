#!/usr/bin/env bash
# Issue 1061: on blueDevil, bash is /bin/bash. A PATH entry named bash whose
# shebang is /usr/bin/bash makes the throwaway DB step's spawn fail with
# posix_spawn ENOENT. The step must run a working bash anyway.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd -P)
runner="$here/head-checks.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp" "$HOME/orca/workspaces/b1061bash"' EXIT
mkdir -p "$tmp/badbin" "$tmp/bin"
printf '#!/usr/bin/bash\nexec /bin/bash "$@"\n' > "$tmp/badbin/bash"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/pgok"
chmod +x "$tmp/badbin/bash" "$tmp/bin/pgok"

repo="$tmp/b1061bash"
mkdir -p "$repo/.agents"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@example.invalid
git -C "$repo" config user.name t
cat > "$repo/.agents/head-checks.conf" <<'CONF'
bun -e 'const r=Bun.spawnSync(["bash","-c","echo drop-ok"],{env:process.env,stdout:"pipe",stderr:"pipe"}); if(r.exitCode!==0){ process.stderr.write(r.stderr.toString()); process.exit(1);} process.stdout.write(r.stdout.toString());' # db
CONF
echo x > "$repo/code.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm base
base=$(git -C "$repo" rev-parse HEAD)

set +e
env PATH="$tmp/badbin:$PATH" HEAD_CHECKS_DB_PROBE="$tmp/bin/pgok" HEAD_CHECKS_WAIT_SECONDS=0 HEAD_CHECKS_SLOTS=1 \
  /bin/bash "$runner" --repo "$repo" --ref HEAD --base "$base" >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
if [ "$rc" -ne 0 ] || ! grep -q 'drop-ok' "$tmp/out"; then
  echo "FAIL: database step could not spawn bash (rc=$rc)"
  cat "$tmp/err" >&2
  cat "$tmp/out" >&2
  exit 1
fi
grep -q 'Checks: PASS' "$tmp/out" || { echo "FAIL: missing pass receipt"; cat "$tmp/out"; exit 1; }
echo "ok database step spawns a working bash"
