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

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
