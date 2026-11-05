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

    def run_pass(self, fx, now, host='backup-box', name_reader=None):
        reader = name_reader if name_reader is not None else fw.coordinator_name_from_state_dir
        return fw.coordinator_notices(self.config, self.state, now, fx.reachable, fx.alert, host, reader)

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
        self.assertEqual(self.run_pass(fx, 600), [TEXT % 10])
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

    def git_env(self):
        return {
            **os.environ,
            'GIT_AUTHOR_NAME': 't',
            'GIT_AUTHOR_EMAIL': 't@example.com',
            'GIT_COMMITTER_NAME': 't',
            'GIT_COMMITTER_EMAIL': 't@example.com',
        }

    def init_state_git(self, local_conf, remote_conf):
        root = Path(self.dir.name)
        bare = root / 'origin.git'
        subprocess.run(['git', 'init', '--bare', str(bare)], check=True, capture_output=True)
        publish = root / 'publish'
        subprocess.run(['git', 'clone', str(bare), str(publish)], check=True, capture_output=True)
        (publish / 'coordinator.conf').write_text(remote_conf)
        subprocess.run(['git', '-C', str(publish), 'add', 'coordinator.conf'], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(publish), 'commit', '-m', 'remote'], check=True, capture_output=True, env=self.git_env())
        subprocess.run(['git', '-C', str(publish), 'push', 'origin', 'HEAD:main'], check=True, capture_output=True)
        state_dir = root / 'state'
        subprocess.run(['git', 'clone', str(bare), str(state_dir)], check=True, capture_output=True)
        (state_dir / 'coordinator.conf').write_text(local_conf)
        self.config['coordinator_watch']['state_dir'] = str(state_dir)
        return state_dir

    def test_stale_local_follows_remote_coordinator(self):
        self.init_state_git('coordinator old-box\n', 'coordinator new-box\n')
        fx = Fixture(up=False)
        self.run_pass(fx, 0)
        notices = self.run_pass(fx, 600)
        self.assertEqual(notices, ['coordinator new-box offline for 10 minutes; failover is manual, ask the owner'])
        self.assertNotIn('old-box', fx.probes)
        self.assertTrue(all(p == 'new-box' for p in fx.probes))
        self.assertEqual(self.state['coordinator_watch']['host'], 'new-box')

    def test_fetch_failure_falls_back_to_local_ssh(self):
        state_dir = self.init_state_git('coordinator main-box\n', 'coordinator remote-box\n')
        subprocess.run(['git', '-C', str(state_dir), 'fetch', '-q', 'origin'], check=True, capture_output=True)
        subprocess.run(
            ['git', '-C', str(state_dir), 'remote', 'set-url', 'origin', '/nonexistent/fleet-watch-fetch-test'],
            check=True, capture_output=True,
        )
        fx = Fixture(up=True)
        self.run_pass(fx, 0)
        self.assertEqual(fx.probes, ['main-box'])
        self.assertNotIn('coordinator_watch', self.state)

    def test_remote_without_coordinator_line_ignores_stale_local(self):
        self.init_state_git('coordinator stale-box\n', '# no coordinator here\n')
        fx = Fixture(up=False)
        self.assertEqual(self.run_pass(fx, 0), [])
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
