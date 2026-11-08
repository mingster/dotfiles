import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

REPO = 'owner/app'
NOW = 1_700_000_000.0
BODY = '## Acceptance criteria\n- observable check passes\n'


def make_issue(number, title, labels=None, body=BODY):
    names = ['ready-for-agent'] + list(labels or [])
    return {
        'number': number,
        'title': title,
        'body': body,
        'labels': [{'name': name} for name in names],
        'comments': [],
        'createdAt': '2026-11-08T00:00:00Z',
    }


class IssueScanAutostartClassifier(unittest.TestCase):
    def test_existing_page_wording_issue_is_eligible(self):
        row = make_issue(1, 'Clarify empty state wording on orders table')
        self.assertTrue(fw.issue_scan_autostart_allowed(row))
        self.assertTrue(fw.issue_scan_eligible(row))

    def test_copy_label_on_existing_page_is_eligible(self):
        row = make_issue(2, 'Clarify shipping dialog hint', labels=['copy'])
        self.assertTrue(fw.issue_scan_autostart_allowed(row))
        self.assertTrue(fw.issue_scan_eligible(row))

    def test_defaults_closed_when_not_wording(self):
        row = make_issue(3, 'Fix race condition in background worker queue', labels=['bug'])
        self.assertFalse(fw.issue_scan_autostart_allowed(row))
        self.assertFalse(fw.issue_scan_eligible(row))

    def test_defaults_closed_on_missing_or_malformed_fields(self):
        self.assertFalse(fw.issue_scan_autostart_allowed(None))
        self.assertFalse(fw.issue_scan_autostart_allowed({}))
        self.assertFalse(fw.issue_scan_autostart_allowed({'title': '', 'labels': [{'name': 'copy'}]}))
        self.assertFalse(fw.issue_scan_autostart_allowed({'title': 'Update wording', 'labels': 'bad'}))

    def test_money_title_or_label_blocks_autostart(self):
        for title, labels in [
            ('Update payment wording on order dialog', []),
            ('Clarify refund copy on receipt', []),
            ('Fix wallet balance label text', []),
            ('Update ledger wording', []),
            ('Fix billing error message', []),
            ('Update button wording', ['money']),
            ('Update button wording', ['secops']),
        ]:
            with self.subTest(title=title, labels=labels):
                row = make_issue(4, title, labels=labels)
                self.assertFalse(fw.issue_scan_autostart_allowed(row))
                self.assertFalse(fw.issue_scan_eligible(row))

    def test_price_title_or_label_blocks_autostart(self):
        for title, labels in [
            ('Fix price wording on product card', []),
            ('Update pricing label text', []),
            ('Clarify discount coupon copy', []),
            ('Update button wording', ['pricing']),
            ('Update button wording', ['price']),
        ]:
            with self.subTest(title=title, labels=labels):
                row = make_issue(5, title, labels=labels)
                self.assertFalse(fw.issue_scan_autostart_allowed(row))
                self.assertFalse(fw.issue_scan_eligible(row))

    def test_new_page_title_or_label_blocks_autostart(self):
        for title, labels in [
            ('Add new page with onboarding wording', []),
            ('Create new UI page for store copy', []),
            ('New screen wording for settings', []),
            ('Update heading wording', ['new-page']),
            ('Update heading wording', ['new-ui']),
        ]:
            with self.subTest(title=title, labels=labels):
                row = make_issue(6, title, labels=labels)
                self.assertFalse(fw.issue_scan_autostart_allowed(row))
                self.assertFalse(fw.issue_scan_eligible(row))

    def test_new_feature_title_or_label_blocks_autostart(self):
        for title, labels in [
            ('New feature: custom store wording', []),
            ('Feature request for button copy', []),
            ('Update button wording', ['feature']),
            ('Update button wording', ['enhancement']),
            ('Update button wording', ['design:architect']),
            ('Update button wording', ['design:arena']),
        ]:
            with self.subTest(title=title, labels=labels):
                row = make_issue(7, title, labels=labels)
                self.assertFalse(fw.issue_scan_autostart_allowed(row))
                self.assertFalse(fw.issue_scan_eligible(row))

    def test_issue_scan_pass_starts_only_wording_issue(self):
        cfg = {
            'issue_scan': {
                'enabled': True,
                'repos': [REPO],
                'run': 'run_x',
                'from_terminal': 'term_coord',
                'host': 'local',
                'agent': 'cursor',
                'model': 'm1',
                'repo_roots': {REPO: '/tmp/app'},
            },
            'host_caps': {'local': 4},
        }
        state = {'issue_scan_backlog_sweep_at': NOW}
        issues = [
            make_issue(10, 'Update payment wording on checkout', labels=['P0']),
            make_issue(11, 'Fix price label copy', labels=['P0']),
            make_issue(12, 'Add new page for help copy', labels=['P0']),
            make_issue(13, 'Update button wording', labels=['P0', 'feature']),
            make_issue(14, 'Fix crash on empty cart', labels=['P0', 'bug']),
            make_issue(15, 'Clarify save button wording on profile form', labels=['P2']),
        ]
        starts = []
        notices, log = fw.issue_scan_pass(
            cfg, state, NOW, [],
            list_issues=lambda _repo: issues,
            pr_fetch=lambda _repo: [],
            gate_check=lambda _c: True,
            admit_fn=lambda _h, _c, _w: {'admitted': True, 'occupied': 0},
            start_worker=lambda cmd: (starts.append(cmd), 0)[1],
            inventory_ok=True,
        )
        self.assertEqual(len(starts), 1)
        self.assertIn('issue-15', starts[0])
        self.assertIn('issue_start=15', log)
        self.assertEqual(notices, ['issue %s #15' % REPO])


if __name__ == '__main__':
    unittest.main()
