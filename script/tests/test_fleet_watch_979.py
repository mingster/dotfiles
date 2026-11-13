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
    'host_caps': {'local': 4, 'hostC': 4, 'hostB': 4},
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
            {'local': FULL, 'hostC': FREE, 'hostB': FREE},
            {'hostC': 'id-hostC', 'hostB': 'id-blue'})
        self.assertEqual(len(starts), 1)
        self.assertEqual(arg(starts[0], '--on'), 'hostC')
        self.assertEqual(arg(starts[0], '--repo'), 'id:id-hostC')
        self.assertEqual(calls, ['local', 'hostC'])
        self.assertIn('issue_scan_placed=hostC', log)
        self.assertIn('issue_start=7', log)

    def test_all_hosts_full_starts_nothing_and_logs_every_refusal(self):
        _, log, starts, _ = run_pass(
            {'local': FULL, 'hostC': {'admitted': False, 'reason': 'cap 4/4'},
             'hostB': {'admitted': False, 'reason': 'inventory failed'}},
            {'hostC': 'a', 'hostB': 'b'})
        self.assertEqual(starts, [])
        text = ','.join(log)
        self.assertIn('issue_scan_refused=host cap exceeded: local 4/4', text)
        self.assertIn('issue_scan_refused_hostC=cap 4/4', text)
        self.assertIn('issue_scan_refused_hostB=inventory failed', text)

    def test_repo_not_registered_on_a_host_skips_that_host(self):
        _, log, starts, _ = run_pass(
            {'local': FULL, 'hostC': FREE, 'hostB': FREE},
            {'hostC': None, 'hostB': 'id-blue'})
        self.assertEqual(arg(starts[0], '--on'), 'hostB')
        self.assertEqual(arg(starts[0], '--repo'), 'id:id-blue')
        self.assertIn('issue_scan_no_repo_hostC', ','.join(log))

    def test_local_admits_stays_local_without_remote_lookup(self):
        _, _, starts, calls = run_pass({'local': FREE}, {})
        self.assertEqual(calls, ['local'])
        self.assertNotIn('--on', starts[0])
        self.assertEqual(arg(starts[0], '--repo'), 'path:/tmp/app')


def repo_row(rid, path, key):
    return {'id': rid, 'path': path, 'gitRemoteIdentity': {'canonicalKey': key, 'remoteName': 'origin'}}


class RepoIdLookup(unittest.TestCase):
    def test_matches_git_remote_when_the_path_differs_per_host(self):
        # hostB has app at /Users/u/app, coord at /Users/u/GitHub/app
        repos = {'repos': [
            repo_row('rb', '/Users/u/other', 'github.com/owner/other'),
            repo_row('idB', '/Users/u/app', 'github.com/owner/app'),
            {'id': 'nokey', 'path': '/x'},
        ]}
        orig = fw.rpc
        calls = []
        fw.rpc = lambda *a: calls.append(a) or repos
        try:
            self.assertEqual(fw.default_repo_id_lookup('hostB', 'owner/app'), 'idB')
            self.assertEqual(fw.default_repo_id_lookup('hostB', 'Owner/App'), 'idB')
            self.assertIsNone(fw.default_repo_id_lookup('hostB', 'owner/missing'))
        finally:
            fw.rpc = orig
        self.assertEqual(calls[0], ('repo', 'list', '--environment', 'hostB'))


class AdoptedConfigKeepsHosts(unittest.TestCase):
    def test_coordinator_config_without_host_caps_inherits_them_from_the_stub(self):
        import json, os, tempfile
        stub_caps = {'coord': 5, 'hostA': 4, 'hostB': 5, 'hostC': 4}
        with tempfile.TemporaryDirectory() as home:
            Path(home, '.config/fleet-watch').mkdir(parents=True)
            Path(home, '.claude/state').mkdir(parents=True)
            stub = Path(home, '.config/fleet-watch/config.json')
            stub.write_text(json.dumps({'local_host': 'coord', 'host_caps': stub_caps}))
            Path(home, '.claude/state/fleet-watch-elon.json').write_text(json.dumps(
                {'runs': [{'id': 'run_x', 'terminal': 't'}], 'issue_scan': {'hosts': ['local', 'hostA']}}))
            old = os.environ.get('HOME')
            os.environ['HOME'] = home
            try:
                config, adopted = fw.resolve_pass_config(json.loads(stub.read_text()), str(stub))
            finally:
                os.environ['HOME'] = old
        self.assertIsNotNone(adopted)
        self.assertEqual(config['host_caps'], stub_caps)
        self.assertEqual(config['local_host'], 'coord')

    def test_remote_hosts_exclude_the_coordinator_by_local_host_name(self):
        config = dict(CONFIG, host_caps={'coord': 5, 'hostA': 4, 'hostB': 5}, local_host='coord')
        starts = []
        _, log = fw.issue_scan_pass(
            config, {'issue_scan_backlog_sweep_at': NOW}, NOW, [],
            list_issues=lambda _r: [ISSUE], pr_fetch=lambda _r: [],
            gate_check=lambda _c: True,
            admit_fn=lambda h, _c, _w: FULL if h in ('local', 'coord') else FREE,
            start_worker=lambda cmd: starts.append(cmd) or 0,
            repo_id_lookup=lambda h, _r: {'hostA': 'idA', 'hostB': 'idB'}.get(h),
        )
        self.assertEqual(arg(starts[0], '--on'), 'hostA')
        self.assertEqual(arg(starts[0], '--repo'), 'id:idA')


if __name__ == '__main__':
    unittest.main()
