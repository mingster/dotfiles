"""Owner rule 2026-11-20: dotfiles issues go to the front of the issue_scan queue."""
import sys
import importlib.util
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)


def row(number, labels, created='2026-01-01T00:00:00Z'):
    return {'number': number, 'body': '## Acceptance\n- [ ] done', 'labels': [{'name': n} for n in labels], 'createdAt': created}


class DotfilesFirst(unittest.TestCase):
    def test_dotfiles_p3_beats_other_repo_p2(self):
        pairs = [
            ('owner/app', row(1, ('ready-for-agent', 'P0'))),
            ('owner/dotfiles', row(2, ('ready-for-agent', 'P3'))),
            ('owner/app', row(3, ('ready-for-agent', 'P2'))),
            ('owner/dotfiles', row(4, ('ready-for-agent', 'P1'))),
        ]
        pairs.sort(key=lambda pair: fw.issue_scan_queue_key(*pair))
        self.assertEqual([p[1]['number'] for p in pairs], [1, 4, 2, 3])

    def test_red_main_then_p0_or_bug_any_repo_then_dotfiles_first(self):
        red = dict(row(9, ('ready-for-agent',)), title=fw.MAIN_RED_TITLE_PREFIX + ' x')
        pairs = [
            ('owner/dotfiles', row(1, ('ready-for-agent', 'P2'))),
            ('owner/app', row(2, ('ready-for-agent', 'P0'))),
            ('owner/dotfiles', row(3, ('ready-for-agent', 'P0'))),
            ('owner/app', row(4, ('ready-for-agent', 'bug'))),
            ('owner/dotfiles', row(5, ('ready-for-agent', 'P1'))),
            ('owner/app', red),
        ]
        pairs.sort(key=lambda pair: fw.issue_scan_queue_key(*pair))
        self.assertEqual([p[1]['number'] for p in pairs], [9, 3, 2, 4, 5, 1])

    def test_bug_label_ranks_p0(self):
        self.assertEqual(fw.issue_scan_priority(row(1, ('ready-for-agent', 'bug'))), 0)
        self.assertEqual(fw.issue_scan_priority(row(1, ('bug', 'P2'))), 0)

    def test_next_issue_uses_queue_key(self):
        listed = {
            'owner/app': [row(2, ('ready-for-agent', 'P0'))],
            'owner/dotfiles': [row(1, ('ready-for-agent', 'P2')), row(3, ('ready-for-agent', 'bug'))],
        }
        repo, issue = fw.next_ready_issue(list(listed), listed.get)
        self.assertEqual((repo, issue['number']), ('owner/dotfiles', 3))
        self.assertIsNone(fw.next_ready_issue(['x/y'], lambda r: []))

    def test_name_must_match_whole_repo_name(self):
        self.assertEqual(fw.issue_scan_queue_key('owner/my-dotfiles', row(1, ()))[2], 1)


if __name__ == '__main__':
    unittest.main()
