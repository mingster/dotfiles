#!/usr/bin/env bash
# Owner approval signing and Keychain secret migration behind Touch ID user presence (dotfiles#945).
# Runs as the owner in his own terminal (never root, so it reads the owner's Keychain and prompts Touch ID).
#
# Why a tiny Swift helper instead of `security add-generic-password`:
#   Plain `security add-generic-password` only sets legacy SecAccess application ACLs (-A, -T) and has no
#   flag for kSecAttrAccessControl or SecAccessControlCreateWithFlags(..., .userPresence, ...). The embedded
#   Swift helper below sets .userPresence and evaluates LAContext(.deviceOwnerAuthentication) before every
#   read, so each signing run requires Touch ID (or device passcode) and fails closed when denied.
#
# Fail closed: the item is stored only in the data protection keychain with a user presence access control.
#   That needs a keychain-access-groups entitlement, which an ad hoc signature cannot carry. An ad hoc
#   helper therefore exits non zero on `set` and stores nothing (no login keychain fallback). The owner
#   signs it with a team identity: APPROVAL_SIGN_IDENTITY="Apple Development: Name (TEAMID)" and
#   APPROVAL_ENTITLEMENTS=<plist with keychain-access-groups TEAMID.agent-team>, plus the matching
#   provisioning profile. Build with `build-helper <path>`, then set APPROVAL_KEYCHAIN_HELPER to it.
#
# Usage:
#   bash script/approval-sign.sh sign <namespace> [ttl]        (or pipe unsigned approval JSON on stdin)
#   bash script/approval-sign.sh migrate [--dry-run] <namespace> [<secret-file>]
#   bash script/approval-sign.sh init <namespace>
#   bash script/approval-sign.sh build-helper <output-path>
#
# Environment for tests (never used to touch real items):
#   APPROVAL_KEYCHAIN_HELPER      executable taking <get|set|delete> <namespace>
#   APPROVAL_KEYCHAIN_CACHE_DIR   cache folder for the compiled Swift binary
#   APPROVAL_SECRET_FILE          default secret file path for migrate
set -euo pipefail

die() { echo "approval-sign: $*" >&2; exit 1; }
usage() {
  sed -n '19,22p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

valid_ns() {
  case "${1:-}" in
    ''|-*|*[!A-Za-z0-9._-]*|.|..) return 1 ;;
  esac
  return 0
}

swift_source() {
  cat <<'SWIFT'
import Foundation
import LocalAuthentication
import Security

let service = "agent-team.approval-secret"
let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: approval-keychain <get|set|delete> <namespace>\n".utf8))
    exit(2)
}
let action = args[0]
let account = args[1]

func dpQuery() -> [String: Any] {
    return [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecUseDataProtectionKeychain as String: true,
    ]
}

func requireUserPresence(reason: String) -> LAContext {
    let context = LAContext()
    context.localizedReason = reason
    var authError: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
        FileHandle.standardError.write(Data("approval-keychain: user presence unavailable\n".utf8))
        exit(2)
    }
    let sem = DispatchSemaphore(value: 0)
    var authed = false
    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
        authed = ok
        sem.signal()
    }
    sem.wait()
    guard authed else {
        FileHandle.standardError.write(Data("approval-keychain: user presence denied\n".utf8))
        exit(2)
    }
    return context
}

switch action {
case "set":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: input, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty,
          let secretData = text.data(using: .utf8) else {
        FileHandle.standardError.write(Data("approval-keychain: empty secret on stdin\n".utf8))
        exit(1)
    }
    var cfErr: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .userPresence,
        &cfErr
    ) else {
        FileHandle.standardError.write(Data("approval-keychain: failed to create access control\n".utf8))
        exit(1)
    }
    SecItemDelete(dpQuery() as CFDictionary)
    var add = dpQuery()
    add[kSecAttrAccessControl as String] = access
    add[kSecValueData as String] = secretData
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else {
        let hint = status == errSecMissingEntitlement
            ? "; the helper must be signed with a keychain-access-groups entitlement. Refusing to store the secret without Touch ID protection"
            : ""
        FileHandle.standardError.write(Data("approval-keychain: SecItemAdd failed (\(status))\(hint)\n".utf8))
        exit(1)
    }
