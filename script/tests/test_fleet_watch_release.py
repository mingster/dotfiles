"""#1958: one release interface. Every retire goes through release_worker(rpc_call, row) on the row's host."""
import ast
import importlib.util
import inspect
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)
from fleet_watch_test_env import isolated_main_env

SOURCE = Path(__file__).parent.parent / 'fleet-watch.py'
spec = importlib.util.spec_from_file_location('fleet_watch_release', SOURCE)
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

FIXTURE = json.loads((Path(__file__).parent / 'fixtures' / 'agy-signin-stopped-remote.json').read_text())
ENV = 'env-b'
LOCAL_TERM = 'term_local'
REMOTE_TERM = 'term_remote'
REPO = 'o/r'


class Rpc:
    """Fake Orca: records every call; worker-show and terminal list answer from `shown` and `terminals`."""

    def __init__(self, shown=None, stop_error=None, terminals=None, host_rows=None):
        self.calls = []
        self.shown = shown or {}
        self.stop_error = stop_error
        self.terminals = terminals if terminals is not None else {}
        self.host_rows = host_rows or {}

    def __call__(self, *args):
        self.calls.append(args)
        env = args[args.index('--environment') + 1] if '--environment' in args else ''
        if args[:2] == ('orchestration', 'worker-stop') and self.stop_error:
            err = fw.OrcaReadError(self.stop_error)
            err.orca_error_code = self.stop_error
            raise err
        if args[:2] == ('orchestration', 'worker-show'):
            return self.shown.get((args[3], env)) or {}
        if args[:2] == ('orchestration', 'worker-list'):
            return {'workers': [] if '--terminal-state' in args else list(self.host_rows.get(env, []))}
        if args[:2] == ('terminal', 'list'):
            return {'terminals': [{'handle': h} for h in self.terminals.get(env, [])]}
        if args[:2] == ('terminal', 'close'):
            handle = args[args.index('--terminal') + 1]
            if handle in self.terminals.get(env, []):
                self.terminals[env].remove(handle)
            return {}
        if args[:2] == ('orchestration', 'run-list'):
            return {'runs': []}
        return {}

    def lifecycle(self):
        """(verb, environment) for each stop, release and close, in order."""
        out = []
        for args in self.calls:
            verb = args[1] if args[0] == 'orchestration' else 'close' if args[:2] == ('terminal', 'close') else ''
            if verb in ('worker-stop', 'worker-release', 'close'):
                out.append((verb.replace('worker-', ''), args[args.index('--environment') + 1] if '--environment' in args else ''))
        return out


LOCAL_STEPS = [('stop', ''), ('release', ''), ('close', '')]
REMOTE_STEPS = [('stop', ENV), ('stop', ''), ('release', ENV), ('release', ''), ('close', ENV)]


def local_row(did='ctx_local', **extra):
    row = {'dispatchId': did, 'dispatchStatus': 'dispatched', 'terminalState': 'active', 'terminal': LOCAL_TERM,
           'projection': {'host': {'id': 'local'}}, '_host': ''}
    row.update(extra)
    return row


def remote_row(did='ctx_remote', **extra):
    row = {'dispatchId': did, 'dispatchStatus': 'dispatched', 'workerState': 'ready', 'server': {'environmentId': ENV},
           '_host': ENV, '_host_terminal': REMOTE_TERM}
    row.update(extra)
    return row


class Base(unittest.TestCase):
    def setUp(self):
        fw._PROTECTED_HANDLES.clear()
        fw._LIVE_TERMINALS.clear()
        self.addCleanup(fw._PROTECTED_HANDLES.clear)
        self.addCleanup(fw._LIVE_TERMINALS.clear)

    def default_rpc(self, fake):
        """Patch the module rpc, so a production default release callback talks to `fake`."""
        patcher = patch.object(fw, 'rpc', fake)
        patcher.start()
        self.addCleanup(patcher.stop)
        return fake


