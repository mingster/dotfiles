"""Red head checks: one workflow rerun per head, then rework, then needs-redesign.

No Orca reply is built here. A gh or Orca stub replays a file under
script/tests/fixtures/fleet-watch/ when #990 has recorded that call.
"""
import importlib.util
import json
import time
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

REPO = 'mingster/dotfiles'
HEAD = 'a' * 40
OTHER = 'b' * 40
THIRD = 'c' * 40
NOW = 1_000_000.0


def recorded_reply(name):
    """One #990 recording, or None when that fixture is not on this tree yet."""
    root = Path(__file__).resolve().parent / 'fixtures' / 'fleet-watch'
    matches = sorted(root.glob('orca-*/%s.json' % name))
    if not matches:
        return None
    data = json.loads(matches[-1].read_text())
    for key in ('exit_code', 'stdout', 'stderr'):
        if key not in data:
            raise AssertionError('%s missing %s' % (matches[-1].name, key))
    return data


def run_row(run_id=1, name='Checks', attempt=1, head=HEAD, age=60):
    created = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(NOW - age))
    return {
        'databaseId': run_id,
        'workflowName': name,
        'attempt': attempt,
        'headSha': head,
        'url': 'https://example.test/runs/%s' % run_id,
        'createdAt': created,
    }


def failing_check_pr(number, head, run_id):
    return {
        'number': number,
        'state': 'OPEN',
        'isDraft': False,
        'headRefOid': head,
        'comments': [],
        'labels': [],
        'statusCheckRollup': [{
            'context': 'Script tests',
            'conclusion': 'FAILURE',
            'detailsUrl': 'https://github.com/%s/actions/runs/%s/job/1' % (REPO, run_id),
        }],
    }


def receipt_fail_pr(number, head):
    return {
        'number': number,
        'state': 'OPEN',
        'isDraft': False,
        'headRefOid': head,
        'comments': [{'body': 'Checks: FAIL head=%s' % head}],
        'labels': [],
        'statusCheckRollup': [],
    }


