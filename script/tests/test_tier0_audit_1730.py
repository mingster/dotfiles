"""#1730: the weekly audit picks 5 random tier 0 PRs merged in the past week, starts a verifier for each, and the report lists results."""
import importlib.util
import os
import random
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location('fleet_watch', HERE.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)
aspec = importlib.util.spec_from_file_location('tier0_audit', HERE.parent / 'tier0-audit.py')
ta = importlib.util.module_from_spec(aspec)
aspec.loader.exec_module(ta)

REPO = 'o/r'
NOW = 1_700_000_000.0  # 2023-11-14
PICK = lambda _role, **_kw: {'selected': {'provider': 'cursor', 'model': 'm', 'eligible': True}}  # noqa: E731
TEST_FILES = [{'path': 'script/tests/test_x.py', 'additions': 20, 'deletions': 0}]
CODE = [{'path': 'script/x.py', 'additions': 300, 'deletions': 5}]


def merged(number, files):
    return {'number': number, 'title': 't', 'headRefName': 'b%d' % number, 'files': files,
            'mergeCommit': {'oid': ('%x' % number).rjust(40, '0')},
            'body': 'Builder: agent=claude model=sonnet'}


def config(root):
    return {
        'issue_scan': {'enabled': True, 'repos': [REPO], 'run': 'run_x', 'from_terminal': 'term', 'repo_roots': {REPO: root}},
        'babysit': {'repos': [REPO], 'startup': '/bin/true'},
    }


class Pick(unittest.TestCase):
    def test_picks_only_tier_0_and_at_most_five(self):
        prs = [merged(n, TEST_FILES) for n in range(1, 10)] + [merged(n, CODE) for n in range(20, 30)]
        picked = ta.pick(prs, fw.pr_tier, rng=random.Random(1))
        self.assertEqual(len(picked), 5)
        self.assertTrue(all(p['number'] < 10 for p in picked))
        self.assertEqual([p['number'] for p in picked], sorted(p['number'] for p in picked))

    def test_fewer_than_five_picks_all(self):
        picked = ta.pick([merged(1, TEST_FILES), merged(2, CODE)], fw.pr_tier)
        self.assertEqual([p['number'] for p in picked], [1])

    def test_pick_is_random_not_the_first_five(self):
        prs = [merged(n, TEST_FILES) for n in range(1, 40)]
        sets = {tuple(p['number'] for p in ta.pick(prs, fw.pr_tier, rng=random.Random(seed))) for seed in range(6)}
        self.assertGreater(len(sets), 1)


