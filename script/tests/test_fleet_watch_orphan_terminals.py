"""#1963: the idle orphan terminal sweep, on #1958's fleet_rows and close_worker_terminal."""
import copy
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from fleet_watch_test_env import isolated_main_env
from test_fleet_watch_start_unknown import Base, CONFIG, COORD, FIXTURE, Fleet, NOW, fw, local_row

IDLE = (NOW - 16 * 60) * 1000
BUSY = (NOW - 60) * 1000


def term(handle, title, last=IDLE, path=''):
    return {'handle': handle, 'title': title, 'lastOutputAt': last, 'worktreePath': path or '/w/' + handle}


class OrphanSweep(Base):
    def closed(self, fleet):
        return sorted((c[c.index('--terminal') + 1], c[c.index('--environment') + 1] if '--environment' in c else '')
                      for c in fleet.calls if c[:2] == ('terminal', 'close'))

    def test_closes_only_unheld_idle_worker_or_run_terminals(self):
        fw.protect_pass_terminals(CONFIG, [])
        fleet = Fleet(terminals={
            '': [term(COORD, '#0|elon'), term('term_orphan_local', '#9|fullstack-dev'),
                 term('term_live_local', '#3|qa-sdet')],
            'host-b': [term('term_orphan', '#5|fullstack-dev'), term('term_run', 'wrap-up-daily run 4'),
                       term('term_auto', 'zsh', path='/w/auto-wrap-up-run-7'),
                       term('term_busy', '#6|fullstack-dev', last=BUSY),
                       term('term_live', '#7|fullstack-dev'),
                       term('term_live_path', '#8|fullstack-dev', path='/w/b8'),
                       term('term_shell', 'zsh'), term('term_no_age', '#10|fullstack-dev', last=None)]})
        rows = [local_row('ctx_l', 'running', 'term_live_local'),
                local_row('ctx_live', 'running', '', _host='env-b', _host_terminal='term_live'),
                local_row('ctx_path', 'running', '', _host='env-b', _host_workspace='ws::/w/b8'),
                local_row('ctx_done', 'succeeded', 'term_orphan', terminalState='released')]
        with patch.object(fw, 'environment_name_by_id', return_value={'env-b': 'host-b'}):
            closed = fw.orphan_terminal_sweep(CONFIG, NOW, fleet, ['', 'host-b'], rows)
        self.assertEqual(sorted(closed), ['term_auto', 'term_orphan', 'term_orphan_local', 'term_run'])
        self.assertEqual(self.closed(fleet), [('term_auto', 'host-b'), ('term_orphan', 'host-b'),
                                              ('term_orphan_local', ''), ('term_run', 'host-b')])

    def test_a_terminal_with_no_output_time_is_not_closed(self):
        fw.protect_pass_terminals(CONFIG, [])
        fleet = Fleet(terminals={'': [term(COORD, '#0|elon'), term('term_zero', '#9|fullstack-dev', last=0),
                                      term('term_false', '#9|fullstack-dev', last=False),
                                      term('term_idle', '#9|fullstack-dev')]})
        closed = fw.orphan_terminal_sweep(CONFIG, NOW, fleet, [''], [])
        self.assertEqual(closed, ['term_idle'])

    def test_a_remote_row_worktree_names_its_issue(self):
        self.assertTrue(fw._live_row_names_issue({'_host_workspace': 'ws::/w/b12'}, 12))
        self.assertFalse(fw._live_row_names_issue({'_host_workspace': 'ws::/w/b12'}, 13))

    def test_a_host_whose_terminal_list_or_rows_cannot_be_read_is_skipped(self):
        fleet = Fleet(terminals={'host-b': [term('term_o', '#5|fullstack-dev')], '': [term('term_l', '#6|qa-sdet')]})
        fleet.fail = {('terminal', 'list')}
        self.assertEqual(fw.orphan_terminal_sweep(CONFIG, NOW, fleet, ['', 'host-b'], []), [])
        fleet.fail = set()
        rows = [local_row('ctx_u', 'running', '', _host='env-b', _host_read=False)]
        with patch.object(fw, 'environment_name_by_id', return_value={'env-b': 'host-b'}):
            self.assertEqual(fw.orphan_terminal_sweep(CONFIG, NOW, fleet, ['', 'host-b'], rows), ['term_l'])

    def test_a_remote_worker_finished_on_its_host_is_not_live_for_the_sweep(self):
        # The coordinator's --full stub still says ready and dispatched; host-b's own row says stopped.
        stub = FIXTURE['worker_list_full_row_started']
        env_id = stub['server']['environmentId']
        hosted = dict(FIXTURE['worker_list_host_row_start_unknown'], state='stopped')
        fleet = Fleet(workers={'host-b': [hosted]},
                      terminals={'host-b': [term(hosted['terminal'], '#77|fullstack-dev', path='/w/b77')]})
        with patch.object(fw, 'environment_name_by_id', return_value={env_id: 'host-b'}):
            rows = fw.fleet_rows(CONFIG, [copy.deepcopy(stub)], ['', 'host-b'], fleet)
            fw.protect_pass_terminals(CONFIG, rows)
            self.assertNotIn(hosted['terminal'], fw._LIVE_TERMINALS)
            closed = fw.orphan_terminal_sweep(CONFIG, NOW, fleet, ['', 'host-b'], rows)
        self.assertEqual(closed, [hosted['terminal']])
        self.assertEqual(self.closed(fleet), [(hosted['terminal'], 'host-b')])

    def test_a_host_whose_worker_list_fails_is_skipped_with_no_coordinator_row_on_it(self):
        fleet = Fleet(terminals={'host-b': [term('term_run', 'wrap-up-daily run 4')], '': [term('term_l', '#6|qa-sdet')]})
        fleet.fail = {('orchestration', 'worker-list')}
        with patch.object(fw, 'environment_name_by_id', return_value={'env-b': 'host-b'}):
            rows = fw.fleet_rows(CONFIG, [], ['', 'host-b'], fleet)
            closed = fw.orphan_terminal_sweep(CONFIG, NOW, fleet, ['', 'host-b'], rows)
        self.assertEqual(rows, [])
        self.assertEqual(closed, ['term_l'])
        self.assertEqual(self.closed(fleet), [('term_l', '')])

    def test_dry_run_closes_nothing_and_lists_what_it_would_close(self):
        fleet = Fleet(terminals={'': [term('term_o', '#5|fullstack-dev')]})
        lines = []
        closed = fw.orphan_terminal_sweep(CONFIG, NOW, fleet, [''], [], dry_run=lines.append)
        self.assertEqual(closed, [])
        self.assertFalse([c for c in fleet.calls if c[:2] == ('terminal', 'close')])
        self.assertEqual(len(lines), 1)
        self.assertIn('would close term_o', lines[0])
        self.assertIn('idle 16m', lines[0])

    def test_fleet_rows_carry_the_host_workspace(self):
        stub = FIXTURE['worker_list_full_row_started']
        env_id = stub['server']['environmentId']
        fleet = Fleet(workers={'host-b': [FIXTURE['worker_list_host_row_start_unknown']]})
        with patch.object(fw, 'environment_name_by_id', return_value={env_id: 'host-b'}):
            row = fw.fleet_rows(CONFIG, [copy.deepcopy(stub)], ['', 'host-b'], fleet)[0]
        self.assertEqual(row['_host_workspace'], FIXTURE['worker_list_host_row_start_unknown']['workspace'])

    def test_main_runs_sweep_after_reap_and_before_babysit(self):
        source = (Path(__file__).parent.parent / 'fleet-watch.py').read_text()
        body = source[source.index('\ndef _main('):]
        self.assertLess(body.index("run_phase('reap'"), body.index("run_phase('sweep'"))
        self.assertLess(body.index("run_phase('sweep'"), body.index("pass_phase('babysit')"))


