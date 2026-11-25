"""#1905: a finished worker idle at its prompt is woken once, then stopped when its work is closed, so its seat comes back."""
import importlib.util
import unittest
from pathlib import Path
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch_idle_seat', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

REPO = 'owner/app'
T = 1_700_000_000.0
TERM = 'term_idle'
QUIET = fw.IDLE_SEAT_QUIET_SECONDS
GRACE = fw.IDLE_SEAT_GRACE_SECONDS


def worker(dispatch='ctx_idle', title='#41|fullstack-dev', server=None):
    row = {'dispatchId': dispatch, 'dispatchStatus': 'ready', 'terminalState': 'active', '_task_title': title,
           'terminal': TERM, 'projection': {'liveness': {'verdict': 'unverifiable'}, 'host': {'id': 'local'}}}
    if server:
        # A remote --include-remote row: server metadata, no projection and no local terminal (#1394).
        row = {'dispatchId': dispatch, 'workerState': 'ready', '_task_title': title, 'terminal': TERM, 'server': server}
    return row


class Fleet:
    """One worker across passes: the rpc calls fleet-watch made, and what it reported."""

    def __init__(self, issue_state, unread=False, w=None):
        self.state = {}
        self.calls = []
        self.issue_state = issue_state
        self.messages = [{'id': 'm1', 'to': TERM, 'read': False}] if unread else []
        self.w = w or worker()

    def rpc(self, *args):
        self.calls.append(args)
        return {}

    def run(self, now, last_output):
        notices, bits = fw.idle_seat_pass(
            {}, self.state, now, [self.w], {TERM: last_output * 1000}, self.messages, self.rpc,
            ref_state=lambda repo, number: self.issue_state if (repo, number) == (REPO, 41) else None,
            repo_of=lambda _w: REPO,
        )
        return notices, bits

    def sent(self):
        return [c for c in self.calls if c[:2] == ('terminal', 'send')]

    def stops(self):
        return [c for c in self.calls if c[:2] == ('orchestration', 'worker-stop')]


class IdleSeat(unittest.TestCase):
    def test_finished_idle_worker_is_woken_once_then_stopped_and_its_seat_counts_free(self):
        fleet = Fleet('CLOSED')
        _n, bits = fleet.run(T, T - QUIET - 60)
        self.assertEqual(len(fleet.sent()), 1, bits)
        self.assertIn('worker_done', ' '.join(fleet.sent()[0]))
        self.assertIn('idle_wake=ctx_idle', bits)
        fleet.run(T + 600, T + 5)  # the wake text is the last output; inside the grace nothing more happens
        self.assertEqual((len(fleet.sent()), fleet.stops()), (1, []))
        notices, bits = fleet.run(T + GRACE + 60, T + 5)
        self.assertEqual(len(fleet.stops()), 1, bits)
        self.assertIn('idle_stop=ctx_idle', bits)
        self.assertTrue(any('ctx_idle' in n and 'stopped' in n for n in notices), notices)
        self.assertFalse(fw.worker_row_is_live(fleet.w))
        # Next pass: Orca may still list the row as live for a while; it no longer counts as a working seat.
        self.assertEqual(fw.working_worker_count([worker()], fleet.state), 0)
        self.assertEqual(fw.working_worker_count([worker(dispatch='ctx_other')], fleet.state), 1)
        fleet.run(T + GRACE + 600, T + 5)
        self.assertEqual((len(fleet.sent()), len(fleet.stops())), (1, 1))

    def test_idle_worker_with_open_issue_is_woken_and_reported_never_stopped(self):
        fleet = Fleet('OPEN', unread=True)
        _n, bits = fleet.run(T, T - QUIET - 60)
        self.assertEqual(len(fleet.sent()), 1, bits)
        notices, bits = fleet.run(T + GRACE + 60, T + 5)
        self.assertIn('idle_report=ctx_idle', bits)
        self.assertTrue(any('ctx_idle' in n and 'not stopped' in n for n in notices), notices)
        for later in (2, 3, 4):
            notices, _bits = fleet.run(T + GRACE * later, T + 5)
            self.assertEqual(notices, [])  # reported once
        self.assertEqual(fleet.stops(), [])
        self.assertEqual(len(fleet.sent()), 1)

    def test_reported_worker_that_goes_back_to_work_fills_a_seat_again(self):
        fleet = Fleet('OPEN', unread=True)
        fleet.run(T, T - QUIET - 60)
        fleet.run(T + GRACE + 60, T + 5)
        self.assertEqual(fw.working_worker_count([fleet.w], fleet.state), 0)
        fleet.run(T + GRACE + 600, T + GRACE + 590)  # it read its inbox and is working
        self.assertEqual(fw.working_worker_count([fleet.w], fleet.state), 1)
        self.assertEqual(fleet.stops(), [])

    def test_idle_worker_with_open_issue_and_nothing_unread_is_left_alone(self):
        fleet = Fleet('OPEN')
        fleet.run(T, T - QUIET - 60)
        self.assertEqual((fleet.calls, fleet.state.get('idle_seat')), ([], {}))

    def test_busy_worker_is_untouched(self):
        fleet = Fleet('CLOSED', unread=True)
        for step in range(6):
            now = T + step * GRACE
            notices, bits = fleet.run(now, now - 30)  # its output keeps changing
            self.assertEqual((notices, bits), ([], []))
        self.assertEqual((fleet.calls, fleet.state.get('idle_seat')), ([], {}))
        self.assertEqual(fw.working_worker_count([fleet.w], fleet.state), 1)

    def test_unknown_issue_state_or_no_output_time_is_not_finished(self):
        fleet = Fleet(None)
        fleet.run(T, T - QUIET - 60)
        self.assertEqual(fleet.calls, [])
        fleet = Fleet('CLOSED')
        fw.idle_seat_pass({}, fleet.state, T, [fleet.w], {}, [], fleet.rpc,
                          ref_state=lambda *_a: 'CLOSED', repo_of=lambda _w: REPO)
        self.assertEqual(fleet.calls, [])

    def test_verifier_waiting_for_its_next_pr_is_left_alone(self):
        fleet = Fleet('CLOSED', unread=True, w=worker(title='#41|qa-sdet'))
        fleet.run(T, T - QUIET - 60)
        self.assertEqual(fleet.calls, [])

    def test_failed_wake_starts_no_grace(self):
        fleet = Fleet('CLOSED')

        def refuse(*args):
            fleet.calls.append(args)
            raise fw.OrcaReadError('terminal gone')
        fleet.rpc = refuse
        fleet.run(T, T - QUIET - 60)
        self.assertEqual(fleet.state.get('idle_seat'), {})

    def test_remote_worker_is_woken_and_stopped_on_its_host(self):
        fleet = Fleet('CLOSED', w=worker(server={'environmentId': 'env-remote'}))
        fleet.run(T, T - QUIET - 60)
        fleet.run(T + GRACE + 60, T + 5)
        self.assertIn('env-remote', fleet.sent()[0])
        self.assertIn('env-remote', fleet.stops()[0])


if __name__ == '__main__':
    unittest.main()
