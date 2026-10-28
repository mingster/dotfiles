#!/usr/bin/env bash
# bootstrap-asdf-tools.sh adds missing plugins, installs the pins, writes ~/.tool-versions, and is a no-op the second time.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/script/bootstrap-asdf-tools.sh"
PASS=0
FAIL=0
check() {
  if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/dot" "$TMP/state"
: >"$TMP/state/plugins"
: >"$TMP/state/installed"
: >"$TMP/log"

cat >"$TMP/bin/asdf" <<'STUB'
#!/usr/bin/env bash
echo "asdf $*" >>"$STUB_LOG"
case "$1 ${2:-}" in
  "plugin list") cat "$STUB_STATE/plugins" ;;
  "plugin add") echo "$3" >>"$STUB_STATE/plugins" ;;
  "list "*) awk -v t="$2" '$1 == t { print "  " $2 }' "$STUB_STATE/installed" ;;
  "install "*) echo "$2 $3" >>"$STUB_STATE/installed" ;;
  "which python3") echo "/stub/python3" ;;
  "which node") echo "/stub/node" ;;
esac
STUB
chmod +x "$TMP/bin/asdf"

printf 'python 3.14.10\nnodejs 24.22.1\n' >"$TMP/dot/.tool-versions"
printf 'java temurin-21\npython 3.9.0\n' >"$TMP/home/.tool-versions"

run() {
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/log" STUB_STATE="$TMP/state" \
    bash "$SCRIPT" --dotfiles "$TMP/dot"
}

# First run: python plugin already present, nodejs missing.
echo python >"$TMP/state/plugins"
out1="$(run)"
check "adds only the missing plugin" \
  "! grep -q 'plugin add python' '$TMP/log' && grep -q 'plugin add nodejs' '$TMP/log'"
check "installs both pins" \
  "grep -q 'asdf install python 3.14.10' '$TMP/log' && grep -q 'asdf install nodejs 24.22.1' '$TMP/log'"
check "keeps unrelated lines" "grep -qx 'java temurin-21' '$TMP/home/.tool-versions'"
check "replaces python line" \
  "grep -qx 'python 3.14.10' '$TMP/home/.tool-versions' && ! grep -q '3.9.0' '$TMP/home/.tool-versions'"
check "adds nodejs line" "grep -qx 'nodejs 24.22.1' '$TMP/home/.tool-versions'"
check "prints resolved paths" "grep -q '/stub/python3' <<<\"\$out1\" && grep -q '/stub/node' <<<\"\$out1\""

# Second run: nothing changes.
cp "$TMP/home/.tool-versions" "$TMP/before"
: >"$TMP/log"
out2="$(run)"
check "second run adds no plugin" "! grep -q 'plugin add' '$TMP/log'"
check "second run issues no install" "! grep -q 'asdf install' '$TMP/log'"
check "second run leaves file byte identical" "cmp -s '$TMP/before' '$TMP/home/.tool-versions'"
check "second run says nothing changed" "grep -qi 'nothing changed' <<<\"\$out2\""

# Missing dotfiles pins fails.
rm "$TMP/dot/.tool-versions"
check "fails without a .tool-versions" "! run >/dev/null 2>&1"

echo "bootstrap-asdf-tools: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
