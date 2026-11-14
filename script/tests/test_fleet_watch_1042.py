import importlib.util
import os
import tempfile
import unittest
import unittest.mock
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

REPO = 'owner/app'
DOTFILES = 'mingster/dotfiles'
NOW = 1_700_000_000.0
HEAD = 'a' * 40
BARE = 'b' * 40
ENV_ID = '11111111-2222-4333-8444-555555555555'


def checks(conclusion='SUCCESS'):
    return [{
        'name': 'checks', 'status': 'COMPLETED', 'conclusion': conclusion, 'isRequired': True,
    }]


def ready_pr(number, head):
    return {
        'number': number, 'state': 'OPEN', 'isDraft': False, 'headRefOid': head,
        'headRefName': 'ready-%d' % number, 'mergeable': 'MERGEABLE',
        'statusCheckRollup': checks(),
        'comments': [{'body': 'Verdict: PASS head=%s verifier=ctx_v author=ctx_a' % head}],
        'labels': [],
    }


def bare_pr():
    return {
        'number': 9, 'state': 'OPEN', 'isDraft': False, 'headRefOid': BARE,
        'headRefName': 'bare', 'mergeable': 'MERGEABLE',
        'statusCheckRollup': [], 'comments': [], 'labels': [],
    }


def scan_config(caps, root='/tmp/app-1042', extra=None):
    config = {
        'issue_scan': {
            'enabled': True,
            'repos': [REPO],
            'run': 'run_x',
            'from_terminal': 'term_coord',
            'host': 'local',
            'agent': 'cursor',
            'model': 'm1',
            'repo_roots': {REPO: root, DOTFILES: root},
        },
        'host_caps': caps,
    }
    if extra:
        config.update(extra)
    return config


class RefusedHostHoldsHeadChecks(unittest.TestCase):
    def test_refused_local_does_not_start_head_checks_and_still_logs_ship_start(self):
        state = {}
        detached = []
        seen = []

        def run(command, **_kwargs):
            seen.append(list(command))

            class Proc:
                returncode = 0
                stderr = ''
                stdout = ''

            return Proc()

        def start_detached(command, extra_env=None):
            detached.append(list(command))
            return fw.BabysitStartResult(0)

        with tempfile.TemporaryDirectory() as tmp:
            log_path = Path(tmp) / 'fleet-watch.log'
            previous = os.environ.get('FLEET_WATCH_LOG_PATH')
            os.environ['FLEET_WATCH_LOG_PATH'] = str(log_path)
            try:
                fw.begin_pass_counts()
                _notices, log = fw.issue_scan_pass(
                    scan_config({'local': 4}), state, NOW, [],
                    list_issues=lambda _repo: [],
                    pr_fetch=lambda _repo: [bare_pr(), ready_pr(3, HEAD)],
                    gate_check=lambda _c: True,
                    admit_fn=lambda _h, _c, _w: {
                        'admitted': False, 'occupied': 4, 'reason': 'host cap exceeded: local 4/4',
                    },
                    start_worker=lambda cmd: fw.default_issue_scan_start(cmd, run=run),
                    start_detached=start_detached,
                )
                fw.finish_pass('scan ' + ','.join(log))
                logged = log_path.read_text(encoding='utf-8')
            finally:
                if previous is None:
                    os.environ.pop('FLEET_WATCH_LOG_PATH', None)
                else:
                    os.environ['FLEET_WATCH_LOG_PATH'] = previous
                fw._PASS = None
                fw._ENV_PASS_ID = None
                fw._ENV_NAMES_CACHE = None
        self.assertEqual(detached, [])
        self.assertNotIn('head_checks_start=', ','.join(log))
        self.assertIn('head_checks_held=%s' % BARE[:8], log)
        self.assertTrue(any('ship.sh' in ' '.join(cmd) for cmd in seen), seen)
        self.assertIn('ship_start=%s' % HEAD[:8], log)
        self.assertIn('ship_start=%s' % HEAD[:8], logged)


class BabysitBriefMatchesAutoShip(unittest.TestCase):
    def test_verifier_and_fixer_name_the_fleet_watch_ship_start(self):
        row = {'number': 4, 'headRefOid': HEAD}
        with tempfile.TemporaryDirectory() as root:
            texts = [
                Path(fw.build_babysit_spec(REPO, row, kind, ('cursor', 'grok-4.7-xhigh'), root)).read_text(
                    encoding='utf-8')
                for kind in ('verifier', 'fixer')
            ]
        for text in texts:
            self.assertIn('fleet-watch starts ship.sh for a ready head', text)
            self.assertNotIn('stays manual', text)


