"""Remote launch boundary: execute preflight in a disposable target environment."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RemoteWorkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.log = self.home / 'calls'
        stub = self.home / 'orca'
        stub.write_text(f'#!{sys.executable}\n' + '''
import json, os, subprocess, sys
from pathlib import Path
a = sys.argv[1:]
home = Path(os.environ['REMOTE_FIXTURE'])
with (home / 'calls').open('a') as f: f.write(json.dumps(a) + '\\n')
def value(k): return a[a.index(k) + 1]
def reply(r): print(json.dumps({'result': r}))
if a[:2] == ['terminal', 'create']:
    assert value('--environment') == 'fixture-environment'
    code = subprocess.run(value('--command'), shell=True,
                          env=dict(os.environ, HOME=str(home), PATH=str(home / 'bin'))).returncode
    (home / 'exit').write_text(str(code))
    reply({'terminal': {'handle': 'term_fixture'}})
elif a[:2] == ['terminal', 'wait']:
    w = {'satisfied': True, 'status': 'exited', 'exitCode': int((home / 'exit').read_text())}
    if os.environ.get('WAIT_MODE') == 'unknown': w.pop('exitCode')
    if os.environ.get('WAIT_MODE') == 'timeout': w.update(satisfied=False, status='running')
    reply({'wait': w})
elif a[:2] == ['terminal', 'close']: reply({})
elif a[:2] == ['orchestration', 'worker-start']:
    assert value('--on') == 'fixture-environment'
    if os.environ.get('START_FAIL'): print('{"ok":false}'); sys.exit(3)
    reply({'state': 'ready', 'dispatch': {'dispatchId': 'ctx_remote1'}})
else: sys.exit(99)
''')
        stub.chmod(0o700)
        self.env = dict(os.environ, ORCA_CLI_COMMAND=str(stub), REMOTE_FIXTURE=str(self.home))

    def launch(self, agent='antigravity'):
        return subprocess.run(['bash', str(ROOT / 'script/start-remote-worker.sh'),
                               '--on', 'fixture-environment', '--agent', agent,
                               '--worktree', 'path:/srv/fixture', '--spec', 'Fixture task'],
                              env=self.env, capture_output=True, text=True)

    def test_missing_cli_refuses_and_names_it_without_dispatch(self):
        for agent, cli in [('antigravity', 'agy'), ('cursor', 'agent'),
                           ('claude', 'claude')]:
            with self.subTest(agent=agent):
                self.log.unlink(missing_ok=True)
                result = self.launch(agent)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(cli, result.stdout + result.stderr)
                self.assertNotIn('worker-start', self.log.read_text())

    def test_present_cli_dispatches_after_successful_target_preflight(self):
        (self.bin / 'agy').write_text('#!/bin/sh\nexit 0\n')
        (self.bin / 'agy').chmod(0o700)
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual([a[:2] for a in calls], [['terminal', 'create'], ['terminal', 'wait'],
                                                ['terminal', 'close'], ['orchestration', 'worker-start']])

    def owner_launch(self, *extra):
        self.owners = self.home / 'owners'
        self.env['WORKER_DONE_OWNER_DIR'] = str(self.owners)
        (self.bin / 'agy').write_text('#!/bin/sh\nexit 0\n')
        (self.bin / 'agy').chmod(0o700)
        return subprocess.run(['bash', str(ROOT / 'script/start-remote-worker.sh'), '--on', 'fixture-environment',
                               '--agent', 'antigravity', '--worktree', 'path:/srv/fixture', '--spec', 'Fixture task', *extra],
                              env=self.env, capture_output=True, text=True)

    def test_owner_flags_write_the_record_and_leave_the_start_output_alone(self):
        result = self.owner_launch('--owner-lead', 'term_lead_Z', '--owner-repo', 'o/n', '--owner-branch', 'feat-x')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'result': {'state': 'ready', 'dispatch': {'dispatchId': 'ctx_remote1'}}})
        self.assertEqual((self.owners / 'ctx_remote1').read_text(), 'term_lead_Z\nkind=builder\nrepo=o/n\nbranch=feat-x\n')
        start = [json.loads(line) for line in self.log.read_text().splitlines()][-1]
        self.assertFalse([a for a in start if a.startswith('--owner')])

    def test_no_owner_flags_no_record(self):
        result = self.owner_launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.owners.exists())

    def test_failed_record_write_warns_and_the_start_succeeds(self):
        blocked = self.home / 'blocked'
        blocked.write_text('')
        result = self.owner_launch('--owner-lead', 'term_lead_Z')
        self.assertEqual(result.returncode, 0)
        self.env['WORKER_DONE_OWNER_DIR'] = str(blocked)
        result = subprocess.run(['bash', str(ROOT / 'script/start-remote-worker.sh'), '--on', 'fixture-environment',
                                 '--agent', 'antigravity', '--worktree', 'path:/srv/fixture', '--spec', 'x',
                                 '--owner-lead', 'term_lead_Z'], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('owner record', result.stderr)
        self.assertIn('ctx_remote1', result.stdout)

    def test_failed_start_keeps_its_exit_code_and_writes_no_record(self):
        self.env['START_FAIL'] = '1'
        result = self.owner_launch('--owner-lead', 'term_lead_Z')
        self.assertEqual(result.returncode, 3)
        self.assertFalse(self.owners.exists())

    def test_uncertain_completion_never_dispatches(self):
        (self.bin / 'agy').touch(mode=0o700)
        for mode in ('unknown', 'timeout'):
            self.log.unlink(missing_ok=True)
            self.env['WAIT_MODE'] = mode
            result = self.launch()
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('worker-start', self.log.read_text())


if __name__ == '__main__':
    unittest.main()
