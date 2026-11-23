#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# elon-startup.sh arguments: -h and --help print usage and exit 0, anything else but --no-pull exits 2,
# both before any host contact or pull. fleet-pull.sh is a stub; HOME and AGENT_STATE_DIR are temp.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=0 fail=0
mkdir -p "$work/script" "$work/home/.claude/state" "$work/state"
cp "$root/script/elon-startup.sh" "$work/script/elon-startup.sh"
printf '#!/usr/bin/env bash\necho called >> "%s/pull.log"\n' "$work" > "$work/script/fleet-pull.sh"
printf '#!/usr/bin/env bash\necho load-stub\n' > "$work/home/.claude/state/fleet-load.sh"
printf 'print("[]")\n' > "$work/script/usage-gate.py"
chmod +x "$work/script/fleet-pull.sh" "$work/home/.claude/state/fleet-load.sh"
echo '{"hosts":[],"repos":[]}' > "$work/fleet.json"

run() { # run <want rc> <want pull calls> <want out pattern> <args...>
  local wantrc=$1 wantpull=$2 pat=$3 rc out pulls; shift 3
  rm -f "$work/pull.log"
  set +e
  out=$(HOME="$work/home" AGENT_STATE_DIR="$work/state" FLEET_PULL_CONFIG="$work/fleet.json" \
    bash "$work/script/elon-startup.sh" "$@" 2>&1)
  rc=$?
  set -e
  pulls=0; [ ! -f "$work/pull.log" ] || pulls=$(wc -l < "$work/pull.log" | tr -d ' ')
  if [ "$rc" = "$wantrc" ] && [ "$pulls" = "$wantpull" ] && grep -qF -- "$pat" <<<"$out"; then
    pass=$((pass + 1)); echo "ok   args: ${*:-none}"
  else
    fail=$((fail + 1)); echo "FAIL args: ${*:-none} (rc=$rc want $wantrc, pulls=$pulls want $wantpull, want '$pat')"; echo "$out" | sed -n '1,6p' | sed 's/^/     /'
  fi
}
nocontact() { # section 0 is the first host contact: it must not appear
  local out
  out=$(HOME="$work/home" AGENT_STATE_DIR="$work/state" FLEET_PULL_CONFIG="$work/fleet.json" bash "$work/script/elon-startup.sh" "$@" 2>&1 || true)
  if grep -qF '== 0 coordinator' <<<"$out"; then fail=$((fail + 1)); echo "FAIL ran startup for: $*"; else pass=$((pass + 1)); echo "ok   no startup for: $*"; fi
}

run 0 0 'Usage: elon-startup.sh [--no-pull]' --help
run 0 0 'Usage: elon-startup.sh [--no-pull]' -h
run 2 0 'Usage: elon-startup.sh [--no-pull]' --bogus
run 2 0 'Usage: elon-startup.sh [--no-pull]' --no-pul
run 2 0 'Usage: elon-startup.sh [--no-pull]' --no-pull extra
run 2 0 'Usage: elon-startup.sh [--no-pull]' -h extra
run 0 0 '== 1 pull latest' --no-pull
run 0 1 '== 1 pull latest'
nocontact --help
nocontact --bogus
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
