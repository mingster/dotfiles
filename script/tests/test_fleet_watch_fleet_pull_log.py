import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

OK = 'fleet-pull 2026-11-17T10:00:00Z pr=5 sha=aaa exit=0\nok   hostA ~/dotfiles abc\n'
BAD = ('fleet-pull 2026-11-17T11:00:00Z pr=6 sha=bbb exit=1\n'
       'ok   hostA ~/dotfiles abc\nfail hostB ~/dotfiles (unreachable host)\n')
HUNG = 'fleet-pull 2026-11-17T12:00:00Z pr=7 sha=ccc exit=124\nok   hostA ~/dotfiles abc\n'


class FleetPullLog(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.log = Path(self.dir.name) / 'fleet-pull-after-ship.log'
        self.state = {}

    def notices(self):
        return fw.fleet_pull_after_ship_notices({}, self.state, 0, path=self.log)

    def test_missing_log_is_silent(self):
        self.assertEqual(self.notices(), [])

    def test_ok_run_is_silent(self):
        self.log.write_text(OK)
        self.assertEqual(self.notices(), [])

    def test_failed_host_is_reported_once(self):
        self.log.write_text(OK + BAD)
        first = self.notices()
        self.assertEqual(len(first), 1)
        self.assertIn('PR 6', first[0])
        self.assertIn('hostB', first[0])
        self.assertNotIn('hostA', first[0])
        self.assertEqual(self.notices(), [])
        with self.log.open('a') as handle:
            handle.write(HUNG)
        later = self.notices()
        self.assertEqual(len(later), 1)
        self.assertIn('PR 7', later[0])
        self.assertIn('timed out', later[0])


if __name__ == '__main__':
    unittest.main()
