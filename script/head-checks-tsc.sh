#!/usr/bin/env bash
# Typecheck at the check worktree head. One incremental cache per host and repo is shared by every
# check worktree, keyed by a hash of the lockfiles and tsconfig files. A changed key is a full run
# that replaces the cache. A run works on a private copy and publishes it with an atomic rename, so
# two runs at once cannot corrupt the shared file.
set -euo pipefail
cache_dir=${HEAD_CHECKS_TSC_CACHE_DIR:?head-checks must export HEAD_CHECKS_TSC_CACHE_DIR}
mkdir -p "$cache_dir"
if command -v shasum >/dev/null 2>&1; then sum() { shasum -a 256; }; else sum() { sha256sum; }; fi
key=$({
  for f in bun.lock bun.lockb package-lock.json pnpm-lock.yaml yarn.lock; do
    [ -f "$f" ] && { printf '%s\n' "$f"; cat "$f"; }
  done
  find . -name node_modules -prune -o -name '.git' -prune -o -name 'tsconfig*.json' -type f -print | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s\n' "$f"; cat "$f"
  done
} | sum | cut -c1-16)
shared="$cache_dir/$key.tsbuildinfo"
# The private copy sits at the same depth in every worktree: tsc stores paths relative to the file,
# so a copy beside a differently named worktree would miss. node_modules survives git clean.
work_dir=./node_modules/.cache/head-checks-tsc
mkdir -p "$work_dir"
work="$work_dir/tsc.tsbuildinfo"
rm -f "$work"
cp "$shared" "$work" 2>/dev/null || rm -f "$work"
bun_cmd=$(command -v bun) || { echo "head-checks-tsc: bun not found" >&2; exit 127; }
if [ -f ./node_modules/typescript/lib/tsc.js ]; then
  tsc=("$bun_cmd" ./node_modules/typescript/lib/tsc.js)
else
  tsc=("$bun_cmd" x tsc)
fi
status=0
"${tsc[@]}" --noEmit --incremental --tsBuildInfoFile "$work" "$@" || status=$?
if [ -s "$work" ]; then
  tmp="$cache_dir/.tmp.$key.$$"
  if cp "$work" "$tmp" 2>/dev/null && mv -f "$tmp" "$shared"; then
    for old in "$cache_dir"/*.tsbuildinfo; do
      [ "$old" = "$shared" ] || rm -f "$old"
    done
  else
    rm -f "$tmp"
  fi
fi
rm -f "$work"
exit "$status"
