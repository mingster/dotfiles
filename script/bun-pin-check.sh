#!/usr/bin/env bash
# Warn when a host's bun is older than the repo's pin. Warning only: always exits 0 (2 on bad usage).
# Usage: bun-pin-check.sh <host> <repo>      bun-pin-check.sh --version <host>
# The pin is packageManager (bun@x.y.z) or engines.bun in package.json, root first, then web/.
# With no pin, warns when the host's bun differs from this machine's. A host that is this
# machine (hostname -s) runs bun directly; any other host is reached with `ssh <host> bun --version`
# (override the runner with BUN_PIN_RUN, called as: $BUN_PIN_RUN <host> bun --version).
# Coordinators run this before an Orca worker-start.
set -u
run="${BUN_PIN_RUN:-ssh}"
host_version() {   # $1 = host
  local v
  if [ "$1" = "$(hostname -s)" ]; then v=$(bun --version 2>/dev/null); else v=$("$run" "$1" bun --version 2>/dev/null); fi
  printf '%s' "$v" | tr -d '[:space:]v'
}
if [ "${1:-}" = --version ] && [ $# -eq 2 ]; then host_version "$2"; echo; exit 0; fi
[ $# -eq 2 ] || { echo "usage: bun-pin-check.sh <host> <repo> | --version <host>" >&2; exit 2; }
host=$1; repo=$2
pin=
for f in "$repo/package.json" "$repo/web/package.json"; do
  [ -f "$f" ] || continue
  pin=$(python3 -c '
import json, re, sys
d = json.load(open(sys.argv[1]))
s = d.get("packageManager", "") if isinstance(d.get("packageManager"), str) else ""
s = s[4:] if s.startswith("bun@") else (d.get("engines") or {}).get("bun", "")
m = re.search(r"\d+(\.\d+){0,2}", s if isinstance(s, str) else "")
print(m.group(0) if m else "")' "$f" 2>/dev/null)
  [ -z "$pin" ] || break
done
have=$(host_version "$host")
[ -n "$have" ] || { echo "bun-pin-check: warning: cannot read bun version on $host" >&2; exit 0; }
older() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }   # $1 < $2
if [ -n "$pin" ]; then
  ! older "$have" "$pin" || echo "bun-pin-check: warning: $host has bun $have, older than the repo pin $pin; failures may be the host, not the code" >&2
else
  here=$(bun --version 2>/dev/null | tr -d '[:space:]v')
  [ -z "$here" ] || [ "$have" = "$here" ] || echo "bun-pin-check: warning: $host has bun $have, this machine has $here and the repo has no pin; failures may be the host, not the code" >&2
fi
exit 0
