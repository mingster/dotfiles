"""#1730: the weekly audit picks 5 random tier 0 PRs merged in the past week, files one issue for them, and the report lists results."""
import importlib.util
import os
import random
import re
import subprocess
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
_env_spec = importlib.util.spec_from_file_location('fleet_watch_test_env', HERE / 'fleet_watch_test_env.py')
_env = importlib.util.module_from_spec(_env_spec)
_env_spec.loader.exec_module(_env)

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
    def run_pass(self, state, prs, log, existing=False, created=None, **kw):
        """Run the pass with fake gh. `created` collects (repo, title, body); the issue number is 99 unless `create` is given."""
        created = [] if created is None else created

        def create(repo, title, body):
            created.append((repo, title, body))
            return 99

        lines, bits = fw.tier0_audit_pass(
            config('/tmp/app'), state, kw.pop('now', NOW), merged_fetch=lambda _repo, _now: prs,
            find_issue=kw.pop('find_issue', lambda _repo, _title: 7 if existing else 0),
            create_issue=kw.pop('create_issue', create), rng=random.Random(3), log_file=log, **kw)
        return created, lines, bits

    def test_files_one_issue_for_five_tier_0_prs_and_logs_them(self):
        prs = [merged(n, TEST_FILES) for n in range(1, 9)] + [merged(50, CODE)]
        with tempfile.TemporaryDirectory() as root:
            log = os.path.join(root, 'audit.tsv')
            created, lines, _bits = self.run_pass({}, prs, log)
            rows = Path(log).read_text().splitlines()
        self.assertEqual(len(created), 1, lines)
        self.assertEqual(created[0][:2], (REPO, 'tier 0 audit 2023-W46'))
        self.assertEqual(len(rows), 5)
        self.assertTrue(all(r.split('\t')[1] == REPO for r in rows))
        self.assertNotIn('#50', created[0][2])
        self.assertEqual(len(re.findall(r'^- #\d+ ', created[0][2], re.M)), 5)


    def test_default_create_is_labelled_ready_for_agent_and_routed_to_qa(self):
        seen = []

        def gh(cmd, **_kw):
            seen.append(cmd)
            return type('R', (), {'stdout': 'https://x/issues/5\n'})()

        real = fw.main_red_create_issue
        fw.main_red_create_issue = lambda repo, t, body, run=None, labels=None: real(repo, t, body, run=gh, labels=labels)
        try:
            with tempfile.TemporaryDirectory() as root:
                fw.tier0_audit_pass(config('/tmp/app'), {}, NOW, merged_fetch=lambda *_a: [merged(1, TEST_FILES)],
                                    find_issue=lambda *_a: 0, log_file=os.path.join(root, 'a.tsv'))
        finally:
            fw.main_red_create_issue = real
        self.assertIn('role:qa', seen[0])
        self.assertIn('ready-for-agent', seen[0])
        labels = [seen[0][i + 1] for i, a in enumerate(seen[0]) if a == '--label']
        self.assertEqual(fw.issue_scan_route({'labels': [{'name': n} for n in labels]})[0], 'qa-sdet')

    def test_picks_are_deduped_against_earlier_weeks(self):
        prs = [merged(n, TEST_FILES) for n in range(1, 9)]
        with tempfile.TemporaryDirectory() as root:
            log = os.path.join(root, 'audit.tsv')
            state = {}
            first, _l, _b = self.run_pass(state, prs, log)
            second, _l, _b = self.run_pass(state, prs, log, now=NOW + 8 * 86400)
        listed = lambda body: {int(n) for n in re.findall(r'^- #(\d+) ', body, re.M)}  # noqa: E731
        self.assertEqual(len(listed(first[0][2])), 5)
        self.assertEqual(len(listed(second[0][2])), 3)  # only the 3 never listed
        self.assertFalse(listed(first[0][2]) & listed(second[0][2]))
        self.assertEqual(second[0][1], 'tier 0 audit 2023-W47')

    def test_another_repos_log_rows_do_not_block_a_pr(self):
        with tempfile.TemporaryDirectory() as root:
            log = os.path.join(root, 'audit.tsv')
            ta.append_log(log, '2023-W40', 'other/repo', [merged(1, TEST_FILES)], now=NOW)
            created, _l, _b = self.run_pass({}, [merged(1, TEST_FILES)], log)
        self.assertEqual(len(created), 1)

    def test_runs_once_per_week(self):
        prs = [merged(n, TEST_FILES) for n in range(1, 9)]
        with tempfile.TemporaryDirectory() as root:
            log = os.path.join(root, 'audit.tsv')
            state = {}
            self.run_pass(state, prs, log)
            again, _l, _b = self.run_pass(state, prs, log, now=NOW + 86400)
        self.assertEqual(again, [])

    def test_an_existing_issue_with_the_title_files_nothing_and_logs_nothing(self):
        asked = []
        with tempfile.TemporaryDirectory() as root:
            log = os.path.join(root, 'audit.tsv')
            created, lines, _bits = self.run_pass(
                {}, [merged(1, TEST_FILES)], log, existing=True,
                find_issue=lambda repo, title: (asked.append((repo, title)), 7)[1])
            self.assertFalse(Path(log).exists())
        self.assertEqual(created, [])
        self.assertEqual(asked, [(REPO, 'tier 0 audit 2023-W46')])
        self.assertIn('issue-exists', ' '.join(lines))

    def test_the_issue_lookup_includes_closed_issues_and_tells_an_error_from_no_issue(self):
        seen = []
        ok = lambda out: (lambda cmd, **_k: (seen.append(cmd), type('R', (), {'stdout': out})())[1])  # noqa: E731
        self.assertEqual(fw.tier0_audit_find_issue(REPO, 't', run=ok('[]')), 0)
        self.assertEqual(seen[0][seen[0].index('--state') + 1], 'all')
        self.assertEqual(fw.tier0_audit_find_issue(REPO, 't', run=ok('[{"number": 4, "title": "t"}]')), 4)

        def boom(*_a, **_k):
            raise subprocess.SubprocessError('502')
        self.assertIsNone(fw.tier0_audit_find_issue(REPO, 't', run=boom))

    def test_a_failed_issue_lookup_files_nothing_and_leaves_the_week_open(self):
        state = {}
        with tempfile.TemporaryDirectory() as root:
            log = os.path.join(root, 'audit.tsv')
            created, lines, bits = self.run_pass(state, [merged(1, TEST_FILES)], log, find_issue=lambda *_a: None)
            self.assertFalse(Path(log).exists())
        self.assertEqual(created, [])
        self.assertNotIn(REPO, state['tier0_audit'])
        self.assertIn('tier0_audit_lookup_fail=%s' % REPO, bits)

    def test_a_failed_log_write_files_no_issue_and_leaves_the_week_open(self):
        state = {}
        with tempfile.TemporaryDirectory() as root:
            log = os.path.join(root, 'audit.tsv')
            os.mkdir(log)  # opening a directory for append raises OSError
            created, _l, bits = self.run_pass(state, [merged(1, TEST_FILES)], log)
        self.assertEqual(created, [])
        self.assertNotIn(REPO, state['tier0_audit'])
        self.assertIn('tier0_audit_log_fail=%s' % REPO, bits)

    def test_no_tier_0_pr_files_nothing(self):
        with tempfile.TemporaryDirectory() as root:
            log = os.path.join(root, 'audit.tsv')
            created, lines, _bits = self.run_pass({}, [merged(9, CODE)], log)
            self.assertFalse(Path(log).exists())
        self.assertEqual(created, [])
        self.assertIn('no-tier-0-pr', ' '.join(lines))

    def test_no_merged_pr_at_all_files_nothing(self):
        with tempfile.TemporaryDirectory() as root:
            created, _l, _b = self.run_pass({}, [], os.path.join(root, 'audit.tsv'))
        self.assertEqual(created, [])

    def test_issue_body_lists_each_pr_with_its_merge_commit_and_an_acceptance_for_the_verifier(self):
        prs = [merged(7, TEST_FILES), merged(12, TEST_FILES)]
        body = fw.tier0_audit_issue_body(prs, REPO)
        for pr in prs:
            self.assertIn('- #%d `%s`' % (pr['number'], pr['mergeCommit']['oid']), body)
        self.assertIn('## Acceptance', body)
        self.assertIn('Audit: PASS merged=<merge commit>', body)
        self.assertIn('Audit: FAIL merged=<merge commit>', body)
        self.assertIn('Never a `Verdict:` line', body)
        self.assertIn('## Out of scope', body)
        self.assertIn('python3 ~/dotfiles/script/tier0-audit.py report --repo %s' % REPO, body)
        self.assertNotIn('<owner/name>', body)

    def test_a_failed_issue_create_does_not_mark_the_week_done_or_log_the_prs(self):
        prs = [merged(1, TEST_FILES)]
        with tempfile.TemporaryDirectory() as root:
            log = os.path.join(root, 'audit.tsv')
            state = {}
            _c, lines, bits = self.run_pass(state, prs, log, create_issue=lambda *_a: None)
            self.assertEqual(Path(log).read_text(), '')  # no row without its issue
            self.assertNotIn(REPO, state['tier0_audit'])
            retried, _l, _b = self.run_pass(state, prs, log, now=NOW + 600)  # the next pass tries again
        self.assertIn('tier0_audit_issue_fail=%s' % REPO, bits)
        self.assertEqual(len(retried), 1)
        self.assertEqual(state['tier0_audit'][REPO], '2023-W46')

    def test_fetch_failure_does_not_mark_the_week_done(self):
        with tempfile.TemporaryDirectory() as root:
            state = {}
            lines, bits = fw.tier0_audit_pass(config('/tmp/app'), state, NOW, merged_fetch=lambda _r, _n: None,
                                              find_issue=lambda *_a: 0, create_issue=lambda *_a: 1,
                                              log_file=os.path.join(root, 'a.tsv'))
        self.assertEqual(state.get('tier0_audit'), {})
        self.assertIn('tier0_audit_fetch_fail=%s' % REPO, bits)

    def test_a_skipped_run_does_not_mark_the_week_done(self):
        # babysit.tier0_audit false: the pass does nothing, so the week is not recorded
        cfg = config('/tmp/app')
        cfg['babysit']['tier0_audit'] = False
        state = {}
        lines, bits = fw.tier0_audit_pass(cfg, state, NOW, merged_fetch=lambda *_a: self.fail('fetched'),
                                          find_issue=lambda *_a: 0, create_issue=lambda *_a: 1)
        self.assertEqual((lines, bits, state), ([], [], {}))


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


