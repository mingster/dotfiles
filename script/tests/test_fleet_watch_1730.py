"""#1730: fleet-watch tiers. Tier 0 ships on Review PASS plus green Checks with no verifier.
Tier 1 verifiers start first and sit outside the per pass cap. Tier 2 is unchanged."""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

REPO = 'o/r'
NOW = 1_700_000_000.0
PICK = lambda _role, **_kw: {'selected': {'provider': 'cursor', 'model': 'm', 'eligible': True}}  # noqa: E731
TEST_FILES = [{'path': 'script/tests/test_x.py', 'additions': 20, 'deletions': 0}]
SMALL_CODE = [{'path': 'script/x.py', 'additions': 10, 'deletions': 5}]
BIG_CODE = [{'path': 'script/x.py', 'additions': 300, 'deletions': 5}]
UI_CODE = [{'path': 'web/Button.tsx', 'additions': 3, 'deletions': 1}]


def pr(number, files, review=True, verdict=False, head=None):
    head = head or ('%x' % number) * 40
    head = head[:40]
    comments = []
    if review:
        comments.append({'body': 'Review: PASS head=%s model=opus' % head})
    if verdict:
        comments.append({'body': 'Verdict: PASS head=%s verifier=ctx_v author=ctx_a' % head})
    return {
        'number': number, 'state': 'OPEN', 'isDraft': False, 'headRefOid': head, 'headRefName': 'b%d' % number,
        'statusCheckRollup': [{'name': 'checks', 'conclusion': 'SUCCESS', 'status': 'COMPLETED'}],
        'comments': comments, 'labels': [], 'mergeable': 'MERGEABLE', 'files': files,
        'body': '## Self-check\n$ bash script/checks-local.sh\nexit 0\nBuilder: agent=claude model=sonnet',
    }


class Classify(unittest.TestCase):
    def test_tier_0_with_review_pass_is_ready_without_a_verdict(self):
        self.assertEqual(fw.classify_open_pr(pr(1, TEST_FILES)), 'ready')

    def test_tier_0_without_review_pass_waits(self):
        self.assertEqual(fw.classify_open_pr(pr(1, TEST_FILES, review=False)), 'waiting')

    def test_tier_2_with_review_pass_but_no_verdict_still_waits(self):
        self.assertEqual(fw.classify_open_pr(pr(1, BIG_CODE)), 'waiting')
        self.assertEqual(fw.classify_open_pr(pr(1, SMALL_CODE)), 'waiting')

    def test_a_tier_0_pr_with_red_checks_is_not_ready(self):
        row = pr(1, TEST_FILES)
        row['statusCheckRollup'] = [{'name': 'checks', 'conclusion': 'FAILURE', 'status': 'COMPLETED'}]
        self.assertNotEqual(fw.classify_open_pr(row), 'ready')

    def test_a_pr_row_without_files_is_tier_2(self):
        row = pr(1, None)
        row.pop('files')
        self.assertEqual(fw.pr_tier(row), 2)
        self.assertEqual(fw.classify_open_pr(row), 'waiting')


def scan_config(root):
    return {
        'issue_scan': {'enabled': True, 'repos': [REPO], 'run': 'run_x', 'from_terminal': 'term', 'host': 'local',
                       'agent': 'cursor', 'model': 'm', 'repo_roots': {REPO: root}},
        'host_caps': {'local': 4},
        'babysit': {'repos': [REPO], 'startup': '/bin/true', 'per_pass_cap': 2},
    }


class AutoShip(unittest.TestCase):
    def scan(self, rows, state):
        starts = []
        _n, log = fw.issue_scan_pass(
            scan_config('/tmp/app'), state, NOW, [], list_issues=lambda _r: [], pr_fetch=lambda _r: rows,
            gate_check=lambda _c: True, admit_fn=lambda _h, _c, _w: {'admitted': True, 'occupied': 0},
            start_worker=lambda cmd: (starts.append(cmd), 0)[1],
        )
        return starts, log

    def test_tier_0_ships_at_once_on_review_pass(self):
        row = pr(1, TEST_FILES)
        starts, log = self.scan([row], {'issue_scan_backlog_sweep_at': NOW})
        self.assertIn('ship_start=%s' % row['headRefOid'][:8], log)
        self.assertEqual(len(starts), 1)

    def test_tier_2_without_a_verdict_does_not_ship(self):
        starts, log = self.scan([pr(2, BIG_CODE)], {'issue_scan_backlog_sweep_at': NOW})
        self.assertEqual(starts, [])
        self.assertFalse([b for b in log if b.startswith('ship_start')])


