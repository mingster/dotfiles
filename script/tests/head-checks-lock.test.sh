#!/usr/bin/env bash
# head-checks.sh lock_acquire: a pid-less fresh lock is held, a pid-less old or dead-pid lock is taken over once.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=0 fail=0
# shellcheck disable=SC1090
eval "$(sed -n '/^lock_acquire() {/,/^}/p' "$root/script/head-checks.sh")"
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

l="$work/fresh.lock"; mkdir "$l"
if lock_acquire "$l"; then bad "fresh pid-less lock respected"; else ok "fresh pid-less lock respected"; fi
[ -d "$l" ] && [ ! -e "$l/pid" ] && ok "fresh pid-less lock left in place" || bad "fresh pid-less lock left in place"

l="$work/old.lock"; mkdir "$l"; touch -t 202001010000 "$l"
if lock_acquire "$l" && [ -d "$l" ]; then ok "old pid-less lock taken over"; else bad "old pid-less lock taken over"; fi
ls "$work" | grep -q 'stale' && bad "stale dir cleaned up" || ok "stale dir cleaned up"

l="$work/dead.lock"; mkdir "$l"; ( exit 0 ) & dead=$!; wait "$dead"; echo "$dead" > "$l/pid"
if lock_acquire "$l" && [ ! -e "$l/pid" ]; then ok "dead pid lock taken over"; else bad "dead pid lock taken over"; fi
if lock_acquire "$l"; then bad "second taker loses once taken"; else ok "second taker loses once taken"; fi

l="$work/live.lock"; mkdir "$l"; echo "$$" > "$l/pid"
if lock_acquire "$l"; then bad "live pid lock held"; else [ "$lock_holder" = "$$" ] && ok "live pid lock held" || bad "live pid lock holder reported"; fi

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
