"""#1820: per phase durations in the pass log line, a killed pass naming its phase, and two slow check throttles."""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
import asdf_pin  # noqa: E402

asdf_pin.pin()  # before any test sets HOME

SCRIPT = Path(__file__).parent.parent / 'fleet-watch.py'
spec = importlib.util.spec_from_file_location('fleet_watch', SCRIPT)
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

APP = 'owner/app'


class PassPhases(unittest.TestCase):
    def setUp(self):
        fw.begin_pass_counts()

    def test_phases_line_lists_each_phase_in_order(self):
        fw._PASS.phase('inventory', now=100.0)
        fw._PASS.phase('babysit', now=101.5)
        fw._PASS.phase(None, now=131.5)
        self.assertEqual(fw.pass_phases_line(), 'phases inventory=1.5,babysit=30.0')

    def test_running_phase_is_listed_last(self):
        fw._PASS.phase('inventory', now=100.0)
        fw._PASS.phase('issue_scan', now=102.0)
        self.assertEqual(fw._PASS.phases_line(now=250.0), 'phases inventory=2.0,issue_scan=148.0')

    def test_no_phase_gives_empty_line(self):
        self.assertEqual(fw.pass_phases_line(), '')

    def test_new_pass_drops_old_phases(self):
        fw._PASS.phase('inventory', now=1.0)
        fw.begin_pass_counts()
        self.assertEqual(fw.pass_phases_line(), '')

    def test_start_durations_follow_the_phases(self):
        fw._PASS.phase('babysit', now=100.0)
        fw._PASS.starts += [41.25, 38.0]
        self.assertEqual(fw._PASS.phases_line(now=180.0), 'phases babysit=80.0 starts=41.2,38.0')

    def test_the_pass_line_ends_with_the_phases(self):
        fw._PASS.phase('inventory', now=100.0)
        fw._PASS.phase(None, now=103.0)
        logged = []
        message = '; '.join(['pass ok 3.0s', fw.pass_counts_line(), fw.pass_phases_line()])
        with patch.object(fw, 'log_fleet_watch', logged.append), patch.object(fw, 'write_automation_summary'):
            fw.finish_pass(message)
        self.assertTrue(logged[0].endswith('phases inventory=3.0'), logged[0])
        self.assertEqual(logged[0].count('started='), 1)

    def test_a_start_inside_the_wrapper_keeps_its_duration(self):
        start = fw.with_coordinator_handle({}, lambda command: 0)
        self.assertEqual(start(['worker-startup.sh']), 0)
        self.assertEqual(len(fw._PASS.starts), 1)

    def test_killed_pass_logs_the_phase_it_was_in(self):
        fw._PASS.phase('inventory', now=100.0)
        fw._PASS.phase('babysit', now=110.0)
        logged = []
        with patch.object(fw, 'log_fleet_watch', logged.append), patch.object(fw.time, 'time', return_value=380.0):
            fw.log_killed_pass(100.0)
        self.assertEqual(logged, ['pass killed 280.0s; phases inventory=10.0,babysit=270.0'])


class Sigterm(unittest.TestCase):
    def test_a_pass_stopped_by_sigterm_logs_its_phase_and_exits_143(self):
        child = (
            "import importlib.util, os, signal, sys, time\n"
            "spec = importlib.util.spec_from_file_location('fw', sys.argv[1])\n"
            "fw = importlib.util.module_from_spec(spec); spec.loader.exec_module(fw)\n"
            "def slow(config):\n"
            "    os.kill(os.getpid(), signal.SIGTERM); time.sleep(30)\n"
            "fw.read_orca_inventory = slow\n"
            "fw.coordinator_stage = lambda *a, **k: ([], False)\n"
            "fw.bind_pass_config = lambda config: 'ok'\n"
            "sys.argv = ['fw', '--config', sys.argv[2], '--state', sys.argv[3]]\n"
            "sys.exit(fw.main())\n")
        with tempfile.TemporaryDirectory() as tmp:
            config, state, log = Path(tmp, 'c.json'), Path(tmp, 's.json'), Path(tmp, 'fw.log')
            config.write_text(json.dumps({'runs': [{'id': 'run_x'}], 'local_host': 'h'}))
            env = dict(os.environ, FLEET_WATCH_LOG_PATH=str(log), HOME=tmp)
            done = subprocess.run([sys.executable, '-c', child, str(SCRIPT), str(config), str(state)],
                                   env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(done.returncode, 143, done.stderr)
            self.assertRegex(log.read_text(), r'pass killed \d+\.\ds; phases inventory=\d+\.\d\n')


def check_result(calls):
    return lambda *a, **k: calls.append(a) or SimpleNamespace(returncode=0, stdout='')


class StaleWorktreeThrottle(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.config = {'repo_roots': {APP: str(Path(__file__).parent)}}

    def test_runs_once_per_interval(self):
        state = {}
        fw.stale_worktree_notices(self.config, state, 1000, run=check_result(self.calls))
        fw.stale_worktree_notices(self.config, state, 1000 + 300, run=check_result(self.calls))
        self.assertEqual(len(self.calls), 1)
        fw.stale_worktree_notices(self.config, state, 1000 + fw.STALE_WORKTREE_EVERY, run=check_result(self.calls))
        self.assertEqual(len(self.calls), 2)

    def test_without_state_it_runs_every_time(self):
        fw.stale_worktree_notices(self.config, run=check_result(self.calls))
        fw.stale_worktree_notices(self.config, run=check_result(self.calls))
        self.assertEqual(len(self.calls), 2)


if __name__ == '__main__':
    unittest.main()
