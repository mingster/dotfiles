#!/usr/bin/env bash
# Behavioral tests for script/set-env-key.py (#2083): it swaps one URL host in place, keeps every other byte,
# the mode and the owner, and never prints a value, on success or on any refusal.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$ROOT/script/set-env-key.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

SECRET='pw-Zq81x'
F="$TMP/support.env"
seed() {
  printf '%s\n' "# support login" "SUPPORT_RO_DATABASE_URL=postgresql://ro_user:$SECRET@old.example.org:5432/db?sslmode=require" \
    "SUPPORT_GH_TOKEN=ghp_$SECRET" > "$F"
  chmod 600 "$F"
}

# 1. The host changes, nothing else does, and the output holds no value.
seed
out=$(python3 "$TOOL" "$F" SUPPORT_RO_DATABASE_URL --replace-host old.example.org 127.0.0.1 2>&1); rc=$?
want=$(printf '%s\n' "# support login" "SUPPORT_RO_DATABASE_URL=postgresql://ro_user:$SECRET@127.0.0.1:5432/db?sslmode=require" \
  "SUPPORT_GH_TOKEN=ghp_$SECRET")
[ "$rc" = 0 ] && [ "$(cat "$F")" = "$want" ] && ok "host replaced, other bytes kept" || bad "host replaced (rc=$rc)"
case "$out" in *"$SECRET"*|*ro_user*|*5432*) bad "success output printed a value" ;; *) ok "success output prints no value" ;; esac
mode=$(stat -f %Lp "$F" 2>/dev/null || stat -c %a "$F")
[ "$mode" = 600 ] && ok "mode 600 kept" || bad "mode is $mode"
[ -z "$(find "$TMP" -name '.set-env-key.*')" ] && ok "no temp file left" || bad "temp file left"

# 2. Refusals change nothing and print no value.
refuse() {
  local label="$1"; shift
  seed
  local before out rc
  before=$(cat "$F")
  out=$(python3 "$TOOL" "$@" 2>&1); rc=$?
  if [ "$rc" != 0 ] && [ "$(cat "$F")" = "$before" ]; then ok "$label refused"; else bad "$label (rc=$rc)"; fi
  case "$out" in *"$SECRET"*|*ro_user*) bad "$label printed a value" ;; esac
}
refuse "wrong old host" "$F" SUPPORT_RO_DATABASE_URL --replace-host other.example.org 127.0.0.1
refuse "missing key" "$F" NO_SUCH_KEY --replace-host old.example.org 127.0.0.1
refuse "key that is not a URL" "$F" SUPPORT_GH_TOKEN --replace-host old.example.org 127.0.0.1
refuse "host with a slash" "$F" SUPPORT_RO_DATABASE_URL --replace-host old.example.org 'evil/x'
refuse "host with a colon" "$F" SUPPORT_RO_DATABASE_URL --replace-host old.example.org '1.2.3.4:99'
refuse "a full value instead of a host" "$F" SUPPORT_RO_DATABASE_URL --replace-host old.example.org 'postgresql://a:b@c/d'
refuse "no --replace-host" "$F" SUPPORT_RO_DATABASE_URL old.example.org 127.0.0.1
refuse "extra argument" "$F" SUPPORT_RO_DATABASE_URL --replace-host old.example.org 127.0.0.1 x
refuse "missing file" "$TMP/none.env" SUPPORT_RO_DATABASE_URL --replace-host old.example.org 127.0.0.1

# 3. A key set twice is refused.
seed
echo "SUPPORT_RO_DATABASE_URL=postgresql://u:$SECRET@old.example.org/db" >> "$F"
before=$(cat "$F")
out=$(python3 "$TOOL" "$F" SUPPORT_RO_DATABASE_URL --replace-host old.example.org 127.0.0.1 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(cat "$F")" = "$before" ] && ok "key set twice refused" || bad "key set twice (rc=$rc)"

# 4. export prefix, quotes and no userinfo.
printf '%s\n' "export DB_URL=\"postgres://old.example.org/db\"" > "$F"
python3 "$TOOL" "$F" DB_URL --replace-host OLD.example.org new.example.org >/dev/null 2>&1
[ "$(cat "$F")" = 'export DB_URL="postgres://new.example.org/db"' ] && ok "export and quotes kept" || bad "export and quotes: $(cat "$F")"

echo "set-env-key: $pass passed, $fail failed"
[ "$fail" = 0 ]