class AuditFamily(unittest.TestCase):
    """#1765: the auditor is another model family than the PR builders, or tagged same-family-different-model."""

    def issue(self):
        prs = [merged(1, TEST_FILES), merged(2, TEST_FILES)]
        return {'number': 9, 'title': 'tier 0 audit 2023-W46', 'body': fw.tier0_audit_issue_body(prs, REPO),
                'labels': [{'name': 'role:qa'}, {'name': 'ready-for-agent'}]}

    def pick(self, others):
        calls = []

        def fn(role, avoid_family=None, tier=None):
            calls.append((role, avoid_family))
            sel = {'provider': 'claude', 'model': 'opus', 'eligible': True, 'same_family_fallback': True}
            if others:
                sel = {'provider': 'antigravity', 'model': 'gemini-4-argon-high', 'eligible': True}
            return {'selected': sel, 'candidates': [sel]}
        return fn, calls

    def test_issue_body_carries_the_builder_line_once(self):
        self.assertEqual(self.issue()['body'].count('Builder: agent=claude model=sonnet'), 1)

    def test_claude_built_batch_starts_a_non_claude_auditor(self):
        fn, calls = self.pick(others=True)
        self.assertEqual(fw.tier0_audit_pick(self.issue(), fn), ('antigravity', 'gemini-4-argon-high', ''))
        self.assertEqual(calls, [('qa-sdet', 'claude')])

    def test_no_other_family_starts_the_same_family_with_the_tag(self):
        fn, _calls = self.pick(others=False)
        self.assertEqual(fw.tier0_audit_pick(self.issue(), fn), ('claude', 'opus', 'same-family-different-model'))

    def test_brief_tells_the_auditor_to_tag_without_asking(self):
        with tempfile.TemporaryDirectory() as root:
            cfg = config(root)
            cfg['issue_scan']['startup'] = '/bin/true'
            os.makedirs(os.path.join(root, 'script'), exist_ok=True)
            tagged = fw.build_issue_start_command(cfg, REPO, self.issue(), None, ('qa-sdet', 'claude', 'opus', 'same-family-different-model'))
            plain = fw.build_issue_start_command(cfg, REPO, self.issue(), None, ('qa-sdet', 'antigravity', 'g', ''))
        self.assertIn('same-family-different-model', Path(tagged[tagged.index('--spec') + 1]).read_text())
        self.assertNotIn('same-family-different-model', Path(plain[plain.index('--spec') + 1]).read_text())


if __name__ == '__main__':
    unittest.main()
