#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# heavy-gate median wait and wrap-up round freshness; no live Orca.
set -euo pipefail
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# The heavy-gate lock lives under $HOME/.cache/heavy-gate. A temp HOME keeps this test off the host's real lock (#1414).
export ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}"
HOME=$(mktemp -d)
export HOME
trap 'rm -rf "$HOME"' EXIT
path_no_asdf=$(printf '%s\n' "${PATH//:/$'\n'}" | grep -v '/\.asdf/shims$' | paste -sd: -)
PYTHON=$(PATH="$path_no_asdf" type -P python3 2>/dev/null || true)
[ -x "$PYTHON" ] || PYTHON="$(ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}" asdf which python3 2>/dev/null || true)"
[ -x "$PYTHON" ] || { echo "missing python3" >&2; exit 1; }
"$PYTHON" - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import importlib.util
import json
import os
import pathlib
import statistics
import subprocess
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

    def test_non_utf8_wait_log_still_yields_median(self):
        wait_log = self.home / 'wait.log'
        wait_log.parent.mkdir(parents=True, exist_ok=True)
        wait_log.write_bytes(b'\xff')
        write_wait_log(wait_log, 'host-a', ['30', '130', '140', '150', '160'])
        waits = watch.read_heavy_gate_waits(wait_log, T0 + 5000)
        self.assertEqual(len(waits), 5)
        self.assertGreater(statistics.median(waits), 120)

    def test_non_utf8_wrap_up_log_still_completes_pass_and_saves_state(self):
        wrap_log = self.home / 'wrap-up-scheduled.log'
        wrap_log.parent.mkdir(parents=True, exist_ok=True)
        old = time.strftime('%Y-%m-%dT%H:%M:%S%z', time.localtime(T0))
        line = '%s wrap-up-scheduled [1] round ok: repos=1 seconds=3\n' % old
        wrap_log.write_bytes(b'\xff\n' + line.encode('utf-8'))
        state = self.home / 'state.json'
        cfg = {
            'runs': [{'id': 'r', 'terminal': 't', 'waiter_pattern': 'w'}],
            'wrap_up': {
                'hosts': {'host-b': str(wrap_log)},
                'issue_repo': 'owner/repo',
            },
        }
        self.run_pass(cfg, state)
        self.assertTrue(state.is_file())
        saved = json.loads(state.read_text())
        self.assertIsInstance(saved, dict)
        age = watch.wrap_up_last_line_age_seconds(wrap_log, T0 + 5000)
        self.assertIsNotNone(age)

    def test_stuck_slot_opens_issue_after_ten_minutes(self):
        cache = self.home / 'cache'
        slot = cache / 'slot-1'
        slot.mkdir(parents=True)
        holder = subprocess.Popen(['sleep', '120'], start_new_session=True)
        self.addCleanup(lambda: (holder.kill(), holder.wait()))
        dead = subprocess.Popen(['true'])
        dead.wait()
        slot.joinpath('pid').write_text(str(dead.pid))
        slot.joinpath('groups').write_text(json.dumps([holder.pid]))
        slot.joinpath('groups-ready').touch()
        slot.joinpath('running').touch()
        state = self.home / 'state.json'
        cfg = {
            'runs': [{'id': 'r', 'terminal': 't', 'waiter_pattern': 'w'}],
            'heavy_gate': {
                'slot_roots': {'host-a': str(cache)},
                'issue_repo': 'owner/repo',
                'stuck_limit_seconds': 600,
            },
        }
        self.run_pass(cfg, state, now=T0)
        creates = [c for c in self.gh_calls if len(c) >= 3 and c[:3] == ['gh', 'issue', 'create']]
        self.assertEqual(creates, [])
        self.gh_calls.clear()
        self.run_pass(cfg, state, now=T0 + 601)
        creates = [c for c in self.gh_calls if len(c) >= 3 and c[:3] == ['gh', 'issue', 'create']]
        self.assertEqual(len(creates), 1)
        title = creates[0][creates[0].index('--title') + 1]
        self.assertEqual(title, 'heavy-gate slot slot-1 stuck on host-a')
        self.gh_calls.clear()
        self.run_pass(cfg, state, issue_exists=True, now=T0 + 900)
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


