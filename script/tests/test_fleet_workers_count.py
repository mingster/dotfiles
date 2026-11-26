"""One count rule (#1942): an unverifiable in progress dispatch is unconfirmed in the status line and the work order line."""
import importlib.util
import sys
import unittest
from pathlib import Path
import fleet_watch_test_env  # noqa: F401

sys.path.insert(0, str(Path(__file__).parent.parent / 'lib'))
import worker_count  # noqa: E402

spec = importlib.util.spec_from_file_location('fleet_watch_count', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)


def row(dispatch, verdict, status='running', terminal='active'):
    return {'dispatchId': dispatch, 'dispatchStatus': status, 'terminalState': terminal,
            'projection': {'host': {'id': 'local'}, 'liveness': {'verdict': verdict}}}


class SharedCount(unittest.TestCase):
    def test_helper_rule(self):
        self.assertEqual(worker_count.bucket(True, 'live'), 'live')
        self.assertEqual(worker_count.bucket(True, 'unverifiable'), 'unconfirmed')
        self.assertIsNone(worker_count.bucket(True, 'exited'))
        self.assertIsNone(worker_count.bucket(False, 'unverifiable'))
        self.assertEqual(worker_count.label(3, 2), '3+2?')
        self.assertEqual(worker_count.label(3, 0), '3')

    def test_work_order_line_shows_unconfirmed_and_skips_finished(self):
        workers = [row('d1', 'live'), row('d2', 'unverifiable'), row('d3', 'unverifiable', 'completed', 'released')]
        self.assertEqual(fw.worker_count_split(workers), (1, 1))
        line = fw.work_order_supply_line({'work_order': {'min_active': 1, 'target_workers': 4}}, 1.0, workers, 0)
        self.assertEqual(line, 'work order: 1+1? live (2 working, 0 waiting on coordinator), supply 0')


if __name__ == '__main__':
    unittest.main()
