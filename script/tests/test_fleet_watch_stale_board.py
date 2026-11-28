import importlib.util
import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

HOUR = 3600


def line(path, why='PR #7 merged', env='local'):
    return '[dry-run] would set %s completed (%s) environment=%s' % (path, why, env)


class StaleBoard(unittest.TestCase):
    def setUp(self):
        self.config = {'board_stale_check': True}
        self.state = {}
        self.output = ''
        self.calls = 0

    def run_pass(self, now):
        def run():
            self.calls += 1
            return self.output
        return fw.stale_board_notices(self.config, self.state, now, run=run)

    def test_off_unless_configured(self):
        self.config = {}
        self.output = line('/w/a')
        self.assertEqual(self.run_pass(0), [])
        self.assertEqual(self.calls, 0)

    def test_first_sighting_is_quiet_then_one_notice_per_worktree(self):
        self.output = line('/w/a') + '\n' + line('/w/b', 'issue #3 closed', 'remote-1') + '\ndry-run: moved=2 unchanged=5 skipped_hosts=0\n'
        self.assertEqual(self.run_pass(0), [])
        notices = self.run_pass(HOUR)
        self.assertEqual(len(notices), 2)
        self.assertIn('/w/a on local (PR #7 merged)', notices[0])
        self.assertIn('/w/b on remote-1 (issue #3 closed)', notices[1])
        self.assertEqual(self.run_pass(2 * HOUR), [])

    def test_a_card_that_moved_to_done_is_not_reported(self):
        self.output = line('/w/a')
        self.run_pass(0)
        self.output = 'dry-run: moved=0 unchanged=5 skipped_hosts=0\n'
        self.assertEqual(self.run_pass(HOUR), [])

    def test_checks_run_at_most_once_an_interval(self):
        self.output = line('/w/a')
        self.run_pass(0)
        self.run_pass(HOUR - 1)
        self.assertEqual(self.calls, 1)

    def test_a_failed_check_keeps_the_state(self):
        self.output = line('/w/a')
        self.run_pass(0)
        self.output = None
        self.assertEqual(self.run_pass(HOUR), [])
        self.output = line('/w/a')
        self.assertEqual(len(self.run_pass(2 * HOUR)), 1)

    def test_at_most_five_per_pass(self):
        self.output = '\n'.join(line('/w/%d' % index) for index in range(8))
        self.run_pass(0)
        self.assertEqual(len(self.run_pass(HOUR)), 5)
        self.assertEqual(len(self.run_pass(2 * HOUR)), 3)


if __name__ == '__main__':
    unittest.main()
