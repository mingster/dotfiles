#!/usr/bin/env python3
"""Pick a fleet host for worker-startup when --on is omitted."""
from __future__ import annotations

import argparse
import fcntl
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path

NON_WORKER_ROLES = frozenset({'heavy', 'release'})
BROWSER_ROLE = 'browser'
CODE_ROLES = frozenset({'code', ''})
LOCAL_MAX_LOAD_PER_CORE = 0.7
DEFAULT_RECENT_START_SECONDS = 300
DEFAULT_CORES_PER_WORKER = 2.0
DEFAULT_MEM_GB_PER_WORKER = 4.0
MEMFREE = re.compile(r'\bmemfree=(?P<gb>[0-9]+(?:\.[0-9]+)?)')
BROWSER_ROLE_LINE = re.compile(r'^Host role:\s*browser\s*$', re.IGNORECASE | re.MULTILINE)
LOAD_LINE = re.compile(
    r'^(?P<host>[A-Za-z0-9._-]+)\s+.*\bcores=(?P<cores>[0-9]+).*'
    r'\bload=(?P<load>[0-9]+(?:\.[0-9]+)?)(?:\s+(?P<load5>[0-9]+(?:\.[0-9]+)?))?',
)
ROLE_STAMP = re.compile(r'^Worker role:\s*([a-z0-9-]+)\s*$', re.MULTILINE)
# Roles whose gate runs Playwright browser tests: a deploy and a verifier (qa-sdet).
BROWSER_TEST_ROLES = frozenset({'release-manager', 'qa-sdet'})
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


class LoadSensorError(Exception):
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
    data['_config_path'] = str(path)
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


