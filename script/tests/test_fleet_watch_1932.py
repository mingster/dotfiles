"""#1932: a verifier that was stopped, failed or disappeared with no Verdict is replaced once, then parked."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_park import HEAD, REPO, verifier_pr  # noqa: E402

PICK = lambda _role: {'selected': {'provider': 'cursor', 'model': 'm', 'eligible': True}}  # noqa: E731
OTHER = {'dispatchId': 'ctx_other', 'dispatchStatus': 'completed', 'terminalState': 'released'}


def stopped(did):
    """How a coordinator stop reads: workerState stopped, with dispatchStatus failed."""
    return {'dispatchId': did, 'workerState': 'stopped', 'dispatchStatus': 'failed', 'terminalState': 'released'}


class Harness:
    def __init__(self, root):
        self.starts, self.released, self.state = [], [], {}
        self.config = {
            'issue_scan': {'run': 'run_live', 'from_terminal': 'term_live', 'repo_roots': {REPO: root}},
            'babysit': {'repos': [REPO], 'startup': '/bin/true'},
        }

    def start(self, command):
        self.starts.append(command)
        result = fw.BabysitStartResult(0, '')
        result.dispatch_id = 'ctx_v%d' % len(self.starts)
        return result

    def run(self, workers=(), pr=None):
        return fw.babysit_pass(
            self.config, self.state, list(workers), pr_fetch=lambda _repo: [pr or verifier_pr()],
            start_worker=self.start, pick=PICK, owner_check=lambda _pr: None,
            release_worker=lambda row: self.released.append(row['dispatchId']) or 'closed',
        )


class DeadVerifier(unittest.TestCase):
    def setUp(self):
        gh = patch.object(fw, 'run_gh', return_value=0)
        gh.start()
        self.addCleanup(gh.stop)
        root = tempfile.TemporaryDirectory()
        self.addCleanup(root.cleanup)
        self.h = Harness(root.name)
        self.h.run()
        self.assertEqual(len(self.h.starts), 1)

    def test_stopped_verifier_is_replaced_once_then_parked(self):
        self.h.run([stopped('ctx_v1')])
        self.assertEqual(len(self.h.starts), 2)
        self.assertEqual(self.h.released, ['ctx_v1'])
        notices, _lines, _log = self.h.run([stopped('ctx_v1'), stopped('ctx_v2')])
        self.assertEqual(len(self.h.starts), 2, 'one retry per head')
        self.assertTrue(any('twice' in str(n) for n in notices), notices)
        notices, _lines, _log = self.h.run([stopped('ctx_v1'), stopped('ctx_v2')])
        self.assertEqual((len(self.h.starts), notices), (2, []))

    def test_failed_and_cancelled_rows_are_replaced(self):
        for row in ({'dispatchStatus': 'failed'}, {'dispatchStatus': 'cancelled'}):
            self.setUp()
            self.h.run([dict(row, dispatchId='ctx_v1')])
            self.assertEqual(len(self.h.starts), 2, row)

    def test_gone_verifier_is_replaced_without_a_release(self):
        self.h.run([OTHER])
        self.assertEqual((len(self.h.starts), self.h.released), (2, []))

    def test_empty_worker_list_is_not_proof_of_gone(self):
        self.h.run([])
        self.assertEqual(len(self.h.starts), 1)

    def test_live_or_succeeded_verifier_is_kept(self):
        for row in ({'dispatchStatus': 'dispatched'}, {'dispatchStatus': 'completed', 'workerState': 'succeeded'}):
            self.h.run([dict(row, dispatchId='ctx_v1')])
        self.assertEqual(len(self.h.starts), 1)

    def test_verdict_at_head_means_no_replacement(self):
        pr = verifier_pr()
        pr['comments'].append({'body': 'Verdict: FAIL head=%s' % HEAD})
        self.h.run([stopped('ctx_v1')], pr=pr)
        self.assertEqual(len(self.h.starts), 1)

    def test_hand_dispatched_live_verifier_keeps_the_retry(self):
        hand = {'dispatchId': 'ctx_hand', 'dispatchStatus': 'dispatched', 'terminalState': 'active', 'title': '#7|qa-sdet'}
        self.h.run([stopped('ctx_v1'), hand])
        self.assertEqual(len(self.h.starts), 1)
        self.h.run([stopped('ctx_v1'), stopped('ctx_hand')])
        self.assertEqual(len(self.h.starts), 2)

    def test_pending_stall_restart_is_left_to_the_stall_pass(self):
        self.h.state['own_dispatches']['ctx_v1']['restarted'] = True
        self.h.run([stopped('ctx_v1')])
        self.assertEqual(len(self.h.starts), 1)

    def test_abandoned_exited_and_gone_remote_rows_are_replaced(self):
        for row in ({'dispatchStatus': 'abandoned'}, {'dispatchStatus': 'dispatched', 'liveness': 'exited'},
                    {'dispatchStatus': 'dispatched', fw.GONE_REMOTE_KEY: True}):
            self.setUp()
            self.h.run([dict(row, dispatchId='ctx_v1')])
            self.assertEqual(len(self.h.starts), 2, row)

    def test_done_hold_keeps_the_verifier(self):
        self.h.state['done_hold'] = {'ctx_v1': {'reason': 'path missing'}}
        self.h.run([stopped('ctx_v1')])
        self.assertEqual((len(self.h.starts), self.h.released), (1, []))

    def test_deferred_or_parked_stall_restart_is_left_to_the_stall_pass(self):
        self.h.state['stall_pending_start'] = {'task': {'old_dispatch': 'ctx_v1'}}
        self.h.run([stopped('ctx_v1')])
        self.h.state['stall_pending_start'] = {}
        self.h.state['own_dispatches']['ctx_v1']['parked'] = True
        self.h.run([stopped('ctx_v1')])
        self.assertEqual(len(self.h.starts), 1)

    def test_stopped_stall_restart_parks_the_head(self):
        fw._record_stall_restart(self.h.state, 'ctx_v1', fw.BabysitStartResult(0, '', 'ctx_r'), 0, [], {})
        notices, _lines, _log = self.h.run([stopped('ctx_v1'), stopped('ctx_r')])
        self.assertEqual((len(self.h.starts), self.h.released), (1, ['ctx_r']))
        self.assertTrue(any('twice' in str(n) for n in notices), notices)


if __name__ == '__main__':
    unittest.main()
