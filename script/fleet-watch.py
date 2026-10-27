#!/usr/bin/env python3
"""One bounded watchdog pass; schedule every minute outside the coordinator.
Config: --config FILE containing runs [{id, terminal, waiter_pattern}], optional
host_caps {host: count}; --state FILE persists missing-waiter timers and alerts.
Counts every active Dispatch, including descendants. No lifecycle mutations.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import time


def rpc(*args):
    command = shlex.split(os.environ.get('ORCA_CLI_COMMAND', 'orca'))
    output = subprocess.run(command + list(args) + ['--json'], capture_output=True, text=True, timeout=15, check=True)
    receipt = json.loads(output.stdout)
    if receipt.get('ok') is False:
        raise RuntimeError('Orca refused inventory')
    return receipt['result']


def alerts(config, state, now, messages, workers, waiter_alive):
    notices = []
    counts = {}
    for worker in workers:
        status = worker.get('dispatchStatus')
        dispatch = worker['dispatchId']
        retried = any(w.get('taskId') == worker.get('taskId') and w.get('dispatchStatus') != 'failed' for w in workers) if worker.get('taskId') else False
        if status == 'failed' and not retried and dispatch not in state.setdefault('failed', []):
            notices.append('failed dispatch ' + dispatch + '; inspect worker-show and provider capacity')
            state['failed'].append(dispatch)
        if status not in ('completed', 'failed', 'cancelled', 'released'):
            host = ((worker.get('projection') or {}).get('host') or {}).get('id', 'local')
            counts[host] = counts.get(host, 0) + 1
    for host, cap in config.get('host_caps', {}).items():
        if counts.get(host, 0) > cap:
            notices.append('host cap exceeded: %s %d/%d (includes child dispatches)' % (host, counts[host], cap))
    for run in config['runs']:
        key = run['id']
        pending = any(m.get('run_id') == key and not m.get('read') for m in messages)
        if waiter_alive[key] or not pending:
            state.pop(key, None)
            continue
        timer = state.setdefault(key, {'since': now, 'alerted': False})
        if now - timer['since'] >= 600 and not timer['alerted']:
            notices.append('inbox waiter absent for 10 minutes with unacked deliveries: ' + key)
            timer['alerted'] = True
    return notices


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--state', type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    state = json.loads(args.state.read_text()) if args.state.exists() else {}
    inbox = rpc('orchestration', 'inbox', '--limit', '5000')
    workers = []
    for run in config['runs']:
        cursor = None
        while True:
            flags = ['--cursor', cursor] if cursor else []
            result = rpc('orchestration', 'worker-list', '--run', run['id'], '--include-remote', *flags)
            workers.extend(result['workers'])
            page = result.get('page') or {}
            if not page.get('hasMore'):
                break
            cursor = page['nextCursor']
    workers = list({worker['dispatchId']: worker for worker in workers}.values())
    # pgrep observes the dedicated waiter process; no process is stopped here.
    alive = {run['id']: subprocess.run(['pgrep', '-f', run['waiter_pattern']], capture_output=True, timeout=5).returncode == 0 for run in config['runs']}
    notices = alerts(config, state, time.time(), inbox['messages'], workers, alive)
    if notices:
        line = 'fleet-watch: ' + '; '.join(notices)
        for run in config['runs']:
            rpc('terminal', 'send', '--terminal', run['terminal'], '--text', line, '--enter')
        print(line)
    # Persist only after successful wake delivery, so failures retry next pass.
    args.state.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.state.with_suffix('.tmp')
    temporary.write_text(json.dumps(state))
    temporary.replace(args.state)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
