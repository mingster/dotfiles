#!/usr/bin/env bash
# heavy-gate median wait and wrap-up round freshness; no live Orca.
set -euo pipefail
PYTHON=python3
if [[ -x /usr/bin/python3 ]]; then PYTHON=/usr/bin/python3; fi
"$PYTHON" - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('fleet_watch', root / 'fleet-watch.py')
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)

_spec_env = importlib.util.spec_from_file_location('fleet_watch_test_env', root / 'tests' / 'fleet_watch_test_env.py')
_fwe = importlib.util.module_from_spec(_spec_env)
_spec_env.loader.exec_module(_fwe)
isolated_main_env = _fwe.isolated_main_env

T0 = 1_700_000_000


def rpc_stub(*_args, **_kwargs):
    if _args[1] == 'inbox':
        return {'messages': []}
    if _args[1] == 'worker-list':
        return {'workers': [], 'page': {'hasMore': False}}
    if _args[:2] == ('terminal', 'list'):
        return {'terminals': []}
    return {}


def write_wait_log(path, host, seconds_list, stamp=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    if stamp is None:
        stamp = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(T0))
    lines = ['%s host=%s wait_s=%s' % (stamp, host, s) for s in seconds_list]
    path.write_text('\n'.join(lines) + '\n')


class HeavyGateWatch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = pathlib.Path(self.tmp.name)
        self.log_path = self.home / 'fleet-watch-test.log'
        self.gh_calls = []

    def fake_gh(self, command):
        self.gh_calls.append(list(command))
        if command[:3] == ['gh', 'issue', 'list']:
            return 0
        return 0

    def run_pass(self, config_body, state_path, issue_exists=False, now=None):
        config = self.home / 'config.json'
        config.write_text(json.dumps(config_body))
        exists = issue_exists
        if now is None:
            now = T0 + 5000

        def open_exists(repo, title):
            return exists

        with isolated_main_env(str(self.home)), \
                patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state_path)]), \
                patch.object(watch, 'rpc', side_effect=rpc_stub), \
                patch.object(watch, 'run_gh', side_effect=self.fake_gh), \
                patch.object(watch, 'open_fixed_title_issue_exists', side_effect=open_exists), \
                patch.object(watch, 'pr_notices', return_value=[]), \
                patch.object(watch, 'usage_notices', return_value=[]), \
                patch.object(watch, 'deliver_notices', return_value=None), \
                patch.object(watch.time, 'time', return_value=now):
            watch.main()

    def test_median_over_two_minutes_opens_one_issue_then_dedupes(self):
        wait_log = self.home / 'wait.log'
        write_wait_log(wait_log, 'host-a', ['30', '130', '140', '150', '160'])
        state = self.home / 'state.json'
        cfg = {
            'runs': [{'id': 'r', 'terminal': 't', 'waiter_pattern': 'w'}],
            'heavy_gate': {
                'hosts': {'host-a': str(wait_log)},
                'issue_repo': 'owner/repo',
            },
        }
        self.run_pass(cfg, state)
        creates = [c for c in self.gh_calls if len(c) >= 3 and c[:3] == ['gh', 'issue', 'create']]
        self.assertEqual(len(creates), 1)
        title = creates[0][creates[0].index('--title') + 1]
        self.assertEqual(title, 'heavy-gate median wait exceeds 2 minutes on host-a')
        self.gh_calls.clear()
        self.run_pass(cfg, state, issue_exists=True)
        creates = [c for c in self.gh_calls if len(c) >= 3 and c[:3] == ['gh', 'issue', 'create']]
        self.assertEqual(creates, [])

    def test_recent_fast_waits_ignore_older_slow_rows_for_median(self):
        wait_log = self.home / 'wait.log'
        now = T0 + 200_000
        old_stamp = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(T0))
        write_wait_log(wait_log, 'host-a', ['180'] * 20, stamp=old_stamp)
        recent_stamp = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now - 100))
        with open(wait_log, 'a') as stream:
            for _ in range(10):
                stream.write('%s host=host-a wait_s=1\n' % recent_stamp)
        state = self.home / 'state.json'
        cfg = {
            'runs': [{'id': 'r', 'terminal': 't', 'waiter_pattern': 'w'}],
            'heavy_gate': {
                'hosts': {'host-a': str(wait_log)},
                'issue_repo': 'owner/repo',
            },
        }
        self.run_pass(cfg, state, now=now)
        creates = [c for c in self.gh_calls if len(c) >= 3 and c[:3] == ['gh', 'issue', 'create']]
        self.assertEqual(creates, [])

    def test_stale_wrap_up_round_opens_one_issue(self):
        wrap_log = self.home / 'wrap-up-scheduled.log'
        wrap_log.parent.mkdir(parents=True, exist_ok=True)
        old = time.strftime('%Y-%m-%dT%H:%M:%S%z', time.localtime(T0))
        wrap_log.write_text('%s wrap-up-scheduled [1] round ok: repos=1 seconds=3\n' % old)
        state = self.home / 'state.json'
        cfg = {
            'runs': [{'id': 'r', 'terminal': 't', 'waiter_pattern': 'w'}],
            'wrap_up': {
                'hosts': {'host-b': str(wrap_log)},
                'issue_repo': 'owner/repo',
            },
        }
        self.run_pass(cfg, state)
        creates = [c for c in self.gh_calls if len(c) >= 3 and c[:3] == ['gh', 'issue', 'create']]
        self.assertEqual(len(creates), 1)
        title = creates[0][creates[0].index('--title') + 1]
        self.assertEqual(title, 'wrap-up last round stale on host-b')


if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
