"""Owner rule 2026-11-20: dotfiles issues go to the front of the issue_scan queue."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)


def row(number, labels, created='2026-01-01T00:00:00Z'):
    return {'number': number, 'labels': [{'name': n} for n in labels], 'createdAt': created}


class DotfilesFirst(unittest.TestCase):
    def test_dotfiles_p3_beats_other_repo_p0(self):
        pairs = [
            ('owner/app', row(1, ('ready-for-agent', 'P0'))),
            ('owner/dotfiles', row(2, ('ready-for-agent', 'P3'))),
            ('owner/app', row(3, ('ready-for-agent', 'P2'))),
            ('owner/dotfiles', row(4, ('ready-for-agent', 'P1'))),
        ]
        pairs.sort(key=lambda pair: fw.issue_scan_queue_key(*pair))
        self.assertEqual([p[1]['number'] for p in pairs], [4, 2, 1, 3])

    def test_name_must_match_whole_repo_name(self):
        self.assertEqual(fw.issue_scan_queue_key('owner/my-dotfiles', row(1, ()))[0], 1)


if __name__ == '__main__':
    unittest.main()
