"""Each fleet-watch pass logs start, refusal, park, failure and send counts."""
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

ROOT = Path(__file__).resolve().parents[2]
HEAD = 'a' * 40
NOW = 1_700_000_000.0
COUNT_KEYS = ('started', 'refused', 'parked', 'failed', 'sent', 'send_failed', 'refused_reasons')


def load_reply(name):
    """Recorded Orca reply from #990. Prefer that ticket's helper when it is on the tree."""
    try:
        from fleet_watch_replies import load_reply as recorded
    except ImportError:
        recorded = None
    if recorded is not None:
        return recorded(name)
    root = Path(__file__).resolve().parent / 'fixtures' / 'fleet-watch'
    dirs = sorted(p for p in root.iterdir() if p.is_dir() and p.name.startswith('orca-'))
    if not dirs:
        raise FileNotFoundError('no recorded replies in %s' % root)
    data = json.loads((dirs[-1] / (name + '.json')).read_text())
    for key in ('exit_code', 'stdout', 'stderr'):
        if key not in data:
            raise ValueError('%s missing %s' % (name, key))
    return data


def verifier_pr(number):
    return {
        'number': number,
        'state': 'OPEN',
        'isDraft': False,
        'headRefOid': HEAD,
        'headRefName': '',
        'mergeable': 'MERGEABLE',
        'statusCheckRollup': [{'name': 'checks', 'status': 'COMPLETED', 'conclusion': 'SUCCESS'}],
        'comments': [],
        'files': [],
    }


def babysit_config(root):
    return {
        'babysit': {
            'repos': ['owner/app'],
            'run': 'run_x',
            'from_terminal': 'term_c',
            'repo_roots': {'owner/app': root},
        },
    }


