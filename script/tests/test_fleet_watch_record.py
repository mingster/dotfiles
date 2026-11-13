"""Recorded Orca replies stay free of handles, and the contract compares shape."""
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

from fleet_watch_replies import (
    default_patterns, leak_kinds, load_reply, redact, reply_shape, same_shape, shape, version_dir,
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

    def test_empty_list_matches_rows_and_a_new_key_does_not(self):
        saved = {'exit_code': 0, 'stdout': {'workers': [{'id': 'str'}]}, 'stderr': ''}
        empty = {'exit_code': 0, 'stdout': {'workers': []}, 'stderr': ''}
        extra = {'exit_code': 0, 'stdout': {'workers': [{'id': 'str', 'extra': 'int'}]}, 'stderr': ''}
        other = {'exit_code': 1, 'stdout': {'workers': [{'id': 'str'}]}, 'stderr': ''}
        self.assertTrue(same_shape(saved, empty))
        self.assertFalse(same_shape(saved, extra))
        self.assertFalse(same_shape(saved, other))


class ContractSkip(unittest.TestCase):
    script = Path(__file__).resolve().parents[1] / 'fleet-watch-record.py'
    live = 'run_2d30da234f80'

    def run_recorder(self, env, *args):
        return subprocess.run(
            ['python3', str(self.script), *args],
            capture_output=True, text=True, env=env, timeout=30,
        )

    def logging_orca(self, tmp, body):
        log = Path(tmp) / 'orca.log'
        fake = Path(tmp) / 'orca'
        fake.write_text(
            "#!/bin/sh\nprintf '%%s\\n' \"$*\" >> %s\n%s" % (json.dumps(str(log)), body)
        )
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
        env = os.environ.copy()
        env['PATH'] = tmp + os.pathsep + env.get('PATH', '')
        env['ORCA_CLI_COMMAND'] = str(fake)
        env.pop('FLEET_WATCH_RECORD_RUN', None)
        gh = Path(tmp) / 'gh'
        gh.write_text('#!/bin/sh\nprintf \'[]\\n\'\nexit 1\n')
        gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
        return env, log

    def test_dry_run_with_a_fake_orca_does_not_send(self):
        with tempfile.TemporaryDirectory() as tmp:
            env, log = self.logging_orca(tmp, 'echo \'{"ok":true}\'\n')
            proc = self.run_recorder(env, '--dry')
            text = log.read_text() if log.exists() else ''
        self.assertEqual(proc.returncode, 0)
        self.assertIn('local', proc.stderr + proc.stdout)
        self.assertIn('--version', text)
        self.assertNotIn('send', text)
        self.assertNotIn('run-create', text)

    def test_refuses_the_coordinator_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            env, log = self.logging_orca(tmp, 'echo 1.4.258\n')
            env['FLEET_WATCH_RECORD_RUN'] = self.live
            proc = self.run_recorder(env, '--dry')
            text = log.read_text() if log.exists() else ''
        self.assertEqual(proc.returncode, 2)
        self.assertIn('refusing', proc.stderr)
        self.assertEqual(text, '')
        self.assertNotIn(self.live, proc.stdout)

    def test_scratch_run_is_the_send_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            env, log = self.logging_orca(tmp, r'''
case "$*" in
  *--version*) echo 1.4.258 ;;
  *run-show*) echo '{"ok":true,"result":{"run":{"coordinator_handle":"term_placeholder"}}}' ;;
  *terminal\ create*) echo '{"ok":true,"result":{"terminal":{"handle":"term_placeholder"}}}' ;;
  *send*) echo '{"ok":true,"result":{"messageId":"<id>"}}' ;;
  *) echo '{"ok":false,"error":{"code":"no_active_sender_terminal","message":"x"}}'; exit 1 ;;
esac
''')
            env['FLEET_WATCH_RECORD_RUN'] = 'run_scratch'
            proc = self.run_recorder(env, '--dry')
            text = log.read_text() if log.exists() else ''
        self.assertNotIn(self.live, text)
        self.assertNotIn(self.live, proc.stdout + proc.stderr)
        self.assertIn('run:run_scratch', text)
        self.assertIn('send', text)

    def test_version_mismatch_is_reported_without_sending(self):
        with tempfile.TemporaryDirectory() as tmp:
            env, log = self.logging_orca(tmp, r'''
case "$*" in
  *--version*) echo 9.9.9 ;;
  *) echo '{"ok":true}'; exit 1 ;;
esac
''')
            env['FLEET_WATCH_RECORD_RUN'] = 'run_scratch'
            proc = self.run_recorder(env, '--dry')
            text = log.read_text() if log.exists() else ''
        self.assertEqual(proc.returncode, 1)
        self.assertIn('version mismatch', proc.stderr)
        self.assertIn('9.9.9', proc.stderr)
        self.assertNotIn('send', text)
        self.assertNotIn('run-create', text)
        self.assertNotIn(self.live, text)

    def test_fresh_shape_mismatch_fails(self):
        """A fresh reply whose error code differs from the saved recording fails the check."""
        with tempfile.TemporaryDirectory() as tmp:
            env, log = self.logging_orca(tmp, r'''
case "$*" in
  *--version*) echo 1.4.258 ;;
  *run-list*) echo '{"ok":true,"result":{"runs":[]}}' ;;
  *terminal\ create*) echo '{"ok":true,"result":{"terminal":{"handle":"term_owned"}}}' ;;
  *run-create*) echo '{"ok":true,"result":{"run":{"id":"run_scratchtest"}}}' ;;
  *run-use*) echo '{"ok":true,"result":{"runId":"run_scratchtest"}}' ;;
  *terminal\ close*) echo '{"ok":true}' ;;
  *send*) echo '{"ok":false,"error":{"code":"consumer_fenced","message":"x"}}'; exit 1 ;;
  *) echo '{"ok":false,"error":{"code":"no_active_sender_terminal","message":"x"}}'; exit 1 ;;
esac
''')
            proc = self.run_recorder(env, '--dry')
            text = log.read_text() if log.exists() else ''
        self.assertEqual(proc.returncode, 1)
        self.assertIn('shape mismatch', proc.stderr)
        self.assertIn('consumer_fenced', proc.stderr)
        self.assertIn('run-create', text)
        self.assertIn('fleet-watch recorder scratch', text)
        self.assertIn('run_scratchtest', text)
        self.assertNotIn(self.live, text + proc.stdout + proc.stderr)


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

    def test_saved_recording_names_its_orca_version(self):
        directory = version_dir()
        named = directory.name[len('orca-'):]
        for path in sorted(directory.glob('*.json')):
            stamped = json.loads(path.read_text()).get('orca_version')
            self.assertEqual(stamped, named, path.name)

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
