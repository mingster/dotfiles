"""#1976: each tick runs a project's bin/support-mailbox-alert.py with the escalation send command."""
import importlib.util
import json
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
import asdf_pin  # noqa: E402

asdf_pin.pin()  # before any test sets HOME

SCRIPT = Path(__file__).parent.parent / 'fleet-watch.py'
spec = importlib.util.spec_from_file_location('fleet_watch', SCRIPT)
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

# Stands in for the project script: one alert, sent through the command after `--`.
FAKE_ALERT = '''import subprocess, sys
send = sys.argv[sys.argv.index('--') + 1:]
subprocess.run(send + ['--subject', 'PROBE-DOWN (UID 7)', '--body', 'b'], check=True)
print('support-mailbox-alert: escalated UID 7')
'''


class MailboxAlert(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.sends = self.root / 'sends'
        orca = self.root / 'orca.py'
        orca.write_text('import sys\nopen(%r, "a").write(" ".join(sys.argv[1:]) + "\\n")\n' % str(self.sends))
        env = mock.patch.dict(os.environ, {'ORCA_CLI_COMMAND': shlex.join([sys.executable, str(orca)])})
        env.start()
        self.addCleanup(env.stop)
        self.config = {'repo_roots': [str(self.root)], 'runs': [{'id': 'run_1', 'terminal': 'term_1'}]}

    def script(self, text):
        path = self.root / 'bin' / 'support-mailbox-alert.py'
        path.parent.mkdir(exist_ok=True)
        path.write_text(text)

    def test_one_alert_yields_one_send(self):
        self.script(FAKE_ALERT)
        self.assertEqual(fw.mailbox_alert_pass(self.config), ['mailbox_alert=0'])
        self.assertEqual(self.sends.read_text().splitlines(), [
            'orchestration send --to run:run_1 --run run_1 --from term_1 --type escalation '
            '--subject PROBE-DOWN (UID 7) --body b'])

    def test_missing_script_is_quiet(self):
        self.assertEqual(fw.mailbox_alert_pass(self.config), [])
        self.assertFalse(self.sends.exists())

    def test_non_zero_exit_logs_unknown(self):
        self.script('raise SystemExit(3)\n')
        self.assertEqual(fw.mailbox_alert_pass(self.config), ['mailbox_alert=unknown'])

    def test_hung_script_logs_unknown(self):
        self.script('import time\ntime.sleep(30)\n')
        with mock.patch.object(fw, 'MAILBOX_ALERT_TIMEOUT', 0.5):
            self.assertEqual(fw.mailbox_alert_pass(self.config), ['mailbox_alert=unknown'])

    def test_no_run_sends_nothing(self):
        self.script(FAKE_ALERT)
        self.config['runs'] = []
        self.assertEqual(fw.mailbox_alert_pass(self.config), [])
        self.assertFalse(self.sends.exists())

    def test_a_full_pass_logs_the_exit(self):
        child = (
            "import importlib.util, sys\n"
            "spec = importlib.util.spec_from_file_location('fw', sys.argv[1])\n"
            "fw = importlib.util.module_from_spec(spec); spec.loader.exec_module(fw)\n"
            "fw.coordinator_stage = lambda *a, **k: ([], False)\n"
            "fw.bind_pass_config = lambda config: 'ok'\n"
            "sys.argv = ['fw', '--config', sys.argv[2], '--state', sys.argv[3]]\n"
            "sys.exit(fw.main())\n")
        self.script(FAKE_ALERT)
        config, log = self.root / 'c.json', self.root / 'fw.log'
        config.write_text(json.dumps(dict(self.config, local_host='h')))
        env = dict(os.environ, FLEET_WATCH_LOG_PATH=str(log), HOME=str(self.root))
        done = subprocess.run([sys.executable, '-c', child, str(SCRIPT), str(config), str(self.root / 's.json')],
                              env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn('mailbox_alert=0', log.read_text())
        self.assertIn('--type escalation', self.sends.read_text())


if __name__ == '__main__':
    unittest.main()
