"""#1741: one escalation per worker and signal, for a CI run stuck in progress and for a worker with no push and no output."""
import unittest

from test_fleet_watch_stall import base_worker, fw

T0 = 1_700_000_000
LIMIT = 15 * 60


def iso(epoch):
    import time
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(epoch))


def worker():
    return base_worker(branch='b1')


def run(state, now, runs, out_age=60, w=None):
    """One pass. out_age is seconds since the terminal last printed."""
    times = {'term_fix': int((now - out_age) * 1000)}
    return fw.worker_signal_pass(
        {}, state, now, [w or worker()], times,
        runs_fn=lambda repo, branch: runs, repo_of=lambda _w: 'o/r')


def ci_run(began, sha='s1'):
    return {'databaseId': 77, 'workflowName': 'Checks', 'status': 'in_progress',
            'startedAt': iso(began), 'createdAt': iso(began), 'headSha': sha}


class CiSignal(unittest.TestCase):
    def test_hung_run_escalates_once_naming_run_and_age(self):
        state = {}
        notices, _ = run(state, T0, [ci_run(T0 - 25 * 60)])
        self.assertEqual(len(notices), 1)
        self.assertIn('signal ci', notices[0])
        self.assertIn('Run 77', notices[0])
        self.assertIn('25 min', notices[0])
        self.assertIn('Check it', notices[0])
        self.assertNotIn('Treat it as a hang', notices[0])

    def test_run_under_the_limit_is_quiet(self):
        notices, _ = run({}, T0, [ci_run(T0 - 14 * 60)])
        self.assertEqual(notices, [])

    def test_no_repeat_until_the_signal_clears(self):
        state = {}
        run(state, T0, [ci_run(T0 - 25 * 60)])
        again, _ = run(state, T0 + 300, [ci_run(T0 - 25 * 60)])
        self.assertEqual(again, [])
        run(state, T0 + 600, [])  # cleared
        refire, _ = run(state, T0 + 1800, [ci_run(T0 + 600 - 1)])
        self.assertEqual(len(refire), 1)


class IdleSignal(unittest.TestCase):
    def test_no_push_and_no_output_escalates_once(self):
        state = {}
        run(state, T0, [], out_age=60)  # first sight starts the push clock
        notices, _ = run(state, T0 + LIMIT + 120, [], out_age=LIMIT + 120)
        self.assertEqual(len(notices), 1)
        self.assertIn('signal idle', notices[0])
        again, _ = run(state, T0 + LIMIT + 420, [], out_age=LIMIT + 420)
        self.assertEqual(again, [])

    def test_quiet_terminal_but_still_pushing_is_not_flagged(self):
        state = {}
        run(state, T0, [{'status': 'completed', 'headSha': 'a'}], out_age=60)
        notices, _ = run(state, T0 + LIMIT + 120, [{'status': 'completed', 'headSha': 'b'}],
                         out_age=LIMIT + 120)
        self.assertEqual(notices, [])

    def test_output_alone_keeps_a_worker_quiet(self):
        state = {}
        run(state, T0, [], out_age=60)
        notices, _ = run(state, T0 + LIMIT + 120, [], out_age=30)
        self.assertEqual(notices, [])

    def test_idle_refires_after_it_clears(self):
        state = {}
        run(state, T0, [], out_age=60)
        run(state, T0 + LIMIT + 120, [], out_age=LIMIT + 120)
        run(state, T0 + LIMIT + 200, [], out_age=10)  # output resumes, signal clears
        notices, _ = run(state, T0 + 2 * LIMIT + 600, [], out_age=LIMIT + 120)
        self.assertEqual(len(notices), 1)


class FailureReads(unittest.TestCase):
    def test_failed_gh_read_does_not_clear_the_ci_flag(self):
        state = {}
        run(state, T0, [ci_run(T0 - 25 * 60)])
        run(state, T0 + 300, None)
        again, _ = run(state, T0 + 600, [ci_run(T0 - 25 * 60)])
        self.assertEqual(again, [])

    def test_unknown_output_time_never_fires_idle(self):
        state = {}
        times = {}
        for now in (T0, T0 + LIMIT + 300):
            notices, _ = fw.worker_signal_pass(
                {}, state, now, [worker()], times, runs_fn=lambda r, b: [], repo_of=lambda _w: 'o/r')
        self.assertEqual(notices, [])

    def test_first_run_read_is_a_baseline_not_a_push(self):
        state = {}
        run(state, T0, None, out_age=60)
        old = [{'status': 'completed', 'headSha': 'old'}]
        run(state, T0 + 600, old, out_age=600)
        notices, _ = run(state, T0 + LIMIT + 60, old, out_age=LIMIT + 60)
        self.assertEqual(len(notices), 1)


if __name__ == '__main__':
    unittest.main()
