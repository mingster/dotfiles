#!/usr/bin/env python3
"""Look at a .env or secret file without printing a secret.

Usage:
  python3 "$HOME/.claude/bin/env-peek.py" <file> [KEY ...]   keys of a dotenv file, values masked
  python3 "$HOME/.claude/bin/env-peek.py" <file>             a non dotenv file (a key, a secrets/ file): its fingerprint

For each key it prints one of:
  KEY = <plain value>                 only for short values whose key name is not secret like
  KEY = <set, 64 chars, fp 1a2b3c4d>  a secret; equal fingerprints mean equal values
  KEY = sqlserver://host:1433;database=app_test;user=***;password=***
                                      a connection string, with credentials masked
  KEY = <empty> / <missing>

A file in the root owned credential folder cannot be opened, so the root owned gate prints its whole file
fingerprint instead (sudo asks Touch ID or the password): no per key lines there.

The fingerprint is the first 8 hex digits of a SHA-256 of the value: enough to tell
whether two copies match, useless for recovering the value.
"""
import hashlib
import os
import re
import subprocess
import sys

GATE = os.environ.get("SECRETS_GATE", "/opt/secrets-gate/secrets-gate")

SECRET_NAME = re.compile(r"SECRET|PASSW|TOKEN|KEY|PRIVATE|CRED|AUTH|SALT|SIGNING|WEBHOOK_ID|DSN", re.I)
URL_CREDS = re.compile(r"^([a-z][a-z0-9+.-]*://)([^:@/;]+)(:[^@/]*)?@", re.I)
KV_CREDS = re.compile(r"((?:^|;)\s*(?:user(?:\s*id)?|uid|username|password|pwd)\s*=)[^;]*", re.I)


def fp(value):
    return hashlib.sha256(value.encode()).hexdigest()[:8]


def show(key, value):
    if value is None:
        return "<missing>"
    if value == "":
        return "<empty>"
    if "://" in value or re.search(r";\s*(password|pwd)\s*=", value, re.I):
        masked = URL_CREDS.sub(lambda m: f"{m.group(1)}***:***@", value)
        masked = KV_CREDS.sub(lambda m: f"{m.group(1)}***", masked)
        masked = re.sub(r"([?&](?:password|pwd|token|key|secret)=)[^&]*", r"\1***", masked, flags=re.I)
        return f"{masked}  (fp {fp(value)})"
    if SECRET_NAME.search(key) or len(value) > 60:
        return f"<set, {len(value)} chars, fp {fp(value)}>"
    return value


def parse(text):
    env = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*(.*)$", line)
        if not m:
            continue
        key, value = m.group(1), m.group(2).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        else:
            value = re.sub(r"\s+#.*$", "", value)
        env[key] = value
    return env


def via_gate(path):
    """The credential folder is root owned: ask the root owned gate for the fingerprint (Touch ID or password)."""
    if not os.access(GATE, os.X_OK):
        print(f"{path}: Permission denied")
        return 1
    return subprocess.run(["sudo", GATE, "fingerprint", path]).returncode


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    path, keys = sys.argv[1], sys.argv[2:]
    try:
        raw = open(path, "rb").read()
    except PermissionError:
        return via_gate(path)
    except OSError as e:
        print(f"{path}: {e.strerror}")
        return 1
    try:
        text = raw.decode()
    except UnicodeDecodeError:
        text = None
    env = parse(text) if text is not None else {}
    if not env:
        print(f"{path}: not a dotenv file; {len(raw)} bytes, fp {hashlib.sha256(raw).hexdigest()[:8]}")
        return 0
    for key in keys or sorted(env):
        print(f"{key} = {show(key, env.get(key))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
