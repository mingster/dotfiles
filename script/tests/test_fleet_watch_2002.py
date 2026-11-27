"""#2002: a finished automation run terminal closes on the next pass without waiting for lastOutputAt.

The run's Orca automation record (status completed) or its tail (the wrapper's `ok <job>` or `FAILED <job>` line)
says the job ended. Worker terminals and guarded terminals keep their rules."""
import unittest
from unittest.mock import patch

from test_fleet_watch_start_unknown import Base, CONFIG, COORD, Fleet, NOW, fw, local_row

FRESH = (NOW - 60) * 1000  # the status line repainted a minute ago
RUN_PATH = '/w/auto-wrap-up-daily-run-6-20261127T0309'


def term(handle, title, last=FRESH, path=''):
    return {'handle': handle, 'title': title, 'lastOutputAt': last, 'worktreePath': path or '/w/' + handle}


def run_record(path, status='completed'):
    return {'id': 'run_' + path[-6:], 'status': status, 'workspaceId': 'proj-host::' + path,
            'title': 'wrap-up-daily run 6'}


class RunFleet(Fleet):
    """Fake orca with automation run records and terminal tails. Other verbs go to Fleet."""

    def __init__(self, runs=(), tails=None, **kwargs):
        super().__init__(**kwargs)
        self.runs = list(runs)
        self.tails = tails or {}

    def __call__(self, *args):
        verb = tuple(args[:2])
        if verb == ('automations', 'runs'):
            self.calls.append(tuple(args))
            if verb in self.fail:
                raise fw.OrcaReadError('automation list unavailable')
            return {'runs': list(self.runs)}
        if verb == ('terminal', 'read') and '--limit' in args:
            self.calls.append(tuple(args))
            handle = args[args.index('--terminal') + 1]
            return {'terminal': {'tail': list(self.tails.get(handle, []))}}
        return super().__call__(*args)


OK_LINE = ['repo /x seconds=36', 'ok wrap-up-daily: skip: load 16.70 at or above 0.7 per core (exit=0, 0s)']
WORKING = ['repo /work/project-a seconds=330', 'Reviewing the wrap-up log', 'load 0.4']


class RunTerminalFinished(Base):
    def sweep(self, fleet, rows=(), dry_run=None):
        fw.protect_pass_terminals(CONFIG, [])
        return fw.orphan_terminal_sweep(CONFIG, NOW, fleet, [''], list(rows), dry_run=dry_run)

    def closed(self, fleet):
        return [c[c.index('--terminal') + 1] for c in fleet.calls if c[:2] == ('terminal', 'close')]

    def test_completed_run_record_closes_a_run_terminal_with_a_fresh_output_time(self):
        fleet = RunFleet(runs=[run_record(RUN_PATH)],
                         terminals={'': [term('term_run', 'wrap-up-daily run 6', path=RUN_PATH)]})
        self.assertEqual(self.sweep(fleet), ['term_run'])
        self.assertEqual(self.closed(fleet), ['term_run'])

    def test_reply_line_in_the_tail_closes_a_run_terminal_with_a_fresh_output_time(self):
        fleet = RunFleet(tails={'term_run': OK_LINE},
                         terminals={'': [term('term_run', 'wrap-up-daily run 6', path=RUN_PATH)]})
        self.assertEqual(self.sweep(fleet), ['term_run'])

    def test_failed_reply_line_also_counts_as_finished(self):
        tail = ['FAILED wrap-up-daily: round failed: repo /x exit 124 (exit=1, 442s)']
        fleet = RunFleet(tails={'term_run': tail},
                         terminals={'': [term('term_run', 'wrap-up-daily run 6', path=RUN_PATH)]})
        self.assertEqual(self.sweep(fleet), ['term_run'])

    def test_a_failed_record_lookup_falls_back_to_the_tail(self):
        fleet = RunFleet(tails={'term_run': OK_LINE}, terminals={'': [term('term_run', 'wrap-up-daily run 6')]})
        fleet.fail = {('automations', 'runs')}
        self.assertEqual(self.sweep(fleet), ['term_run'])

    def test_a_working_run_terminal_with_no_finish_signal_is_kept(self):
        fleet = RunFleet(tails={'term_run': WORKING},
                         terminals={'': [term('term_run', 'wrap-up-daily run 6', path=RUN_PATH)]})
        self.assertEqual(self.sweep(fleet), [])
        self.assertEqual(self.closed(fleet), [])

    def test_a_run_record_that_is_not_completed_does_not_close_the_terminal(self):
        fleet = RunFleet(runs=[run_record(RUN_PATH, status='running')],
                         terminals={'': [term('term_run', 'wrap-up-daily run 6', path=RUN_PATH)]})
        self.assertEqual(self.sweep(fleet), [])

    def test_a_reply_line_of_another_job_does_not_close_the_terminal(self):
        fleet = RunFleet(tails={'term_run': ['ok other-job: done (exit=0)']},
                         terminals={'': [term('term_run', 'wrap-up-daily run 6')]})
        self.assertEqual(self.sweep(fleet), [])

    def test_a_worker_terminal_keeps_the_idle_rule_even_with_a_finished_run_record(self):
        fleet = RunFleet(runs=[run_record(RUN_PATH)], tails={'term_w': OK_LINE},
                         terminals={'': [term('term_w', '#5|fullstack-dev', path=RUN_PATH)]})
        self.assertEqual(self.sweep(fleet), [])

    def test_a_live_run_terminal_stays_open_even_when_finished(self):
        fleet = RunFleet(runs=[run_record(RUN_PATH)],
                         terminals={'': [term('term_run', 'wrap-up-daily run 6', path=RUN_PATH)]})
        rows = [local_row('ctx_live', 'running', 'term_run')]
        self.assertEqual(self.sweep(fleet, rows), [])

    def test_the_coordinator_run_terminal_stays_open_even_when_finished(self):
        fleet = RunFleet(tails={COORD: OK_LINE}, terminals={'': [term(COORD, 'wrap-up-daily run 9')]})
        self.assertEqual(self.sweep(fleet), [])

    def test_no_run_record_is_read_without_a_run_terminal(self):
        fleet = RunFleet(runs=[run_record(RUN_PATH)],
                         terminals={'': [term('term_w', '#5|fullstack-dev', last=FRESH)]})
        self.sweep(fleet)
        self.assertFalse([c for c in fleet.calls if c[:2] == ('automations', 'runs')])

    def test_dry_run_lists_a_finished_run_and_closes_nothing(self):
        fleet = RunFleet(runs=[run_record(RUN_PATH)],
                         terminals={'': [term('term_run', 'wrap-up-daily run 6', path=RUN_PATH)]})
        lines = []
        self.assertEqual(self.sweep(fleet, dry_run=lines.append), [])
        self.assertEqual(self.closed(fleet), [])
        self.assertEqual(len(lines), 1)
        self.assertIn('would close term_run', lines[0])
        self.assertIn('run finished', lines[0])


if __name__ == '__main__':
    unittest.main()