class ReleaseWorker(Base):
    def test_local_row_is_stopped_released_and_closed_here(self):
        fake = Rpc()
        row = local_row()
        self.assertEqual(fw.release_worker(fake, row), 'closed')
        self.assertEqual(fake.lifecycle(), LOCAL_STEPS)
        self.assertTrue(row['released'])

    def test_remote_row_is_stopped_and_released_on_its_host_then_here_and_closed_there(self):
        fake = Rpc()
        self.assertEqual(fw.release_worker(fake, remote_row()), 'closed')
        self.assertEqual(fake.lifecycle(), REMOTE_STEPS)

    def test_remote_handle_comes_from_worker_show_on_the_host(self):
        fake = Rpc(shown={('ctx_remote', ENV): {'terminal': REMOTE_TERM}})
        row = remote_row()
        row.pop('_host_terminal')
        self.assertEqual(fw.release_worker(fake, row), 'closed')
        self.assertIn(('terminal', 'close', '--environment', ENV, '--terminal', REMOTE_TERM), fake.calls)

    def test_a_gone_dispatch_counts_as_stopped(self):
        fake = Rpc(stop_error='dispatch_not_found')
        self.assertEqual(fw.release_worker(fake, local_row()), 'closed')
        self.assertEqual(fake.lifecycle(), LOCAL_STEPS)

    def test_any_other_stop_error_does_nothing_else(self):
        fake = Rpc(stop_error='terminal_busy')
        row = remote_row()
        self.assertEqual(fw.release_worker(fake, row), 'stop_failed:terminal_busy')
        self.assertEqual(fake.lifecycle(), [('stop', ENV)])
        self.assertNotIn('released', row)

    def test_the_coordinator_terminal_is_kept(self):
        fw._PROTECTED_HANDLES.add(LOCAL_TERM)
        fake = Rpc()
        self.assertEqual(fw.release_worker(fake, local_row()), 'kept:coordinator')
        self.assertEqual(fake.lifecycle(), LOCAL_STEPS[:2])

    def test_no_handle_is_kept_no_handle(self):
        fake = Rpc()
        self.assertEqual(fw.release_worker(fake, {'dispatchId': 'ctx_x', '_host': ''}), 'kept:no_handle')
        self.assertEqual(fake.lifecycle(), LOCAL_STEPS[:2])


class FleetRows(Base):
    def coordinator_row(self):
        return dict(FIXTURE['worker_list_full_row_started'], _task_title='#1958|fullstack-dev', _fleet_watch_list_run='run_x')

    def test_fixture_remote_row_is_merged_with_its_host_row(self):
        env_id = FIXTURE['worker_list_full_row_started']['server']['environmentId']
        fake = Rpc(host_rows={'host-b': [FIXTURE['worker_list_host_row_start_unknown']]})
        with patch.object(fw, 'environment_name_by_id', return_value={env_id: 'host-b'}):
            rows = fw.fleet_rows({}, [self.coordinator_row()], ['', 'host-b'], fake)
        self.assertEqual(len([r for r in rows if r['dispatchId'] == 'ctx_a3e0fbf0486a']), 1)
        row = rows[0]
        self.assertEqual(row['_task_title'], '#1958|fullstack-dev')
        self.assertEqual(row['_host'], env_id)
        self.assertEqual(row['_state'], 'start_unknown')
        self.assertEqual(row['_host_terminal'], 'term_acafe9e8-9506-4d00-9015-61ec51cad6da')
        self.assertTrue(row['_host_read'])

    def test_merged_row_stays_remote_for_every_other_pass(self):
        env_id = FIXTURE['worker_list_full_row_started']['server']['environmentId']
        fake = Rpc(host_rows={'host-b': [FIXTURE['worker_list_host_row_start_unknown']]})
        with patch.object(fw, 'environment_name_by_id', return_value={env_id: 'host-b'}):
            row = fw.fleet_rows({}, [self.coordinator_row()], ['', 'host-b'], fake)[0]
        self.assertTrue(fw.worker_is_remote(row, {}))
        self.assertNotEqual(fw.worker_execution_host_id(row), 'local')
        self.assertEqual(fw.worker_terminal_handle(row), '')

    def test_unreadable_host_marks_its_rows(self):
        env_id = FIXTURE['worker_list_full_row_started']['server']['environmentId']

        def broken(*args):
            if '--environment' in args:
                raise fw.OrcaReadError('down')
            return {}
        with patch.object(fw, 'environment_name_by_id', return_value={env_id: 'host-b'}):
            rows = fw.fleet_rows({}, [self.coordinator_row(), local_row()], ['', 'host-b'], broken)
        self.assertEqual([r['_host_read'] for r in rows], [False, True])
        self.assertEqual(rows[1]['_host'], '')

    def test_repo_falls_back_to_the_recorded_start(self):
        state = {}
        fw.record_own_dispatch(state, 'ctx_local', 'issue', repo=REPO)
        rows = fw.fleet_rows({}, [{'dispatchId': 'ctx_local', 'projection': {'host': {'id': 'local'}}}], [''], Rpc(), state)
        self.assertEqual(rows[0]['_repo'], REPO)

    def test_row_for_dispatch_returns_the_row_or_a_minimal_one(self):
        row = local_row()
        self.assertIs(fw.row_for_dispatch([row], 'ctx_local'), row)
        self.assertEqual(fw.row_for_dispatch([row], 'ctx_gone', ENV), {'dispatchId': 'ctx_gone', '_host': ENV})


