#!/usr/bin/env python3
"""Refuse a Bash command that changes the schema of a shared dev database (#1680).

Usage: check-shared-db-write.py                     PreToolUse hook: reads the hook JSON on stdin, prints a deny decision.
       check-shared-db-write.py --command "<cmd>"   prints the refusal and exits 1, or exits 0 when allowed.
       -h, --help                                   print this text.

A command is refused when it runs DDL or a migration (psql with CREATE, ALTER or DROP; prisma db push,
db execute or migrate; dbpush) and its target is a shared database. The target is a database name in the
command, else DATABASE_URL or DIRECT_URL in the environment. A name in the command wins over the environment.

The shared names are private (this repo is public), so they come from a pattern file, not from this script:
${SHARED_DB_PATTERN_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/shared-db.pattern}, two lines:
  shared: <extended regex that matches a whole shared database name>
  verifier: <prefix of the allowed verifier temp databases>
No file means nothing is checked (exit 0, and --command says so on stderr).

Allowed: databases starting with the verifier prefix, bin/bootstrap-regression-shard.ts, and the release-manager
role (the brief's first line `Worker role: release-manager`). Unexpected input exits 0: a gate, not a crash.
"""
import json
import os
import re
import sys

NAME = re.compile(r"[A-Za-z0-9_]+")
PRISMA = re.compile(r"\bprisma\s+(?:db\s+(?:push|execute)|migrate)\b")
DBPUSH = re.compile(r"(?<![\w-])dbpush(?![\w-])")
PSQL = re.compile(r"(?<![\w-])psql\b")
DDL = re.compile(r"\b(?:create|alter|drop)\b", re.I)
SQL_FILE = re.compile(r"(?:-f|--file)[=\s]+(\S+)")
BOOTSTRAP = "bootstrap-regression-shard.ts"
ENV_NAMES = ("DATABASE_URL", "DIRECT_URL")


def pattern_path():
    return os.environ.get("SHARED_DB_PATTERN_FILE") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "dotfiles", "shared-db.pattern")


def load_config():
    """(shared regex, verifier prefix), or None when the file is missing or unusable."""
    try:
        with open(pattern_path(), encoding="utf-8") as fh:
            lines = fh.read().splitlines()
        shared = next(l.split(":", 1)[1].strip() for l in lines if l.startswith("shared:"))
        verifier = next((l.split(":", 1)[1].strip() for l in lines if l.startswith("verifier:")), "")
        return re.compile(shared), verifier
    except (OSError, StopIteration, re.error):
        return None


def refusal(db, verifier):
    v = f"{verifier}<id>"
    return (f"Refused: this changes the schema of the shared database `{db}`. Workers never write to a shared dev database. "
            f"Use a verifier temp database instead: `createdb {v}`, point DATABASE_URL at it "
            f"(`postgres://.../{v}`), run the migration or `prisma db push` there, then `dropdb {v}`. "
            "A regression shard comes from `bin/bootstrap-regression-shard.ts`. See deploy-facts.md, Verifier schema.")


def is_ddl(cmd):
    if PRISMA.search(cmd) or DBPUSH.search(cmd):
        return True
    if not PSQL.search(cmd):
        return False
    if DDL.search(cmd):
        return True
    for path in SQL_FILE.findall(cmd):
        try:
            with open(os.path.expanduser(path.strip("'\"")), encoding="utf-8", errors="replace") as fh:
                if DDL.search(fh.read(1 << 20)):
                    return True
        except OSError:
            continue
    return False


def shared_target(cmd, shared, verifier):
    """The shared database the command targets, or ''. A database named in the command wins over the environment."""
    named = False
    for tok in NAME.findall(cmd):
        if shared.fullmatch(tok):
            return tok
        named = named or bool(verifier and tok.startswith(verifier))
    if named:
        return ""
    for var in ENV_NAMES:
        for tok in NAME.findall(os.environ.get(var, "")):
            if shared.fullmatch(tok):
                return tok
    return ""


def role_of(transcript_path):
    """The `Worker role:` stamp on the first line of the session's first user message."""
    try:
        with open(transcript_path, encoding="utf-8", errors="replace") as fh:
            raw = fh.read(65536)
    except (OSError, TypeError):
        return ""
    for line in raw.splitlines():
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        msg = obj.get("message") if isinstance(obj, dict) else None
        if not isinstance(msg, dict) or msg.get("role") != "user" or obj.get("isMeta") or obj.get("toolUseResult"):
            continue
        content = msg.get("content")
        if isinstance(content, list):
            if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
                continue
            content = "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
        if isinstance(content, str) and content.strip():
            m = re.fullmatch(r"Worker role: ([a-z0-9-]+)", content.lstrip("﻿").split("\n", 1)[0].rstrip("\r"))
            return m.group(1) if m else ""
    return ""


def check(cmd, role="", config=None):
    """The refusal text, or '' when the command is allowed."""
    config = config or load_config()
    if not config or not isinstance(cmd, str) or BOOTSTRAP in cmd or role == "release-manager":
        return ""
    if not is_ddl(cmd):
        return ""
    db = shared_target(cmd, *config)
    return refusal(db, config[1]) if db else ""


def main(argv):
    if any(a in ("-h", "--help") for a in argv):
        print(__doc__.strip())
        return 0
    if argv[:1] == ["--command"]:
        if len(argv) != 2:
            print("Usage: check-shared-db-write.py --command <cmd>", file=sys.stderr)
            return 2
        if not load_config():
            print(f"no usable pattern file at {pattern_path()}: nothing checked", file=sys.stderr)
        msg = check(argv[1])
        if msg:
            print(msg)
        return 1 if msg else 0
    if argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        data = json.load(sys.stdin)
        if data.get("tool_name") != "Bash":
            return 0
        msg = check((data.get("tool_input") or {}).get("command"), role_of(data.get("transcript_path")))
    except (ValueError, AttributeError):
        return 0
    if msg:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                 "permissionDecision": "deny", "permissionDecisionReason": msg}}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