class AuditPass(unittest.TestCase):
    def run_pass(self, state, prs, root, log, **kw):
        starts = []

        def start(command):
            starts.append(command)
            return fw.BabysitStartResult(0)

        lines, bits = fw.tier0_audit_pass(
            config(root), state, kw.pop('now', NOW), [], merged_fetch=lambda _repo, _now: prs, start_worker=start,
            pick=PICK, rng=random.Random(3), log_file=log, **kw)
        return starts, lines, bits

    def test_starts_one_audit_per_picked_pr_and_logs_them(self):
        prs = [merged(n, TEST_FILES) for n in range(1, 9)] + [merged(50, CODE)]
        with tempfile.TemporaryDirectory() as root:
            log = os.path.join(root, 'audit.tsv')
            starts, lines, _bits = self.run_pass({}, prs, root, log)
            self.assertEqual(len(starts), 5, lines)
            rows = Path(log).read_text().splitlines()
            self.assertEqual(len(rows), 5)
            self.assertTrue(all(r.split('\t')[1] == REPO for r in rows))
            self.assertNotIn('#50', ' '.join(lines))

    def test_runs_once_per_week(self):
        prs = [merged(n, TEST_FILES) for n in range(1, 9)]
        with tempfile.TemporaryDirectory() as root:
            log = os.path.join(root, 'audit.tsv')
            state = {}
            first, _l, _b = self.run_pass(state, prs, root, log)
            again, _l, _b = self.run_pass(state, prs, root, log, now=NOW + 86400)
            next_week, _l, _b = self.run_pass(state, prs, root, log, now=NOW + 8 * 86400)
        self.assertEqual((len(first), len(again), len(next_week)), (5, 0, 5))

    def test_audit_worker_is_never_taken_for_a_verifier_of_the_merged_pr(self):
        prs = [merged(7, TEST_FILES)]
        with tempfile.TemporaryDirectory() as root:
            starts, _lines, _bits = self.run_pass({}, prs, root, os.path.join(root, 'a.tsv'))
        command = starts[0]
        title = command[command.index('--title') + 1]
        name = command[command.index('--name') + 1]
        worker = {'dispatchId': 'ctx_a', '_task_title': title, 'name': name, 'workerState': 'ready',
                  'dispatchStatus': 'dispatched', 'terminalState': 'active',
                  'projection': {'workspace': {'id': 'wt::/tmp/audit-7'}, 'liveness': {'verdict': 'live'}}}
        self.assertEqual(fw.verifier_title_prs(worker), [])
        self.assertFalse(fw._worker_titled_verifier(worker))
        self.assertIsNone(fw.live_verifier_worker({'number': 7, 'headRefName': 'b7'}, [worker]))

    def test_brief_is_an_audit_not_a_merge_or_a_verdict(self):
        spec_path = fw.build_tier0_audit_spec(REPO, merged(7, TEST_FILES))
        text = Path(spec_path).read_text()
        self.assertIn('Audit: PASS merged=', text)
        self.assertIn('Never post a "Verdict:" line', text)
        self.assertNotIn('--ship', text)
        self.assertNotIn('open PR', text)

    def test_fetch_failure_does_not_mark_the_week_done(self):
        with tempfile.TemporaryDirectory() as root:
            state = {}
            lines, bits = fw.tier0_audit_pass(config(root), state, NOW, [], merged_fetch=lambda _r, _n: None,
                                              start_worker=lambda _c: fw.BabysitStartResult(0), pick=PICK,
                                              log_file=os.path.join(root, 'a.tsv'))
        self.assertEqual(state.get('tier0_audit'), {})
        self.assertIn('tier0_audit_fetch_fail=%s' % REPO, bits)


class Report(unittest.TestCase):
    def test_report_lists_pass_fail_pending_and_the_fail_rate(self):
        sha = lambda n: ('%x' % n).rjust(40, '0')  # noqa: E731
        with tempfile.TemporaryDirectory() as root:
            log = os.path.join(root, 'a.tsv')
            ta.append_log(log, '2023-W46', REPO, [merged(1, TEST_FILES), merged(2, TEST_FILES), merged(3, TEST_FILES)], now=NOW)
            comments = {
                1: [{'body': 'Audit: PASS merged=%s\nok' % sha(1)}],
                2: [{'body': 'Audit: FAIL merged=%s\ntautology' % sha(2)}],
                3: [{'body': 'Verdict: PASS head=%s verifier=a author=b' % sha(3)}],
            }
            text = ta.report(REPO, log, 14, fetch=lambda _repo, n: comments[n], now=NOW + 3600)
        self.assertIn('3 picked, 1 PASS, 1 FAIL, 1 pending', text)
        self.assertIn('#2 FAIL', text)
        self.assertIn('FAIL rate: 50%', text)
        self.assertIn('over the bar', text)

    def test_an_edited_audit_comment_or_one_for_another_commit_does_not_count(self):
        sha = ('%x' % 1).rjust(40, '0')
        self.assertEqual(ta.audit_result([{'body': 'Audit: PASS merged=%s' % sha, 'includesCreatedEdit': True}], sha), 'pending')
        self.assertEqual(ta.audit_result([{'body': 'Audit: PASS merged=%s' % ('f' * 40)}], sha), 'pending')

    def test_empty_log_says_so(self):
        with tempfile.TemporaryDirectory() as root:
            text = ta.report(REPO, os.path.join(root, 'none.tsv'), 14, fetch=lambda *_a: [], now=time.time())
        self.assertIn('no PR picked', text)


if __name__ == '__main__':
    unittest.main()
