#!/usr/bin/env bash
# Grok: merge ide/grok/config.defaults.toml into ~/.grok/config.toml. Adds missing keys and tables,
# never changes a key the file already has. Safe to re-run.
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
SRC="$DOTFILES/ide/grok/config.defaults.toml"
DEST="${GROK_CONFIG:-$HOME/.grok/config.toml}"

if [ ! -f "$SRC" ]; then
  echo "setup-grok: missing $SRC" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "setup-grok: python3 not found; skipping." >&2
  exit 0
fi

mkdir -p "$(dirname "$DEST")"
[ -f "$DEST" ] || : >"$DEST"

python3 -I - "$SRC" "$DEST" <<'PY'
import re
import sys

src, dest = sys.argv[1:3]
header = re.compile(r"^\s*\[{1,2}\s*([^\]]+?)\s*\]{1,2}\s*(#.*)?$")


def read_defaults(path):
    out, table = [], None
    for line in open(path, encoding="utf-8"):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        m = header.match(s)
        if m:
            table = m.group(1)
        elif table and "=" in s:
            key = s.split("=", 1)[0].strip()
            out.append((table, key, s))
    return out


lines = open(dest, encoding="utf-8").read().splitlines()
added = []
for table, key, text in read_defaults(src):
    start = next((i for i, l in enumerate(lines) if (m := header.match(l)) and m.group(1) == table and not l.lstrip().startswith("[[")), None)
    if start is None:
        if lines and lines[-1].strip():
            lines.append("")
        lines += [f"[{table}]", text]
        added.append(f"{table}.{key}")
        continue
    end = next((i for i in range(start + 1, len(lines)) if header.match(lines[i])), len(lines))
    if any(re.match(rf"^\s*{re.escape(key)}\s*=", l) for l in lines[start + 1:end]):
        continue
    at = end
    while at > start + 1 and not lines[at - 1].strip():
        at -= 1
    lines.insert(at, text)
    added.append(f"{table}.{key}")

if added:
    open(dest, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("setup-grok: added " + (", ".join(added) if added else "nothing") + f" in {dest}")
PY