class Callers(Base):
    """One test per caller in the #1958 table, through the production default release, only rpc faked."""

    def both(self, run):
        for row, steps in ((local_row(), LOCAL_STEPS), (remote_row(), REMOTE_STEPS)):
            fake = self.default_rpc(Rpc())
            run(row)
            self.assertEqual(fake.lifecycle(), steps, row['dispatchId'])

    def test_stop_and_release_stalled(self):
        for row, steps in ((local_row(), LOCAL_STEPS), (remote_row(), REMOTE_STEPS)):
            fake = Rpc()
            self.assertEqual(fw.stop_and_release_stalled(fake, row, row['dispatchId'], row['_host']), '')
            self.assertEqual(fake.lifecycle(), steps)
        fake = Rpc(stop_error='busy')
        self.assertEqual(fw.stop_and_release_stalled(fake, local_row(), 'ctx_local'), 'busy')
        self.assertEqual(fake.lifecycle(), [('stop', '')])

    def test_reconcile_remote_completions(self):
        fake = Rpc()
        row = remote_row(workerState='failed', dispatchStatus='failed')
        fw.reconcile_remote_completions({}, {}, [row], [], fake)
        self.assertEqual(fake.lifecycle(), REMOTE_STEPS)

    def test_release_green_successes(self):
        def run(row):
            row.update(githubPullRequestNumber=7, repo=REPO)
            done = {'id': 'm', 'type': 'worker_done', 'payload': {'dispatchId': row['dispatchId'], 'outcome': 'succeeded'}}
            pr = {'number': 7, 'state': 'OPEN', 'statusCheckRollup': [{'conclusion': 'SUCCESS', 'status': 'COMPLETED'}]}
            with patch.object(fw, 'repo_for_worker', return_value=REPO):
                freed = fw.release_green_successes([done], [row], {}, {}, fw._release_row, lambda _r, _n: pr)
            self.assertEqual(freed, [row['dispatchId']])
        self.both(run)

    def test_release_green_successes_books_only_a_real_release(self):
        state = {}
        row = local_row(githubPullRequestNumber=7)
        done = {'id': 'm', 'type': 'worker_done', 'payload': {'dispatchId': 'ctx_local', 'outcome': 'succeeded'}}
        pr = {'number': 7, 'state': 'OPEN', 'statusCheckRollup': [{'conclusion': 'SUCCESS', 'status': 'COMPLETED'}]}
        with patch.object(fw, 'repo_for_worker', return_value=REPO):
            freed = fw.release_green_successes([done], [row], {}, state, lambda _row: 'failed', lambda _r, _n: pr)
        self.assertEqual((freed, state['auto_released']), ([], []))

    def test_release_dead_followups(self):
        def run(row):
            parent = {'dispatchId': 'ctx_parent', 'workerState': 'succeeded', 'dispatchStatus': 'completed'}
            row.update(dispatchStatus='failed', follow_up_of_dispatch_id='ctx_parent', liveness='exited')
            row['projection'] = dict(row.get('projection') or {}, liveness={'verdict': 'exited'})
            state = {}
            self.assertEqual(fw.release_dead_followups([parent, row], state, fw._release_row), [row['dispatchId']])
            self.assertEqual(state['followup_released'], [row['dispatchId']])
        self.both(run)

    def verifier(self, row):
        row.update(title='#7|qa-sdet', terminalState='active', dispatchStatus='dispatched')
        return row

    def test_release_closed_verifier(self):
        self.both(lambda row: self.assertTrue(fw.release_closed_verifier(
            {'number': 7}, [self.verifier(row)], {}, REPO, fw._release_row)))

    def test_release_idle_rework_verifier(self):
        head = 'a' * 40
        pr = {'number': 7, 'headRefOid': head, 'comments': [{'body': 'Review: FAIL head=%s' % head}]}

        def run(row):
            handle = row.get('_host_terminal') or row['terminal']
            row['terminal'] = handle
            self.assertTrue(fw.release_idle_rework_verifier(
                pr, [self.verifier(row)], {}, REPO, 10_000, {handle: 1}, fw._release_row))
        self.both(run)

    def test_route_rework_head(self):
        def run(row):
            handle = row.get('_host_terminal') or row['terminal']
            row['terminal'] = handle
            state = {'verifier_head': {REPO: {'7': 'old'}}}
            got = fw.route_rework_head({'number': 7, 'headRefOid': 'new'}, [self.verifier(row)], state, REPO,
                                       10_000, {handle: 1}, fw._release_row, lambda *_a: None)
            self.assertEqual(got, 'released')
        self.both(run)

    def test_standing_retire_finds_the_row_or_uses_the_record_host(self):
        self.both(lambda row: fw.standing_retire(
            {}, 'host-x', {'dispatch_id': row['dispatchId']}, 'gone', [row], fw._release_row, 0, []))
        fake = self.default_rpc(Rpc())
        fw.standing_retire({}, ENV, {'dispatch_id': 'ctx_gone'}, 'gone', [], fw._release_row, 0, [])
        self.assertEqual(fake.lifecycle()[:4], REMOTE_STEPS[:4])
        fake = self.default_rpc(Rpc())
        fw.standing_retire({}, ENV, {'dispatch_id': 'ctx_gone', 'local': True}, 'gone', [], fw._release_row, 0, [])
        self.assertEqual(fake.lifecycle(), LOCAL_STEPS[:2])

    def test_standing_housekeeping_and_wake_fail_pass_rows_through(self):
        def run(row):
            row.update(dispatchStatus='failed')
            state = {'standing_verifiers': {'h': {'dispatch_id': row['dispatchId']}}}
            fw.standing_housekeeping({}, state, [row], {}, None, fw._release_row, 0, [])
        self.both(run)
        self.both(lambda row: fw.standing_wake_fail(
            {}, 'h', {'dispatch_id': row['dispatchId']}, 'probe', [row], fw._release_row, 0, []))

    def test_standing_route_retires_through_the_row_callback(self):
        class IO:
            def read(self, _terminal, _host):
                return '', None

        def run(row):
            rec = {'dispatch_id': row['dispatchId'], 'terminal': 't', 'prs_assigned': ['a', 'b', 'c', 'd', 'e', 'f']}
            state = {'standing_verifiers': {'h': rec}}
            config = {'standing_verifier': {'enabled': True, 'hosts': ['h'], 'max_prs': 1}}
            with patch.object(fw, '_agy_signin', return_value=type('S', (), {'usable': lambda _s, _a, _h, _c: True})()), \
                    patch.object(fw, 'standing_settings', return_value={'enabled': True, 'hosts': ['h'], 'max_prs': 1,
                                                                        'agent': 'claude', 'model': 'm'}), \
                    patch.object(fw, 'build_babysit_command', return_value=None):
                fw.standing_route(config, state, [row], REPO, {'number': 7, 'headRefOid': 'h'}, None, '', {}, IO(),
                                  lambda _c: 1, fw._release_row, 0, {}, [])
        self.both(run)

    def test_babysit_pass_dead_verifier_uses_the_default_row_callback(self):
        from test_fleet_watch_1932 import Harness, stopped
        for row_extra, steps in (({}, LOCAL_STEPS[:2]), ({'_host': ENV}, REMOTE_STEPS[:4])):
            with tempfile.TemporaryDirectory() as root, patch.object(fw, 'run_gh', return_value=0):
                h = Harness(root)
                fake = self.default_rpc(Rpc())
                h.run()
                fake.calls.clear()
                fw.babysit_pass(h.config, h.state, [dict(stopped('ctx_v1'), **row_extra)],
                                pr_fetch=lambda _repo: [__import__('test_fleet_watch_park').verifier_pr()],
                                start_worker=h.start, pick=lambda _r: {'selected': {'provider': 'cursor', 'model': 'm', 'eligible': True}},
                                owner_check=lambda _pr: None)
                self.assertEqual(fake.lifecycle()[:len(steps)], steps, row_extra)