case "get":
    let context = requireUserPresence(reason: "read the \(account) owner approval signing secret")
    var query = dpQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = context
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
        exit(3)
    }
    guard status == errSecSuccess, let data = item as? Data, !data.isEmpty else {
        FileHandle.standardError.write(Data("approval-keychain: Keychain read failed (\(status))\n".utf8))
        exit(2)
    }
    FileHandle.standardOutput.write(data)
case "delete":
    let s1 = SecItemDelete(dpQuery() as CFDictionary)
    guard s1 == errSecSuccess || s1 == errSecItemNotFound else {
        exit(1)
    }
default:
    exit(2)
}
SWIFT
}

build_helper() {
  local out=$1
  [ "$(uname -s)" = Darwin ] || die "macOS Keychain helper requires Darwin (set APPROVAL_KEYCHAIN_HELPER in tests)"
  command -v swiftc >/dev/null 2>&1 || die "swiftc is required to build the Keychain helper"
  mkdir -p "$(dirname "$out")"
  local tmp_dir
  tmp_dir=$(mktemp -d "$(dirname "$out")/.keychain-build.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" RETURN
  swift_source > "$tmp_dir/helper.swift"
  swiftc -O "$tmp_dir/helper.swift" -o "$tmp_dir/approval-keychain"
  # Hardened runtime blocks DYLD_INSERT_LIBRARIES into the helper. An ad hoc signature carries no keychain
  # entitlement, so the protected store fails closed until the owner signs it (see the header).
  codesign --force --sign "${APPROVAL_SIGN_IDENTITY:--}" --options runtime ${APPROVAL_ENTITLEMENTS:+--entitlements "$APPROVAL_ENTITLEMENTS"} "$tmp_dir/approval-keychain" \
    || die "codesign failed for the Keychain helper"
  chmod 0700 "$tmp_dir/approval-keychain"
  mv -f "$tmp_dir/approval-keychain" "$out"
}

resolve_helper() {
  if [ -n "${APPROVAL_KEYCHAIN_HELPER:-}" ]; then
    [ -x "$APPROVAL_KEYCHAIN_HELPER" ] || die "APPROVAL_KEYCHAIN_HELPER is not executable: $APPROVAL_KEYCHAIN_HELPER"
    printf '%s\n' "$APPROVAL_KEYCHAIN_HELPER"
    return 0
  fi
  local cache_dir="${APPROVAL_KEYCHAIN_CACHE_DIR:-$HOME/.cache/agent-team}"
  local bin="$cache_dir/approval-keychain"
  local stamp="$cache_dir/approval-keychain.sha256"
  local want
  want=$(swift_source | python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
  if [ ! -x "$bin" ] || [ ! -f "$stamp" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$want" ]; then
    build_helper "$bin"
    printf '%s\n' "$want" > "$stamp"
  fi
  printf '%s\n' "$bin"
}

cmd_sign() {
  local ns=${1:-}
  local ttl=${2:-1800}
  [ $# -le 2 ] || usage
  valid_ns "$ns" || { echo "approval-sign: namespace must be letters, digits, dot, dash or underscore" >&2; exit 2; }
  [[ "$ttl" =~ ^[1-9][0-9]*$ ]] || { echo "approval-sign: ttl must be a positive integer" >&2; exit 2; }
  local helper rc=0 secret
  helper=$(resolve_helper)
  secret=$("$helper" get "$ns" </dev/null) || rc=$?
  if [ "$rc" -eq 3 ]; then
    die "no Keychain secret for '$ns'. Run: bash ~/dotfiles/script/approval-sign.sh migrate $ns (or init $ns on a new host)"
  fi
  if [ "$rc" -ne 0 ] || [ -z "${secret//[[:space:]]/}" ]; then
    die "Touch ID user presence was denied or failed for '$ns'; refusing to sign"
  fi
  python3 -I -c '
import getpass, hashlib, hmac, json, os, secrets, sys, time

ttl = int(sys.argv[1])
secret = os.fdopen(3).read().strip()
if not secret:
    sys.exit(1)

raw_in = "" if sys.stdin.isatty() else sys.stdin.read().strip()
if raw_in:
    try:
        rec = json.loads(raw_in)
    except Exception:
        sys.stderr.write("approval-sign: stdin is not valid JSON\n")
        sys.exit(1)
    if not isinstance(rec, dict):
        sys.stderr.write("approval-sign: stdin is not a JSON object\n")
        sys.exit(1)
    now = int(time.time())
    rec.setdefault("scope", "sysadmin")
    rec.setdefault("target", None)
    rec.setdefault("schema", False)
    rec.setdefault("apply", False)
    rec.setdefault("created_at", now)
    rec.setdefault("expires_at", now + ttl)
    rec.setdefault("by", getpass.getuser())
else:
    now = int(time.time())
    rec = {
        "scope": "sysadmin",
        "target": None,
        "schema": False,
        "apply": False,
        "created_at": now,
        "expires_at": now + ttl,
        "by": getpass.getuser(),
    }

exp = int(rec["expires_at"])
nonce = secrets.token_hex(16)
mac = hmac.new(secret.encode(), f"sysadmin|{nonce}|{exp}".encode(), hashlib.sha256).hexdigest()
rec["nonce"] = nonce
rec["token"] = f"{nonce}.{exp}.{mac}"
print(json.dumps(rec))
' "$ttl" 3<<<"$secret"
}

cmd_migrate() {
  local dry=0
  local args=()
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      *) args+=("$a") ;;
    esac
  done
  [ "${#args[@]}" -ge 1 ] && [ "${#args[@]}" -le 2 ] || usage
  local ns=${args[0]}
  valid_ns "$ns" || { echo "approval-sign: namespace must be letters, digits, dot, dash or underscore" >&2; exit 2; }
  local secret_file=${args[1]:-${APPROVAL_SECRET_FILE:-$HOME/.config/$ns/approval-secret}}
  [ -f "$secret_file" ] && [ -s "$secret_file" ] \
    || die "secret file $secret_file is missing or empty; nothing to migrate"
  local file_secret
  file_secret=$(python3 -I -c 'import sys; s=open(sys.argv[1]).read().strip(); assert s; print(s)' "$secret_file" 2>/dev/null) \
    || die "secret file $secret_file has no secret content"
  if [ "$dry" -eq 1 ]; then
    echo "This will:"
    echo "  1. create Keychain item agent-team.approval-secret ($ns) behind Touch ID user presence from $secret_file"
    echo "  2. verify a signing run for $ns (prompts Touch ID) against the secret"
    echo "  3. delete $secret_file after verification succeeds"
    echo "Dry run: nothing changed."
    return 0
  fi
  local helper signed
  helper=$(resolve_helper)
  printf '%s' "$file_secret" | "$helper" set "$ns" \
    || die "failed to store '$ns' secret in Keychain; $secret_file was kept"
  signed=$(APPROVAL_KEYCHAIN_HELPER="$helper" "$0" sign "$ns" </dev/null) \
    || die "verification sign failed for '$ns'; $secret_file was kept"
  python3 -I -c '
import hashlib, hmac, json, os, sys
secret = os.fdopen(3).read().strip()
rec = json.loads(sys.argv[1])
nonce = rec["nonce"]
exp = rec["expires_at"]
want = f"{nonce}.{exp}." + hmac.new(secret.encode(), f"sysadmin|{nonce}|{exp}".encode(), hashlib.sha256).hexdigest()
assert rec.get("scope") == "sysadmin" and rec.get("token") == want
' "$signed" 3<<<"$file_secret" \
    || die "verification signature mismatch for '$ns'; $secret_file was kept"
  rm -f -- "$secret_file"
  echo "approval-sign: migrated '$ns' secret to Keychain behind Touch ID, verified signing, and deleted $secret_file"
}

cmd_init() {
  [ $# -eq 1 ] || usage
  local ns=$1
  valid_ns "$ns" || { echo "approval-sign: namespace must be letters, digits, dot, dash or underscore" >&2; exit 2; }
  local helper
  helper=$(resolve_helper)
  python3 -I -c 'import secrets; print(secrets.token_hex(32))' | "$helper" set "$ns" \
    || die "failed to create Keychain secret for '$ns'"
  echo "approval-sign: created Keychain secret for '$ns' behind Touch ID (not printed)."
}

cmd=${1:-}
case "$cmd" in
  sign) shift; cmd_sign "$@" ;;
  migrate) shift; cmd_migrate "$@" ;;
  init) shift; cmd_init "$@" ;;
  build-helper)
    [ $# -eq 2 ] || usage
    build_helper "$2"
    ;;
  -h|--help|'') usage ;;
  *)
    if valid_ns "$cmd"; then
      cmd_sign "$@"
    else
      usage
    fi
    ;;
esac
