#!/usr/bin/env python3
"""Antigravity sign-in screen matcher and the per-host agy-unavailable record (#1240).

  agy-signin.py match               read a worker screen on stdin; exit 0 when it is the sign-in screen
  agy-signin.py unavailable <host>  exit 0 when the host is marked agy-unavailable
  agy-signin.py mark <host>         mark the host for 6 hours; print "notify" when a notice is due, else "known"
  agy-signin.py usable --agent <a> --host <h> [--config <fleet config>]
                                    exit 0 when the agent may start on the host, 1 when not (#1966)

A plain `agy -p` probe over ssh says "authentication failed" on a signed in host (the keychain is not
reachable from ssh), so the worker screen is the only check.
"""
import json
import os
import re
import socket
import sys
import time
from pathlib import Path

UNAVAILABLE_SECONDS = 6 * 3600
# Only a short line counts. A working agent quoting the words inside a long sentence is not the sign-in screen.
MAX_LINE = 100
SIGN_IN_RE = re.compile(
    r'not signed in|select login method|\b(?:please |you must )?sign in (?:to|with|required|again)\b'
    r'|\bauthentication (?:failed|required|error)\b', re.I)
ANSI_RE = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')
# Lines the agent itself prints while it works (prompt marker, tool and thinking lines).
WORKING_RE = re.compile(r'^(>|[⠁-⣿]|•|esc to interrupt)|\b(running|thinking|working on)\b', re.I)


def screen_lines(raw):
    """Screen text as stripped lines. Accepts plain text or an `orca terminal read --json` document."""
    text = raw
    try:
        doc = json.loads(raw)
    except ValueError:
        doc = None
    if isinstance(doc, dict):
        result = doc.get('result') if isinstance(doc.get('result'), dict) else doc
        term = result.get('terminal')
        tail = term.get('tail') if isinstance(term, dict) else None
        if isinstance(tail, list):
            text = '\n'.join(str(line) for line in tail)
        elif isinstance(term, dict) and isinstance(term.get('screen'), str):
            text = term['screen']
        elif isinstance(term, str):
            text = term
    lines = [ANSI_RE.sub('', line).strip() for line in text.splitlines()]
    return [line for line in lines if line][-30:]


def is_sign_in_screen(raw):
    for line in screen_lines(raw):
        if len(line) <= MAX_LINE and SIGN_IN_RE.search(line) and not WORKING_RE.search(line):
            return True
    return False


def state_path():
    return Path(os.environ.get('AGY_UNAVAILABLE_STATE') or Path.home() / '.claude' / 'state' / 'agy-unavailable.json')


def _load(path):
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _fleet_config(config):
    """The fleet config, found the way worker-placement.py finds it, when the caller passes none."""
    if config is not None:
        return config
    env = os.environ.get('FLEET_WATCH_CONFIG') or os.environ.get('FLEET_PLACEMENT_CONFIG')
    return _load(Path(os.path.expanduser(env)) if env else Path.home() / '.config' / 'fleet-watch' / 'config.json')


def host_key(host, config=None):
    """The record key for a host: lowercase, with '', 'local', the config local_host and this machine's name
    all mapped to the config local_host (or 'local' when the config names none)."""
    local = (_fleet_config(config).get('local_host') or '')
    local = local.strip().lower() if isinstance(local, str) else ''
    key = (host or '').strip().lower()
    this = socket.gethostname().split('.')[0].lower()
    if key in ('', 'local', local, this):
        return local or 'local'
    return key


def usable(agent, host, config=None, now=None, path=None):
    """False only for antigravity on a host marked agy-unavailable; every other agent is usable (#1966)."""
    if (agent or '').strip().lower() not in ('antigravity', 'agy'):
        return True
    return not is_unavailable(host, now=now, path=path, config=config)


def is_unavailable(host, now=None, path=None, config=None):
    now = time.time() if now is None else now
    row = _load(path or state_path()).get(host_key(host, config))
    until = row.get('until') if isinstance(row, dict) else None
    return isinstance(until, (int, float)) and not isinstance(until, bool) and now < until


def mark(host, now=None, path=None, config=None):
    """Mark the host for 6 hours. True when the owner is due a notice: at most one per host per 6 hours."""
    now = time.time() if now is None else now
    path = path or state_path()
    data = _load(path)
    key = host_key(host, config)
    row = data.get(key) if isinstance(data.get(key), dict) else {}
    notified = row.get('notified_at')
    due = not (isinstance(notified, (int, float)) and not isinstance(notified, bool)
               and now - notified < UNAVAILABLE_SECONDS)
    row['until'] = now + UNAVAILABLE_SECONDS
    if due:
        row['notified_at'] = now
    data[key] = row
    data = {h: r for h, r in data.items() if isinstance(r, dict) and now < max(
        r.get('until') or 0, (r.get('notified_at') or 0) + UNAVAILABLE_SECONDS)}
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp')
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True))
    os.replace(tmp, path)
    return due


def main(argv):
    if any(arg in ('-h', '--help') for arg in argv[1:]):
        print(__doc__.rstrip())
        return 0
    cmd = argv[1] if len(argv) > 1 else ''
    if cmd == 'match':
        return 0 if is_sign_in_screen(sys.stdin.read()) else 1
    if cmd == 'unavailable' and len(argv) == 3:
        return 0 if is_unavailable(argv[2]) else 1
    if cmd == 'mark' and len(argv) == 3:
        print('notify' if mark(argv[2]) else 'known')
        return 0
    if cmd == 'usable':
        opts = dict(zip(argv[2::2], argv[3::2]))
        if len(argv) % 2 or set(opts) - {'--agent', '--host', '--config'} or not {'--agent', '--host'} <= set(opts):
            print(__doc__, file=sys.stderr)
            return 2
        config = _load(Path(opts['--config'])) if '--config' in opts else None
        return 0 if usable(opts['--agent'], opts['--host'], config) else 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
