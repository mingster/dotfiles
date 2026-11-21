"""fleet-watch tells the coordinator a PM "needs owner" issue is already answered (#1298)."""
import importlib.util
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('fleet_watch_1298', ROOT / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

WORKER = {
    'dispatchId': 'ctx_p', 'terminal': 'term_p',
    '_task_title': 'architect-pm - triage',
    'projection': {'role': 'worker', 'workspace': {'id': 'wt::/tmp/not-a-checkout'}},
}
CONFIG = {'issue_scan': {'repo_roots': {'o/r': '/tmp/not-a-checkout'}}}


def message(body, mid='m1'):
    return {'id': mid, 'type': 'worker_done', 'body': body,
            'payload': {'dispatchId': 'ctx_p', 'outcome': 'succeeded'}}


class AnsweredOwnerAsks(unittest.TestCase):
    def run_check(self, messages, rc=0, worker=WORKER, state=None):
        calls = []

        def fake(cmd, **_kw):
            calls.append(cmd[1:])
            return types.SimpleNamespace(returncode=rc, stdout='#7: Owner decision: use A.\n', stderr='')

        state = {} if state is None else state
        lines = fw.answered_owner_asks(messages, [worker], state, CONFIG, run=fake)
        return lines, calls, state

    def test_answered_issue_is_reported_as_already_answered(self):
        lines, calls, _ = self.run_check([message('Issue #7 needs owner: pick A or B.')])
        self.assertEqual(calls, [['o/r', '7']])
        self.assertEqual(len(lines), 1)
        self.assertIn('already answered', lines[0])
        self.assertIn('o/r#7', lines[0])

    def test_unanswered_issue_stays_silent(self):
        lines, calls, _ = self.run_check([message('Issue #7 needs owner.')], rc=1)
        self.assertEqual(len(calls), 1)
        self.assertEqual(lines, [])

    def test_message_without_needs_owner_is_not_checked(self):
        lines, calls, _ = self.run_check([message('Triaged #7, ready-for-agent.')])
        self.assertEqual((lines, calls), ([], []))

    def test_non_pm_worker_is_not_checked(self):
        builder = dict(WORKER, _task_title='fullstack-dev - build')
        lines, calls, _ = self.run_check([message('#7 needs owner')], worker=builder)
        self.assertEqual((lines, calls), ([], []))

    def test_same_message_is_told_once(self):
        state = {}
        first, _, state = self.run_check([message('#7 needs owner')], state=state)
        second, calls, _ = self.run_check([message('#7 needs owner')], state=state)
        self.assertEqual(len(first), 1)
        self.assertEqual((second, calls), ([], []))


if __name__ == '__main__':
    unittest.main()
