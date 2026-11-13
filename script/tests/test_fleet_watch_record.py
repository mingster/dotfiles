"""Recorded Orca replies stay free of handles, and the contract compares shape."""
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

from fleet_watch_replies import (
    default_patterns, leak_kinds, load_reply, redact, reply_shape, shape, version_dir,
)


class Redact(unittest.TestCase):
    def test_replaces_handles_paths_and_ids_and_keeps_the_error_code(self):
        raw = {
            'ok': False,
            'error': {'code': 'no_active_sender_terminal', 'message': 'pane term_abc at 10.1.2.3'},
            'topologyRevisions': {'/Users/someone/proj': 3},
            'preview': 'screen line',
            'token': 'wtr_1b973d5384ad',
            'note': '10.1.2.3',
        }
        out = redact(raw, patterns=[], homes=('/Users/someone',))
        text = json.dumps(out)
        self.assertEqual(out['error']['code'], 'no_active_sender_terminal')
        self.assertEqual(out['preview'], '<redacted>')
        self.assertEqual(out['token'], '<id>')
        self.assertEqual(out['note'], '<ip>')
        self.assertEqual(out['topologyRevisions'], {'<key>': 3})
        self.assertEqual(leak_kinds(text), [])
        self.assertNotIn('10.1.2.3', text)
        self.assertNotIn('screen line', text)

    def test_shape_tracks_error_code_and_ignores_other_strings(self):
        accepted = {'ok': True, 'result': {'messageId': 'msg_abc123'}}
        refused = {'ok': False, 'error': {'code': 'no_active_sender_terminal', 'message': 'one'}}
        again = {'ok': False, 'error': {'code': 'no_active_sender_terminal', 'message': 'two'}}
        other = {'ok': False, 'error': {'code': 'consumer_fenced', 'message': 'one'}}
        self.assertEqual(shape(refused), shape(again))
        self.assertNotEqual(shape(refused), shape(other))
        self.assertNotEqual(shape(accepted), shape(refused))

    def test_reply_shape_includes_the_exit_code(self):
        base = {'exit_code': 0, 'stdout': '{"ok": true}\n', 'stderr': ''}
        failed = {'exit_code': 1, 'stdout': '{"ok": true}\n', 'stderr': ''}
        self.assertNotEqual(reply_shape(base), reply_shape(failed))


class ContractSkip(unittest.TestCase):
    def test_dry_run_skips_a_fake_orca(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / 'orca'
            fake.write_text('#!/bin/sh\necho \'{"ok":true}\'\n')
            fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
            env = os.environ.copy()
            env['PATH'] = tmp + os.pathsep + env.get('PATH', '')
            proc = subprocess.run(
                ['python3', str(Path(__file__).resolve().parents[1] / 'fleet-watch-record.py'), '--dry'],
                capture_output=True, text=True, env=env, timeout=30,
            )
        self.assertEqual(proc.returncode, 0)
        self.assertIn('skipped', proc.stderr)


class RecordedReplies(unittest.TestCase):
    required = (
        'send-no-sender', 'send-from-receiver', 'send-to-run', 'send-from-owned-terminal',
        'worker-list', 'worker-start-missing-repo', 'run-list', 'run-list-full', 'run-show',
        'terminal-list', 'inbox', 'gh-pr-list',
    )

    def test_saved_replies_expose_no_handles_hosts_or_ips(self):
        problems = []
        patterns = default_patterns()
        for path in sorted(version_dir().glob('*.json')):
            text = path.read_text()
            kinds = leak_kinds(text)
            if any(cre.search(text) for cre in patterns):
                kinds.append('project')
            if kinds:
                problems.append('%s:%s' % (path.name, ','.join(kinds)))
        self.assertEqual(problems, [])

    def test_each_fleet_watch_call_has_a_recording(self):
        names = {path.stem for path in version_dir().glob('*.json')}
        missing = [name for name in self.required if name not in names]
        self.assertEqual(missing, [])

    def test_sender_candidates(self):
        def outcome(name):
            reply = load_reply(name)
            body = json.loads(reply['stdout'])
            err = body.get('error') if isinstance(body.get('error'), dict) else {}
            return reply['exit_code'], body.get('ok'), err.get('code')

        self.assertEqual(outcome('send-no-sender'), (1, False, 'no_active_sender_terminal'))
        self.assertEqual(outcome('send-to-run'), (1, False, 'no_active_sender_terminal'))
        self.assertEqual(outcome('send-from-receiver')[:2], (0, True))
        self.assertEqual(outcome('send-from-owned-terminal')[:2], (0, True))
        code, ok, _err = outcome('worker-start-missing-repo')
        self.assertNotEqual(code, 0)
        self.assertIs(ok, False)


if __name__ == '__main__':
    unittest.main()
