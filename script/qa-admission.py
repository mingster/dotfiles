#!/usr/bin/env python3
"""Read-only, expiring QA admission for an exact saved Orca workspace.

Policy version 1 binds saved environment ID/name, native repo/project/identity,
path/head and execution host. Both routed hosts require fresh load evidence.
Native terminal inventory currently lacks observed model/process evidence: any
occupied target host remains UNKNOWN, with no policy waiver or preview inference.
A successful snapshot is NOT an atomic capacity reservation. No worker is started.
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

# Current owner-authorized routing bounds. Policy may narrow, never expand them.
# Expiry belongs to the explicit operator policy, not a hardcoded calendar date.
BOUNDS = {'blueDevil': (3, 12, 'codex', 'gpt-6.1-sol'),
          'niteking': (2, 8, 'cursor', 'composer-2.5')}
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


def load_policy(args):
    policy = read_json(args.policy, 'policy')
    if type(policy.get('version')) is not int or policy['version'] != 1:
        refuse('policy: version mismatch')
    policy_window(policy)
    review = obj(policy.get('review'), 'policy review')
    for key in ('runtime_host', 'repo', 'worktree_path', 'head', 'repo_id', 'project_id',
                'worktree_identity', 'execution_host_id', 'saved_environment_id', 'saved_environment_name'):
        string(review.get(key), 'policy review ' + key)
    project = args.repo if args.repo.startswith('github:') else 'github:' + args.repo
    if (review['repo'] != project or review['project_id'] != project or
            review['head'] != args.head or review['worktree_path'] != args.worktree_path or
            not re.fullmatch(r'[0-9a-f]{40}', args.head) or not args.worktree_path.startswith('/') or
            not TOKEN.fullmatch(review['repo_id']) or
            not TOKEN.fullmatch(review['saved_environment_id']) or
            review['saved_environment_id'] == 'LOCAL' or
            not IDENTITY.fullmatch(review['worktree_identity']) or
            review['worktree_identity'].split(':')[1] != review['execution_host_id']):
        refuse('policy: repo/project/worktree binding mismatch')
    hosts = obj(policy.get('hosts'), 'policy hosts')
    if set(hosts) != set(BOUNDS):
        refuse('policy: both authorized routed hosts required')
    caps = obj(read_json(args.fleet_config, 'fleet config').get('host_caps'), 'fleet config caps')
    for host, (max_cap, max_load, provider, model) in BOUNDS.items():
        route = obj(hosts[host], 'policy host')
        cap = route.get('cap')
        if (type(cap) is not int or not 0 < cap <= max_cap or
                type(caps.get(host)) is not int or caps[host] != cap):
            refuse('policy/fleet cap disagreement for ' + host)
        ceiling = finite(route.get('load_ceiling'), 'policy load ceiling')
        if not 0 < ceiling <= max_load:
            refuse('policy load ceiling exceeds authorization')
        providers = obj(route.get('providers'), 'policy providers')
        if set(providers) != {provider}:
            refuse('policy provider outside host authorization')
        models = obj(providers[provider], 'policy provider').get('models')
        if models != [model]:
            refuse('policy provider model outside authorization')
    host = review['runtime_host']
    if host not in hosts or review['saved_environment_name'] != host:
        refuse('policy saved environment runtime mismatch')
    _, _, provider, model = BOUNDS[host]
    if (args.verifier_provider, args.verifier_model) != (provider, model):
        refuse('verifier provider/model not authorized on ' + host)
    return policy, review


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


def saved_environment(orca, review):
    rows = orca_result(orca, 'environment', 'list').get('environments')
    if not isinstance(rows, list):
        refuse('saved environment inventory missing')
    by_name, ids = {}, set()
    for row in rows:
        row = obj(row, 'saved environment')
        name = string(row.get('name'), 'saved environment name')
        eid = string(row.get('id'), 'saved environment id')
        if name in by_name or eid in ids:
            refuse('ambiguous saved environment inventory')
        by_name[name] = eid
        ids.add(eid)
    if by_name.get(review['saved_environment_name']) != review['saved_environment_id']:
        refuse('saved environment ID/name mismatch')
    return review['saved_environment_id']


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


def fleet_receipt(command, config, host, cap):
    data = run_json([command, '--config', config, '--admit', host], 'fleet receipt')
    nested = obj(data.get('receipt'), 'fleet receipt nested')
    keys = ('host', 'admitted', 'cap', 'occupied', 'live_count', 'retained_count')
    if (data.get('ok') is not True or data.get('admitted') is not True or
            data.get('host') != host or nested.get('status') != 'admitted' or
            any(nested.get(k) != data.get(k) or type(nested.get(k)) is not type(data.get(k)) for k in keys)):
        refuse('fleet receipt: inconsistent admission')
    for key in ('cap', 'occupied', 'live_count', 'retained_count'):
        if type(data.get(key)) is not int or data[key] < 0:
            refuse('fleet receipt: invalid counts')
    if data['cap'] != cap or not data['occupied'] < cap:
        refuse('fleet receipt: cap disagreement or full')
    resources = data.get('resources')
    if not isinstance(resources, list):
        refuse('fleet receipt: missing resources')
    # fleet-watch already deduplicates physical workers. Validate its emitted
    # dispatch resources without counting a duplicated dispatch twice.
    unique = {}
    for resource in resources:
        resource = obj(resource, 'fleet receipt resource')
        dispatch = string(resource.get('dispatchId'), 'fleet receipt dispatch')
        if (resource.get('host') != host or resource.get('category') not in ('live', 'retained') or
                not isinstance(resource.get('evidence'), list) or not resource['evidence']):
            refuse('fleet receipt: invalid resource evidence')
        if dispatch in unique:
            refuse('fleet receipt: duplicate resource')
        unique[dispatch] = resource
    live = sum(r['category'] == 'live' for r in unique.values())
    if (len(unique) != data['occupied'] or live != data['live_count'] or
            len(unique)-live != data['retained_count']):
        refuse('fleet receipt: resource/count disagreement')
    return unique


def terminal_resources(rows, host):
    unique = {}
    for row in rows:
        row = obj(row, 'terminal inventory')
        handle = string(row.get('handle'), 'terminal inventory handle')
        if row.get('executionHostId') != host:
            refuse('terminal inventory: UNKNOWN execution host')
        if handle in unique and unique[handle] != row:
            refuse('terminal inventory: conflicting duplicate resource')
        unique[handle] = row
    return unique


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
        if not tokens or tokens[0] not in BOUNDS:
            continue
        host = tokens[0]
        match = re.search(r'\bload=([0-9]+(?:\.[0-9]+)?)\s', line)
        if host in observations or not match:
            refuse('load observations: duplicate or unreachable host')
        observations[host] = {'load_1m': float(match[1]), 'observed_at': observed}
    return observations


def validate_loads(observations, policy):
    for host, route in policy['hosts'].items():
        obs = obj(observations.get(host), 'load observation ' + host)
        value = finite(obs.get('load_1m'), 'load ' + host)
        age = (datetime.now(timezone.utc) - utc(obs.get('observed_at'), 'load timestamp')).total_seconds()
        if not 0 <= age <= 60 or value >= route['load_ceiling']:
            refuse('load observation stale/future or at ceiling: ' + host)


def admit(args):
    policy, review = load_policy(args)
    observations = load_observations(args.fleet_load)
    validate_loads(observations, policy)
    orca = os.environ.get('ORCA_CLI_COMMAND', 'orca')
    environment = saved_environment(orca, review)
    host_id = review['execution_host_id']
    rows = inventory(orca_result(orca, 'worktree', 'list', '--environment', environment,
                                '--repo', 'id:'+review['repo_id'], '--limit', '100'), 'worktrees', host_id)
    workspace(rows, review)
    terminals = inventory(orca_result(orca, 'terminal', 'list', '--environment', environment), 'terminals', host_id)
    terminal_seats = terminal_resources(terminals, host_id)
    fleet_watch = os.environ.get('ON_WORKER_DONE_FLEET_WATCH', os.path.join(os.path.dirname(__file__), 'fleet-watch.py'))
    host = review['runtime_host']
    fleet_seats = fleet_receipt(fleet_watch, args.fleet_config, host, policy['hosts'][host]['cap'])
    # Neither native terminals nor fleet resources currently expose observed
    # model + process evidence or a supported cross-inventory seat join. Do not
    # infer it from agentIdentity, orphaned, preview, requested flags or policy.
    if terminal_seats or fleet_seats:
        refuse('UNKNOWN occupied-seat model/process or inventory correlation; launch refused')
    validate_loads(observations, policy)
    policy_window(policy)
    return {'environment_id': environment, 'worktree_selector': 'identity:'+review['worktree_identity'], 'host': host}


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
