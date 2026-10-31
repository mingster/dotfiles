#!/usr/bin/env python3
"""Real admission against canned native inventories, never a success double."""
import copy
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from qa_admission_fixture import NativeFixture, HEAD, PATH, REPO

QA = Path(__file__).resolve().parents[1]/'qa-admission.py'


class QaAdmission(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.f = NativeFixture(self.tmp.name)
        self.provider, self.model = 'claude', 'sonnet'
        self.extra = {}

    def run_cli(self):
        env = {**self.f.env(), **self.extra}
        env = {k: v for k, v in env.items() if v is not None}
        return subprocess.run(['python3', str(QA), '--repo', REPO, '--head', HEAD,
                               '--worktree-path', PATH, '--verifier-provider', self.provider,
                               '--verifier-model', self.model],
                              env=env, text=True, capture_output=True, timeout=15)

    def success(self, host='alpha'):
        p = self.run_cli()
        self.assertEqual(p.returncode, 0, p.stderr)
        data = json.loads(p.stdout)
        self.assertEqual(data['environment_id'], host+'-saved')
        self.assertEqual(data['worktree_selector'], 'identity:wt2:local:'+host+'-instance')
        self.assertEqual(data['host'], host)
        return data

    def refuse(self, reason):
        p = self.run_cli()
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, '')
        self.assertIn(reason, p.stderr)
        self.assertNotIn('Traceback', p.stderr)

    def test_absent_optional_policy_accepts_claude(self):
        self.success()

    def test_requested_models_are_not_hardcoded_by_host(self):
        for self.provider, self.model in [('codex', 'gpt-6.1-sol'), ('cursor', 'composer-2.5'),
                                          ('antigravity', 'gemini-next'), ('claude', 'claude-sonnet')]:
            with self.subTest(provider=self.provider): self.success()

    def test_occupied_undercap_succeeds(self):
        self.f.occupy('alpha', 1)
        self.success()

    def test_retained_resources_count_without_model_proof(self):
        self.f.occupy('alpha', 1, 'completed')
        self.success()

    def test_full_selected_host_tries_available_host(self):
        self.f.occupy('alpha', 2)
        self.success('beta')

    def test_all_full_enumerates_counts(self):
        self.f.occupy('alpha', 2); self.f.occupy('beta', 3)
        self.refuse('alpha 2/2')
        self.refuse('beta 3/2')

    def test_worktree_binding_fields_failclosed(self):
        for key, val in [('repoId', 'other'), ('projectId', 'github:other/repo'),
                         ('head', 'b'*40), ('path', '/other'), ('hostId', 'other'), ('id', 'other')]:
            with self.subTest(key=key):
                original = copy.deepcopy(self.f.data)
                for h in ('alpha', 'beta'): self.f.data[h]['worktrees']['worktrees'][0][key] = val
                self.refuse('worktree')
                self.f.data = original

    def test_identity_git_bindings_failclosed(self):
        for obj, key, value in [('identity', 'executionHostId', 'other'),
                                ('identity', 'key', 'wt2:local:other'),
                                ('git', 'head', 'b'*40), ('git', 'path', '/other'), ('git', 'isBare', True)]:
            with self.subTest(key=key):
                original = copy.deepcopy(self.f.data)
                for h in ('alpha', 'beta'): self.f.data[h]['worktrees']['worktrees'][0][obj][key] = value
                self.refuse('worktree')
                self.f.data = original

    def test_unknown_worktree_coverage_refuses(self):
        for key, value in [('truncated', True), ('hostScope', {}), ('worktrees', None)]:
            with self.subTest(key=key):
                original = copy.deepcopy(self.f.data)
                self.f.data['alpha']['worktrees'][key] = value
                self.refuse('inventory')
                self.f.data = original

    def test_unknown_worker_data_refuses(self):
        for field, value in [('workers', None), ('page', {}), ('scope', {})]:
            with self.subTest(field=field):
                original = copy.deepcopy(self.f.data)
                self.f.data['alpha']['workers'][field] = value
                self.refuse('worker')
                self.f.data = original

    def test_unknown_host_or_status_refuses(self):
        self.f.occupy('alpha', 1)
        worker = self.f.data['alpha']['workers']['workers'][0]
        del worker['projection']
        self.refuse('host')
        worker['projection'] = {'host': {'id': 'local'}}
        worker['dispatchStatus'] = 'mystery'
        self.refuse('worker')

    def test_unknown_release_refuses(self):
        self.f.occupy('alpha', 1, 'release_unknown')
        self.refuse('release_unknown')

    def test_duplicate_dispatch_refuses(self):
        self.f.occupy('alpha', 1)
        rows = self.f.data['alpha']['workers']['workers']; rows.append(copy.deepcopy(rows[0]))
        self.refuse('duplicate')

    def test_invalid_config_caps_refuse(self):
        for value in (0, True, -1, '2'):
            with self.subTest(value=value):
                self.f.config['host_caps']['alpha'] = value
                self.refuse('cap')

    def test_load_unknown_invalid_or_hot_refuses(self):
        original = copy.deepcopy(self.f.loads)
        for val in (True, -1, '1', float('nan'), 12):
            with self.subTest(value=val):
                self.f.loads['alpha']['load_1m'] = val
                self.refuse('load')
                self.f.loads = copy.deepcopy(original)
        del self.f.loads['alpha']; self.refuse('load')

    def test_stale_or_future_load_refuses(self):
        for stamp in ('2000-01-01T00:00:00Z', '2099-01-01T00:00:00Z', 'bad'):
            self.f.loads['alpha']['observed_at'] = stamp
            self.refuse('load')

    def test_optional_policy_cannot_expand_configuration(self):
        p = Path(self.tmp.name)/'policy.json'
        p.write_text(json.dumps({'version': 1, 'issued_at': '2000-01-01T00:00:00Z',
                                'expires_at': '2099-01-01T00:00:00Z',
                                'hosts': {'alpha': {'cap': 3}}}))
        self.extra['ON_WORKER_DONE_ADMISSION_POLICY'] = str(p)
        self.refuse('cap')

    def test_native_retained_release_state_counts(self):
        self.f.occupy('alpha', 1)
        self.f.data['alpha']['workers']['workers'][0]['resource']['releaseState'] = 'retained'
        data = self.success()
        self.assertEqual(data['receipts'][0]['occupied'], 1)

    def test_native_legacy_retained_dispatch_needs_no_model_proof(self):
        self.f.occupy('alpha', 1, 'completed')
        worker = self.f.data['alpha']['workers']['workers'][0]
        worker.update(resource=None, terminalState='retained', agentTerminalHandle='term-native')
        data = self.success()
        self.assertEqual(data['receipts'][0]['retained_count'], 1)

    def test_malformed_nested_native_json_fails_without_traceback(self):
        self.f.data['alpha']['repos'][0]['gitRemoteIdentity'] = []
        self.refuse('inventory')

    def test_native_pagination_counts_later_page(self):
        self.f.occupy('alpha', 1)
        first = self.f.data['alpha']['workers']
        second = copy.deepcopy(first)
        second['workers'][0]['dispatchId'] = 'ctx-second'
        second['workers'][0]['resource']['terminalHandle'] = 'term-second'
        first['page'] = {'hasMore': True, 'nextCursor': 'next'}
        self.f.data['alpha']['next_page'] = second
        self.success('beta')
        calls = [json.loads(line) for line in (Path(self.tmp.name)/'calls').read_text().splitlines()]
        self.assertTrue(any('--cursor' in call and 'next' in call for call in calls))

    def test_repeated_or_missing_page_cursor_refuses(self):
        page = self.f.data['alpha']['workers']['page']
        page.update(hasMore=True, nextCursor='same')
        self.f.data['alpha']['next_page'] = self.f.data['alpha']['workers']
        self.refuse('cursor')
        page.pop('nextCursor')
        self.refuse('cursor')

    def test_local_native_identity_does_not_invent_saved_server(self):
        self.f.config['local_host'] = 'alpha'
        self.f.data['environments'] = [r for r in self.f.data['environments'] if r['name'] != 'alpha']
        self.f.data['local'] = self.f.data.pop('alpha')
        p = self.run_cli()
        self.assertEqual(p.returncode, 0, p.stderr)
        data = json.loads(p.stdout)
        self.assertEqual(data['environment_id'], 'local')
        self.assertEqual(data['worktree_selector'], 'identity:wt2:local:alpha-instance')

    def test_optional_policy_validity_and_model_narrowing(self):
        p = Path(self.tmp.name)/'policy.json'
        policy = {'version': 1, 'issued_at': '2000-01-01T00:00:00Z',
                  'expires_at': '2099-01-01T00:00:00Z',
                  'hosts': {'alpha': {'providers': {'claude': {'models': ['sonnet']}}}}}
        self.extra['ON_WORKER_DONE_ADMISSION_POLICY'] = str(p)
        p.write_text(json.dumps(policy))
        self.success()
        self.model = 'other'; self.refuse('provider/model')
        self.model = 'sonnet'
        policy['expires_at'] = '2001-01-01T00:00:00Z'; p.write_text(json.dumps(policy))
        self.refuse('policy')

    def test_unconfigured_sensor_failure_does_not_block_configured_hosts(self):
        sensor = Path(self.tmp.name)/'load.sh'
        sensor.write_text("echo 'alpha cores=8 load=1 1 1'\necho 'beta cores=8 load=1 1 1'\necho 'unused unreachable'\n")
        self.extra.update(QA_ADMISSION_LOAD_OBS=None, QA_ADMISSION_FLEET_LOAD=str(sensor))
        self.success()

    def test_native_resource_reuse_counts_one_live_seat(self):
        self.f.occupy('alpha', 1)
        rows = self.f.data['alpha']['workers']['workers']
        old = copy.deepcopy(rows[0]); old.update(dispatchId='ctx-old', dispatchStatus='completed')
        rows.append(old)
        data = self.success()
        self.assertEqual(data['receipts'][0]['occupied'], 1)
        self.assertEqual(data['receipts'][0]['live_count'], 1)

    def test_identity_key_cannot_target_another_execution_host(self):
        for h in ('alpha', 'beta'):
            self.f.data[h]['worktrees']['worktrees'][0]['identity']['key'] = 'wt2:other:'+h+'-instance'
        self.refuse('worktree')

    def test_ambiguous_repo_inventory_is_unknown(self):
        self.f.data['alpha']['repos'].append(copy.deepcopy(self.f.data['alpha']['repos'][0]))
        self.refuse('repo inventory')

    def test_malformed_worktree_host_scope_refuses_without_traceback(self):
        self.f.data['alpha']['worktrees']['hostScope']['hostIds'] = [{}]
        self.refuse('inventory')

    def test_missing_or_expired_explicit_policy_refuses(self):
        self.extra['ON_WORKER_DONE_ADMISSION_POLICY'] = str(Path(self.tmp.name)/'missing')
        self.refuse('policy')

    def test_workers_across_multiple_runs_share_host_cap(self):
        self.f.add_run('alpha', 'run-other')
        self.f.occupy('alpha', 1, run_id='run-alpha')
        self.f.occupy('alpha', 1, run_id='run-other')
        self.success('beta')

    def test_bound_run_scope_refuses(self):
        self.f.data['alpha']['workers_by_run']['run-alpha']['scope'] = {'source': 'bound', 'run': 'run-alpha'}
        self.refuse('UNKNOWN coverage')

    def test_run_list_pagination_counts_every_run(self):
        self.f.data['alpha']['runs'] = {'runs': [{'id': 'run-alpha'}], 'nextCursor': 'runs-2'}
        self.f.data['alpha']['run_pages'] = {'runs-2': {'runs': [{'id': 'run-extra'}], 'nextCursor': None}}
        self.f.occupy('alpha', 1, run_id='run-alpha')
        self.f.occupy('alpha', 1, run_id='run-extra')
        self.success('beta')
        calls = [json.loads(line) for line in (Path(self.tmp.name)/'calls').read_text().splitlines()]
        self.assertTrue(any(a[:2] == ['orchestration', 'run-list'] and '--cursor' in a for a in calls))

    def test_incomplete_run_inventory_refuses(self):
        self.f.data['alpha']['runs']['nextCursor'] = 'missing-page'
        self.refuse('Orca orchestration inventory')

    def test_remote_inventory_unavailable_refuses(self):
        self.f.data['alpha']['workers_by_run']['run-alpha']['scope']['remote'] = 'unavailable'
        self.refuse('remote inventory unavailable')


if __name__ == '__main__': unittest.main()
