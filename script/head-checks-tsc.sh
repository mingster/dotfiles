#!/usr/bin/env bash
# Typecheck at the check worktree head; incremental state is kept outside the repo checkout.
set -euo pipefail
build_info=${HEAD_CHECKS_TSC_BUILD_INFO:?head-checks must export HEAD_CHECKS_TSC_BUILD_INFO}
mkdir -p "$(dirname "$build_info")"
if [ -f ./node_modules/typescript/lib/tsc.js ]; then
  bun_cmd=$(command -v bun)
  [ -n "$bun_cmd" ] || { echo "head-checks-tsc: bun not found" >&2; exit 127; }
  exec "$bun_cmd" ./node_modules/typescript/lib/tsc.js --noEmit --incremental --tsBuildInfoFile "$build_info" "$@"
fi
bun_cmd=$(command -v bun)
[ -n "$bun_cmd" ] || { echo "head-checks-tsc: bun not found" >&2; exit 127; }
exec "$bun_cmd" x tsc --noEmit --incremental --tsBuildInfoFile "$build_info" "$@"
