#!/usr/bin/env bash
# Tests for the Keychain owner approval signing and migration script (dotfiles#945).
# Uses a fake Keychain helper and a temp directory; never touches the real Keychain or real secret files.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIGN="$ROOT/script/approval-sign.sh"
WRITE="$ROOT/script/approval-write.sh"

TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
STORE="$TMP/keychain-store"
FAKE_HELPER="$TMP/bin/fake-keychain"
mkdir -p "$HOME/.config/acme" "$STORE" "$TMP/bin" "$TMP/etc/agent-team/acme"

cat > "$FAKE_HELPER" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
action=${1:-}
ns=${2:-}
item="${FAKE_KEYCHAIN_DIR:?}/$ns"
case "$action" in
  set)
    [ "${FAKE_SET_FAIL:-0}" != 1 ] || { echo "fake-keychain: set failed" >&2; exit 1; }
    val=$(cat)
    [ -n "$val" ] || exit 1
    printf '%s' "$val" > "$item"
    chmod 0600 "$item"
    ;;
  get)
    case "${FAKE_TOUCH_ID:-allow}" in
      allow) ;;
      empty) exit 0 ;;
      *) echo "fake-keychain: user presence denied" >&2; exit 2 ;;
    esac
    [ -f "$item" ] || exit 3
    cat "$item"
    ;;
  delete)
    rm -f "$item"
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod 0755 "$FAKE_HELPER"
export FAKE_KEYCHAIN_DIR="$STORE"
export APPROVAL_KEYCHAIN_HELPER="$FAKE_HELPER"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

[ -x "$SIGN" ] && ok "approval-sign.sh exists and is executable" || bad "approval-sign.sh missing or not executable"

# 1. Missing item gives a clear owner message and fails closed.
out=$("$SIGN" sign acme </dev/null 2>"$TMP/err") && bad "missing item must fail" || ok "missing item exits non-zero"
[ -z "$out" ] && grep -q "no Keychain secret for 'acme'" "$TMP/err" && grep -q "migrate acme" "$TMP/err" \
  && ok "missing item prints a clear owner migration message and no stdout" || bad "missing item message: $(cat "$TMP/err")"

# 2. One-time migration: dry-run changes nothing, denied prompt or failed set keeps the file, success verifies and deletes.
SECRET_VAL="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
SECRET_PATH="$HOME/.config/acme/approval-secret"
printf '%s\n' "$SECRET_VAL" > "$SECRET_PATH"
chmod 0600 "$SECRET_PATH"

dry_out=$("$SIGN" migrate --dry-run acme 2>&1) \
  && [ -f "$SECRET_PATH" ] && [ ! -f "$STORE/acme" ] \
  && [[ "$dry_out" != *"$SECRET_VAL"* ]] \
  && ok "migrate --dry-run prints the plan, keeps the file, and never prints the secret" \
  || bad "migrate --dry-run: $dry_out"

FAKE_SET_FAIL=1 "$SIGN" migrate acme >/dev/null 2>&1 \
  && bad "migrate must fail when Keychain set fails" \
  || { [ -f "$SECRET_PATH" ] && ok "migrate keeps the secret file when Keychain set fails" || bad "file deleted on set failure"; }

FAKE_TOUCH_ID=deny "$SIGN" migrate acme >"$TMP/mig-out" 2>"$TMP/mig-err" \
  && bad "migrate must fail when verification Touch ID prompt is denied" \
  || { [ -f "$SECRET_PATH" ] && ! grep -q "$SECRET_VAL" "$TMP/mig-out" "$TMP/mig-err" \
       && ok "migrate keeps the secret file and prints no secret when Touch ID is denied" \
       || bad "migrate denied prompt behavior"; }
rm -f "$STORE/acme"

mig_out=$("$SIGN" migrate acme 2>&1) \
  && [ ! -e "$SECRET_PATH" ] && [ -f "$STORE/acme" ] \
  && [[ "$mig_out" != *"$SECRET_VAL"* ]] \
  && ok "migrate stores the secret in Keychain, verifies signing, deletes the file, and prints no secret" \
  || bad "migrate success: $mig_out"

