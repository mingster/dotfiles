import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

REPO = 'mingster/dotfiles'
HEAD = 'a' * 40
OTHER = 'b' * 40


def pr(number=7, state='OPEN', head=HEAD, comments=(), checks=(), merge=None):
    return {'number': number, 'state': state, 'headRefOid': head, 'comments': list(comments),
            'statusCheckRollup': list(checks), 'mergeCommit': {'oid': merge} if merge else None}


def comment(id, body):
    return {'id': id, 'body': body}


class PrEvents(unittest.TestCase):
    def diff(self, old, prs, now=0):
        return fw.pr_events(REPO, old, prs, now, 600)

    def test_first_pass_records_and_sends_nothing(self):
        prs = [pr(state='MERGED', merge='c' * 40), pr(8, comments=[comment('v1', 'Verdict: PASS head=x')])]
        events, state = self.diff(None, prs)
        self.assertEqual(events, [])
        self.assertEqual(self.diff(state, prs)[0], [])

    def test_merge_names_repo_number_and_sha_once(self):
        _, state = self.diff(None, [pr()])
        merged = [pr(state='MERGED', merge='c' * 40)]
        events, state = self.diff(state, merged)
        self.assertEqual(events, ['merged mingster/dotfiles #7 ' + 'c' * 40])
        self.assertEqual(self.diff(state, merged)[0], [])

    def test_new_verdict_gives_its_first_line_once(self):
        _, state = self.diff(None, [pr()])
        line = 'Verdict: PASS head=%s verifier=ctx_1 author=unknown' % HEAD
        prs = [pr(comments=[comment('v1', line + '\n\nFindings'), comment('c1', 'not a verdict')])]
        events, state = self.diff(state, prs)
        self.assertEqual(events, ['mingster/dotfiles #7 ' + line])
        self.assertEqual(self.diff(state, prs)[0], [])

    def test_failing_pr_is_stuck_once_after_the_limit(self):
        prs = [pr(comments=[comment('k1', 'Checks: FAIL head=' + HEAD)])]
        _, state = self.diff(None, prs, 0)
        events, state = self.diff(state, prs, 599)
        self.assertEqual(events, [])
        events, state = self.diff(state, prs, 600)
        self.assertEqual(len(events), 1)
        self.assertIn('stuck mingster/dotfiles #7', events[0])
        self.assertEqual(self.diff(state, prs, 1200)[0], [])

    def test_failing_status_check_counts(self):
        prs = [pr(checks=[{'conclusion': 'FAILURE'}])]
        _, state = self.diff(None, prs, 0)
        self.assertEqual(len(self.diff(state, prs, 600)[0]), 1)

    def test_new_head_restarts_the_timer(self):
        _, state = self.diff(None, [pr(checks=[{'conclusion': 'FAILURE'}])], 0)
        moved = [pr(head=OTHER, checks=[{'conclusion': 'FAILURE'}])]
        events, state = self.diff(state, moved, 600)
        self.assertEqual(events, [])
        self.assertEqual(len(self.diff(state, moved, 1200)[0]), 1)

    def test_later_checks_pass_clears_a_fail_at_the_same_head(self):
        prs = [pr(comments=[comment('k1', 'Checks: FAIL head=' + HEAD), comment('k2', 'Checks: PASS head=' + HEAD)])]
        _, state = self.diff(None, prs, 0)
        self.assertEqual(self.diff(state, prs, 600)[0], [])

    def test_status_check_failing_after_a_pass_receipt_counts(self):
        receipt = {'id': 'k1', 'body': 'Checks: PASS head=' + HEAD, 'createdAt': '2026-11-05T10:00:00Z'}
        late = {'conclusion': 'FAILURE', 'completedAt': '2026-11-05T10:05:00Z'}
        prs = [pr(comments=[receipt], checks=[late])]
        _, state = self.diff(None, prs, 0)
        self.assertEqual(len(self.diff(state, prs, 600)[0]), 1)

    def test_status_check_failing_before_a_pass_receipt_does_not_count(self):
        receipt = {'id': 'k1', 'body': 'Checks: PASS head=' + HEAD, 'createdAt': '2026-11-05T10:00:00Z'}
        early = {'conclusion': 'FAILURE', 'completedAt': '2026-11-05T09:55:00Z'}
        prs = [pr(comments=[receipt], checks=[early])]
        _, state = self.diff(None, prs, 0)
        self.assertEqual(self.diff(state, prs, 600)[0], [])

    def test_checks_fail_on_an_old_head_does_not_count(self):
        prs = [pr(comments=[comment('k1', 'Checks: FAIL head=' + OTHER)])]
        _, state = self.diff(None, prs, 0)
        self.assertEqual(self.diff(state, prs, 600)[0], [])


class PrNotices(unittest.TestCase):
    config = {'pr_watch': {'repos': [REPO], 'stuck_minutes': 10}}

    def test_no_pr_watch_config_fetches_nothing(self):
        state = {}
        self.assertEqual(fw.pr_notices({}, state, 0, lambda repo: self.fail('fetched')), [])
        self.assertEqual(state, {})

    def test_failed_fetch_sends_nothing_and_keeps_state(self):
        state = {}
        fw.pr_notices(self.config, state, 0, lambda repo: [pr()])
        before = repr(state)
        self.assertEqual(fw.pr_notices(self.config, state, 60, lambda repo: None), [])
        self.assertEqual(repr(state), before)

    def test_event_after_a_failed_fetch_still_arrives(self):
        state = {}
        fw.pr_notices(self.config, state, 0, lambda repo: [pr()])
        fw.pr_notices(self.config, state, 60, lambda repo: None)
        notices = fw.pr_notices(self.config, state, 120, lambda repo: [pr(state='MERGED', merge='c' * 40)])
        self.assertEqual(notices, ['merged mingster/dotfiles #7 ' + 'c' * 40])

    def test_default_stuck_limit_is_30_minutes(self):
        config = {'pr_watch': {'repos': [REPO]}}
        prs = [pr(checks=[{'conclusion': 'FAILURE'}])]
        state = {}
        fw.pr_notices(config, state, 0, lambda repo: prs)
        self.assertEqual(fw.pr_notices(config, state, 1799, lambda repo: prs), [])
        self.assertEqual(len(fw.pr_notices(config, state, 1800, lambda repo: prs)), 1)


class FetchPrs(unittest.TestCase):
    def test_gh_failure_returns_none(self):
        real = fw.subprocess.run
        def boom(*args, **kwargs):
            raise fw.subprocess.TimeoutExpired('gh', 30)
        fw.subprocess.run = boom
        try:
            self.assertIsNone(fw.fetch_prs(REPO))
        finally:
            fw.subprocess.run = real


if __name__ == '__main__':
    unittest.main()
