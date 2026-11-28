"""#1692: issue_scan skips an issue with a live dispatch titled '#<n>|', whatever its labels say."""
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
from test_fleet_watch_1216 import fw, row, run_pass


def live_worker(title):
    return {'_task_title': title, 'status': 'running'}


class LiveDispatchSkipsIssue(unittest.TestCase):
    def test_live_dispatch_blocks_a_ready_issue(self):
        with patch.object(fw, 'worker_row_is_live', return_value=True):
            starts, edits, bits, _st = run_pass([row(5)], workers=[live_worker('#5|fullstack-dev')])
        self.assertEqual(starts, [])
        self.assertEqual(edits, [])
        self.assertIn('issue_live=5', bits)

    def test_live_dispatch_blocks_an_issue_without_ready_for_agent(self):
        with patch.object(fw, 'worker_row_is_live', return_value=True):
            starts, _edits, bits, _st = run_pass(
                [row(5, ('P2',))], workers=[live_worker('#5|fullstack-dev-small')])
        self.assertEqual(starts, [])
        self.assertIn('issue_live=5', bits)

    def test_any_role_or_suffix_after_the_number_blocks(self):
        for title in ('#5|qa-sdet', '#5|architect-pm', '#5|fullstack-dev|retry'):
            with patch.object(fw, 'worker_row_is_live', return_value=True):
                starts, *_ = run_pass([row(5, ('P2',))], workers=[live_worker(title)])
            self.assertEqual(starts, [], title)

    def test_a_finished_dispatch_does_not_block(self):
        with patch.object(fw, 'worker_row_is_live', return_value=False):
            starts, *_ = run_pass([row(5)], workers=[live_worker('#5|fullstack-dev')])
        self.assertEqual(len(starts), 1)

    def test_a_longer_number_does_not_block(self):
        with patch.object(fw, 'worker_row_is_live', return_value=True):
            starts, *_ = run_pass([row(5)], workers=[live_worker('#55|fullstack-dev')])
        self.assertEqual(len(starts), 1)

    def test_a_title_without_the_bar_does_not_block(self):
        with patch.object(fw, 'worker_row_is_live', return_value=True):
            starts, *_ = run_pass([row(5)], workers=[live_worker('builder - #5')])
        self.assertEqual(len(starts), 1)


if __name__ == '__main__':
    unittest.main()