# 3. Success path: sign reads from Keychain, computes valid HMAC, never prints the raw secret, fresh nonce each run.
signed1=$("$SIGN" sign acme </dev/null 2>"$TMP/sign-err") \
  && [[ "$signed1" != *"$SECRET_VAL"* ]] && ! grep -q "$SECRET_VAL" "$TMP/sign-err" \
  && ok "sign succeeds after migration and never prints the raw secret" \
  || bad "sign after migrate"

signed2=$("$SIGN" sign acme 900 </dev/null)
python3 -I -c '
import hashlib, hmac, json, sys, time
sec, s1, s2 = sys.argv[1:4]
r1, r2 = json.loads(s1), json.loads(s2)
assert r1["scope"] == "sysadmin" and r1["target"] is None
n1, e1, m1 = r1["token"].split(".")
assert n1 == r1["nonce"] and int(e1) == r1["expires_at"]
want = hmac.new(sec.encode(), f"sysadmin|{n1}|{e1}".encode(), hashlib.sha256).hexdigest()
assert m1 == want, (m1, want)
assert 1700 <= r1["expires_at"] - int(time.time()) <= 1860
assert 800 <= r2["expires_at"] - int(time.time()) <= 960
assert r1["nonce"] != r2["nonce"] and r1["token"] != r2["token"]
' "$SECRET_VAL" "$signed1" "$signed2" \
  && ok "sign produces valid HMAC-SHA256 sysadmin tokens with a fresh nonce each run" \
  || bad "token verification failed"

# 4. Denied prompt or empty helper output fails closed on sign.
out=$(FAKE_TOUCH_ID=deny "$SIGN" sign acme </dev/null 2>"$TMP/deny-err") \
  && bad "denied Touch ID prompt must fail closed" \
  || { [ -z "$out" ] && grep -qi "Touch ID user presence" "$TMP/deny-err" \
       && ok "denied Touch ID prompt fails closed with empty stdout" \
       || bad "denied output: out=$out err=$(cat "$TMP/deny-err")"; }

out=$(FAKE_TOUCH_ID=empty "$SIGN" sign acme </dev/null 2>"$TMP/empty-err") \
  && bad "empty secret from helper must fail closed" \
  || { [ -z "$out" ] && ok "empty helper output fails closed" || bad "empty helper output allowed"; }

# 5. Piped JSON record is signed and works with approval-write.sh.
export AGENT_APPROVAL_ROOT="$TMP/etc/agent-team"
echo '{"scope":"sysadmin","target":null,"schema":false,"apply":false,"created_at":1700000000,"expires_at":1700001800}' \
  | "$SIGN" sign acme | bash "$WRITE" acme \
  && python3 -I -c '
import hashlib, hmac, json, sys
sec, path = sys.argv[1:3]
d = json.load(open(path))
n, e, m = d["token"].split(".")
assert e == "1700001800"
assert m == hmac.new(sec.encode(), f"sysadmin|{n}|{e}".encode(), hashlib.sha256).hexdigest()
' "$SECRET_VAL" "$TMP/etc/agent-team/acme/approval.json" \
  && ok "piped JSON is signed and written through approval-write.sh" \
  || bad "piped JSON + approval-write"

# 6. init creates a fresh Keychain secret without printing it, and bad inputs are refused.
init_out=$("$SIGN" init fresh-ns 2>&1) \
  && [ -s "$STORE/fresh-ns" ] \
  && [[ "$init_out" != *"$(cat "$STORE/fresh-ns")"* ]] \
  && "$SIGN" sign fresh-ns </dev/null >/dev/null \
  && ok "init creates a Keychain secret without printing it and sign works" \
  || bad "init fresh-ns"

"$SIGN" sign "../bad" </dev/null 2>/dev/null && bad "accepted traversal namespace" || ok "refuses traversal namespace"
"$SIGN" migrate no-such-ns "$TMP/missing" 2>/dev/null && bad "accepted missing secret file" || ok "migrate refuses a missing secret file"

# 7. On macOS with swiftc, verify the embedded Swift helper compiles cleanly without running it.
if [ "$(uname -s)" = Darwin ] && command -v swiftc >/dev/null 2>&1; then
  "$SIGN" build-helper "$TMP/bin/compiled-keychain" \
    && [ -x "$TMP/bin/compiled-keychain" ] \
    && ok "embedded Swift Keychain helper compiles with swiftc" \
    || bad "swiftc build-helper failed"
else
  ok "swiftc compile check skipped (not Darwin)"
fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