class Babysit(unittest.TestCase):
    def run_pass(self, rows, state=None, cap=2, dry_run=False):
        starts = []
        with tempfile.TemporaryDirectory() as root:
            config = scan_config(root)
            config['babysit']['per_pass_cap'] = cap
            _n, lines, _log = fw.babysit_pass(
                config, {} if state is None else state, [], pr_fetch=lambda _r: rows,
                start_worker=lambda cmd: (starts.append(cmd), fw.BabysitStartResult(0))[1],
                pick=PICK, owner_check=lambda _pr, **_kw: None, dry_run=dry_run,
            )
        return starts, lines

    def verifier_prs(self, lines):
        return [int(l.split('#')[1].split()[0]) for l in lines if ' action=verifier' in l]

    def test_tier_0_with_review_pass_starts_no_verifier(self):
        starts, lines = self.run_pass([pr(1, TEST_FILES)])
        self.assertEqual(starts, [], lines)
        self.assertTrue(any('tier0-ship' in l for l in lines), lines)

    def test_tier_0_falls_back_to_a_verifier_once_the_auto_ship_tried_this_head(self):
        row = pr(1, TEST_FILES)
        state = {'issue_scan_ship': {REPO: {row['headRefOid']: True}}}
        starts, lines = self.run_pass([row], state=state)
        self.assertEqual(len(starts), 1, lines)

    def test_tier_0_gets_a_verifier_when_fleet_watch_does_not_auto_ship_the_repo(self):
        row = pr(1, TEST_FILES)
        starts = []
        with tempfile.TemporaryDirectory() as root:
            config = scan_config(root)
            config['issue_scan']['enabled'] = False
            fw.babysit_pass(
                config, {}, [], pr_fetch=lambda _r: [row],
                start_worker=lambda cmd: (starts.append(cmd), fw.BabysitStartResult(0))[1],
                pick=PICK, owner_check=lambda _pr, **_kw: None,
            )
        self.assertEqual(len(starts), 1)

    def test_tier_0_without_review_pass_is_not_special(self):
        starts, _lines = self.run_pass([pr(1, TEST_FILES, review=False)])
        self.assertEqual(starts, [])  # the review gate holds it exactly as before

    def test_tier_1_verifier_does_not_count_against_the_cap(self):
        rows = [pr(1, SMALL_CODE), pr(2, SMALL_CODE), pr(3, SMALL_CODE), pr(4, BIG_CODE), pr(5, BIG_CODE)]
        starts, lines = self.run_pass(rows, cap=2)
        self.assertEqual(self.verifier_prs(lines), [1, 2, 3, 4, 5], lines)
        self.assertEqual(len(starts), 5)

    def test_tier_1_does_not_use_up_the_cap_for_tier_2(self):
        rows = [pr(1, SMALL_CODE), pr(2, SMALL_CODE), pr(3, BIG_CODE), pr(4, BIG_CODE), pr(5, BIG_CODE)]
        _starts, lines = self.run_pass(rows, cap=2, dry_run=True)
        self.assertEqual(self.verifier_prs(lines), [1, 2, 3, 4], lines)
        self.assertTrue(any('#5 ' in l and 'cap' in l for l in lines), lines)

    def test_tier_1_starts_before_a_lower_numbered_tier_2(self):
        rows = [pr(1, BIG_CODE), pr(2, BIG_CODE), pr(3, SMALL_CODE)]
        _starts, lines = self.run_pass(rows, cap=1, dry_run=True)
        self.assertEqual(self.verifier_prs(lines), [3, 1], lines)

    def test_ui_file_is_tier_2_and_counts_against_the_cap(self):
        rows = [pr(1, UI_CODE), pr(2, UI_CODE), pr(3, UI_CODE)]
        _starts, lines = self.run_pass(rows, cap=2, dry_run=True)
        self.assertEqual(self.verifier_prs(lines), [1, 2], lines)

    def test_tier_2_is_unchanged(self):
        rows = [pr(1, BIG_CODE), pr(2, BIG_CODE), pr(3, BIG_CODE)]
        starts, lines = self.run_pass(rows, cap=2)
        self.assertEqual(self.verifier_prs(lines), [1, 2], lines)
        self.assertEqual(len(starts), 2)
        self.assertTrue(any('#3 ' in l and 'cap' in l for l in lines), lines)


if __name__ == '__main__':
    unittest.main()
