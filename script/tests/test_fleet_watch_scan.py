import importlib.util
import time
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

REPO = 'owner/app'
OTHER_REPO = 'owner/other'
NOW = 1_700_000_000.0


def issue(number, labels=None, body='', comments=None, created=None, blocked=False):
    labels = labels or []
    created = created or '2026-01-01T00:00:00Z'
    row = {
        'number': number,
        'title': 'ticket %d' % number,
        'body': body,
        'labels': [{'name': n} for n in labels],
        'comments': comments or [],
        'createdAt': created,
    }
    if blocked:
        row['isBlocked'] = True
    return row


def pr(number, head='a' * 40, checks=(), comments=()):
    return {
        'number': number,
        'state': 'OPEN',
        'headRefOid': head,
        'statusCheckRollup': list(checks),
        'comments': list(comments),
    }


class IssueEligibility(unittest.TestCase):
    def test_ready_label_and_acceptance_required(self):
        good = issue(1, ['ready-for-agent'], '## Acceptance criteria\n- x')
        self.assertTrue(fw.issue_scan_eligible(good))
        self.assertFalse(fw.issue_scan_eligible(issue(2, ['ready-for-agent'], 'no criteria')))
        self.assertFalse(fw.issue_scan_eligible(issue(3, [], '## Acceptance criteria\n- x')))

    def test_acceptance_may_live_in_comments(self):
        self.assertTrue(fw.issue_scan_eligible(issue(1, ['ready-for-agent'], '', comments=[{'body': '## Acceptance criteria\n- y'}])))

    def test_blocked_issues_never_eligible(self):
        self.assertFalse(fw.issue_scan_eligible(issue(1, ['ready-for-agent'], '## Acceptance criteria\n- x', blocked=True)))


class IssueScanOrder(unittest.TestCase):
    def test_p0_before_p1_before_oldest(self):
        rows = [
            issue(3, ['ready-for-agent', 'P1'], '## Acceptance criteria\n- x', created='2026-01-03T00:00:00Z'),
            issue(1, ['ready-for-agent', 'P0'], '## Acceptance criteria\n- x', created='2026-01-01T00:00:00Z'),
            issue(2, ['ready-for-agent'], '## Acceptance criteria\n- x', created='2026-01-02T00:00:00Z'),
            issue(4, ['ready-for-agent', 'P1'], '## Acceptance criteria\n- x', created='2026-01-01T12:00:00Z'),
        ]
        ordered = fw.issue_scan_sorted_eligible(rows)
        self.assertEqual([r['number'] for r in ordered], [1, 4, 3, 2])


class IssueScanPass(unittest.TestCase):
    CONFIG = {
        'issue_scan': {
            'enabled': True,
            'repos': [REPO],
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
    }

    def run_pass(self, state, issues_by_repo=None, starts=None, gate_ok=True, admitted=True, prs_by_repo=None):
        issues_by_repo = issues_by_repo or {}
        prs_by_repo = prs_by_repo or {}
        starts = starts if starts is not None else []

        def list_issues(repo):
            return issues_by_repo.get(repo, [])

        def fetch_prs(repo):
            return prs_by_repo.get(repo, [])

        def gate_check(_cfg):
            return gate_ok

        def admit(_host, _cfg, _workers):
            return {'admitted': admitted}

        def start_worker(command):
            starts.append(command)
            return 0

        notices, log = fw.issue_scan_pass(
            self.CONFIG, state, NOW, [],
            list_issues=list_issues, pr_fetch=fetch_prs,
            gate_check=gate_check, admit_fn=admit, start_worker=start_worker,
        )
        return notices, log, starts

    def test_disabled_starts_nothing(self):
        cfg = {'issue_scan': {'enabled': False}}
        notices, log = fw.issue_scan_pass(cfg, {}, NOW, [])
        self.assertEqual(notices, [])
        self.assertEqual(log, ['issue_scan_off'])

    def test_no_config_starts_nothing(self):
        notices, log = fw.issue_scan_pass({}, {}, NOW, [])
        self.assertEqual(notices, [])
        self.assertEqual(log, ['issue_scan_off'])

    def test_eligible_issue_starts_once(self):
        state = {}
        issues = {
            REPO: [issue(9, ['ready-for-agent'], '## Acceptance criteria\n- prove it')],
        }
        _, log, starts = self.run_pass(state, issues)
        self.assertEqual(len(starts), 1)
        joined = ' '.join(starts[0])
        self.assertIn('worker-startup', joined)
        self.assertIn('--run', starts[0])
        self.assertIn('run_x', starts[0])
        _, log2, starts2 = self.run_pass(state, issues)
        self.assertEqual(starts2, [])
        self.assertIn('issue_scan_none', log2)

    def test_ineligible_never_starts(self):
        state = {}
        issues = {
            REPO: [
                issue(1, ['ready-for-agent'], 'no section'),
                issue(2, [], '## Acceptance criteria\n- x'),
                issue(3, ['ready-for-agent'], '## Acceptance criteria\n- x', blocked=True),
            ],
        }
        _, _, starts = self.run_pass(state, issues)
        self.assertEqual(starts, [])

    def test_gate_refusal_starts_nothing(self):
        state = {}
        issues = {REPO: [issue(1, ['ready-for-agent', 'P0'], '## Acceptance criteria\n- x')]}
        _, log, starts = self.run_pass(state, issues, gate_ok=False)
        self.assertEqual(starts, [])
        self.assertIn('issue_scan_gate', log)

    def test_load_refusal_starts_nothing(self):
        state = {}
        issues = {REPO: [issue(1, ['ready-for-agent', 'P0'], '## Acceptance criteria\n- x')]}
        _, log, starts = self.run_pass(state, issues, admitted=False)
        self.assertEqual(starts, [])
        self.assertIn('issue_scan_load', log)

    def test_priority_order_picks_first_eligible_only(self):
        state = {}
        issues = {
            REPO: [
                issue(2, ['ready-for-agent'], '## Acceptance criteria\n- x', created='2026-01-02T00:00:00Z'),
                issue(1, ['ready-for-agent', 'P0'], '## Acceptance criteria\n- x', created='2026-01-03T00:00:00Z'),
            ],
        }
        _, _, starts = self.run_pass(state, issues)
        self.assertEqual(len(starts), 1)
        self.assertIn('#1', ' '.join(starts[0]))

    def test_failed_review_starts_one_rework_per_head(self):
        state = {}
        head = 'c' * 40
        prs = {
            REPO: [
                pr(7, head=head, checks=[{'context': 'head-checks', 'conclusion': 'SUCCESS'},
                                         {'context': 'review', 'conclusion': 'FAILURE'}]),
            ],
        }
        _, log, starts = self.run_pass(state, prs_by_repo=prs)
        self.assertEqual(len(starts), 1)
        self.assertIn('rework', ' '.join(starts[0]).lower())
        _, _, starts2 = self.run_pass(state, prs_by_repo=prs)
        self.assertEqual(starts2, [])
        other = 'd' * 40
        prs[REPO][0]['headRefOid'] = other
        _, _, starts3 = self.run_pass(state, prs_by_repo=prs)
        self.assertEqual(len(starts3), 1)


if __name__ == '__main__':
    unittest.main()