class RestartExceptions(Base):
    """The two named restarts keep their own rpc call, sent to the row's host (#1958)."""

    def stall_rows(self):
        import test_fleet_watch_stall as stall
        return stall

    def test_stall_restart_stops_on_the_row_host(self):
        stall = self.stall_rows()
        for host, where in (('', ()), (ENV, ('--environment', ENV))):
            fake = Rpc()
            w = stall.base_worker(_host=host, projection={'host': {'id': 'local'}, 'provider': {'id': 'claude', 'model': None},
                                                          'outcome': 'in_progress', 'liveness': {'verdict': 'idle'}})
            fw.worker_stall_pass(stall.stall_test_config(), stall.mark_own({}, 'disp_fixture'), stall.T0, [w],
                                 {'term_fix': stall.OLD_MS}, fake)
            stops = [c for c in fake.calls if c[:2] == ('orchestration', 'worker-stop')]
            self.assertEqual(stops, [('orchestration', 'worker-stop', '--dispatch', 'disp_fixture') + where], host)

    def test_startup_retry_releases_on_the_row_host(self):
        stall = self.stall_rows()
        for host, where in (('', ()), (ENV, ('--environment', ENV))):
            fake = Rpc()
            w = stall.base_worker(_host=host, dispatchStatus='failed', stage='agent_readiness',
                                  lastError='terminal_exited')
            fw.worker_stall_pass(stall.stall_test_config(), stall.mark_own({}, 'disp_fixture'), stall.T0, [w],
                                 {'term_fix': stall.OLD_MS}, fake)
            releases = [c for c in fake.calls if c[:2] == ('orchestration', 'worker-release')]
            self.assertEqual(releases, [('orchestration', 'worker-release', '--dispatch', 'disp_fixture') + where], host)


