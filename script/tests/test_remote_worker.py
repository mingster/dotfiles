"""Remote launch boundary: execute preflight in a disposable target environment."""
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import asdf_pin  # noqa: E402

asdf_pin.pin()  # before any test sets HOME


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
if a[:2] == ['worktree', 'list']:
    reply({'worktrees': [
        {'path': '/srv/other', 'isMainWorktree': False},
        {'path': '/srv/main', 'isMainWorktree': True}]})
elif a[:2] == ['terminal', 'create']:
    assert value('--environment') == 'fixture-environment'
    if '--worktree' not in a:
        print('Remote terminal create requires --worktree because the client cwd cannot identify a server worktree.', file=sys.stderr)
        sys.exit(1)
    if os.environ.get('CREATE_MODE') == 'fail':
        print('Orca server unreachable', file=sys.stderr)
        sys.exit(1)
    # The remote user's shell is unknown (bash, zsh or dash as /bin/sh), so the preflight must be POSIX: run it under dash.
    code = subprocess.run([os.environ['REMOTE_SHELL'], '-c', value('--command')],
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
    reply({'state': 'ready'})
else: sys.exit(99)
''')
        stub.chmod(0o700)
        self.gate = self.home / 'gate.py'
        self.gate.write_text('import sys\nsys.exit(0)\n')
        self.env = dict(os.environ, ORCA_CLI_COMMAND=str(stub), REMOTE_FIXTURE=str(self.home),
                        USAGE_GATE_CLI=str(self.gate), REMOTE_SHELL=shutil.which('dash') or '/bin/sh')

    def launch(self, agent='antigravity', worktree='path:/srv/fixture'):
        return subprocess.run(['bash', str(ROOT / 'script/start-remote-worker.sh'),
                               '--on', 'fixture-environment', '--agent', agent,
                               '--worktree', worktree, '--spec', 'Fixture task'],
                              env=self.env, capture_output=True, text=True)

    def test_usage_gate_refusal_stops_before_any_orca_call(self):
        self.gate.write_text('import sys\nsys.exit(3)\n')
        result = self.launch()
        self.assertEqual(result.returncode, 3)
        self.assertIn('usage gate', result.stderr)
        self.assertFalse(self.log.exists())

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

    def test_target_host_updates_dotfiles_and_links_the_preset_before_dispatch(self):
        (self.bin / 'agy').write_text('#!/bin/sh\nexit 0\n')
        (self.bin / 'agy').chmod(0o700)
        (self.bin / 'git').write_text('#!/bin/sh\necho "$@" >> "$HOME/git-calls"\nexit 0\n')
        (self.bin / 'git').chmod(0o700)
        setup = self.home / 'dotfiles/script/setup-orca.sh'
        setup.parent.mkdir(parents=True)
        setup.write_text(': > "$HOME/preset-linked"\n')
        (self.bin / 'bash').symlink_to('/bin/bash')
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('pull', (self.home / 'git-calls').read_text())
        self.assertTrue((self.home / 'preset-linked').exists())

    def test_tilde_remote_repo_expands_to_the_remote_home(self):
        (self.bin / 'agy').write_text('#!/bin/sh\nexit 0\n')
        (self.bin / 'agy').chmod(0o700)
        (self.bin / 'git').write_text('#!/bin/sh\necho "$@" >> "$HOME/git-calls"\nexit 0\n')
        (self.bin / 'git').chmod(0o700)
        (self.home / 'app').mkdir()
        # fleet-pull.json lists repos as typed, tilde included.
        (self.bin / 'jq').write_text('#!/bin/sh\necho "~/app"\n')
        (self.bin / 'jq').chmod(0o700)
        (self.home / 'agent-state').mkdir()
        (self.home / 'agent-state/fleet-pull.json').write_text('{}')
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'-C {self.home}/app pull', (self.home / 'git-calls').read_text())

    def test_failed_dotfiles_pull_refuses_dispatch(self):
        (self.bin / 'agy').write_text('#!/bin/sh\nexit 0\n')
        (self.bin / 'agy').chmod(0o700)
        (self.bin / 'git').write_text('#!/bin/sh\nexit 1\n')
        (self.bin / 'git').chmod(0o700)
        (self.home / 'dotfiles').mkdir(parents=True)
        result = self.launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('worker-start', self.log.read_text())

    def test_new_top_level_preflights_in_the_main_remote_worktree(self):
        (self.bin / 'agy').write_text('#!/bin/sh\nexit 0\n')
        (self.bin / 'agy').chmod(0o700)
        result = self.launch(worktree='new-top-level')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        create = next(a for a in calls if a[:2] == ['terminal', 'create'])
        self.assertEqual(create[create.index('--worktree') + 1], 'path:/srv/main')
        start = next(a for a in calls if a[:2] == ['orchestration', 'worker-start'])
        self.assertEqual(start[start.index('--worktree') + 1], 'new-top-level')

    def test_failed_preflight_prints_host_and_orca_error(self):
        self.env['CREATE_MODE'] = 'fail'
        result = self.launch(worktree='new-top-level')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('fixture-environment', result.stderr)
        self.assertIn('Orca server unreachable', result.stderr)
        self.assertNotIn('worker-start', self.log.read_text())

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
