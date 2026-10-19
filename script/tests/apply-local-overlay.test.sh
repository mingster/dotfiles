#!/usr/bin/env bash
# apply-local-overlay.py merges an untracked local overlay over a tracked JSON file.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo '{"a":{"x":1},"l":["one"],"k":1}' > "$tmp/base.json"
echo '{"a":{"y":2},"l":["one","two"],"k":3}' > "$tmp/over.json"
out=$(python3 "$here/apply-local-overlay.py" "$tmp/base.json" "$tmp/over.json" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin),sort_keys=True))')
[ "$out" = '{"a": {"x": 1, "y": 2}, "k": 3, "l": ["one", "two"]}' ] || { echo "FAIL merge: $out"; exit 1; }
out=$(python3 "$here/apply-local-overlay.py" "$tmp/base.json" "$tmp/missing.json" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin),sort_keys=True))')
[ "$out" = '{"a": {"x": 1}, "k": 1, "l": ["one"]}' ] || { echo "FAIL missing overlay: $out"; exit 1; }
echo "ok: apply-local-overlay"