class EnvironmentListOncePerPass(unittest.TestCase):
    def test_two_admits_read_the_environment_list_once(self):
        calls = []

        def rpc(*args):
            calls.append(args)
            return {'environments': [{'id': ENV_ID, 'name': 'host-b'}]}

        workers = [{
            'dispatchId': 'ctx_remote',
            'dispatchStatus': 'running',
            'host': ENV_ID,
        }]
        config = {'local_host': 'coord', 'host_caps': {'coord': 2, 'host-b': 2}}
        fw.begin_pass_counts()
        original = fw.rpc
        fw.rpc = rpc
        try:
            fw.admit('local', config, workers)
            named = fw.admit('host-b', config, workers)
        finally:
            fw.rpc = original
            fw._PASS = None
            fw._ENV_PASS_ID = None
            fw._ENV_NAMES_CACHE = None
        self.assertEqual(calls, [('environment', 'list')])
        self.assertEqual(named['occupied'], 1)


class OverflowNeedsRepoMapping(unittest.TestCase):
    def mapping(self):
        return {
            'worker_placement': {
                'repos': {
                    'niteking': {'mingster/other': 'id:other'},
                    'host-c': {DOTFILES: 'id:dots'},
                },
            },
        }

    def test_issue_scan_skips_a_free_host_with_no_mapping_for_the_repo(self):
        looked = []

        def lookup(host, repo):
            looked.append((host, repo))
            return 'id-%s' % host

        starts = []
        state = {'issue_scan_backlog_sweep_at': NOW}
        config = scan_config(
            {'local': 1, 'niteking': 4, 'host-c': 4},
            extra=self.mapping(),
        )
        config['issue_scan']['repos'] = [DOTFILES]
        _notices, log = fw.issue_scan_pass(
            config,
            state, NOW, [],
            list_issues=lambda _repo: [{
                'number': 7, 'title': 't',
                'body': (
                    'Refs mingster/dotfiles#9\n\n'
                    '## Acceptance\n- [ ] prove it\n\n'
                    '## Out of scope\nother files\n\n'
                    '## Verify\nbash script/checks-local.sh\n\n'
                    '## Finish\n'
                    'Self-review, run orca worktree set --worktree active '
                    '--workspace-status in-review, then worker_done.\n'
                ),
                'labels': [{'name': 'ready-for-agent'}], 'comments': [],
                'createdAt': '2026-01-01T00:00:00Z',
            }],
            pr_fetch=lambda _repo: [],
            gate_check=lambda _c: True,
            admit_fn=lambda host, _c, _w: (
                {'admitted': False, 'occupied': 1, 'reason': 'host cap exceeded: local 1/1'}
                if host == 'local' else {'admitted': True, 'occupied': 0}
            ),
            start_worker=lambda cmd: starts.append(cmd) or 0,
            repo_id_lookup=lookup,
        )
        self.assertEqual(len(starts), 1, log)
        self.assertEqual(starts[0][starts[0].index('--on') + 1], 'host-c')
        self.assertIn('issue_scan_no_repo_niteking', log)
        self.assertNotIn('niteking', [host for host, _repo in looked])

    def test_admit_overflow_skips_an_unmapped_host(self):
        config = {
            'local_host': 'coord',
            'host_caps': {'coord': 4, 'niteking': 4, 'host-c': 4},
        }
        config.update(self.mapping())
        with unittest.mock.patch.dict(os.environ, {
            'FLEET_WATCH_TEST_LOAD_PER_CORE': '0.85',
            'FLEET_WATCH_TEST_FREE_GB': '12',
        }):
            receipt = fw.admit('local', config, workers=[], repo=DOTFILES, repo_lookup=lambda *_a: 'should-not-run')
        self.assertEqual(receipt['overflow_host'], 'host-c')
        self.assertNotIn('niteking', receipt.get('reason') or '')

    def test_admit_without_a_table_uses_the_repo_lookup(self):
        config = {
            'local_host': 'coord',
            'host_caps': {'coord': 4, 'niteking': 4, 'host-c': 4},
        }

        def lookup(host, repo):
            self.assertEqual(repo, DOTFILES)
            return None if host == 'niteking' else 'id-c'

        with unittest.mock.patch.dict(os.environ, {
            'FLEET_WATCH_TEST_LOAD_PER_CORE': '0.85',
            'FLEET_WATCH_TEST_FREE_GB': '12',
        }):
            receipt = fw.admit('local', config, workers=[], repo=DOTFILES, repo_lookup=lookup)
        self.assertEqual(receipt['overflow_host'], 'host-c')


if __name__ == '__main__':
    unittest.main()