def read_loads(sensor: Path, timeout: float) -> dict[str, tuple[float, int, float, float | None] | None]:
    if not sensor.is_file():
        raise LoadSensorError(f'missing load sensor {sensor}')
    try:
        proc = subprocess.run(
            ['bash', str(sensor)],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise LoadSensorError(f'load sensor failed ({exc})') from exc
    if proc.returncode != 0:
        raise LoadSensorError('load sensor failed')
    out: dict[str, tuple[float, int, float, float | None] | None] = {}
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
            load5 = float(match.group('load5')) if match.group('load5') else load
            cores = int(match.group('cores'))
            if cores < 1:
                cores = 1
            mem = MEMFREE.search(line)
            out[host] = (load, cores, load5, float(mem.group('gb')) if mem else None)
        except ValueError:
            out[host] = None
    return out


def placement_order(config: dict) -> list[str]:
    """Every host_caps host. worker_placement.order only ranks them for ties."""
    host_caps = config.get('host_caps') or {}
    if not isinstance(host_caps, dict) or not host_caps:
        return []
    placement = config.get('worker_placement') or {}
    if isinstance(placement, dict):
        order = placement.get('order')
        if isinstance(order, list) and all(isinstance(h, str) and h for h in order):
            ranked = [h for h in order if h in host_caps]
            return ranked + [h for h in host_caps if h not in ranked]
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


HEAVY_LINE = re.compile(r'^Heavy:\s*yes\b', re.IGNORECASE | re.MULTILINE)
HEAVY_WORDS = re.compile(r'playwright|regression|xcodebuild|build-and-test\.sh|bun run build|head-checks-tsc|\btsc\b|\b(?:createdb|dropdb|psql|pg_dump|pg_restore)\b', re.IGNORECASE)


def heavy_start(spec_path: Path | None) -> bool:
    """True when the brief says `Heavy: yes`, its role is release-manager, or it names a heavy step (#1965)."""
    if spec_path is None or not spec_path.is_file():
        return False
    try:
        text = spec_path.read_text(encoding='utf-8', errors='replace')
    except OSError:
        return False
    role = ROLE_STAMP.search(text)
    return bool(HEAVY_LINE.search(text) or (role and role.group(1) == 'release-manager') or HEAVY_WORDS.search(text))


def light_only_hosts(config: dict) -> set[str]:
    """Lowercase light_only_hosts of the fleet config; empty when the key is absent (#1965)."""
    hosts = config.get('light_only_hosts')
    return {str(h).lower() for h in hosts} if isinstance(hosts, list) else set()


def needs_browser_host(spec_path: Path | None) -> bool:
    """True when the brief's `Worker role:` stamp is a role whose gate runs browser tests."""
    if spec_path is None or not spec_path.is_file():
        return False
    try:
        match = ROLE_STAMP.search(spec_path.read_text(encoding='utf-8', errors='replace'))
    except OSError:
        return False
    return bool(match) and match.group(1) in BROWSER_TEST_ROLES


def browser_hosts(config: dict) -> set[str] | None:
    """Lowercase browser_hosts of the fleet config, or None when the key is absent (no rule)."""
    hosts = config.get('browser_hosts')
    if not isinstance(hosts, list):
        return None
    return {str(h).lower() for h in hosts}


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


def host_caps_of(config: dict) -> dict[str, int]:
    raw = config.get('host_caps') or {}
    out: dict[str, int] = {}
    if isinstance(raw, dict):
        for host, cap in raw.items():
            try:
                out[str(host)] = int(cap)
            except (TypeError, ValueError):
                continue
    return out


def load_fleet_watch():
    path = Path(__file__).resolve().parent / 'fleet-watch.py'
    spec = importlib.util.spec_from_file_location('fleet_watch_for_placement', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_usage_gate():
    path = Path(__file__).resolve().parent / 'usage-gate.py'
    spec = importlib.util.spec_from_file_location('usage_gate_for_placement', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_agy_signin():
    path = Path(__file__).resolve().parent / 'agy-signin.py'
    spec = importlib.util.spec_from_file_location('agy_signin_for_placement', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def live_worker_counts(config: dict, hosts: list[str]) -> tuple[dict[str, int], set[str]] | None:
    """Occupied workers per host, counted the way fleet-watch admit counts them, and every dispatch id the inventory knows.

    None when the inventory cannot be read; the caller then counts 0 live workers (recent starts still count).
    WORKER_PLACEMENT_COUNT_WORKERS=0 skips the inventory (tests without an orca fake), the same as a failed read.
    """
    if os.environ.get('WORKER_PLACEMENT_COUNT_WORKERS') == '0':
        return None
    try:
        fw = load_fleet_watch()
        config, _adopted = fw.resolve_pass_config(dict(config), config.get('_config_path') or '')
        workers = fw.deduplicate_workers(fw.fetch_workers(config))
        env_names = fw._resolve_env_names(workers, config, None)
        released = fw.persisted_released_ids(os.environ.get('FLEET_WATCH_STATE'))
        counts: dict[str, int] = {}
        for host in hosts:
            receipt = fw.admit(host, config, workers=workers, env_names=env_names, released_ids=released)
            counts[host] = int(receipt.get('occupied') or 0)
        known = {w['dispatchId'] for w in workers if isinstance(w, dict) and isinstance(w.get('dispatchId'), str)}
        return counts, known | set(released)
    except Exception as exc:  # inventory is advisory; never block placement on it
        print('worker-placement: worker count unavailable (%s); placing on load only' % exc, file=sys.stderr)
        return None


def recent_start_seconds(config: dict) -> float:
    placement = config.get('worker_placement') or {}
    raw = placement.get('recent_start_seconds') if isinstance(placement, dict) else None
    try:
        return float(raw) if raw is not None else float(DEFAULT_RECENT_START_SECONDS)
    except (TypeError, ValueError):
        return float(DEFAULT_RECENT_START_SECONDS)


def placement_float(config: dict, key: str, default: float) -> float:
    placement = config.get('worker_placement') or {}
    raw = placement.get(key) if isinstance(placement, dict) else None
    try:
        value = float(raw) if raw is not None else default
    except (TypeError, ValueError):
        return default
    return value if value > 0 else default


def scaled_cap(cap: int, cores: int, cores_per_worker: float) -> int:
    """host_caps never goes up; a host with few cores takes fewer workers than its cap."""
    if cap <= 0:
        return cap
    return max(1, min(cap, int(cores // cores_per_worker)))


def memory_full(mem_free: float | None, recent_starts: int, gb_per_worker: float) -> bool:
    """Free memory the sensor read, less what the recent starts have yet to take, leaves no room."""
    if mem_free is None:
        return False
    return mem_free - recent_starts * gb_per_worker < gb_per_worker


def recent_file_path(config: dict) -> Path:
    env = os.environ.get('WORKER_PLACEMENT_RECENT_FILE')
    if env:
        return Path(expand(env))
    placement = config.get('worker_placement') or {}
    raw = placement.get('recent_file') if isinstance(placement, dict) else None
    if isinstance(raw, str) and raw.strip():
        return Path(expand(raw.strip()))
    return Path(expand('~/.claude/state/worker-placement-recent.json'))


def read_recent(path: Path, window: float, now: float) -> list[dict]:
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return []
    rows = data.get('starts') if isinstance(data, dict) else None
    if not isinstance(rows, list):
        return []
    keep = []
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get('host'), str):
            continue
        try:
            at = float(row.get('at'))
        except (TypeError, ValueError):
            continue
        if now - at <= window:
            claim = {'host': row['host'], 'at': at}
            for key in ('id', 'dispatch'):
                if isinstance(row.get(key), str) and row[key]:
                    claim[key] = row[key]
            keep.append(claim)
    return keep


def edit_recent(config: dict, change) -> bool:
    """Change the recent starts under their lock. change(rows) returns False to leave the file as it is."""
    path = recent_file_path(config)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        lock = open(str(path) + '.lock', 'a', encoding='utf-8')
    except OSError:
        return False
    with lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rows = read_recent(path, recent_start_seconds(config), time.time())
        if not change(rows):
            return False
        tmp = path.with_name(path.name + '.tmp')
        try:
            tmp.write_text(json.dumps({'starts': rows}), encoding='utf-8')
            os.replace(tmp, path)
        except OSError:
            return False
    return True


def unrecord_start(config: dict, host: str, claim_id: str | None = None) -> bool:
    """Drop the claim of a start that failed before launching, so it frees its seat (#1273).

    With a claim id only that claim goes; without one, the newest claim for the host.
    """
    def drop(rows: list[dict]) -> bool:
        for index in range(len(rows) - 1, -1, -1):
            row = rows[index]
            if (row.get('id') == claim_id) if claim_id else (row['host'] == host):
                del rows[index]
                return True
        return False
    return edit_recent(config, drop)


def bind_start(config: dict, claim_id: str, dispatch_id: str) -> bool:
    """Tie a recent-start claim to the dispatch it created, so the claim stops counting once the inventory lists it (#1411)."""
    def bind(rows: list[dict]) -> bool:
        for row in rows:
            if row.get('id') == claim_id:
                row['dispatch'] = dispatch_id
                return True
        return False
    return edit_recent(config, bind)


def pending_starts(rows: list[dict], known_dispatches: set[str] | None) -> dict[str, int]:
    """Recent starts per host that the inventory does not show yet. Each is one seat and one worker's memory.

    A claim stops counting once its dispatch is in the inventory: a live one is counted there, a settled one holds nothing.
    """
    out: dict[str, int] = {}
    for row in rows:
        if known_dispatches is not None and row.get('dispatch') in known_dispatches:
            continue
        out[row['host']] = out.get(row['host'], 0) + 1
    return out


def pick_host(
    config: dict,
    spec_path: Path | None,
    repo_selector: str | None = None,
    record: bool = False,
    agent: str | None = None,
) -> dict:
    """Pick a host. With record, hold a lock and remember the start for the recent window.
    With agent, a host that agent cannot start on (antigravity on a host signed out of agy) is skipped (#1966)."""
    if not record:
        return _pick_host(config, spec_path, repo_selector, [], agent)
    path = recent_file_path(config)
    window = recent_start_seconds(config)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        lock = open(str(path) + '.lock', 'a', encoding='utf-8')
    except OSError as exc:
        print('worker-placement: recent starts unavailable (%s)' % exc, file=sys.stderr)
        return _pick_host(config, spec_path, repo_selector, [], agent)
    with lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rows = read_recent(path, window, time.time())
        result = _pick_host(config, spec_path, repo_selector, rows, agent)
        if result.get('ok'):
            result['claim'] = uuid.uuid4().hex
            rows.append({'host': result['host'], 'at': time.time(), 'id': result['claim']})
            tmp = path.with_name(path.name + '.tmp')
            try:
                tmp.write_text(json.dumps({'starts': rows}), encoding='utf-8')
                os.replace(tmp, path)
            except OSError as exc:
                print('worker-placement: could not record start (%s)' % exc, file=sys.stderr)
    return result


def _pick_host(
    config: dict, spec_path: Path | None, repo_selector: str | None, recent: list[dict], agent: str | None = None,
) -> dict:
    kind = task_kind(spec_path)
    roles = host_roles(config)
    order = placement_order(config)
    if not order:
        return {'ok': False, 'reason': 'no worker_placement order or host_caps in fleet config'}
    hosts = eligible_hosts(order, config, kind, roles)
    browser = browser_hosts(config) if needs_browser_host(spec_path) else None
    if browser is not None:
        hosts = [h for h in hosts if h.lower() in browser]
        if not hosts:
            return {'ok': False, 'reason': 'no eligible fleet host is listed under browser_hosts'}
    if not hosts:
        return {'ok': False, 'reason': 'no eligible fleet hosts for this task'}
    if (agent or '').lower() in ('antigravity', 'agy'):  # only antigravity has a per host sign-in (agy-signin.py usable)
        usable = load_agy_signin().usable
        signed_in = []
        for host in hosts:
            if usable(agent, host, config):
                signed_in.append(host)
            else:
                print('worker-placement: skip %s (not signed in to agy)' % host, file=sys.stderr)
        if not signed_in:
            return {'ok': False, 'reason': 'no eligible host is signed in to agy'}
        hosts = signed_in
    if (agent or '').lower() == 'grok':
        # Only grok_hosts have the Grok CLI. With none listed, only this host can start it (require_grok_host).
        listed = load_usage_gate().grok_hosts() or {str(config.get('local_host') or '').lower()} - {''}
        if listed:
            hosts = [h for h in hosts if h.lower() in listed]
        if not hosts:
            return {'ok': False, 'reason': 'no eligible fleet host is listed under grok_hosts'}
    try:
        loads = read_loads(load_sensor_path(config), float(os.environ.get('WORKER_PLACEMENT_TIMEOUT', '120')))
    except LoadSensorError as exc:
        return {'ok': False, 'reason': str(exc), 'loads': {}}
    local_host = config.get('local_host') if isinstance(config.get('local_host'), str) else None
    caps = host_caps_of(config)
    live, known_dispatches = live_worker_counts(config, hosts) or (None, None)
    pending = pending_starts(recent, known_dispatches)
    cores_per_worker = placement_float(config, 'cores_per_worker', DEFAULT_CORES_PER_WORKER)
    mem_per_worker = placement_float(config, 'mem_gb_per_worker', DEFAULT_MEM_GB_PER_WORKER)
    try:
        gate_lock = load_fleet_watch().head_checks_gate_lock
    except Exception as exc:  # advisory like the worker count; never block placement on it
        print('worker-placement: heavy gate holds unavailable (%s); placing without them' % exc, file=sys.stderr)
        gate_lock = lambda _host: None  # noqa: E731
    considered: dict[str, float] = {}
    full: dict[str, str] = {}
    candidates: list[tuple[bool, float, float, int, str, float, float, int, int]] = []
    unmapped = 0
    for index, host in enumerate(hosts):
        if not host_has_repo_mapping(config, host, local_host, repo_selector):
            unmapped += 1
            print(
                'worker-placement: skip %s (no repo mapping for %s)'
                % (host, repo_map_key(repo_selector) or repo_selector),
                file=sys.stderr,
            )
            continue
        if caps.get(host, 0) <= 0:
            continue
        sample = loads.get(host)
        if sample is None:
            continue
        load, cores, load5, mem_free = sample
        ceiling = ceiling_for(host, config)
        if ceiling is None:
            continue
        considered[host] = load
        held = gate_lock(host)
        if held:
            # #1844: head checks on this host hold the database step on that host's heavy gate.
            print('worker-placement: skip %s (head checks hold the heavy gate: %s)' % (host, held), file=sys.stderr)
            full[host] = 'heavy-gate-held'
            continue
        cap = scaled_cap(caps[host], cores, cores_per_worker)
        workers = (0 if live is None else live.get(host, 0)) + pending.get(host, 0)
        if workers >= cap:
            full[host] = '%d/%d' % (workers, cap)
            continue
        if memory_full(mem_free, pending.get(host, 0), mem_per_worker):
            full[host] = 'memory'
            continue
        if host_over_load(host, load, cores, ceiling, local_host):
            continue
        share = workers / cap
        candidates.append((False, share, load5 / cores if cores > 0 else 0.0, index, host, load, ceiling, workers, cap))
    light = light_only_hosts(config) if heavy_start(spec_path) else set()
    held_light = sorted(c[4] for c in candidates if c[4].lower() in light)
    candidates = [c for c in candidates if c[4].lower() not in light]
    if held_light and not candidates:
        reason = 'heavy start held (light-only hosts: %s)' % ', '.join(held_light)
        print('worker-placement: ' + reason, file=sys.stderr)
        return {'ok': False, 'reason': reason}
    if candidates:
        has_remote = any(c[4] != local_host for c in candidates)
        ranked = [(c[4] == local_host and has_remote,) + c[1:] for c in candidates]
        _, _, _, _, host, load, ceiling, workers, cap = min(ranked)
        is_local = host == local_host
        result: dict = {
            'ok': True,
            'host': host,
            'load_1m': load,
            'ceiling': ceiling,
            'workers': workers,
            'cap': cap,
            'local': is_local,
            'environment': None if is_local else host,
            'task_kind': kind,
        }
        if repo_selector and not is_local:
            mapped = translate_repo(config, host, repo_selector)
            if mapped:
                result['repo'] = mapped
        return result
    remote_hosts = [h for h in hosts if h != local_host]
    every_remote_unmapped = bool(remote_hosts) and all(
        not host_has_repo_mapping(config, h, local_host, repo_selector) for h in remote_hosts
    )
    # A local host that is merely busy is not a mapping miss. When every remote host was
    # skipped for no repo mapping, say that, even if the local host also had no load.
    if every_remote_unmapped or unmapped == len(hosts):
        return {'ok': False, 'reason': 'no host has a repo mapping', 'loads': considered}
    if not considered:
        return {'ok': False, 'reason': 'no readable load for any eligible host', 'loads': {}}
    if full and len(full) == len(considered):
        if all(v == 'heavy-gate-held' for v in full.values()):
            return {'ok': False, 'reason': 'head checks hold the heavy gate on every eligible host', 'workers': full}
        return {'ok': False, 'reason': 'all eligible hosts at worker cap', 'workers': full}
    return {'ok': False, 'reason': 'all eligible hosts over load ceiling or worker cap', 'loads': considered,
            'workers': full}


def check_host(config: dict, host: str, spec_path: Path | None, repo_selector: str | None = None) -> dict:
    """Judge a host the caller already chose (--on). Same load rule as pick_host."""
    browser = browser_hosts(config) if needs_browser_host(spec_path) else None
    if browser is not None and host.lower() not in browser:
        return {'ok': False, 'host': host, 'reason': 'not listed under browser_hosts, a browser test gate cannot run there'}
    known = {h.lower(): h for h in (config.get('host_caps') or {})}
    name = known.get(host.lower())
    if name is not None and host_caps_of(config).get(name, 0) <= 0:
        return {'ok': False, 'host': name, 'reason': 'host_caps is 0, the host takes no workers'}
    ceiling = ceiling_for(name, config) if name else None
    if name is None or ceiling is None:
        return {'ok': True, 'host': host, 'reason': 'no load limit configured for this host'}
    try:
        loads = read_loads(load_sensor_path(config), float(os.environ.get('WORKER_PLACEMENT_TIMEOUT', '120')))
    except LoadSensorError as exc:
        return {'ok': True, 'host': name, 'reason': str(exc)}
    sample = loads.get(name)
    if sample is None:
        return {'ok': True, 'host': name, 'reason': 'no readable load'}
    load, cores, _, _ = sample
    local_host = config.get('local_host') if isinstance(config.get('local_host'), str) else None
    if not host_over_load(name, load, cores, ceiling, local_host):
        return {'ok': True, 'host': name, 'load_1m': load, 'ceiling': ceiling}
    alt = pick_host(config, spec_path, repo_selector)
    return {
        'ok': False,
        'host': name,
        'load_1m': load,
        'ceiling': ceiling,
        'alternative': alt.get('host') if alt.get('ok') else None,
        'alternative_load_1m': alt.get('load_1m') if alt.get('ok') else None,
    }


def reason_host(config: dict, reason: str) -> str | None:
    """Host a --force-host reason names in worker_placement.reasons, or None."""
    placement = config.get('worker_placement') or {}
    reasons = placement.get('reasons') if isinstance(placement, dict) else None
    host = reasons.get(reason) if isinstance(reasons, dict) else None
    return host if isinstance(host, str) and host.strip() else None


def format_check_line(result: dict) -> str:
    if result.get('ok'):
        return 'worker-placement: forced host=%s within limit' % result['host']
    if 'load_1m' not in result:
        return 'worker-placement: refused forced host=%s (%s)' % (result['host'], result['reason'])
    line = 'worker-placement: refused forced host=%s load_1m=%s limit=%s' % (
        result['host'], result['load_1m'], result['ceiling'])
    alt = result.get('alternative')
    if alt:
        line += '; least loaded host placement would pick: %s (load_1m=%s)' % (alt, result['alternative_load_1m'])
    else:
        line += '; no other host is under its limit'
    return line


def format_line(result: dict) -> str:
    if result.get('ok'):
        line = 'worker-placement: host=%s load_1m=%s' % (result['host'], result['load_1m'])
        line += ' workers=%s/%s' % (result['workers'], result['cap'])
        return line
    reason = result.get('reason') or 'unknown'
    if 'worker cap' in reason and not result.get('loads'):
        parts = ' '.join('%s=%s' % (h, v) for h, v in sorted((result.get('workers') or {}).items()))
        return 'worker-placement: refused (%s) %s' % (reason, parts)
    loads = result.get('loads') or {}
    if loads and 'repo mapping' not in reason:
        parts = ' '.join('%s=%s' % (h, loads[h]) for h in sorted(loads))
        return 'worker-placement: refused %s' % parts
    if loads:
        parts = ' '.join('%s=%s' % (h, loads[h]) for h in sorted(loads))
        return 'worker-placement: refused (%s) %s' % (reason, parts)
    return 'worker-placement: refused (%s)' % reason


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
    result = pick_host(cfg, spec, args.repo, record=args.record, agent=args.agent)
    if args.json:
        print(json.dumps(result, separators=(',', ':')))
    else:
        print(format_line(result))
    return 0 if result.get('ok') else 1


def cmd_unrecord(args: argparse.Namespace) -> int:
    try:
        cfg = load_config(config_path(args.config))
    except FleetConfigError:
        return 0
    unrecord_start(cfg, args.host, args.claim)
    return 0


def cmd_bind(args: argparse.Namespace) -> int:
    try:
        cfg = load_config(config_path(args.config))
    except FleetConfigError:
        return 0
    bind_start(cfg, args.claim, args.dispatch)
    return 0


def cmd_seats(args: argparse.Namespace) -> int:
    try:
        cfg = load_config(config_path(args.config))
    except FleetConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    fw = load_fleet_watch()
    report = fw.fleet_seat_report(cfg, cfg.get('_config_path'), os.environ.get('FLEET_WATCH_STATE'))
    print(json.dumps(report, indent=2) if args.json else fw.format_seat_report(report))
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    try:
        cfg = load_config(config_path(args.config))
    except FleetConfigMissing:
        print(json.dumps({'ok': True, 'skipped': True, 'host': args.host}))
        return 0
    except FleetConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    result = check_host(cfg, args.host, Path(args.spec) if args.spec else None, args.repo)
    result['line'] = format_check_line(result)
    print(json.dumps(result, separators=(',', ':')))
    return 0 if result['ok'] else 1


def cmd_reason_host(args: argparse.Namespace) -> int:
    try:
        host = reason_host(load_config(config_path(args.config)), args.reason)
    except FleetConfigError:
        host = None
    if not host:
        return 1
    print(host)
    return 0


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
    pick.add_argument('--record', action='store_true', help='Remember this start so the next pick counts it')
    pick.add_argument('--agent', default=None, help='Skip hosts this agent cannot start on (antigravity signed out)')
    pick.set_defaults(func=cmd_pick)
    unrecord = sub.add_parser('unrecord', help='Forget the newest recorded start on a host (a start that failed early)')
    unrecord.add_argument('--host', required=True)
    unrecord.add_argument('--claim', default=None, help='Claim id from pick --record; drops that claim only')
    unrecord.add_argument('--config', default=None)
    unrecord.set_defaults(func=cmd_unrecord)
    bind = sub.add_parser('bind', help='Tie a recorded start to the dispatch it created')
    bind.add_argument('--claim', required=True)
    bind.add_argument('--dispatch', required=True)
    bind.add_argument('--config', default=None)
    bind.set_defaults(func=cmd_bind)
    seats = sub.add_parser('seats', help='Live and retained seats per host, naming each retained worker')
    seats.add_argument('--config', default=None)
    seats.add_argument('--json', action='store_true')
    seats.set_defaults(func=cmd_seats)
    check = sub.add_parser('check-host', help='Judge a host chosen with --on against its load limit')
    check.add_argument('--host', required=True)
    check.add_argument('--spec', default=None)
    check.add_argument('--repo', default=None)
    check.add_argument('--config', default=None)
    check.set_defaults(func=cmd_check)
    reason = sub.add_parser('reason-host', help='Host a --force-host reason maps to')
    reason.add_argument('--reason', required=True)
    reason.add_argument('--config', default=None)
    reason.set_defaults(func=cmd_reason_host)
    translate = sub.add_parser('translate-repo', help='Map a local repo selector to a remote environment')
    translate.add_argument('--environment', required=True)
    translate.add_argument('--repo', required=True)
    translate.add_argument('--config', default=None)
    translate.set_defaults(func=cmd_translate_repo)
    args = parser.parse_args()
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())
