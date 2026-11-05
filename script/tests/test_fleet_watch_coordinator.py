import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

SCRIPT = Path(__file__).parent.parent / 'fleet-watch.py'
TEXT = 'coordinator main-box offline for %d minutes; failover is manual, ask the owner'


class Fixture:
    """Fake ssh and alert calls; no network, no real command."""

    def __init__(self, up=True, alert_ok=True):
        self.up = up
        self.alert_ok = alert_ok
        self.probes = []
        self.sent = []

    def reachable(self, name):
        self.probes.append(name)
        return self.up

    def alert(self, command, text):
        self.sent.append((command, text))
        return self.alert_ok


class CoordinatorWatch(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.write_conf('coordinator main-box\n')
        self.config = {'runs': [], 'coordinator_watch': {
            'state_dir': self.dir.name, 'offline_minutes': 10, 'alert_command': ['notify']}}
        self.state = {}

    def write_conf(self, text):
        (Path(self.dir.name) / 'coordinator.conf').write_text(text)

    def run_pass(self, fx, now, host='backup-box'):
        return fw.coordinator_notices(self.config, self.state, now, fx.reachable, fx.alert, host)

    def test_reachable_does_nothing(self):
        fx = Fixture(up=True)
        self.assertEqual(self.run_pass(fx, 0), [])
        self.assertEqual(fx.sent, [])
        self.assertNotIn('coordinator_watch', self.state)

    def test_unreachable_under_threshold_waits(self):
        fx = Fixture(up=False)
        self.run_pass(fx, 0)
        self.assertEqual(self.run_pass(fx, 599), [])
        self.assertEqual(fx.sent, [])
        self.assertEqual(self.state['coordinator_watch'], {'host': 'main-box', 'since': 0, 'alerted': False})

    def test_at_threshold_one_alert(self):
        fx = Fixture(up=False)
        self.run_pass(fx, 0)
        notices = self.run_pass(fx, 600)
        self.assertEqual(notices, [TEXT % 10])
        self.assertEqual(fx.sent, [(['notify'], TEXT % 10)])
        self.assertTrue(self.state['coordinator_watch']['alerted'])

    def test_next_pass_does_not_repeat(self):
        fx = Fixture(up=False)
        self.run_pass(fx, 0)
        self.run_pass(fx, 600)
        self.assertEqual(self.run_pass(fx, 660), [])
        self.assertEqual(len(fx.sent), 1)

    def test_back_online_rearms_and_says_back(self):
        fx = Fixture(up=False)
        self.run_pass(fx, 0)
        self.run_pass(fx, 600)
        fx.up = True
        self.assertEqual(self.run_pass(fx, 700), ['coordinator main-box back'])
        self.assertEqual(fx.sent[-1], (['notify'], 'coordinator main-box back'))
        self.assertNotIn('coordinator_watch', self.state)
        self.assertEqual(self.run_pass(fx, 760), [])
        fx.up = False
        self.run_pass(fx, 800)
        self.assertEqual(self.run_pass(fx, 1400), [TEXT % 10])

    def test_back_before_alert_is_silent(self):
        fx = Fixture(up=False)
        self.run_pass(fx, 0)
        fx.up = True
        self.assertEqual(self.run_pass(fx, 300), [])
        self.assertEqual(fx.sent, [])

    def test_this_host_is_coordinator(self):
        fx = Fixture(up=False)
        self.assertEqual(self.run_pass(fx, 0, host='MAIN-Box'), [])
        self.assertEqual(fx.probes, [])
        self.assertNotIn('coordinator_watch', self.state)

    def test_no_coordinator_line(self):
        self.write_conf('# nothing here\nother thing\n')
        fx = Fixture(up=False)
        self.assertEqual(self.run_pass(fx, 0), [])
        self.assertEqual(fx.probes, [])

    def test_failed_alert_retries(self):
        fx = Fixture(up=False, alert_ok=False)
        self.run_pass(fx, 0)
        self.assertEqual(self.run_pass(fx, 600), [])
        self.assertFalse(self.state['coordinator_watch']['alerted'])
        fx.alert_ok = True
        self.assertEqual(self.run_pass(fx, 660), [TEXT % 11])
        self.assertTrue(self.state['coordinator_watch']['alerted'])

    def test_changed_coordinator_resets(self):
        fx = Fixture(up=False)
        self.run_pass(fx, 0)
        self.run_pass(fx, 600)
        self.write_conf('coordinator other-box\n')
        self.assertEqual(self.run_pass(fx, 700), [])
        self.assertEqual(self.state['coordinator_watch'], {'host': 'other-box', 'since': 700, 'alerted': False})

    def test_config_without_key_is_unchanged(self):
        fx = Fixture(up=False)
        self.config.pop('coordinator_watch')
        self.assertEqual(self.run_pass(fx, 0), [])
        self.assertEqual(self.state, {})
        self.assertEqual(fx.probes, [])


class NoOrca(unittest.TestCase):
    def test_empty_runs_passes_without_orca(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            me = socket.gethostname().split('.')[0]
            (tmp / 'coordinator.conf').write_text('coordinator %s\n' % me)
            config = tmp / 'config.json'
            config.write_text(json.dumps({'runs': [], 'coordinator_watch': {'state_dir': str(tmp)}}))
            state = tmp / 'state.json'
            env = dict(os.environ, ORCA_CLI_COMMAND=str(tmp / 'no-such-orca'))
            done = subprocess.run([sys.executable, str(SCRIPT), '--config', str(config), '--state', str(state)],
                                  capture_output=True, text=True, env=env, timeout=30)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertTrue(state.exists())


if __name__ == '__main__':
    unittest.main()
