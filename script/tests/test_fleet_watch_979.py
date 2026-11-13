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

    def lookup(host, repo):
        assert repo == REPO
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


def repo_row(rid, path, key):
    return {'id': rid, 'path': path, 'gitRemoteIdentity': {'canonicalKey': key, 'remoteName': 'origin'}}


class RepoIdLookup(unittest.TestCase):
    def test_matches_git_remote_when_the_path_differs_per_host(self):
        # blueDevil has dotfiles at /Users/mtsai/dotfiles, mini6 at /Users/mtsai/GitHub/dotfiles
        repos = {'repos': [
            repo_row('rb', '/Users/mtsai/projects/riben.life', 'github.com/mingster/riben.life'),
            repo_row('a7cf6848', '/Users/mtsai/dotfiles', 'github.com/mingster/dotfiles'),
            {'id': 'nokey', 'path': '/x'},
        ]}
        orig = fw.rpc
        calls = []
        fw.rpc = lambda *a: calls.append(a) or repos
        try:
            self.assertEqual(fw.default_repo_id_lookup('blueDevil', 'mingster/dotfiles'), 'a7cf6848')
            self.assertEqual(fw.default_repo_id_lookup('blueDevil', 'Mingster/Dotfiles'), 'a7cf6848')
            self.assertIsNone(fw.default_repo_id_lookup('blueDevil', 'mingster/other'))
        finally:
            fw.rpc = orig
        self.assertEqual(calls[0], ('repo', 'list', '--environment', 'blueDevil'))


class AdoptedConfigKeepsHosts(unittest.TestCase):
    def test_coordinator_config_without_host_caps_inherits_them_from_the_stub(self):
        import json, os, tempfile
        stub_caps = {'mini6': 5, 'niteking': 4, 'blueDevil': 5, 'miniu': 4}
        with tempfile.TemporaryDirectory() as home:
            Path(home, '.config/fleet-watch').mkdir(parents=True)
            Path(home, '.claude/state').mkdir(parents=True)
            stub = Path(home, '.config/fleet-watch/config.json')
            stub.write_text(json.dumps({'local_host': 'mini6', 'host_caps': stub_caps}))
            Path(home, '.claude/state/fleet-watch-elon.json').write_text(json.dumps(
                {'runs': [{'id': 'run_x', 'terminal': 't'}], 'issue_scan': {'hosts': ['local', 'niteking']}}))
            old = os.environ.get('HOME')
            os.environ['HOME'] = home
            try:
                config, adopted = fw.resolve_pass_config(json.loads(stub.read_text()), str(stub))
            finally:
                os.environ['HOME'] = old
        self.assertIsNotNone(adopted)
        self.assertEqual(config['host_caps'], stub_caps)
        self.assertEqual(config['local_host'], 'mini6')

    def test_remote_hosts_exclude_the_coordinator_by_local_host_name(self):
        config = dict(CONFIG, host_caps={'mini6': 5, 'niteking': 4, 'blueDevil': 5}, local_host='mini6')
        starts = []
        _, log = fw.issue_scan_pass(
            config, {'issue_scan_backlog_sweep_at': NOW}, NOW, [],
            list_issues=lambda _r: [ISSUE], pr_fetch=lambda _r: [],
            gate_check=lambda _c: True,
            admit_fn=lambda h, _c, _w: FULL if h in ('local', 'mini6') else FREE,
            start_worker=lambda cmd: starts.append(cmd) or 0,
            repo_id_lookup=lambda h, _r: {'niteking': '5c45d9ec', 'blueDevil': 'a7cf6848'}.get(h),
        )
        self.assertEqual(arg(starts[0], '--on'), 'niteking')
        self.assertEqual(arg(starts[0], '--repo'), 'id:5c45d9ec')


if __name__ == '__main__':
    unittest.main()
