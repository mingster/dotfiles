#!/usr/bin/env bash
# Typecheck at the check worktree head. One incremental cache per host and repo is shared by every
# check worktree, keyed by a hash of the lockfiles and tsconfig files. A changed key is a full run
# that replaces the cache. A run works on a private copy and publishes it with an atomic rename, so
# two runs at once cannot corrupt the shared file.
set -euo pipefail
# Seconds tsc may run before it is stopped with its whole process group (exit 124).
limit=${HEAD_CHECKS_TSC_TIMEOUT_SECONDS:-600}
case "$limit" in
  ''|*[!0-9]*|0) echo "head-checks-tsc: HEAD_CHECKS_TSC_TIMEOUT_SECONDS must be a whole number of seconds above 0, got '$limit'" >&2; exit 2 ;;
esac
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
# tsc gets its own process group, so the limit (or a signal to this script) stops tsc and everything it
# started together. Without that, a hung run keeps its memory until someone kills it by pid.
tsc_pid=
kill_tsc() {
  [ -n "$tsc_pid" ] || return 0
  kill -TERM -- "-$tsc_pid" 2>/dev/null || true
  for _ in 1 2 3; do kill -0 -- "-$tsc_pid" 2>/dev/null || break; sleep 1; done
  kill -KILL -- "-$tsc_pid" 2>/dev/null || true
  wait "$tsc_pid" 2>/dev/null || true
  tsc_pid=
}
trap 'kill_tsc; rm -f "$work"; exit 143' HUP INT TERM
set -m
"${tsc[@]}" --noEmit --incremental --tsBuildInfoFile "$work" "$@" &
tsc_pid=$!
set +m
deadline=$((SECONDS + limit))
timed_out=0
while kill -0 "$tsc_pid" 2>/dev/null; do
  if [ "$SECONDS" -ge "$deadline" ]; then timed_out=1; break; fi
  sleep 1
done
if [ "$timed_out" -eq 1 ]; then
  kill_tsc
  rm -f "$work"
  echo "head-checks-tsc: tsc passed the limit and was stopped (HEAD_CHECKS_TSC_TIMEOUT_SECONDS=$limit); the shared cache was not changed" >&2
  exit 124
fi
wait "$tsc_pid" || status=$?
tsc_pid=
trap - HUP INT TERM
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
