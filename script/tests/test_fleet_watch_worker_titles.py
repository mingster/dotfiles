"""Worker titles are "#<issue>|<role>" (owner rule 2026-11-18); parsers still read the old forms."""
import importlib.util
import re
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

REPO = 'acme/app'
NEW_FORM = re.compile(r'^#[0-9]+\|[a-z][a-z-]*$')


def arg(command, flag):
    return command[command.index(flag) + 1]


class EmittedTitles(unittest.TestCase):
    def config(self):
        root = tempfile.mkdtemp()
        return {'issue_scan': {'run': 'run_x', 'from_terminal': 'term_c', 'repo_roots': {REPO: root},
                               'role': 'fullstack-dev'},
                'babysit': {'run': 'run_x', 'from_terminal': 'term_c', 'repo_roots': {REPO: root}}}

    def test_issue_start_title(self):
        command = fw.build_issue_start_command(self.config(), REPO, {'number': 42, 'body': 'x'})
        self.assertEqual(arg(command, '--title'), '#42|fullstack-dev')

    def test_rework_title(self):
        pr = {'number': 9, 'headRefOid': 'a' * 40, 'comments': []}
        command = fw.build_rework_start_command(self.config(), REPO, pr)
        self.assertEqual(arg(command, '--title'), '#9|fullstack-dev')

    def test_sweep_title_matches_the_form(self):
        command = fw.build_backlog_sweep_command(self.config(), REPO, 'architect-pm')
        self.assertRegex(arg(command, '--title'), NEW_FORM)

    def test_verifier_and_fix_titles(self):
        config = self.config()
        pr = {'number': 7, 'headRefName': 'b', 'headRefOid': 'a' * 40}
        verifier = fw.build_babysit_command(config, REPO, pr, 'verifier', 'claude', 'sonnet', None)
        fix = fw.build_babysit_command(config, REPO, pr, 'fix', 'claude', 'sonnet', None)
        self.assertEqual(arg(verifier, '--title'), '#7|qa-sdet')
        self.assertEqual(arg(fix, '--title'), '#7|fullstack-dev')


class ParsedTitles(unittest.TestCase):
    def test_verifier_prs_read_both_forms(self):
        for title, prs in (('#7|qa-sdet', [7]), ('#7|qa-sdet|another try', [7]),('qa-sdet - verify PR #7', [7]), ('qa-sdet verify o/r#7', [7]),
                           ('#7|fullstack-dev', []), ('qa-sdet - verify PRs #7, #8', [7, 8])):
            self.assertEqual(fw.verifier_title_prs({'_task_title': title}), prs, title)

    def test_verifier_prs_read_the_pr_in_the_detail_segment(self):
        for title, prs in (('#1204|qa-sdet|verify PR 1207', [1204, 1207]), ('#1204|qa-sdet|verify PR #1207', [1204, 1207]),
                           ('#1204|qa-sdet|standing', [1204]), ('#1204|fullstack-dev|verify PR 1207', [])):
            self.assertEqual(fw.verifier_title_prs({'_task_title': title}), prs, title)

    def test_verifier_prs_read_title_and_name_keys(self):
        self.assertEqual(fw.verifier_title_prs({'title': '#5|qa-sdet|verify PR 9'}), [5, 9])
        self.assertEqual(fw.verifier_title_prs({'name': 'qa-sdet verify o/r#9'}), [9])

    def test_verifier_prs_read_the_worktree_basename(self):
        for path, prs in (('/w/dotfiles/verify-7', [7]), ('/w/dotfiles/v7', [7]), ('/w/dotfiles/verify-7-b', [7]),
                          ('/w/dotfiles/vd-7', [7]), ('/w/dotfiles/d1222', []), ('/w/dotfiles/verify-standing-x', [])):
            self.assertEqual(fw.verifier_title_prs({'workspace': 'wt::' + path}), prs, path)

    def test_builder_role_reads_both_forms(self):
        self.assertEqual(fw._builder_role({'_task_title': '#42|fullstack-dev'}), 'fullstack-dev')
        self.assertEqual(fw._builder_role({'_task_title': 'fullstack-dev - #42'}), 'fullstack-dev')
        self.assertEqual(fw._builder_role({'_task_title': '#42|fullstack-dev|second try'}), 'fullstack-dev')

    def test_worker_issue_number_reads_both_forms(self):
        self.assertEqual(fw._worker_issue_number({'_task_title': '#42|fullstack-dev'}), 42)
        self.assertEqual(fw._worker_issue_number({'_task_title': 'fullstack-dev - #42'}), 42)
        self.assertEqual(fw._worker_issue_number({'_task_title': '#42|fullstack-dev|second try'}), 42)

    def test_rework_fix_and_verify_workers_are_not_issue_builders(self):
        for name in ('rework-9', 'fix-9', 'verify-9'):
            self.assertIsNone(fw._worker_issue_number({'_task_title': '#9|fullstack-dev', 'name': name}), name)


if __name__ == '__main__':
    unittest.main()
