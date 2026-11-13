#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# Shell startup files must not put an API key, token or secret into the environment (#942), and .zshrc
# must find psql and createdb from libpq. Static check on the tracked files, then a real zsh run.
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
check() {
  if [ "$2" = ok ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi
}

files=()
for f in .zshenv .zshrc .zlogin; do [ -f "$root/$f" ] && files+=("$root/$f"); done

if grep -n -E '^[[:space:]]*(export[[:space:]]+)?[A-Za-z0-9_]*(_KEY|_TOKEN|_SECRET)=' "${files[@]}" >/dev/null; then
  check "startup files assign no *_KEY, *_TOKEN or *_SECRET" bad
else
  check "startup files assign no *_KEY, *_TOKEN or *_SECRET" ok
fi

# Sourcing a dotenv file loads every key in it into every shell.
if grep -n -E '^[^#]*(source|\.)[[:space:]]+[^#]*\.env' "${files[@]}" >/dev/null; then
  check "startup files source no .env file" bad
else
  check "startup files source no .env file" ok
fi

if grep -q 'opt/libpq/bin' "$root/.zshrc"; then check ".zshrc puts libpq bin on PATH" ok; else check ".zshrc puts libpq bin on PATH" bad; fi

if command -v zsh >/dev/null 2>&1; then
  home="$tmp/home"
  mkdir -p "$home/dotfiles"
  printf 'export FAKE_API_KEY=leak-1\nFAKE_ACCESS_TOKEN=leak-2\n' > "$home/dotfiles/.env"
  # Names only: the exported parameter names of a clean zsh that read the startup files.
  # STARSHIP_SESSION_KEY is starship's own random session id, not a credential.
  names=$(env -i HOME="$home" ZDOTDIR="$home" PATH="$PATH" zsh -f -c ". '$root/.zshenv' 2>/dev/null; . '$root/.zshrc' >/dev/null 2>&1; print -l \${(k)parameters[(R)*export*]}" 2>/dev/null | grep -E '(_KEY|_TOKEN|_SECRET)$' | grep -v -x STARSHIP_SESSION_KEY)
  leaked=$(printf '%s' "$names" | grep -c .)
  [ "$leaked" = 0 ] || echo "exported: $names"
  if [ "$leaked" = 0 ]; then check "zsh run with a dotenv in the dotfiles folder exports no key" ok; else check "zsh run with a dotenv in the dotfiles folder exports no key" bad; fi
fi

# with-keychain: refuses a missing item without printing a value, and passes a stored value to one command.
stub="$tmp/stub"
mkdir -p "$stub"
cat > "$stub/security" <<'EOF'
#!/bin/sh
[ "$5" = FAKE_KEY ] && { printf 'stored-value\n'; exit 0; }
exit 44
EOF
chmod +x "$stub/security"
out=$(PATH="$stub:$PATH" "$root/bin/with-keychain" FAKE_KEY -- sh -c 'printf "%s" "$FAKE_KEY"' 2>&1)
if [ "$out" = stored-value ]; then check "with-keychain gives the stored value to the command" ok; else check "with-keychain gives the stored value to the command" bad; fi
out=$(PATH="$stub:$PATH" "$root/bin/with-keychain" MISSING_KEY -- true 2>&1); rc=$?
if [ "$rc" = 1 ] && [[ "$out" == *MISSING_KEY* ]] && [[ "$out" != *stored-value* ]]; then check "with-keychain stops on a missing item" ok; else check "with-keychain stops on a missing item" bad; fi
"$root/bin/with-keychain" >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then check "with-keychain without arguments prints usage" ok; else check "with-keychain without arguments prints usage" bad; fi

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
