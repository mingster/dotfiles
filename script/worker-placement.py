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
LOCAL_MAX_LOAD_PER_CORE = 0.7
BROWSER_ROLE_LINE = re.compile(r'^Host role:\s*browser\s*$', re.IGNORECASE | re.MULTILINE)
LOAD_LINE = re.compile(
    r'^(?P<host>[A-Za-z0-9._-]+)\s+.*\bcores=(?P<cores>[0-9]+).*'
    r'\bload=(?P<load>[0-9]+(?:\.[0-9]+)?)',
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


class FleetConfigError(Exception):
    pass


class FleetConfigMissing(FleetConfigError):
    pass


def load_config(path: Path) -> dict:
    if not path.is_file():
        raise FleetConfigMissing(path)
    try:
        with path.open(encoding='utf-8') as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        raise FleetConfigError(f'worker-placement: unreadable fleet config {path} ({exc})') from exc
    if not isinstance(data, dict):
        raise FleetConfigError(f'worker-placement: fleet config must be a JSON object ({path})')
    return data


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


def read_loads(sensor: Path, timeout: float) -> dict[str, tuple[float, int] | None]:
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
    out: dict[str, tuple[float, int] | None] = {}
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
            load = float(match.group('load'))
            cores = int(match.group('cores'))
            if cores < 1:
                cores = 1
            out[host] = (load, cores)
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
    return 'browser' if BROWSER_ROLE_LINE.search(text) else 'code'


def ceiling_for(host: str, config: dict) -> float | None:
    ceilings = config.get('host_load_ceilings')
    if isinstance(ceilings, dict) and host in ceilings:
        try:
            return float(ceilings[host])
        except (TypeError, ValueError):
            return None
    return None


def repo_map_key(repo_selector: str | None) -> str | None:
    if not repo_selector:
        return None
    sel = repo_selector.strip()
    if sel.startswith('id:'):
        return sel[3:].strip() or None
    if sel.startswith('path:'):
        return sel[5:].strip() or None
    return sel or None


def repos_for_env(config: dict) -> dict[str, dict[str, str]]:
    placement = config.get('worker_placement') or {}
    if not isinstance(placement, dict):
        return {}
    raw = placement.get('repos')
    if not isinstance(raw, dict):
        return {}
    out: dict[str, dict[str, str]] = {}
    for env, mapping in raw.items():
        if not isinstance(env, str) or not isinstance(mapping, dict):
            continue
        out[env] = {str(k): str(v) for k, v in mapping.items() if isinstance(v, str) and v.strip()}
    return out


def translate_repo(config: dict, environment: str, repo_selector: str) -> str | None:
    key = repo_map_key(repo_selector)
    if key is None:
        return None
    mapping = repos_for_env(config).get(environment) or {}
    mapped = mapping.get(key) or mapping.get(repo_selector)
    return mapped if mapped else None


def host_has_repo_mapping(config: dict, host: str, local_host: str | None, repo_selector: str | None) -> bool:
    if not repo_selector or host == local_host:
        return True
    return translate_repo(config, host, repo_selector) is not None


def host_over_load(
    host: str,
    load: float,
    cores: int,
    ceiling: float,
    local_host: str | None,
) -> bool:
    if load >= ceiling:
        return True
    if host != local_host or cores < 1:
        return False
    return (load / cores) >= LOCAL_MAX_LOAD_PER_CORE


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


def pick_host(config: dict, spec_path: Path | None, repo_selector: str | None = None) -> dict:
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
    unmapped = 0
    for host in hosts:
        if not host_has_repo_mapping(config, host, local_host, repo_selector):
            unmapped += 1
            print(
                'worker-placement: skip %s (no repo mapping for %s)'
                % (host, repo_map_key(repo_selector) or repo_selector),
                file=sys.stderr,
            )
            continue
        sample = loads.get(host)
        if sample is None:
            continue
        load, cores = sample
        ceiling = ceiling_for(host, config)
        if ceiling is None:
            continue
        considered[host] = load
        if not host_over_load(host, load, cores, ceiling, local_host):
            is_local = host == local_host
            result: dict = {
                'ok': True,
                'host': host,
                'load_1m': load,
                'ceiling': ceiling,
                'local': is_local,
                'environment': None if is_local else host,
                'task_kind': kind,
            }
            if repo_selector and not is_local:
                mapped = translate_repo(config, host, repo_selector)
                if mapped:
                    result['repo'] = mapped
            return result
    if unmapped == len(hosts):
        return {'ok': False, 'reason': 'no host has a repo mapping', 'loads': {}}
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
    try:
        cfg = load_config(path)
    except FleetConfigMissing:
        print('worker-placement: skipped (no fleet config)', file=sys.stderr)
        print(json.dumps({'ok': False, 'skipped': True, 'reason': 'no fleet config'}))
        return 0
    except FleetConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    result = pick_host(cfg, spec, args.repo)
    if args.json:
        print(json.dumps(result, separators=(',', ':')))
    else:
        print(format_line(result))
    return 0 if result.get('ok') else 1


def cmd_translate_repo(args: argparse.Namespace) -> int:
    path = config_path(args.config)
    try:
        cfg = load_config(path)
    except FleetConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    mapped = translate_repo(cfg, args.environment, args.repo)
    if not mapped:
        print(
            'worker-placement: no repo mapping for %s on %s'
            % (repo_map_key(args.repo) or args.repo, args.environment),
            file=sys.stderr,
        )
        return 1
    print(mapped)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='cmd', required=True)
    pick = sub.add_parser('pick', help='Choose a host under its load ceiling')
    pick.add_argument('--spec', default=None, help='Task brief file (browser routing)')
    pick.add_argument('--repo', default=None, help='Repo selector for remote placement (id: or path:)')
    pick.add_argument('--config', default=None, help='Fleet-watch JSON config')
    pick.add_argument('--json', action='store_true', help='Emit JSON instead of one line')
    pick.set_defaults(func=cmd_pick)
    translate = sub.add_parser('translate-repo', help='Map a local repo selector to a remote environment')
    translate.add_argument('--environment', required=True)
    translate.add_argument('--repo', required=True)
    translate.add_argument('--config', default=None)
    translate.set_defaults(func=cmd_translate_repo)
    args = parser.parse_args()
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())