class HeadChecksGatePlacement(unittest.TestCase):
    """#1844: while head checks hold the database step on a host, no new worker goes there."""
    REPO = 'owner/app'
    CONFIG = {
        'issue_scan': {
            'enabled': True, 'repos': [REPO], 'run': 'run_x', 'from_terminal': 'term_coord',
            'host': 'local', 'agent': 'cursor', 'model': 'm1', 'repo_roots': {REPO: '/tmp/app'},
        },
        'host_caps': {'local': 0, 'db_host': 4, 'hostB': 4},
    }
    ISSUE = {
        'number': 7, 'title': 't', 'labels': [{'name': 'ready-for-agent'}], 'comments': [],
        'body': '## Acceptance\n- [ ] it works\n\n## Out of scope\nnothing else\n',
        'createdAt': '2026-01-01T00:00:00Z',
    }

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = pathlib.Path(self.tmp.name)
        env = patch.dict(os.environ, {'HOME': str(self.home), 'FLEET_WATCH_TEST_LOAD_PER_CORE': '0.1',
                                      'FLEET_WATCH_TEST_FREE_GB': '50'})
        env.start()
        self.addCleanup(env.stop)
        gh = patch.object(watch, 'run_gh', return_value=0)
        gh.start()
        self.addCleanup(gh.stop)

    def hold(self, host, pid):
        # The lock head-checks.sh takes for the database step: _db-<host>_<remote dir>.lock with the holder pid.
        lock = self.home / 'orca/workspaces/app' / ('_db-%s__home_u_lead_train.lock' % host)
        lock.mkdir(parents=True)
        (lock / 'pid').write_text(str(pid))
        return lock

    def scan(self, config=None):
        starts = []
        _, log = watch.issue_scan_pass(
            config or self.CONFIG, {'issue_scan_backlog_sweep_at': T0}, T0, [],
            list_issues=lambda _r: [self.ISSUE], pr_fetch=lambda _r: [],
            gate_check=lambda _c: True, admit_fn=lambda host, cfg, workers: watch.admit(host, cfg, workers=workers),
            start_worker=lambda cmd: starts.append(cmd) or 0,
            repo_id_lookup=lambda host, repo: 'id-' + host,
        )
        return starts, ','.join(log)

    def test_held_host_refuses_and_the_start_moves_to_another_host(self):
        lock = self.hold('db_host', os.getpid())
        receipt = watch.admit('db_host', self.CONFIG, workers=[])
        self.assertFalse(receipt['admitted'])
        self.assertEqual(receipt['reason'], 'head checks hold the heavy gate on db_host (%s)' % lock)
        self.assertTrue(watch.admit('hostB', self.CONFIG, workers=[])['admitted'])
        starts, log = self.scan()
        self.assertEqual(len(starts), 1)
        self.assertEqual(starts[0][starts[0].index('--on') + 1], 'hostB')
        self.assertIn('issue_scan_refused_db_host=head checks hold the heavy gate on db_host', log)

    def test_held_host_with_no_other_host_holds_the_start(self):
        self.hold('db_host', os.getpid())
        config = dict(self.CONFIG, host_caps={'local': 0, 'db_host': 4})
        starts, log = self.scan(config)
        self.assertEqual(starts, [])
        self.assertIn('issue_scan_refused_db_host=head checks hold the heavy gate on db_host', log)

    def test_lock_of_a_finished_run_does_not_hold_the_host(self):
        done = subprocess.Popen(['true'])
        done.wait()
        self.hold('db_host', done.pid)
        self.assertTrue(watch.admit('db_host', self.CONFIG, workers=[])['admitted'])
        starts, _ = self.scan()
        self.assertEqual(starts[0][starts[0].index('--on') + 1], 'db_host')

    def test_lock_for_another_host_does_not_hold_this_one(self):
        # head-checks.sh keys db-host-2 as db_host_2, which shares the db_host_ prefix.
        self.hold('db_host_2', os.getpid())
        self.assertTrue(watch.admit('db_host', self.CONFIG, workers=[])['admitted'])


if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