class MainWiring(Base):
    def main(self, argv, inventory=None, workers_json=None):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'config.json'
            state = Path(directory) / 'state.json'
            config.write_text(json.dumps({'runs': [{'id': 'run_fixture', 'terminal': 'term_sender'}],
                                          'babysit': {'repos': [REPO]}}))
            state.write_text('{}')
            extra = []
            if workers_json is not None:
                path = Path(directory) / 'workers.json'
                path.write_text(json.dumps(workers_json))
                extra = ['--workers-json', str(path)]
            seen = {}
            with isolated_main_env(directory), \
                    patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)] + argv + extra), \
                    patch.object(fw, 'rpc', return_value={}), \
                    patch.object(fw, 'read_orca_inventory', return_value=inventory or {}), \
                    patch.object(fw, 'pr_notices', return_value=[]), \
                    patch.object(fw, 'usage_notices', return_value=[]), \
                    patch.object(fw, 'deliver_notices', return_value=None), \
                    patch.object(fw, 'release_green_successes',
                                 side_effect=lambda *a, **k: seen.setdefault('green', a[4]) and []), \
                    patch.object(fw, 'release_dead_followups',
                                 side_effect=lambda *a, **k: seen.setdefault('followup', a[2]) and []), \
                    patch.object(fw, 'babysit_pass',
                                 side_effect=lambda *a, **k: seen.setdefault('babysit', (a[2], k)) and ([], [], [])):
                fw.main()
            return seen

    def test_main_release_phase_uses_the_row_callback(self):
        inventory = {'messages': [], 'workers': [local_row()], 'alive': {'run_fixture': True}, 'leads': {}}
        seen = self.main([], inventory)
        self.assertIs(seen['green'], fw._release_row)
        self.assertIs(seen['followup'], fw._release_row)

    def test_babysit_only_builds_fleet_rows_first(self):
        seen = self.main(['--babysit-only'], workers_json=[{'dispatchId': 'ctx_r', 'server': {'environmentId': ENV}}])
        rows, kwargs = seen['babysit']
        self.assertEqual(rows[0]['_host'], ENV)
        self.assertNotIn('release_worker', kwargs)