class SweepDryRunMain(Base):
    def run_main(self, directory, *extra):
        config = Path(directory) / 'config.json'
        config.write_text(json.dumps(CONFIG))
        fleet = Fleet(terminals={'': [term('term_o', '#5|fullstack-dev')]})
        lines = []
        with isolated_main_env(directory), \
                patch('sys.argv', ['fleet-watch', '--config', str(config), '--sweep-dry-run', *extra]), \
                patch.object(fw, 'rpc', side_effect=fleet), \
                patch.object(fw, 'fetch_workers', return_value=[]), \
                patch.object(fw, 'environment_name_by_id', return_value={}), \
                patch.object(fw, 'acquire_pass_lock', return_value=None) as lock, \
                patch('builtins.print', side_effect=lambda *a, **k: lines.append(' '.join(map(str, a)))):
            code = fw.main()
        return code, lines, lock, fleet

    def test_sweep_dry_run_needs_no_state_and_takes_no_pass_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            code, lines, lock, fleet = self.run_main(directory)
        self.assertEqual(code, 0)
        self.assertEqual(lock.call_count, 0)
        self.assertTrue(any('would close term_o' in line for line in lines), lines)
        self.assertFalse([c for c in fleet.calls if c[:2] == ('terminal', 'close')])

    def test_sweep_dry_run_lists_while_a_real_pass_holds_the_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            code, lines, lock, _ = self.run_main(directory, '--state', str(Path(directory) / 'state.json'))
        self.assertEqual(code, 0)
        self.assertEqual(lock.call_count, 0)
        self.assertTrue(any('would close term_o' in line for line in lines), lines)


class MainPassWithoutInventory(unittest.TestCase):
    def test_a_failed_inventory_runs_no_reap_or_sweep_and_keeps_the_reaper_book(self):
        book = {'ctx_u': {'at': NOW - 900, 'resent_at': NOW - 300}}
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'config.json'
            state = Path(directory) / 'state.json'
            config.write_text(json.dumps(CONFIG))
            state.write_text(json.dumps({'start_unknown': book}))
            closes = []

            def rpc(*args):
                if args[:2] == ('terminal', 'list'):
                    return {'terminals': [term('term_live', '#7|fullstack-dev')]}
                if args[:2] == ('terminal', 'close'):
                    closes.append(args)
                return {}
            with isolated_main_env(directory), \
                    patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                    patch.object(fw, 'rpc', side_effect=rpc), \
                    patch.object(fw, 'read_orca_inventory', side_effect=fw.OrcaReadError('inbox timed out')), \
                    patch.object(fw, 'environment_name_by_id', return_value={}), \
                    patch.object(fw.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), \
                    patch.object(fw, 'pr_notices', return_value=[]), \
                    patch.object(fw, 'usage_notices', return_value=[]), \
                    patch.object(fw, 'deliver_notices', return_value=None), \
                    patch.object(fw.time, 'time', return_value=NOW), \
                    patch.object(fw, 'start_unknown_reaper', wraps=fw.start_unknown_reaper) as reap, \
                    patch.object(fw, 'orphan_terminal_sweep', wraps=fw.orphan_terminal_sweep) as sweep:
                self.assertEqual(fw.main(), 0)
                saved = json.loads(state.read_text())
        self.assertEqual((reap.call_count, sweep.call_count), (0, 0))
        self.assertEqual(closes, [])
        self.assertEqual(saved.get('start_unknown'), book)


if __name__ == "__main__":
    unittest.main()
