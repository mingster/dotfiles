#!/usr/bin/env python3
"""Read-only QA admission from complete native worker/workspace inventories.

Configured caps and fresh host loads bound admission. Optional expiring policy
can narrow that configuration. A snapshot is not an atomic reservation.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

TOKEN = re.compile(r'[A-Za-z0-9_-]+')
IDENTITY = re.compile(r'wt2:[A-Za-z0-9_-]+:[A-Za-z0-9_-]+')


def refuse(message):
    raise SystemExit(message)


def obj(value, label):
    if not isinstance(value, dict):
        refuse(label + ': expected JSON object')
    return value


def string(value, label):
    if not isinstance(value, str) or not value or value.strip() != value:
        refuse(label + ': expected nonempty string')
    return value


def utc(value, label):
    if not isinstance(value, str):
        refuse(label + ': explicit UTC timestamp required')
    try:
        stamp = datetime.fromisoformat(value.replace('Z', '+00:00'))
        if stamp.tzinfo is None or stamp.utcoffset().total_seconds() != 0:
            raise ValueError('not UTC')
        return stamp.astimezone(timezone.utc)
    except ValueError:
        refuse(label + ': explicit UTC timestamp required')


def read_json(path, label):
    try:
        with open(path) as stream:
            return obj(json.load(stream), label)
    except (OSError, ValueError):
        refuse(label + ': missing or invalid JSON')


def finite(value, label):
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
        refuse(label + ': finite nonnegative number required')
    return value


def policy_window(policy):
    issued = utc(policy.get('issued_at'), 'policy issued_at')
    expires = utc(policy.get('expires_at'), 'policy expires_at')
    now = datetime.now(timezone.utc)
    if not issued <= now < expires:
        refuse('policy: interval not currently authorized')


def load_policy(args, config):
    """An explicit policy may narrow configuration; ordinary calls need none."""
    if not args.policy:
        return None
    policy = read_json(args.policy, 'policy')
    if policy.get('version') != 1:
        refuse('policy: version mismatch')
    policy_window(policy)
    for host, route in obj(policy.get('hosts'), 'policy hosts').items():
        route = obj(route, 'policy host')
        if host not in config['host_caps']:
            refuse('policy: unknown configured host')
        cap = route.get('cap', config['host_caps'][host])
        if type(cap) is not int or not 0 < cap <= config['host_caps'][host]:
            refuse('policy: cap exceeds configuration')
        maximum = config.get('host_load_ceilings', {}).get(host)
        if 'load_ceiling' in route:
            value = finite(route['load_ceiling'], 'policy load ceiling')
            if value <= 0 or (maximum is not None and value > maximum):
                refuse('policy load ceiling exceeds configuration')
    return policy


def run_json(command, label):
    proc = subprocess.run(command, text=True, capture_output=True, timeout=30)
    if proc.returncode:
        refuse(label + ': command exit ' + str(proc.returncode))
    try:
        return obj(json.loads(proc.stdout), label)
    except ValueError:
        refuse(label + ': invalid JSON')


def orca_result(orca, *args):
    label = 'Orca ' + args[0] + ' inventory'
    payload = run_json([orca, *args, '--json'], label)
    if payload.get('ok') is not True:
        refuse(label + ': ok is not true')
    return obj(payload.get('result'), label)


def environments(orca):
    rows = orca_result(orca, 'environment', 'list').get('environments')
    if not isinstance(rows, list):
        refuse('saved environment inventory missing')
    by_name, ids = {}, set()
    for row in rows:
        row = obj(row, 'saved environment')
        name = string(row.get('name'), 'saved environment name')
        eid = string(row.get('id'), 'saved environment id')
        if not TOKEN.fullmatch(eid) or eid.lower() == 'local' or name in by_name or eid in ids:
            refuse('ambiguous saved environment inventory')
        by_name[name] = eid
        ids.add(eid)
    return by_name


def inventory(result, key, host):
    label = key + ' inventory'
    scope = obj(result.get('hostScope'), label + ' hostScope')
    # Multiple execution hosts cannot be mapped to this saved physical host.
    if (result.get('truncated') is not False or scope.get('hostIds') != [host] or
            scope.get('omittedHostIds') != [] or not isinstance(result.get(key), list)):
        refuse(label + ': incomplete or UNKNOWN host coverage')
    return result[key]


def workspace(rows, review):
    matches = [row for row in rows if obj(row, 'worktree inventory').get('path') == review['worktree_path']]
    if len(matches) != 1:
        refuse('worktree inventory: authorized path not unique')
    row = matches[0]
    identity = obj(row.get('identity'), 'worktree identity')
    git = obj(row.get('git'), 'worktree git')
    expected = {'repoId': review['repo_id'], 'projectId': review['project_id'],
                'hostId': review['execution_host_id'], 'path': review['worktree_path'],
                'head': review['head'], 'id': review['repo_id']+'::'+review['worktree_path']}
    if (any(row.get(k) != v for k, v in expected.items()) or
            identity.get('key') != review['worktree_identity'] or
            identity.get('executionHostId') != review['execution_host_id'] or
            identity.get('instanceId') != review['worktree_identity'].split(':')[-1] or
            git.get('head') != review['head'] or git.get('path') != review['worktree_path'] or
            git.get('isBare') is not False):
        refuse('worktree inventory: authorized native identity/project/path/head mismatch')


def worker_counts(orca, flags, host_id):
    """Count native Dispatch resources, never generic terminals or inferred models."""
    seen, seats, cursor = set(), {}, None
    live = retained = 0
    cursors = set()
    while True:
        paging = ['--cursor', cursor] if cursor else []
        result = orca_result(orca, 'orchestration', 'worker-list', *flags,
                             '--include-remote', *paging)
        rows = result.get('workers')
        page = obj(result.get('page'), 'worker page')
        if (not isinstance(rows, list) or type(page.get('hasMore')) is not bool or
                obj(result.get('scope'), 'worker scope').get('source') != 'all'):
            refuse('worker inventory: incomplete or UNKNOWN coverage')
        for row in rows:
            row = obj(row, 'worker inventory row')
            dispatch = string(row.get('dispatchId'), 'worker dispatch')
            if dispatch in seen:
                refuse('worker inventory: duplicate dispatch')
            seen.add(dispatch)
            host = string(obj(obj(row.get('projection'), 'worker projection host').get('host'),
                              'worker host').get('id'), 'worker host id')
            if host != host_id:
                continue
            status = row.get('dispatchStatus')
            resource = obj(row.get('resource'), 'worker resource')
            release = resource.get('releaseState')
            if status == 'release_unknown' or release == 'release_unknown' or row.get('terminalState') == 'release_unknown':
                refuse('worker inventory: release_unknown')
            if status not in ('running', 'dispatched', 'pending', 'active', 'completed', 'failed', 'cancelled', 'released'):
                refuse('worker inventory: unknown worker status')
            if release not in ('not_requested', 'requested', 'releasing', 'failed', 'released', 'completed'):
                refuse('worker inventory: unknown release state')
            if release in ('released', 'completed'):
                if status in ('running', 'dispatched', 'pending', 'active'):
                    refuse('worker inventory: live/released disagreement')
                continue
            # A native terminal handle identifies a retained physical resource.
            # Workers without terminals still occupy their own Dispatch seat.
            seat = resource.get('terminalHandle') or dispatch
            string(seat, 'worker resource identity')
            category = 'live' if status in ('running', 'dispatched', 'pending', 'active') else 'retained'
            if seat in seats:
                if seats[seat] != category:
                    refuse('worker inventory: conflicting resource observations')
                continue
            seats[seat] = category
            live += category == 'live'
            retained += category == 'retained'
        if not page['hasMore']:
            break
        cursor = string(page.get('nextCursor'), 'worker page cursor')
        if cursor in cursors:
            refuse('worker inventory: repeated page cursor')
        cursors.add(cursor)
    return {'occupied': live + retained, 'live_count': live, 'retained_count': retained}


def load_observations(path):
    raw = os.environ.get('QA_ADMISSION_LOAD_OBS')
    if raw is not None:
        try:
            return obj(json.loads(raw), 'load observations')
        except ValueError:
            refuse('load observations: invalid JSON')
    if path.endswith('.json'):
        return read_json(path, 'load observations')
    # fleet-load.sh emits host names and live load= values. Timestamp the start,
    # so a slow sensor cannot manufacture a fresh observation on completion.
    observed = datetime.now(timezone.utc).isoformat()
    proc = subprocess.run(['bash', path], text=True, capture_output=True, timeout=30)
    if proc.returncode:
        refuse('load observations: fleet sensor failed')
    observations = {}
    for line in proc.stdout.splitlines():
        tokens = line.split()
        if not tokens:
            continue
        host = tokens[0]
        match = re.search(r'\bload=([0-9]+(?:\.[0-9]+)?)\s', line)
        if host in observations or not match:
            refuse('load observations: duplicate or unreachable host')
        cores = re.search(r'\bcores=([0-9]+)\b', line)
        observations[host] = {'load_1m': float(match[1]), 'observed_at': observed,
                              'cores': int(cores[1]) if cores else None}
    return observations


def validate_loads(observations, config, policy):
    for host in config['host_caps']:
        obs = obj(observations.get(host), 'load observation ' + host)
        value = finite(obs.get('load_1m'), 'load ' + host)
        age = (datetime.now(timezone.utc) - utc(obs.get('observed_at'), 'load timestamp')).total_seconds()
        maximum = config.get('host_load_ceilings', {}).get(host, obs.get('cores'))
        ceiling = finite(maximum, 'load ceiling ' + host)
        if policy and host in policy['hosts']:
            ceiling = min(ceiling, policy['hosts'][host].get('load_ceiling', ceiling))
        if ceiling <= 0 or not 0 <= age <= 60 or value >= ceiling:
            refuse('load observation stale/future or at ceiling: ' + host)


def discover_workspace(orca, flags, args):
    project = args.repo if args.repo.startswith('github:') else 'github:' + args.repo
    repos = orca_result(orca, 'repo', 'list', *flags).get('repos')
    if not isinstance(repos, list):
        refuse('repo inventory missing')
    matches = [r for r in repos if obj(r, 'repo inventory').get('gitRemoteIdentity', {}).get('canonicalKey') ==
               'github.com/' + project.removeprefix('github:')]
    if len(matches) != 1:
        return None
    repo_id = string(matches[0].get('id'), 'repo id')
    if not TOKEN.fullmatch(repo_id):
        refuse('repo inventory: invalid id')
    result = orca_result(orca, 'worktree', 'list', *flags, '--repo', 'id:'+repo_id, '--limit', '100')
    scope = obj(result.get('hostScope'), 'worktree inventory host scope')
    hosts = scope.get('hostIds')
    if not isinstance(hosts, list) or not hosts or len(hosts) != len(set(hosts)):
        refuse('worktree inventory: unknown hosts')
    if result.get('truncated') is not False or scope.get('omittedHostIds') != [] or not isinstance(result.get('worktrees'), list):
        refuse('worktree inventory: incomplete coverage')
    rows = result['worktrees']
    matches = [r for r in rows if obj(r, 'worktree inventory row').get('path') == args.worktree_path]
    if not matches:
        return None
    if len(matches) != 1:
        refuse('worktree inventory: ambiguous requested path')
    row = matches[0]
    host = row.get('hostId')
    # --on chooses a saved server, not its SSH execution targets.
    if host != 'local' or host not in hosts:
        refuse('worktree inventory: unsupported execution host')
    key = obj(row.get('identity'), 'worktree identity').get('key')
    if not isinstance(key, str) or not IDENTITY.fullmatch(key):
        refuse('worktree inventory: malformed identity')
    review = {'repo_id': repo_id, 'project_id': project, 'execution_host_id': host,
              'worktree_path': args.worktree_path, 'head': args.head, 'worktree_identity': key}
    workspace(rows, review)
    return review


def admit(args):
    if not re.fullmatch(r'[0-9a-f]{40}', args.head) or not args.worktree_path.startswith('/'):
        refuse('worktree: exact absolute path and head required')
    config = read_json(args.fleet_config, 'fleet config')
    caps = obj(config.get('host_caps'), 'fleet config caps')
    if not caps:
        refuse('fleet config: missing host caps')
    for host, cap in caps.items():
        string(host, 'configured host')
        if type(cap) is not int or cap <= 0:
            refuse('fleet config: invalid cap for ' + host)
    policy = load_policy(args, config)
    observations = load_observations(args.fleet_load)
    validate_loads(observations, config, policy)
    orca = os.environ.get('ORCA_CLI_COMMAND', 'orca')
    saved = environments(orca)
    # Physical hostname comes from this OS; an explicit configuration may name
    # the local sensor alias. No saved server or SSH host is guessed.
    local_host = config.get('local_host', os.uname().nodename.split('.')[0])
    candidates, reasons, receipts = [], [], []
    for host, cap in caps.items():
        if policy and host not in policy['hosts']:
            continue
        route = policy['hosts'][host] if policy else {}
        providers = route.get('providers')
        if providers is not None and args.verifier_model not in obj(obj(providers, 'policy providers').get(args.verifier_provider, {}), 'policy provider').get('models', []):
            reasons.append(host+': policy excludes requested provider/model')
            continue
        eid = saved.get(host)
        if eid is None and host != local_host:
            reasons.append(host+': no native saved environment or local binding')
            continue
        flags = ['--environment', eid] if eid else []
        review = discover_workspace(orca, flags, args)
        if review is None:
            reasons.append(host+': exact repo/worktree unavailable')
            continue
        if policy and policy.get('review'):
            expected = {**review, 'repo': review['project_id'], 'runtime_host': host,
                        'saved_environment_id': eid or 'local', 'saved_environment_name': host}
            if any(expected.get(k) != v for k, v in obj(policy['review'], 'policy review').items()):
                reasons.append(host+': policy worktree binding mismatch')
                continue
        counts = worker_counts(orca, flags, review['execution_host_id'])
        cap = min(cap, route.get('cap', cap))
        receipt = {'host': host, 'cap': cap, **counts}
        receipts.append(receipt)
        if counts['occupied'] < cap:
            candidates.append({'environment_id': eid or 'local',
                               'worktree_selector': 'identity:'+review['worktree_identity'],
                               'host': host})
    validate_loads(observations, config, policy)
    if policy:
        policy_window(policy)
    if candidates:
        return {**candidates[0], 'receipts': receipts}
    counts = ', '.join(f"{r['host']} {r['occupied']}/{r['cap']} (live={r['live_count']}, retained={r['retained_count']})" for r in receipts)
    refuse('no eligible host under cap: ' + counts + ('; '+ '; '.join(reasons) if reasons else ''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--policy', default=os.environ.get('ON_WORKER_DONE_ADMISSION_POLICY', ''))
    parser.add_argument('--fleet-config', default=os.environ.get('ON_WORKER_DONE_FLEET_CONFIG', ''))
    parser.add_argument('--fleet-load', default=os.environ.get('QA_ADMISSION_FLEET_LOAD', os.path.expanduser('~/.claude/state/fleet-load.sh')))
    for flag in ('repo', 'head', 'worktree-path', 'verifier-provider', 'verifier-model'):
        parser.add_argument('--'+flag, required=True)
    try:
        print(json.dumps(admit(parser.parse_args())))
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        refuse('admission boundary failed: ' + str(exc))


if __name__ == '__main__':
    main()
