"""#1963: the idle orphan terminal sweep, on #1958's fleet_rows and close_worker_terminal."""
import copy
import unittest
from pathlib import Path
from unittest.mock import patch

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

    def test_a_host_whose_terminal_list_or_rows_cannot_be_read_is_skipped(self):
        fleet = Fleet(terminals={'host-b': [term('term_o', '#5|fullstack-dev')], '': [term('term_l', '#6|qa-sdet')]})
        fleet.fail = {('terminal', 'list')}
        self.assertEqual(fw.orphan_terminal_sweep(CONFIG, NOW, fleet, ['', 'host-b'], []), [])
        fleet.fail = set()
        rows = [local_row('ctx_u', 'running', '', _host='env-b', _host_read=False)]
        with patch.object(fw, 'environment_name_by_id', return_value={'env-b': 'host-b'}):
            self.assertEqual(fw.orphan_terminal_sweep(CONFIG, NOW, fleet, ['', 'host-b'], rows), ['term_l'])

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


if __name__ == "__main__":
    unittest.main()
