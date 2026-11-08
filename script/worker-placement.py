#!/usr/bin/env python3
"""Pick a fleet host for worker-startup when --on is omitted."""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

NON_WORKER_ROLES = frozenset({'heavy', 'release'})
BROWSER_ROLE = 'browser'
CODE_ROLES = frozenset({'code', ''})
BROWSER_MARKERS = re.compile(
    r'\b(agent-browser|browser host|browser work|built-in-browser|chrome-browser)\b'
    r'|\bsecrets\b|\bmain checkout\b',
    re.IGNORECASE,
)
LOAD_LINE = re.compile(
    r'^(?P<host>[A-Za-z0-9._-]+)\s+.*\bload=(?P<load>[0-9]+(?:\.[0-9]+)?)',
)
UNREACHABLE = re.compile(r'\bunreachable\b', re.IGNORECASE)


def expand(path: str) -> str:
    return os.path.expanduser(path)


def config_path(explicit: str | None) -> Path:
    if explicit:
        return Path(expand(explicit))
    env = os.environ.get('FLEET_WATCH_CONFIG') or os.environ.get('FLEET_PLACEMENT_CONFIG')
    if env:
        return Path(expand(env))
    return Path(expand('~/.config/fleet-watch/config.json'))


def load_config(path: Path) -> dict:
    if not path.is_file():
        raise SystemExit(f'worker-placement: missing fleet config {path}')
    with path.open(encoding='utf-8') as fh:
        data = json.load(fh)
    return data if isinstance(data, dict) else {}


def load_sensor_path(config: dict) -> Path:
    placement = config.get('worker_placement') or {}
    if isinstance(placement, dict):
        for key in ('load_sensor', 'fleet_load'):
            raw = placement.get(key)
            if isinstance(raw, str) and raw.strip():
                return Path(expand(raw.strip()))
    env = os.environ.get('FLEET_LOAD_SCRIPT') or os.environ.get('WORKER_PLACEMENT_LOAD_SCRIPT')
    if env:
        return Path(expand(env))
    return Path(expand('~/.claude/state/fleet-load.sh'))


def read_loads(sensor: Path, timeout: float) -> dict[str, float | None]:
    if not sensor.is_file():
        raise SystemExit(f'worker-placement: missing load sensor {sensor}')
    try:
        proc = subprocess.run(
            ['bash', str(sensor)],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise SystemExit(f'worker-placement: load sensor failed ({exc})') from exc
    if proc.returncode != 0:
        raise SystemExit('worker-placement: load sensor failed')
    out: dict[str, float | None] = {}
    for line in proc.stdout.splitlines():
        if UNREACHABLE.search(line):
            host = line.split(None, 1)[0] if line.split() else ''
            if host:
                out[host] = None
            continue
        match = LOAD_LINE.match(line.strip())
        if not match:
            continue
        host = match.group('host')
        try:
            out[host] = float(match.group('load'))
        except ValueError:
            out[host] = None
    return out


def placement_order(config: dict) -> list[str]:
    placement = config.get('worker_placement') or {}
    if isinstance(placement, dict):
        order = placement.get('order')
        if isinstance(order, list) and all(isinstance(h, str) and h for h in order):
            return order
    host_caps = config.get('host_caps') or {}
    if not isinstance(host_caps, dict) or not host_caps:
        return []
    local_host = config.get('local_host')
    local = local_host if isinstance(local_host, str) and local_host in host_caps else None
    others = [h for h in host_caps if h != local]
    ceilings = config.get('host_load_ceilings') if isinstance(config.get('host_load_ceilings'), dict) else {}
    others.sort(key=lambda h: (float(ceilings.get(h, 9999)), h))
    if local:
        return [local] + others
    return others


def host_roles(config: dict) -> dict[str, str]:
    placement = config.get('worker_placement') or {}
    roles = placement.get('roles') if isinstance(placement, dict) else None
    if isinstance(roles, dict):
        return {str(k): str(v) for k, v in roles.items()}
    return {}


def task_kind(spec_path: Path | None) -> str:
    if spec_path is None or not spec_path.is_file():
        return 'code'
    try:
        text = spec_path.read_text(encoding='utf-8', errors='replace')
    except OSError:
        return 'code'
    return 'browser' if BROWSER_MARKERS.search(text) else 'code'


def ceiling_for(host: str, config: dict) -> float | None:
    ceilings = config.get('host_load_ceilings')
    if isinstance(ceilings, dict) and host in ceilings:
        try:
            return float(ceilings[host])
        except (TypeError, ValueError):
            return None
    return None


def eligible_hosts(order: list[str], config: dict, kind: str, roles: dict[str, str]) -> list[str]:
    host_caps = config.get('host_caps') or {}
    if not isinstance(host_caps, dict):
        host_caps = {}
    picked: list[str] = []
    for host in order:
        if host not in host_caps:
            continue
        role = roles.get(host, 'code')
        if kind == 'browser':
            if role != BROWSER_ROLE:
                continue
        else:
            if role in NON_WORKER_ROLES or role == BROWSER_ROLE:
                continue
        picked.append(host)
    return picked


def pick_host(config: dict, spec_path: Path | None) -> dict:
    kind = task_kind(spec_path)
    roles = host_roles(config)
    order = placement_order(config)
    if not order:
        return {'ok': False, 'reason': 'no worker_placement order or host_caps in fleet config'}
    hosts = eligible_hosts(order, config, kind, roles)
    if not hosts:
        return {'ok': False, 'reason': 'no eligible fleet hosts for this task'}
    loads = read_loads(load_sensor_path(config), float(os.environ.get('WORKER_PLACEMENT_TIMEOUT', '120')))
    local_host = config.get('local_host') if isinstance(config.get('local_host'), str) else None
    considered: dict[str, float] = {}
    for host in hosts:
        load = loads.get(host)
        if load is None:
            continue
        ceiling = ceiling_for(host, config)
        if ceiling is None:
            continue
        considered[host] = load
        if load < ceiling:
            is_local = host == local_host
            return {
                'ok': True,
                'host': host,
                'load_1m': load,
                'ceiling': ceiling,
                'local': is_local,
                'environment': None if is_local else host,
                'task_kind': kind,
            }
    if not considered:
        return {'ok': False, 'reason': 'no readable load for any eligible host', 'loads': {}}
    return {'ok': False, 'reason': 'all eligible hosts over load ceiling', 'loads': considered}


def format_line(result: dict) -> str:
    if result.get('ok'):
        return 'worker-placement: host=%s load_1m=%s' % (result['host'], result['load_1m'])
    loads = result.get('loads') or {}
    if loads:
        parts = ' '.join('%s=%s' % (h, loads[h]) for h in sorted(loads))
        return 'worker-placement: refused %s' % parts
    return 'worker-placement: refused (%s)' % (result.get('reason') or 'unknown')


def cmd_pick(args: argparse.Namespace) -> int:
    path = config_path(args.config)
    spec = Path(args.spec) if args.spec else None
    result = pick_host(load_config(path), spec)
    if args.json:
        print(json.dumps(result, separators=(',', ':')))
    else:
        print(format_line(result))
    return 0 if result.get('ok') else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='cmd', required=True)
    pick = sub.add_parser('pick', help='Choose a host under its load ceiling')
    pick.add_argument('--spec', default=None, help='Task brief file (browser routing)')
    pick.add_argument('--config', default=None, help='Fleet-watch JSON config')
    pick.add_argument('--json', action='store_true', help='Emit JSON instead of one line')
    pick.set_defaults(func=cmd_pick)
    args = parser.parse_args()
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())
