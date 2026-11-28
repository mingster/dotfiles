"""fleet-watch reruns head-checks on Checks: INFRA at most N times per head (#1088)."""
import sys
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch_1088', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

REPO = 'owner/app'
NOW = 1_700_000_000.0
HEAD = 'e' * 40
NEXT_HEAD = 'f' * 40


def infra(head, n):
    return {
        'body': 'Checks: INFRA head=%s\nResult: exit 137; retryable infra failure' % head,
        'createdAt': '2026-11-15T10:%02d:00Z' % n,
    }


def pr_row(head, comments):
    return {
        'number': 34, 'state': 'OPEN', 'isDraft': False, 'headRefOid': head, 'headRefName': 'feature/pr',
        'statusCheckRollup': [], 'comments': list(comments), 'labels': [],
    }


class InfraRerunCap(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        wt = os.path.join(self.tmp.name, 'wt')
        subprocess.run(['git', 'init', '-q', wt], check=True)
        subprocess.run(['git', '-C', wt, 'config', 'user.email', 't@example.com'], check=True)
        subprocess.run(['git', '-C', wt, 'config', 'user.name', 't'], check=True)
        subprocess.run(['git', '-C', wt, 'commit', '--allow-empty', '-m', 'init', '-q'], check=True)
        self.config = {
            'issue_scan': {
                'enabled': True, 'repos': [REPO], 'repo_roots': {REPO: wt},
                'run': 'run_x', 'from_terminal': 'term_x', 'host': 'local',
                'agent': 'cursor', 'model': 'grok-4.7-xhigh',
            },
            'host_caps': {'local': 4},
            'local_host': 'local',
        }

    def scan(self, state, row, config=None):
        starts = []

        def start_detached(command, extra_env=None):
            starts.append(command)
            return 0

        notices, log = fw.issue_scan_pass(
            config or self.config, state, NOW, [],
            pr_fetch=lambda _repo: [row],
            gate_check=lambda _c: True,
            admit_fn=lambda _h, _c, _w: {'admitted': True, 'occupied': 0},
            start_detached=start_detached,
            checks_lock_live=lambda _root: False,
        )
        return notices, log, starts

    def test_first_infra_receipt_reruns_head_checks(self):
        _notices, log, starts = self.scan({}, pr_row(HEAD, [infra(HEAD, 1)]))
        self.assertEqual(len(starts), 1, log)
        self.assertIn('head_checks_start=' + HEAD[:8], ','.join(log))

    def test_cap_stops_reruns_and_posts_one_digest_line(self):
        state = {}
        row = pr_row(HEAD, [infra(HEAD, 1), infra(HEAD, 2)])
        _notices, log, starts = self.scan(state, row)
        self.assertEqual(len(starts), 1, log)
        row = pr_row(HEAD, [infra(HEAD, 1), infra(HEAD, 2), infra(HEAD, 3)])
        notices, log, starts = self.scan(state, row)
        self.assertEqual(starts, [], log)
        capped = [n for n in notices if 'INFRA' in n]
        self.assertEqual(len(capped), 1, notices)
        self.assertIn('%s#34' % REPO, capped[0])
        notices, log, starts = self.scan(state, row)
        self.assertEqual(starts, [])
        self.assertEqual([n for n in notices if 'INFRA' in n], [])

    def test_cap_comes_from_config(self):
        config = dict(self.config, head_checks={'infra_reruns': 1})
        row = pr_row(HEAD, [infra(HEAD, 1), infra(HEAD, 2)])
        notices, _log, starts = self.scan({}, row, config)
        self.assertEqual(starts, [])
        self.assertEqual(len([n for n in notices if 'INFRA' in n]), 1)

    def test_new_head_resets_the_count(self):
        state = {}
        capped = pr_row(HEAD, [infra(HEAD, 1), infra(HEAD, 2), infra(HEAD, 3)])
        self.scan(state, capped)
        fresh = pr_row(NEXT_HEAD, capped['comments'])
        _notices, log, starts = self.scan(state, fresh)
        self.assertEqual(len(starts), 1, log)
        self.assertIn('head_checks_start=' + NEXT_HEAD[:8], ','.join(log))


if __name__ == '__main__':
    unittest.main()
