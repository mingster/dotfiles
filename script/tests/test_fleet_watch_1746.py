"""#1746: an open "red gate: <tool>" issue goes to the front of the issue scan queue, like a red main fix."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)


def row(number, title, labels=('ready-for-agent', 'P1'), created='2026-01-01T00:00:00Z'):
    return {'number': number, 'title': title, 'labels': [{'name': n} for n in labels], 'createdAt': created}


class RedGateFirst(unittest.TestCase):
    def test_red_gate_fix_starts_ahead_of_other_work_in_any_repo(self):
        pairs = [
            ('owner/dotfiles', row(1, 'feat: something', ('ready-for-agent', 'P0'))),
            ('owner/app', row(2, 'red gate: shared-db')),
            ('owner/dotfiles', row(3, 'chore: tidy', ('ready-for-agent', 'P2'))),
        ]
        pairs.sort(key=lambda pair: fw.issue_scan_queue_key(*pair))
        self.assertEqual([p[1]['number'] for p in pairs], [2, 1, 3])

    def test_red_gate_and_red_main_share_the_front(self):
        pairs = [
            ('owner/app', row(5, 'red gate: run-scoped-tests', created='2026-01-02T00:00:00Z')),
            ('owner/app', row(4, 'main red: 99', created='2026-01-01T00:00:00Z')),
            ('owner/app', row(6, 'ordinary', ('ready-for-agent', 'P0'))),
        ]
        pairs.sort(key=lambda pair: fw.issue_scan_queue_key(*pair))
        self.assertEqual([p[1]['number'] for p in pairs], [4, 5, 6])

    def test_only_the_exact_prefix_counts(self):
        self.assertEqual(fw.issue_scan_queue_key('owner/app', row(7, 'fix the red gate: thing'))[0], 1)


if __name__ == '__main__':
    unittest.main()
