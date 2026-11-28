"""fleet-watch sends no mail to a settled or released worker (#1089)."""
import sys
import importlib.util
import io
import unittest
import unittest.mock
from contextlib import redirect_stderr
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('fleet_watch_1089', ROOT / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

HEAD = 'a' * 40
NEW = 'b' * 40
REPO = 'o/r'
NOW = 1_700_000_000


def verifier(**changes):
    row = {
        'dispatchId': 'ctx_v', 'terminal': 'term_v',
        'workerState': 'ready', 'dispatchStatus': 'dispatched', 'terminalState': 'active',
        'projection': {
            'role': 'worker', 'outcome': 'in_progress',
            'liveness': {'verdict': 'live'},
            'stage': {'worker': 'ready', 'dispatch': 'dispatched'},
        },
        '_task_title': 'qa-sdet - verify PR #7',
    }
    row.update(changes)
    return row


def pr_row():
    return {
        'number': 7, 'state': 'OPEN', 'isDraft': False, 'headRefOid': NEW, 'headRefName': 'b',
        'statusCheckRollup': [{'name': 'checks', 'conclusion': 'SUCCESS', 'status': 'COMPLETED'}],
        'comments': [{'body': 'Review: PASS head=%s' % NEW}], 'labels': [], 'mergeable': 'MERGEABLE',
        'body': '## Self-check\n$ bash script/checks-local.sh\nexit 0\nBuilder: agent=claude model=opus',
    }


def route(worker):
    notes = []
    state = {'verifier_head': {REPO: {'7': HEAD}}}
    err = io.StringIO()
    with unittest.mock.patch.object(fw, 'log_fleet_watch') as log, redirect_stderr(err):
        result = fw.route_rework_head(
            pr_row(), [worker], state, REPO, NOW, {'term_v': NOW - 10}, lambda _d: None,
            lambda terminal, text: notes.append((terminal, text)),
        )
    return result, notes, log, err.getvalue()


class VerifierMail(unittest.TestCase):
    def test_live_worker_still_gets_the_rework_mail(self):
        result, notes, log, _err = route(verifier())
        self.assertEqual(result, 'sticky')
        self.assertEqual([terminal for terminal, _text in notes], ['term_v'])
        log.assert_not_called()

    def test_settled_worker_is_not_mailed_and_logs_one_line(self):
        for kind in ('succeeded', 'stopped', 'failed'):
            with self.subTest(kind=kind):
                result, notes, log, err = route(verifier(workerState=kind))
                self.assertEqual(notes, [])
                self.assertEqual(log.call_count, 1)
                self.assertIn('ctx_v', log.call_args[0][0])
                self.assertIn(kind, log.call_args[0][0])
                self.assertEqual(err.count('\n'), 1, err)


class BounceMail(unittest.TestCase):
    def bounce(self, worker):
        sent = []
        config = {'issue_scan': {'repo_roots': {REPO: '/tmp/not-a-checkout'}}}
        message = {'id': 'm1', 'type': 'worker_done', 'payload': {'dispatchId': 'ctx_b', 'outcome': 'succeeded'}}
        state = {}
        with unittest.mock.patch.object(fw, 'log_fleet_watch') as log, redirect_stderr(io.StringIO()):
            lines = fw.bounce_builder_dones(
                [message], [worker], lambda _repo, _number: '## Acceptance\n- [ ] open\n',
                lambda terminal, text: sent.append((terminal, text)), state, config,
            )
        return lines, sent, state, log

    def worker(self, **changes):
        row = {
            'dispatchId': 'ctx_b', 'terminal': 'term_b', 'githubPullRequestNumber': 8,
            '_task_title': 'fullstack-dev - build the thing',
            'projection': {'role': 'worker', 'workspace': {'id': 'wt::/tmp/not-a-checkout'}},
        }
        row.update(changes)
        return row

    def test_idle_builder_after_worker_done_still_gets_the_bounce(self):
        lines, sent, _state, log = self.bounce(self.worker(workerState='succeeded', terminalState='retained'))
        self.assertEqual([terminal for terminal, _text in sent], ['term_b'])
        log.assert_not_called()

    def test_released_builder_is_not_mailed_and_is_not_retried(self):
        lines, sent, state, log = self.bounce(self.worker(terminalState='released'))
        self.assertEqual(sent, [])
        self.assertEqual(log.call_count, 1)
        self.assertEqual(state['bounced_done'], ['m1'])


if __name__ == '__main__':
    unittest.main()
