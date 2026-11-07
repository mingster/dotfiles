#!/usr/bin/env bash
# fleet-toolchain-check.sh with stubbed versions (no network).
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

printf '%s\n' '{"hosts":["niteking","mini6"],"repos":[]}' > "$tmp/fleet.json"
export FLEET_PULL_CONFIG="$tmp/fleet.json"
export DOTFILES_DIR="$(cd "$here/.." && pwd)"
export FLEET_TOOLCHAIN_BASELINE_HOST=mini6
export FLEET_TOOLCHAIN_LATEST_ORCA=1.4.253
export FLEET_TOOLCHAIN_LATEST_BUN=1.4.4
export FLEET_TOOLCHAIN_LATEST_NODE=24.22.1
export FLEET_TOOLCHAIN_VERSIONS='{
  "mini6": {"orca": "1.4.253", "bun": "1.4.4", "node": "24.22.1"},
  "niteking": {"orca": "1.4.251", "bun": "1.4.4", "node": "24.22.1"}
}'
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/ssh"; chmod +x "$tmp/ssh"
export FLEET_TOOLCHAIN_RUN="$tmp/ssh"

out=$("$here/fleet-toolchain-check.sh" 2>&1)
check "older orca on niteking is reported" "$(echo "$out" | grep -q 'niteking orca 1.4.251 is below latest 1.4.253'; echo $?)"
check "mini6 at latest is quiet for orca" "$(echo "$out" | grep -q 'mini6 orca' && echo 1 || echo 0)"
check "same bun and node produce no extra lines" "$([ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ]; echo $?)"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