class Defaults(Base):
    def test_every_release_callback_takes_exactly_one_row(self):
        self.assertEqual(list(inspect.signature(fw._release_row).parameters), ['row'])
        self.default_rpc(Rpc())
        self.assertEqual(fw._release_row(local_row()), 'closed')
        tree = ast.parse(SOURCE.read_text())
        bad = []
        for fn in ast.walk(tree):
            if not isinstance(fn, ast.FunctionDef):
                continue
            params = {a.arg for a in fn.args.args + fn.args.kwonlyargs}
            for call in ast.walk(fn):
                if not isinstance(call, ast.Call) or not isinstance(call.func, ast.Name):
                    continue
                name = call.func.id
                callback = name == 'release' or (name == 'release_worker' and 'release_worker' in params)
                want = 1 if callback else 2 if name == 'release_worker' else None
                if want is not None and len(call.args) != want:
                    bad.append('%s:%d %s' % (fn.name, call.lineno, name))
        self.assertEqual(bad, [])

    def test_babysit_pass_default_is_the_row_callback(self):
        self.assertIsNone(inspect.signature(fw.babysit_pass).parameters['release_worker'].default)
        self.assertIn('release_worker = _release_row', inspect.getsource(fw.babysit_pass))


class ReleaseByFragment(Base):
    def test_remote_finished_worker_is_released_and_its_terminal_gone(self):
        host_row = {'dispatchId': 'ctx_abcd1234', 'state': 'succeeded', 'terminal': REMOTE_TERM, 'host': 'local'}
        fake = Rpc(host_rows={ENV: [host_row]}, terminals={ENV: [REMOTE_TERM], '': []})
        code, message = fw.release_worker_by_fragment('abcd1234', {}, fake, ['', ENV])
        self.assertEqual(code, 0, message)
        self.assertEqual(fake.lifecycle(), REMOTE_STEPS)
        self.assertEqual(fake.terminals[ENV], [])

    def test_dead_dispatch_with_terminal_gone_from_host_releases_clean(self):
        dead = {'dispatchId': 'ctx_dead1234', 'state': 'ready', 'terminal': REMOTE_TERM, 'host': 'local'}
        fake = Rpc(host_rows={ENV: [dead]}, terminals={ENV: [], '': []})
        code, message = fw.release_worker_by_fragment('dead1234', {}, fake, ['', ENV], allow_live=True)
        self.assertEqual(code, 0, message)
        self.assertIn('terminal already gone', message)
        self.assertEqual(fake.lifecycle(), [('stop', ENV), ('stop', ''), ('release', ENV), ('release', '')])

    def test_live_target_needs_live_and_coordinator_is_refused(self):
        live = {'dispatchId': 'ctx_live1234', 'state': 'ready', 'terminal': LOCAL_TERM}
        fake = Rpc(host_rows={'': [live]}, terminals={'': [LOCAL_TERM]})
        code, message = fw.release_worker_by_fragment('live1234', {}, fake, [''])
        self.assertEqual((code, fake.lifecycle()), (1, []), message)
        code, message = fw.release_worker_by_fragment('live1234', {'runs': [{'terminal': LOCAL_TERM}]}, fake, [''], True)
        self.assertIn('coordinator', message)
        self.assertEqual(fake.lifecycle(), [])

    def test_script_passes_the_fragment_through(self):
        text = (SOURCE.parent / 'release-worker.sh').read_text()
        self.assertIn('--release-worker "$1"', text)


if __name__ == '__main__':
    unittest.main()
