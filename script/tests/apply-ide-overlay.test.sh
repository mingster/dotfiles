#!/usr/bin/env bash
# apply-ide-overlay.py inserts overlay list items into a JSONC settings file.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '{\n  // keep\n  "cSpell.userWords": [\n    "totp"\n  ],\n  "x": 1,\n}\n' > "$tmp/base.json"
echo '{"cSpell.userWords":["extra","totp"]}' > "$tmp/over.json"
out=$(python3 "$here/apply-ide-overlay.py" "$tmp/base.json" "$tmp/over.json")
want=$(printf '{\n  // keep\n  "cSpell.userWords": [\n    "extra",\n    "totp"\n  ],\n  "x": 1,\n}\n')
[ "$out" = "$want" ] || { echo "FAIL insert: $out"; exit 1; }
[ "$(python3 "$here/apply-ide-overlay.py" "$tmp/base.json" "$tmp/none.json")" = "$(cat "$tmp/base.json")" ] || { echo "FAIL missing overlay"; exit 1; }
echo "ok: apply-ide-overlay"
