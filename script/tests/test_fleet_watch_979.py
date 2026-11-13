import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

REPO = 'owner/app'
NOW = 1_700_000_000.0
BODY = '## Acceptance\n- [ ] it works\n\n## Out of scope\nnothing else\n'

CONFIG = {
    'issue_scan': {
        'enabled': True, 'repos': [REPO], 'run': 'run_x', 'from_terminal': 'term_coord',
        'host': 'local', 'agent': 'cursor', 'model': 'm1',
        'repo_roots': {REPO: '/tmp/app'},
    },
    'host_caps': {'local': 4, 'miniu': 4, 'blueDevil': 4},
}
ISSUE = {
    'number': 7, 'title': 't', 'body': BODY, 'labels': [{'name': 'ready-for-agent'}], 'comments': [],
    'createdAt': '2026-01-01T00:00:00Z',
}


def run_pass(admit_by_host, repo_ids):
    """repo_ids maps host to a repo id, or None when the repo is not registered there."""
    starts, admit_calls = [], []

    def admit(host, _cfg, _workers):
        admit_calls.append(host)
        return admit_by_host[host]

    def lookup(host, root):
        assert root == '/tmp/app'
        return repo_ids.get(host)

    state = {'issue_scan_backlog_sweep_at': NOW}
    notices, log = fw.issue_scan_pass(
        CONFIG, state, NOW, [],
        list_issues=lambda _r: [ISSUE], pr_fetch=lambda _r: [],
        gate_check=lambda _c: True, admit_fn=admit,
        start_worker=lambda cmd: starts.append(cmd) or 0,
        repo_id_lookup=lookup,
    )
    return notices, log, starts, admit_calls


FULL = {'admitted': False, 'reason': 'host cap exceeded: local 4/4'}
FREE = {'admitted': True, 'occupied': 0}


def arg(cmd, flag):
    return cmd[cmd.index(flag) + 1]


class IssueScanRemoteHosts(unittest.TestCase):
    def test_local_full_places_on_first_admitting_remote_with_its_repo_id(self):
        _, log, starts, calls = run_pass(
            {'local': FULL, 'miniu': FREE, 'blueDevil': FREE},
            {'miniu': 'id-miniu', 'blueDevil': 'id-blue'})
        self.assertEqual(len(starts), 1)
        self.assertEqual(arg(starts[0], '--on'), 'miniu')
        self.assertEqual(arg(starts[0], '--repo'), 'id:id-miniu')
        self.assertEqual(calls, ['local', 'miniu'])
        self.assertIn('issue_scan_placed=miniu', log)
        self.assertIn('issue_start=7', log)

    def test_all_hosts_full_starts_nothing_and_logs_every_refusal(self):
        _, log, starts, _ = run_pass(
            {'local': FULL, 'miniu': {'admitted': False, 'reason': 'cap 4/4'},
             'blueDevil': {'admitted': False, 'reason': 'inventory failed'}},
            {'miniu': 'a', 'blueDevil': 'b'})
        self.assertEqual(starts, [])
        text = ','.join(log)
        self.assertIn('issue_scan_refused=host cap exceeded: local 4/4', text)
        self.assertIn('issue_scan_refused_miniu=cap 4/4', text)
        self.assertIn('issue_scan_refused_blueDevil=inventory failed', text)

    def test_repo_not_registered_on_a_host_skips_that_host(self):
        _, log, starts, _ = run_pass(
            {'local': FULL, 'miniu': FREE, 'blueDevil': FREE},
            {'miniu': None, 'blueDevil': 'id-blue'})
        self.assertEqual(arg(starts[0], '--on'), 'blueDevil')
        self.assertEqual(arg(starts[0], '--repo'), 'id:id-blue')
        self.assertIn('issue_scan_no_repo_miniu', ','.join(log))

    def test_local_admits_stays_local_without_remote_lookup(self):
        _, _, starts, calls = run_pass({'local': FREE}, {})
        self.assertEqual(calls, ['local'])
        self.assertNotIn('--on', starts[0])
        self.assertEqual(arg(starts[0], '--repo'), 'path:/tmp/app')


class RepoIdLookup(unittest.TestCase):
    def test_matches_path_and_ignores_other_repos(self):
        repos = {'repos': [{'id': 'x', 'path': '/other'}, {'id': 'y', 'path': '/tmp/app'}]}
        orig = fw.rpc
        calls = []
        fw.rpc = lambda *a: calls.append(a) or repos
        try:
            self.assertEqual(fw.default_repo_id_lookup('miniu', '/tmp/app'), 'y')
            self.assertIsNone(fw.default_repo_id_lookup('miniu', '/nope'))
        finally:
            fw.rpc = orig
        self.assertEqual(calls[0], ('repo', 'list', '--environment', 'miniu'))


if __name__ == '__main__':
    unittest.main()