class PassCounts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.log = Path(self.tmp.name) / 'fleet-watch.log'
        self.summary = Path(self.tmp.name) / 'summary.txt'
        patcher = patch.dict(os.environ, {
            'FLEET_WATCH_LOG_PATH': str(self.log),
            'AUTOMATION_TRACE_SUMMARY_FILE': str(self.summary),
        })
        patcher.start()
        self.addCleanup(patcher.stop)
        fw.USAGE_GATE_REFUSALS.clear()
        fw.USAGE_GATE_CALLS[0] = 0
        fw.begin_pass_counts()

    def test_a_quiet_pass_logs_zero_counts_and_the_same_summary(self):
        directory = Path(self.tmp.name)
        config = directory / 'config.json'
        state = directory / 'state.json'
        config.write_text(json.dumps({
            'runs': [{'id': 'r', 'terminal': 't', 'waiter_pattern': 'fleet-watch-test-waiter-absent'}],
        }))

        def rpc(*args):
            if args[1] == 'inbox':
                return {'messages': []}
            if args[1] == 'worker-list':
                return {'workers': [], 'page': {'hasMore': False}}
            if args[:2] == ('terminal', 'list'):
                return {'terminals': []}
            if args[1] == 'task-list':
                return {'tasks': []}
            return {}

        with patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                patch.object(fw, 'rpc', side_effect=rpc), \
                patch.object(fw.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), \
                patch.object(fw, 'deliver_notices', return_value=None):
            self.assertEqual(fw.main(), 0)
        line = self.log.read_text().strip().splitlines()[-1]
        summary = self.summary.read_text().strip()
        for key in COUNT_KEYS:
            self.assertIn(key + '=', line)
            self.assertIn(key + '=', summary)
        for key in ('started', 'refused', 'parked', 'failed', 'sent', 'send_failed'):
            self.assertIn('%s=0' % key, line)
            self.assertIn('%s=0' % key, summary)
        self.assertTrue(line.endswith(summary), (line, summary))
        self.assertNotIn('no change', line)
        self.assertNotIn('no change', summary)
        self.assertRegex(summary, r'refused_reasons=$')

    def test_issue_scan_gate_logs_the_reason_not_a_bare_token(self):
        def run(command, **kwargs):
            return subprocess.CompletedProcess(command, 4, stdout=json.dumps({
                'provider': 'cursor', 'verdict': 'blocked', 'reason': 'daily cap',
                'reading_age_min': 1, 'headroom': 30,
            }))

        def gate(config):
            return fw.default_issue_scan_gate(config, run=run)

        _notices, log = fw.issue_scan_pass(
            {'issue_scan': {'enabled': True, 'agent': 'cursor', 'model': 'm', 'repos': []}},
            {}, NOW, [], gate_check=gate,
        )
        self.assertNotIn('issue_scan_gate', log)
        self.assertTrue(any(bit.startswith('issue_scan_gate=') and 'daily cap' in bit for bit in log), log)
        self.assertIn('refused=1', fw.pass_counts_line())
        self.assertIn('refused_reasons=usage_gate:1', fw.pass_counts_line())

    def test_pick_fail_logs_the_reason_not_a_bare_token(self):
        def pick(_role):
            return {
                'selected': None,
                'candidates': [{
                    'provider': 'cursor', 'model': 'grok', 'eligible': False,
                    'verdict': 'blocked', 'reason': 'daily cap',
                }],
            }

        _notices, lines, log = fw.babysit_pass(
            babysit_config(self.tmp.name), {}, workers=[],
            pr_fetch=lambda _repo: [verifier_pr(7)],
            pick=pick,
            owner_check=lambda _pr: None,
        )
        self.assertTrue(lines)
        self.assertNotIn('pick_fail=7', log)
        self.assertTrue(any(bit.startswith('pick_fail=7:') and 'daily cap' in bit for bit in log), log)
        self.assertIn('refused=1', fw.pass_counts_line())
        self.assertIn('usage_gate:1', fw.pass_counts_line())

    def test_a_cap_skip_is_host_cap_and_a_real_start_and_failure_are_counted(self):
        fw.begin_pass_counts()
        fw.babysit_pass(
            dict(babysit_config(self.tmp.name), babysit={
                **babysit_config(self.tmp.name)['babysit'], 'per_pass_cap': 0,
            }),
            {}, workers=[],
            pr_fetch=lambda _repo: [verifier_pr(1), verifier_pr(2)],
            pick=lambda _role: None,
            owner_check=lambda _pr: None,
        )
        capped = fw.pass_counts_line()
        self.assertIn('refused=2', capped)
        self.assertIn('refused_reasons=host_cap:2', capped)
        self.assertIn('started=0', capped)

        fw.begin_pass_counts()
        chosen = {'selected': {'provider': 'cursor', 'model': 'grok', 'eligible': True}}
        fw.babysit_pass(
            babysit_config(self.tmp.name), {}, workers=[],
            pr_fetch=lambda _repo: [verifier_pr(8)],
            pick=lambda _role: chosen,
            owner_check=lambda _pr: None,
            start_worker=lambda _command: 0,
        )
        self.assertIn('started=1', fw.pass_counts_line())
        self.assertIn('failed=0', fw.pass_counts_line())

        fw.begin_pass_counts()
        fw.babysit_pass(
            babysit_config(self.tmp.name), {}, workers=[],
            pr_fetch=lambda _repo: [verifier_pr(9)],
            pick=lambda _role: chosen,
            owner_check=lambda _pr: None,
            start_worker=lambda _command: 1,
        )
        self.assertIn('failed=1', fw.pass_counts_line())
        self.assertIn('parked=1', fw.pass_counts_line())
        self.assertIn('started=0', fw.pass_counts_line())

    def test_recorded_send_replies_count_sent_and_send_failed(self):
        config = {'runs': [{'id': 'run_x', 'terminal': 'term_live'}]}

        def deliver(name):
            recorded = load_reply(name)
            fw.begin_pass_counts()
            seen = []

            def fake_run(cmd, **kwargs):
                seen.append(list(cmd))
                return subprocess.CompletedProcess(
                    cmd, recorded['exit_code'], stdout=recorded['stdout'], stderr=recorded['stderr'],
                )

            state = {}
            log = Path(self.tmp.name) / (name + '.log')
            err = io.StringIO()
            with patch.dict(os.environ, {'FLEET_WATCH_LOG_PATH': str(log)}), \
                    patch.object(fw.subprocess, 'run', side_effect=fake_run), \
                    contextlib.redirect_stderr(err):
                fw.deliver_notices(config, state, [fw.Urgent('boom')], now=100.0)
            text = log.read_text(encoding='utf-8') if log.exists() else ''
            return state, text, err.getvalue(), seen

        sent_state, sent_log, _sent_err, seen = deliver('send-from-owned-terminal')
        self.assertIn('sent=1', fw.pass_counts_line())
        self.assertIn('send_failed=0', fw.pass_counts_line())
        self.assertIn('sent=1', sent_log)
        self.assertNotIn('run:run_x', sent_state.get('notice_queue', {}))
        send = [cmd for cmd in seen if 'send' in cmd][0]
        self.assertEqual(send[send.index('--to') + 1], 'run:run_x')
        self.assertEqual(send[send.index('--from') + 1], 'term_live')

        refused_state, refused_log, refused_err, _seen = deliver('send-no-sender')
        self.assertIn('sent=0', fw.pass_counts_line())
        self.assertIn('send_failed=1', fw.pass_counts_line())
        self.assertIn('run:run_x', refused_state.get('notice_queue', {}))
        self.assertIn('no_active_sender_terminal', refused_err)
        self.assertIn('no_active_sender_terminal', refused_log)
        self.assertEqual(load_reply('send-no-sender')['exit_code'], 1)

    def test_wrapper_summary_carries_the_pass_counts(self):
        directory = Path(self.tmp.name)
        config = directory / 'config.json'
        state = directory / 'state.json'
        autolog = directory / 'automation.log'
        watch_log = directory / 'fleet-watch.log'
        fake = directory / 'fake-orca.py'
        config.write_text(json.dumps({
            'runs': [{'id': 'r', 'terminal': 't', 'waiter_pattern': 'fleet-watch-test-waiter-absent'}],
        }))
        fake.write_text(
            'import json, sys\n'
            'args = sys.argv[1:]\n'
            'def ok(result):\n'
            '    json.dump({"ok": True, "result": result}, sys.stdout)\n'
            '    raise SystemExit(0)\n'
            'if "inbox" in args:\n'
            '    ok({"messages": []})\n'
            'if "worker-list" in args:\n'
            '    ok({"workers": [], "page": {"hasMore": False}})\n'
            'if "task-list" in args:\n'
            '    ok({"tasks": []})\n'
            'if "terminal" in args and "list" in args:\n'
            '    ok({"terminals": []})\n'
            'sys.stderr.write("unexpected %s\\n" % " ".join(args))\n'
            'raise SystemExit(1)\n'
        )
        env = os.environ.copy()
        env.update({
            'HOME': str(directory / 'home'),
            'FLEET_WATCH_LOG_PATH': str(watch_log),
            'ORCA_CLI_COMMAND': '%s %s' % (sys.executable, fake),
        })
        (directory / 'home').mkdir()
        proc = subprocess.run(
            [
                'bash', str(ROOT / 'script' / 'automation-precheck-wrapper.sh'),
                'fleet-watch', str(autolog), '--',
                sys.executable, str(ROOT / 'script' / 'fleet-watch.py'),
                '--config', str(config), '--state', str(state),
            ],
            env=env, cwd=str(ROOT), timeout=60, check=False,
            capture_output=True, text=True,
        )
        text = autolog.read_text() if autolog.exists() else ''
        watched = watch_log.read_text() if watch_log.exists() else ''
        self.assertIn('phase=end', text, proc.stderr[-500:] + text[-500:])
        self.assertNotIn('summary=no change', text)
        counts = 'started=0 refused=0 parked=0 failed=0 sent=0 send_failed=0 refused_reasons='
        self.assertIn('summary=' + counts, text)
        self.assertIn(counts, watched)


if __name__ == '__main__':
    unittest.main()
