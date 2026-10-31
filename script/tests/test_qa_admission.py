#!/usr/bin/env python3
"""CLI boundary fixtures shaped from native environment/worktree/terminal responses.

The only positive fixture is a hypothetical vacant saved execution host. Current
occupied manual terminals expose agentIdentity, not observed model/process proof.
"""
import copy
import json
import os
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
QA = ROOT / 'qa-admission.py'
ENV_ID = 'e842b011-16a2-4b19-a845-adea377bdee5'
REPO_ID = '5c45d9ec-0d77-4c92-859f-bda6af348340'
IDENTITY = 'wt2:local:572c47db-7726-4298-91ee-0827c6cdf261'
HEAD = 'a' * 40
PATH = '/Users/fixture/orca/workspaces/dotfiles/review'


def utc(seconds=0):
    return (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat()


class QaAdmission(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.policy = {
            'version': 1, 'issued_at': utc(-60), 'expires_at': utc(3600),
            'review': {'runtime_host': 'niteking', 'repo': 'github:mingster/dotfiles',
                       'worktree_path': PATH, 'head': HEAD, 'repo_id': REPO_ID,
                       'project_id': 'github:mingster/dotfiles', 'worktree_identity': IDENTITY,
                       'execution_host_id': 'local', 'saved_environment_id': ENV_ID,
                       'saved_environment_name': 'niteking'},
            'hosts': {
                'blueDevil': {'cap': 3, 'load_ceiling': 12,
                             'providers': {'codex': {'models': ['gpt-6.1-sol']}}},
                'niteking': {'cap': 2, 'load_ceiling': 8,
                            'providers': {'cursor': {'models': ['composer-2.5']}}}}}
        self.config = {'host_caps': {'blueDevil': 3, 'niteking': 2}, 'runs': []}
        self.environments = {'ok': True, 'result': {'environments': [{'id': ENV_ID, 'name': 'niteking'}]}}
        # Fields below are native response fields; no fabricated provider health.
        row = {'id': REPO_ID + '::' + PATH, 'repoId': REPO_ID,
               'projectId': 'github:mingster/dotfiles', 'hostId': 'local',
               'path': PATH, 'head': HEAD,
               'identity': {'key': IDENTITY, 'executionHostId': 'local',
                            'instanceId': IDENTITY.split(':')[-1]},
               'git': {'path': PATH, 'head': HEAD, 'isBare': False}}
        self.worktrees = self.inventory('worktrees', [row])
        self.terminals = self.inventory('terminals', [])
        self.loads = {h: {'load_1m': 1.0, 'observed_at': utc()} for h in self.config['host_caps']}
        self.receipt = {'ok': True, 'admitted': True, 'host': 'niteking', 'cap': 2,
                        'occupied': 0, 'live_count': 0, 'retained_count': 0,
                        'resources': [], 'reason': 'admitted',
                        'receipt': {'host': 'niteking', 'admitted': True, 'status': 'admitted',
                                    'cap': 2, 'occupied': 0, 'live_count': 0, 'retained_count': 0}}
        self.extra_env = {}
        self.write_executable('orca', '''import json,os,sys
from pathlib import Path
root=Path(os.environ['FIXTURE_ROOT'])
args=sys.argv[1:]
with (root/'calls').open('a') as out: out.write(json.dumps(args)+'\\n')
if args[:2]==['environment','list']: name='environments'
elif args[:2]==['worktree','list']: name='worktrees'
elif args[:2]==['terminal','list']: name='terminals'
else: sys.exit(9)
print((root/(name+'.json')).read_text())
''')
        self.write_executable('fleet-watch', '''import os,sys
from pathlib import Path
root=Path(os.environ['FIXTURE_ROOT'])
print((root/'receipt.json').read_text())
sys.exit(int(os.environ.get('FLEET_EXIT','0')))
''')

    @staticmethod
    def inventory(key, rows):
        return {'ok': True, 'result': {key: rows, 'truncated': False,
                'hostScope': {'hostIds': ['local'], 'omittedHostIds': []}}}

    def write_executable(self, name, content):
        p = self.root / name
        p.write_text('#!/usr/bin/env python3\n' + content)
        p.chmod(0o755)

    def run_cli(self):
        for name, value in [('policy', self.policy), ('config', self.config),
                            ('environments', self.environments), ('worktrees', self.worktrees),
                            ('terminals', self.terminals), ('receipt', self.receipt)]:
            (self.root / (name + '.json')).write_text(json.dumps(value))
        env = dict(os.environ, FIXTURE_ROOT=str(self.root),
                   ORCA_CLI_COMMAND=str(self.root/'orca'),
                   ON_WORKER_DONE_FLEET_WATCH=str(self.root/'fleet-watch'),
                   QA_ADMISSION_LOAD_OBS=json.dumps(self.loads), **self.extra_env)
        return subprocess.run(['python3', str(QA), '--policy', str(self.root/'policy.json'),
                               '--fleet-config', str(self.root/'config.json'),
                               '--repo', 'mingster/dotfiles', '--head', HEAD,
                               '--worktree-path', PATH, '--verifier-provider', 'cursor',
                               '--verifier-model', 'composer-2.5'],
                              env=env, text=True, capture_output=True, timeout=15)

    def refused(self, reason):
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, '')
        self.assertIn(reason, result.stderr)
        self.assertNotIn('Traceback', result.stderr)

    def test_vacant_saved_host_uses_native_repo_selector_and_reads_terminals(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'environment_id': ENV_ID,
                         'worktree_selector': 'identity:' + IDENTITY, 'host': 'niteking'})
        calls = [json.loads(s) for s in (self.root/'calls').read_text().splitlines()]
        self.assertIn(['worktree', 'list', '--environment', ENV_ID, '--repo', 'id:'+REPO_ID,
                       '--limit', '100', '--json'], calls)
        self.assertIn(['terminal', 'list', '--environment', ENV_ID, '--json'], calls)

    def test_saved_id_name_mismatch(self):
        self.policy['review']['saved_environment_id'] = 'wrong-id'
        self.refused('saved environment')

    def test_saved_name_missing_no_local_fallback(self):
        del self.policy['review']['saved_environment_name']
        self.refused('saved_environment_name')

    def test_duplicate_environment(self):
        self.environments['result']['environments'] *= 2
        self.refused('ambiguous')

    def test_worktree_bindings(self):
        for key, value in [('repoId', 'other'), ('projectId', 'github:other/repo'),
                           ('path', '/other'), ('head', 'b'*40), ('hostId', 'other'),
                           ('id', 'other')]:
            with self.subTest(key=key):
                saved = copy.deepcopy(self.worktrees)
                self.worktrees['result']['worktrees'][0][key] = value
                try:
                    self.refused('worktree')
                finally:
                    self.worktrees = saved

    def test_identity_and_git_bindings(self):
        for obj, key, value in [('identity', 'key', 'wt2:local:other'),
                                ('identity', 'executionHostId', 'other'),
                                ('git', 'head', 'b'*40), ('git', 'path', '/other')]:
            with self.subTest(obj=obj, key=key):
                saved = copy.deepcopy(self.worktrees)
                self.worktrees['result']['worktrees'][0][obj][key] = value
                try:
                    self.refused('worktree')
                finally:
                    self.worktrees = saved

    def test_complete_native_inventory_required(self):
        for target in ('worktrees', 'terminals'):
            for change in ('missing_truncated', 'truncated', 'missing_scope', 'empty_hosts', 'omitted', 'missing_rows'):
                with self.subTest(target=target, change=change):
                    original = copy.deepcopy(getattr(self, target))
                    result = getattr(self, target)['result']
                    if change == 'missing_truncated': del result['truncated']
                    if change == 'truncated': result['truncated'] = True
                    if change == 'missing_scope': del result['hostScope']
                    if change == 'empty_hosts': result['hostScope']['hostIds'] = []
                    if change == 'omitted': result['hostScope']['omittedHostIds'] = ['remote:unknown']
                    if change == 'missing_rows': del result[target]
                    try:
                        self.refused('inventory')
                    finally:
                        setattr(self, target, original)

    def test_policy_cap_agrees_with_configuration_and_bounds(self):
        for target in ('blueDevil', 'niteking'):
            with self.subTest(host=target):
                self.policy['hosts'][target]['cap'] += 1
                try:
                    self.refused('cap')
                finally:
                    self.policy['hosts'][target]['cap'] -= 1
        self.config['host_caps']['niteking'] = 3
        self.refused('cap')

    def test_policy_cannot_authorize_wrong_host_provider(self):
        self.policy['hosts']['niteking']['providers'] = {'codex': {'models': ['gpt-6.1-sol']}}
        self.refused('provider')

    def test_policy_interval_is_explicit_utc_and_not_calendar_hardcoded(self):
        # The normal positive fixture expires relative to now, not a historical owner date.
        for field, value in [('issued_at', '2026-01-01T00:00:00'),
                             ('expires_at', utc(-1)), ('issued_at', utc(60)),
                             ('expires_at', 'garbage')]:
            with self.subTest(field=field, value=value):
                saved = self.policy[field]
                self.policy[field] = value
                try:
                    self.refused('policy')
                finally:
                    self.policy[field] = saved

    def test_load_both_hosts_finite_fresh_nonfuture(self):
        for host in ('blueDevil', 'niteking'):
            for value in (float('nan'), float('inf'), -1, True, '1.0', 12 if host=='blueDevil' else 8):
                with self.subTest(host=host, load=value):
                    saved = copy.deepcopy(self.loads)
                    self.loads[host]['load_1m'] = value
                    try:
                        self.refused('load')
                    finally:
                        self.loads = saved
            for stamp in (utc(-61), utc(60), 'bad', '2026-01-01T00:00:00'):
                with self.subTest(host=host, stamp=stamp):
                    saved = copy.deepcopy(self.loads)
                    self.loads[host]['observed_at'] = stamp
                    try:
                        self.refused('load')
                    finally:
                        self.loads = saved
        del self.loads['blueDevil']
        self.extra_env['QA_ADMISSION_SELF_LOAD'] = '{"load_1m":0}'
        self.refused('load')

    def test_manual_model_and_process_unknown_even_with_preview(self):
        for orphaned in (True, False):
            with self.subTest(orphaned=orphaned):
                self.terminals['result']['terminals'] = [{
                    'handle': 'term_live', 'executionHostId': 'local',
                    'worktreeId': REPO_ID+'::'+PATH, 'worktreePath': PATH,
                    'connected': True, 'writable': True, 'orphaned': orphaned,
                    'agentIdentity': 'cursor', 'preview': 'Composer 2.5 ready'}]
                self.refused('UNKNOWN')

    def test_strict_fleet_receipt(self):
        for key, value in [('ok', False), ('admitted', 'true'), ('cap', 3),
                           ('occupied', True), ('resources', None), ('receipt', {}),
                           ('live_count', 1), ('host', 'blueDevil')]:
            with self.subTest(key=key):
                saved = copy.deepcopy(self.receipt)
                self.receipt[key] = value
                try:
                    self.refused('receipt')
                finally:
                    self.receipt = saved

    def test_occupied_fleet_resources_have_no_observed_model_process(self):
        self.receipt.update(occupied=1, live_count=1, resources=[{
            'dispatchId': 'ctx_occupied', 'host': 'niteking', 'category': 'live',
            'role': 'reviewer', 'evidence': ['agent running']}])
        self.receipt['receipt'].update(occupied=1, live_count=1)
        self.refused('UNKNOWN')

    def test_fleet_nonzero_cannot_admit(self):
        self.extra_env['FLEET_EXIT'] = '1'
        self.refused('fleet')


if __name__ == '__main__':
    unittest.main()
