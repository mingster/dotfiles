#!/usr/bin/env bash
# Set the four Claude display keys in settings files to the fleet value (#1682). Uses python3, never jq.
# Usage: fix-display-settings.sh <settings.json>...   (-h and --help print this text)
# Keys: verbose=false, spinnerTipsEnabled=false, prefersReducedMotion=true, tui="fullscreen" (same as check-display-settings.sh).
# Each file is rewritten atomically (temp file in the same folder, then rename) and only when a key differs.
# Other keys keep their values and order. A symlink is skipped and an unreadable or non-object file is reported, never overwritten.
# Prints one line per file: "fixed <path>", "ok <path>", "skip <path> (symlink)" or "fail <path> (<reason>)". Exits 1 when any file fails.
set -u
print_usage() { sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}"; }
for a in ${1+"$@"}; do case "$a" in -h|--help) print_usage; exit 0 ;; --) break ;; esac; done
[ "$#" -ge 1 ] || { print_usage >&2; exit 2; }
command -v python3 >/dev/null || { echo 'fix-display-settings requires python3' >&2; exit 2; }
exec python3 -I - "$@" <<'PY'
import json, os, sys, tempfile

WANT = {"verbose": False, "spinnerTipsEnabled": False, "prefersReducedMotion": True, "tui": "fullscreen"}
rc = 0
for path in sys.argv[1:]:
    if os.path.islink(path):
        print(f"skip {path} (symlink)")
        continue
    if not os.path.isfile(path):
        print(f"fail {path} (no settings file)")
        rc = 1
        continue
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        data = None
    if not isinstance(data, dict):
        print(f"fail {path} (unreadable settings file, left unchanged)")
        rc = 1
        continue
    if all(k in data and type(data[k]) is type(v) and data[k] == v for k, v in WANT.items()):
        print(f"ok {path}")
        continue
    data.update(WANT)
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".settings.", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            json.dump(data, out, indent=2, ensure_ascii=False)
            out.write("\n")
        os.chmod(tmp, os.stat(path).st_mode & 0o7777)
        os.replace(tmp, path)
        print(f"fixed {path}")
    except OSError as e:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)
        print(f"fail {path} ({e.strerror or 'write failed'})")
        rc = 1
sys.exit(rc)
PY
