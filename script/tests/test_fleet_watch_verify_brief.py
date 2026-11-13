"""Verifier and rework briefs name script/checks-local.sh only when the repo has it."""
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

REPO = 'owner/app'
HEAD = 'a' * 40
ABSENT = 'checks-local.sh does not apply to this repo'
LINT = Path(__file__).parent.parent / 'brief-lint.sh'


def verify_body(text):
    lines = text.splitlines()
    start = lines.index('## Verify') + 1
    end = lines.index('## Finish')
    return '\n'.join(lines[start:end]).strip()


def read_spec(command):
    path = command[command.index('--spec') + 1]
    return Path(path).read_text(encoding='utf-8')


class VerifyBrief(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.present = Path(self.tmp.name) / 'with-checks'
        self.absent = Path(self.tmp.name) / 'without-checks'
        (self.present / 'script').mkdir(parents=True)
        (self.present / 'script' / 'checks-local.sh').write_text('#!/bin/bash\nexit 0\n', encoding='utf-8')
        self.absent.mkdir()

    def config(self, root):
        return {
            'issue_scan': {
                'run': 'run_x',
                'from_terminal': 'term_c',
                'repo_roots': {REPO: str(root)},
            },
        }

    def pr_row(self):
        return {
            'number': 4,
            'headRefOid': HEAD,
            'headRefName': 'mingster/brief',
            'comments': [{'body': 'Checks: FAIL head=%s\nlint broke' % HEAD}],
        }

    def assert_names_the_script(self, text):
        body = verify_body(text)
        self.assertIn('bash script/checks-local.sh', body)
        self.assertNotIn(ABSENT, text)
        self.assertEqual(subprocess.run(['bash', str(LINT), self._write(text)], capture_output=True, text=True).returncode, 0)

    def assert_names_nothing_else(self, text):
        body = verify_body(text)
        self.assertEqual(body, ABSENT)
        self.assertNotIn('script/checks-local.sh', text)
        self.assertNotIn('bash ', body)
        lint = subprocess.run(['bash', str(LINT), self._write(text)], capture_output=True, text=True)
        self.assertEqual(lint.returncode, 0, lint.stdout + lint.stderr)

    def _write(self, text):
        path = Path(self.tmp.name) / 'brief.md'
        path.write_text(text, encoding='utf-8')
        return str(path)

    def test_verifier_names_checks_local_only_when_the_repo_has_it(self):
        row = {'number': 4, 'headRefOid': HEAD}
        present = Path(fw.build_babysit_spec(REPO, row, 'verifier', ('claude', 'opus'), str(self.present))).read_text(encoding='utf-8')
        absent = Path(fw.build_babysit_spec(REPO, row, 'verifier', ('claude', 'opus'), str(self.absent))).read_text(encoding='utf-8')
        self.assert_names_the_script(present)
        self.assert_names_nothing_else(absent)

    def test_babysit_rework_names_checks_local_only_when_the_repo_has_it(self):
        row = {'number': 4, 'headRefOid': HEAD}
        present = Path(fw.build_babysit_spec(REPO, row, 'rework', None, str(self.present))).read_text(encoding='utf-8')
        absent = Path(fw.build_babysit_spec(REPO, row, 'rework', None, str(self.absent))).read_text(encoding='utf-8')
        self.assert_names_the_script(present)
        self.assert_names_nothing_else(absent)

    def test_rework_command_names_checks_local_only_when_the_repo_has_it(self):
        present = read_spec(fw.build_rework_start_command(self.config(self.present), REPO, self.pr_row()))
        absent = read_spec(fw.build_rework_start_command(self.config(self.absent), REPO, self.pr_row()))
        self.assert_names_the_script(present)
        self.assertIn('lint broke', present)
        self.assert_names_nothing_else(absent)
        self.assertIn('lint broke', absent)
        self.assertNotIn('then the failing check', verify_body(absent))

    def test_rework_excerpt_with_a_percent_sign_still_builds(self):
        row = self.pr_row()
        row['comments'] = [{'body': 'Checks: FAIL head=%s\n100%% of lint broke' % HEAD}]
        text = read_spec(fw.build_rework_start_command(self.config(self.present), REPO, row))
        self.assertIn('100% of lint broke', text)
        self.assertIn('bash script/checks-local.sh', verify_body(text))


if __name__ == '__main__':
    unittest.main()