class RedCheckLadder(unittest.TestCase):
    CONFIG = {
        'pr_watch': {'repos': [REPO], 'workflows': ['Checks', 'Review']},
        'issue_scan': {
            'enabled': True,
            'repos': [REPO],
            'pr_repos': [REPO],
            'run': 'run_x',
            'from_terminal': 'term_coord',
            'host': 'local',
            'agent': 'cursor',
            'model': 'm1',
            'rework_agent': 'cursor',
            'rework_model': 'm1',
            'repo_roots': {REPO: '/tmp/app'},
        },
        'host_caps': {'local': 4},
        'worker_stall': {'needs_elon_label': 'needs-elon', 'needs_redesign_label': 'needs-redesign'},
    }

    def setUp(self):
        self.commands = []
        self.code = 0

    def act(self, command):
        self.commands.append(command)
        return self.code

    def workflow(self, state, *runs):
        return fw.workflow_notices(
            self.CONFIG, state, NOW, fetch=lambda repo: list(runs), act=self.act)

    def verbs(self):
        return [command[1:3] for command in self.commands]

    def rework(self, state, pr, prior):
        starts = []

        def start_worker(command):
            starts.append(command)
            return 0

        if 'issue_scan_backlog_sweep_at' not in state:
            state['issue_scan_backlog_sweep_at'] = NOW
        notices, _log = fw.issue_scan_pass(
            self.CONFIG, state, NOW, [],
            list_issues=lambda repo: [],
            pr_fetch=lambda repo: [pr],
            gate_check=lambda _cfg: True,
            admit_fn=lambda _h, _c, _w: {'admitted': True, 'occupied': 0},
            start_worker=start_worker,
            act=self.act,
            workflow_watch_prior=prior,
        )
        return notices, starts

    def test_one_rerun_per_head_and_a_new_head_reruns(self):
        state = {}
        self.workflow(
            state,
            run_row(1, head=HEAD),
            run_row(2, head=HEAD),
            run_row(3, head=OTHER),
        )
        self.workflow(
            state,
            run_row(1, head=HEAD),
            run_row(2, head=HEAD),
            run_row(9, head=HEAD),
            run_row(4, head=THIRD),
        )
        reruns = [command[3] for command in self.commands if command[1:3] == ['run', 'rerun']]
        self.assertEqual(reruns, ['1', '3', '4'])
        self.assertNotIn(['issue', 'create'], self.verbs())

    def test_second_attempt_opens_no_failed_twice_issue(self):
        state = {}
        self.workflow(state, run_row())
        notices = self.workflow(state, run_row(attempt=2))
        self.assertEqual(notices, [])
        self.assertEqual(self.verbs(), [['run', 'rerun']])
        self.assertNotIn('needs-elon', [part for command in self.commands for part in command])

    def test_refused_rerun_is_one_try_and_opens_no_issue(self):
        self.code = 1
        state = {}
        notices = self.workflow(state, run_row())
        self.workflow(state, run_row())
        self.assertEqual(notices, [])
        self.assertEqual(self.verbs(), [['run', 'rerun']])

    def test_attempt_already_two_is_not_rerun_and_opens_no_issue(self):
        state = {}
        notices = self.workflow(state, run_row(attempt=2))
        self.assertEqual(notices, [])
        self.assertEqual(self.commands, [])
        self.assertEqual(state['workflow_watch'][REPO]['1'], 'rerun')

    def test_still_red_after_rerun_starts_one_rework_worker(self):
        state = {}
        prior = {}
        self.workflow(state, run_row(77, head=HEAD))
        pr = failing_check_pr(13, HEAD, '77')
        same_pass, starts = self.rework(state, pr, prior)
        self.assertEqual(starts, [])
        self.assertFalse(any(isinstance(notice, fw.Urgent) for notice in same_pass))
        later, starts = self.rework(state, pr, state['workflow_watch'])
        self.assertEqual(len(starts), 1)
        self.assertIn('rework', ' '.join(starts[0]).lower())
        again, starts_again = self.rework(state, pr, state['workflow_watch'])
        self.assertEqual(starts_again, [])
        self.assertEqual(again, [])
        self.assertNotIn(['issue', 'create'], self.verbs())

    def test_second_failed_round_labels_needs_redesign_once(self):
        state = {}
        notices = []
        starts = []
        for head in (HEAD, OTHER, THIRD):
            round_notices, round_starts = self.rework(state, receipt_fail_pr(10, head), {})
            notices.extend(round_notices)
            starts.extend(round_starts)
        self.assertEqual(len(starts), 2)
        redesign = [notice for notice in notices if isinstance(notice, fw.Urgent)]
        self.assertEqual(len(redesign), 1)
        self.assertNotIn('failed twice', redesign[0])
        labels = [command for command in self.commands if command[:3] == ['gh', 'pr', 'edit']]
        self.assertEqual(len(labels), 1)
        self.assertIn('needs-redesign', labels[0])
        self.assertNotIn(['issue', 'create'], self.verbs())
        later, later_starts = self.rework(state, receipt_fail_pr(10, 'd' * 40), {})
        self.assertEqual(later_starts, [])
        self.assertEqual(later, [])

    def test_red_main_still_sends_one_notice(self):
        state = {}
        fetch_red = lambda repo: {
            'databaseId': 7,
            'conclusion': 'failure',
            'url': 'https://example.test/runs/7',
        }
        first = fw.main_red_notices(self.CONFIG, state, NOW, fetch=fetch_red)
        self.assertEqual(len(first), 1)
        self.assertIsInstance(first[0], fw.Urgent)
        self.assertIn('https://example.test/runs/7', first[0])
        self.assertEqual(fw.main_red_notices(self.CONFIG, state, NOW, fetch=fetch_red), [])
        workflow_notices = self.workflow(state, run_row(7, head='e' * 40))
        self.assertNotIn('failed twice', ' '.join(workflow_notices))
        self.assertNotIn(['issue', 'create'], self.verbs())

    def test_recorded_pr_list_opens_no_failed_twice_issue(self):
        recorded = recorded_reply('gh-pr-list')
        self.assertIsNotNone(recorded, 'gh-pr-list recording from #990')
        self.assertEqual(recorded['exit_code'], 0)
        prs = json.loads(recorded['stdout'])
        self.assertIsInstance(prs, list)
        state = {'issue_scan_backlog_sweep_at': NOW}
        notices, _log = fw.issue_scan_pass(
            self.CONFIG, state, NOW, [],
            list_issues=lambda repo: [],
            pr_fetch=lambda repo: prs,
            gate_check=lambda _cfg: True,
            admit_fn=lambda _h, _c, _w: {'admitted': True, 'occupied': 0},
            start_worker=lambda _command: 0,
            act=self.act,
            workflow_watch_prior={},
        )
        self.assertNotIn(['issue', 'create'], self.verbs())
        self.assertFalse(any('failed twice on' in str(notice) for notice in notices))


if __name__ == '__main__':
    unittest.main()
