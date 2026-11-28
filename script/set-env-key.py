#!/usr/bin/env python3
"""Replace the host inside one key's URL value in an env file, in place, printing no value (#2083).

  set-env-key.py <file> <KEY> --replace-host <old> <new>

The key must appear exactly once as `KEY=<scheme>://...` (an `export ` prefix and quotes are kept), and the URL's
host must equal <old>. Only the host changes; user, password, port, path and every other line stay byte for byte.
The file keeps its mode and owner. Output and errors name the file and the key, never a value.
The guard asks the owner before an agent runs this on a file in the credential folder.
"""
import os
import re
import sys
import tempfile

HOST = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?")
KEY = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
USAGE = "usage: set-env-key.py <file> <KEY> --replace-host <old> <new>"


def fail(msg, code=1):
    print(f"set-env-key: {msg}", file=sys.stderr)
    sys.exit(code)


def main(argv):
    if len(argv) != 5 or argv[2] != "--replace-host":
        fail(USAGE, 2)
    path, key, _, old, new = argv
    if not KEY.fullmatch(key):
        fail("the key must be a plain env name", 2)
    if not HOST.fullmatch(old) or not HOST.fullmatch(new):
        fail("each host must be a plain host name or IPv4 address", 2)
    try:
        st = os.stat(path)
        with open(path, "rb") as f:
            lines = f.read().split(b"\n")
    except OSError as exc:
        fail(f"cannot read {path}: {exc.strerror}")

    line_re = re.compile(rb"^(\s*(?:export\s+)?" + key.encode() + rb"=['\"]?[A-Za-z][A-Za-z0-9+.-]*://(?:[^/?#@'\"\s]*@)?)"
                         rb"([^:/?#'\"\s]*)(.*)$", re.DOTALL)
    named = re.compile(rb"^\s*(?:export\s+)?" + key.encode() + rb"=")
    hits = [i for i, line in enumerate(lines) if named.match(line)]
    if not hits:
        fail(f"{key} is not set in {path}")
    if len(hits) > 1:
        fail(f"{key} is set more than once in {path}")
    m = line_re.match(lines[hits[0]])
    if not m:
        fail(f"{key} in {path} is not a URL")
    if m.group(2).decode(errors="replace").lower() != old.lower():
        fail(f"the {key} host in {path} is not {old}; nothing changed")
    lines[hits[0]] = m.group(1) + new.encode() + m.group(3)

    folder = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".set-env-key.")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(b"\n".join(lines))
        os.chmod(tmp, st.st_mode & 0o7777)
        if os.stat(tmp).st_uid != st.st_uid or os.stat(tmp).st_gid != st.st_gid:
            os.chown(tmp, st.st_uid, st.st_gid)
        os.replace(tmp, path)
    except OSError as exc:
        os.unlink(tmp)
        fail(f"cannot write {path}: {exc.strerror}")
    print(f"set-env-key: {key} host {old} -> {new} in {path}")


if __name__ == "__main__":
    main(sys.argv[1:])
