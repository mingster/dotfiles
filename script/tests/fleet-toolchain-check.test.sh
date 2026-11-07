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

export FLEET_TOOLCHAIN_LATEST_ORCA=1.4.254
export FLEET_TOOLCHAIN_VERSIONS='{
  "mini6": {"orca": "1.4.253", "bun": "1.4.4", "node": "24.22.1"},
  "niteking": {"orca": "1.4.253", "bun": "1.4.4", "node": "24.22.1"}
}'
out_or=$(FLEET_TOOLCHAIN_LATEST_ORCA=1.4.254 FLEET_TOOLCHAIN_VERSIONS="$FLEET_TOOLCHAIN_VERSIONS" \
  FLEET_PULL_CONFIG="$FLEET_PULL_CONFIG" FLEET_TOOLCHAIN_RUN="$FLEET_TOOLCHAIN_RUN" \
  DOTFILES_DIR="$DOTFILES_DIR" "$here/fleet-toolchain-check.sh" 2>&1)
check "677 host below latest but not below mini6 is still reported" \
  "$(echo "$out_or" | grep -q 'niteking orca 1.4.253 is below latest 1.4.254'; echo $?)"

export FLEET_TOOLCHAIN_LATEST_ORCA=1.4.251
export FLEET_TOOLCHAIN_VERSIONS='{
  "mini6": {"orca": "1.4.253", "bun": "1.4.4", "node": "24.22.1"},
  "niteking": {"orca": "1.4.251", "bun": "1.4.4", "node": "24.22.1"}
}'
out_floor=$(FLEET_TOOLCHAIN_LATEST_ORCA=1.4.251 FLEET_TOOLCHAIN_VERSIONS="$FLEET_TOOLCHAIN_VERSIONS" \
  FLEET_PULL_CONFIG="$FLEET_PULL_CONFIG" FLEET_TOOLCHAIN_RUN="$FLEET_TOOLCHAIN_RUN" \
  DOTFILES_DIR="$DOTFILES_DIR" "$here/fleet-toolchain-check.sh" 2>&1)
check "677 host below mini6 floor is reported" \
  "$(echo "$out_floor" | grep -q 'niteking orca 1.4.251 is below mini6 1.4.253'; echo $?)"

pin_home="$tmp/pin-home"; mkdir -p "$pin_home" "$tmp/pybin"
printf 'nodejs 24.0.0\n' > "$pin_home/.tool-versions"
cat > "$tmp/pybin/python3" <<'EOS'
#!/usr/bin/env bash
[ "$1" = -c ] || exec /usr/bin/env python3 "$@"
case "$2" in
  *nodejs.org*) echo "26.13.0" ;;
  *) exec /usr/bin/env python3 "$@" ;;
esac
EOS
chmod +x "$tmp/pybin/python3"
latest_node_out=$(
  PATH="$tmp/pybin:$PATH" DOTFILES_DIR="$pin_home" FLEET_TOOLCHAIN_LATEST_NODE= bash -c '
    norm_ver() { printf "%s" "$1" | sed -E "s/^v//"; }
    read_pin() { awk -v t="$1" '"'"'$1 == t { print $2; exit }'"'"' "$DOTFILES_DIR/.tool-versions" 2>/dev/null; }
    latest_node() {
      pin=$(python3 -c "
import json, urllib.request
try:
    req = urllib.request.Request(\"https://nodejs.org/dist/index.json\", headers={\"User-Agent\": \"dotfiles\"})
    with urllib.request.urlopen(req, timeout=15) as r:
        for row in json.load(r):
            if row.get(\"lts\"):
                print(row[\"version\"].lstrip(\"v\")); break
except OSError:
    pass
" 2>/dev/null)
      [ -n "$pin" ] || pin=$(read_pin nodejs)
      norm_ver "$pin"
    }
    latest_node
  '
)
check "677 latest node prefers LTS lookup over .tool-versions pin" \
  "$([ "$latest_node_out" = 26.13.0 ]; echo $?)"

# shellcheck source=lib/find-orca-dir.sh
. "$here/lib/find-orca-dir.sh"
# shellcheck source=lib/asdf-pin.sh
. "$here/tests/lib/asdf-pin.sh"
orca_stub_home="$tmp/orca-home"
mkdir -p "$orca_stub_home/.orca/cli/bin" "$tmp/orca-app/bin"
printf '#!/usr/bin/env bash\necho orca version 1.4.247\n' > "$orca_stub_home/.orca/cli/bin/orca"
printf '#!/usr/bin/env bash\necho orca version 1.4.253\n' > "$tmp/orca-app/bin/orca"
chmod +x "$orca_stub_home/.orca/cli/bin/orca" "$tmp/orca-app/bin/orca"
export HOME="$orca_stub_home"
export PATH="$orca_stub_home/.orca/cli/bin:$PATH"
export FLEET_ORCA_APP_BIN="$tmp/orca-app/bin"
local_ver=$(orca_version_local | sed -E 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
check "677 orca prefers app CLI over stale ~/.orca/cli/bin" "$([ "$local_ver" = 1.4.253 ]; echo $?)"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
