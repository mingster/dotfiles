#!/usr/bin/env bash
# Parity: install_node.sh uses the nodejs pin from .tool-versions (no hardcoded version).
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/.." && pwd -P)
script="$here/install_node.sh"
tv="$root/.tool-versions"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ $# -gt 1 ] && echo "$2"; }

[ -f "$script" ] || { echo "FAIL install_node.sh missing"; exit 1; }
[ -f "$tv" ] || { echo "FAIL .tool-versions missing"; exit 1; }

pin=$(awk '$1=="nodejs" { print $2; exit }' "$tv")
[ -n "${pin:-}" ] || { bad 'missing nodejs in .tool-versions'; echo "$pass passed, $fail failed"; exit 1; }

if grep -E 'asdf (install|set).*nodejs [0-9]+\.[0-9]+\.[0-9]+' "$script" \
  | grep -vq "$pin"; then
  bad 'install_node.sh hardcodes a nodejs version' "$(grep -E 'asdf (install|set).*nodejs' "$script")"
else
  ok 'install_node.sh does not hardcode a different nodejs version'
fi

grep -q '.tool-versions' "$script" && ok 'install_node.sh reads .tool-versions' \
  || bad 'install_node.sh must read .tool-versions'

bash -n "$script" && ok 'install_node.sh syntax' || bad 'install_node.sh syntax'

# Behavior against a fake asdf: whole-version match decides "already installed" (#1571).
fake=$(mktemp -d)
trap 'rm -rf "$fake"' EXIT
cat >"$fake/asdf" <<'STUB'
#!/usr/bin/env bash
echo "asdf $*" >>"$FAKE_LOG"
case "$1 ${2:-}" in
  "plugin list") echo nodejs ;;
  "list nodejs") printf '  %s\n' $FAKE_INSTALLED ;;
esac
STUB
printf '#!/bin/sh\nexit 0\n' >"$fake/bun"
chmod +x "$fake/asdf" "$fake/bun"
run_node() {
  : >"$fake/log"
  FAKE_LOG="$fake/log" FAKE_INSTALLED="$1" PATH="$fake:$PATH" bash "$script" >/dev/null 2>&1 || true
}
run_node "${pin}0 1${pin}"
grep -q "^asdf install nodejs $pin\$" "$fake/log" \
  && ok 'near-miss versions still trigger asdf install' || bad 'near-miss versions skipped asdf install' "$(cat "$fake/log")"
run_node "$pin"
grep -q '^asdf install nodejs' "$fake/log" \
  && bad 'exact installed version still ran asdf install' "$(cat "$fake/log")" || ok 'exact installed version skips asdf install'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
