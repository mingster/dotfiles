import importlib.util
from pathlib import Path
import time
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


class UsageNotices(unittest.TestCase):
    def test_no_hosts_configured_runs_nothing(self):
        self.assertEqual(fw.usage_notices({}, run=None), [])

    def test_publishes_to_each_host_and_reports_failure(self):
        calls = []
        def run(command, **kw):
            calls.append(command)
            return type('R', (), {'returncode': 4})()
        self.assertEqual(fw.usage_notices({'usage_hosts': ['a', 'b']}, run=run), ['usage reading not published: exit 4'])
        self.assertEqual(calls[0][-5:], ['publish', '--host', 'a', '--host', 'b'])


class WorkflowNotices(unittest.TestCase):
    NOW = 1_000_000.0
    CONFIG = {'pr_watch': {'repos': [REPO], 'workflows': ['Checks', 'Review']}}

    def run_row(self, id=1, name='Checks', attempt=1, age=60):
        created = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(self.NOW - age))
        return {'databaseId': id, 'workflowName': name, 'attempt': attempt, 'headSha': HEAD, 'url': 'u', 'createdAt': created}

    def setUp(self):
        self.commands = []
        self.code = 0

    def act(self, command):
        self.commands.append(command)
        return self.code

    def notices(self, state, *runs):
        return fw.workflow_notices(self.CONFIG, state, self.NOW, fetch=lambda repo: list(runs), act=self.act)

    def verbs(self):
        return [command[1:3] for command in self.commands]

    def test_first_failure_is_rerun_once(self):
        state = {}
        self.notices(state, self.run_row())
        self.notices(state, self.run_row())
        self.assertEqual(self.verbs(), [['run', 'rerun']])

    def test_second_failure_opens_one_issue(self):
        state = {}
        self.notices(state, self.run_row())
        self.assertIn('failed twice', self.notices(state, self.run_row(attempt=2))[0])
        self.notices(state, self.run_row(attempt=2))
        self.assertEqual(self.verbs(), [['run', 'rerun'], ['issue', 'create']])

    def test_refused_rerun_opens_an_issue(self):
        self.code = 1
        self.notices({}, self.run_row())
        self.assertEqual(self.commands[0][1:3], ['run', 'rerun'])
        self.assertEqual(self.commands[1][1:3], ['issue', 'create'])

    def test_failed_workflow_issue_is_reported_and_retried(self):
        state = {}
        self.code = 1
        self.assertIn('issue not opened', self.notices(state, self.run_row(attempt=2))[0])
        self.code = 0
        self.notices(state, self.run_row(attempt=2))
        self.assertEqual(self.verbs(), [['issue', 'create'], ['issue', 'create']])

    def test_ignores_other_workflows_and_old_runs(self):
        self.notices({}, self.run_row(name='CodeQL'), self.run_row(id=2, age=3 * 3600))
        self.assertEqual(self.commands, [])

    def test_failed_fetch_keeps_state(self):
        state = {'workflow_watch': {REPO: {'1': 'rerun'}}}
        fw.workflow_notices(self.CONFIG, state, self.NOW, fetch=lambda repo: None, act=self.act)
        self.assertEqual(state['workflow_watch'][REPO], {'1': 'rerun'})

    def test_no_workflows_configured_runs_nothing(self):
        self.assertEqual(fw.workflow_notices({'pr_watch': {'repos': [REPO]}}, {}, self.NOW, fetch=None, act=None), [])


class BackupNotices(unittest.TestCase):
    NOW = 1_000_000.0
    CONFIG = {'backup': {'stamp': '/stamp', 'issue_repo': REPO}}

    def setUp(self):
        self.commands = []
        self.code = 0
        self.open_titles = []

    def act(self, command):
        self.commands.append(command)
        return self.code

    def list_open(self, repo):
        return list(self.open_titles)

    def notices(self, state, age):
        return fw.backup_notices(
            self.CONFIG, state, self.NOW,
            stamp_time=lambda path: self.NOW - age, act=self.act, list_open=self.list_open)

    def test_fresh_backup_is_quiet(self):
        self.assertEqual(self.notices({}, 29 * 60), [])
        self.assertEqual(self.commands, [])

    def test_stale_backup_opens_one_issue(self):
        state = {}
        self.assertIn('agent-state', self.notices(state, 31 * 60)[0])
        self.assertEqual(self.notices(state, 36 * 60), [])
        self.assertEqual([command[1:3] for command in self.commands], [['issue', 'create']])

    def test_next_outage_opens_a_new_issue(self):
        state = {}
        self.notices(state, 31 * 60)
        self.notices(state, 60)
        self.notices(state, 31 * 60)
        self.assertEqual(len(self.commands), 2)

    def test_duplicate_open_issue_skips_create(self):
        state = {}
        self.open_titles = [fw.AGENT_STATE_BACKUP_STALE_TITLE]
        self.assertEqual(self.notices(state, 31 * 60), [])
        self.assertEqual(self.commands, [])

    def test_gh_issue_list_failure_skips_create_and_sets_no_flag(self):
        state = {}

        def list_open_returns_none(repo):
            return None

        n = fw.backup_notices(
            self.CONFIG, state, self.NOW,
            stamp_time=lambda path: self.NOW - 31 * 60, act=self.act, list_open=list_open_returns_none)
        self.assertEqual(n, [])
        self.assertEqual(self.commands, [])
        self.assertNotIn('backup_issue', state)

    def test_failed_backup_issue_is_reported_and_retried(self):
        state = {}
        self.code = 1
        self.assertIn('issue not opened', self.notices(state, 31 * 60)[0])
        self.code = 0
        self.notices(state, 36 * 60)
        self.assertEqual(len(self.commands), 2)

    def test_missing_stamp_counts_as_stale(self):
        def gone(path):
            raise OSError
        fw.backup_notices(
            self.CONFIG, {}, self.NOW, stamp_time=gone, act=self.act, list_open=self.list_open)
        self.assertEqual(len(self.commands), 1)

    def test_no_backup_configured_runs_nothing(self):
        self.assertEqual(fw.backup_notices({}, {}, self.NOW, stamp_time=None, act=None), [])


if __name__ == '__main__':
    unittest.main()
