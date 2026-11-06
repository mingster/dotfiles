import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)


def worker(name):
    return {'dispatchId': name, 'dispatchStatus': 'running'}


class WorkerPages(unittest.TestCase):
    """Current Orca worker-list has workers, scope, nextCursor and warnings, and no page object."""

    def fetch(self, config, pages):
        """pages maps (command, run or None, cursor or None) to a result."""
        calls = []

        def rpc(*args):
            calls.append(args)
            run = args[args.index('--run') + 1] if '--run' in args else None
            cursor = args[args.index('--cursor') + 1] if '--cursor' in args else None
            return pages[(args[1], run, cursor)]
        with patch.object(fw, 'rpc', side_effect=rpc):
            return fw.fetch_workers(config), calls

    def test_tags_list_run_on_rows_missing_run_id(self):
        w = worker('a')
        got, _ = self.fetch({'runs': [{'id': 'rx'}]}, {
            ('worker-list', 'rx', None): {'workers': [w], 'scope': {}, 'warnings': []}})
        self.assertEqual(len(got), 1)
        self.assertEqual(got[0].get('_fleet_watch_list_run'), 'rx')

    def test_follows_top_level_next_cursor(self):
        got, _ = self.fetch({'runs': [{'id': 'r'}]}, {
            ('worker-list', 'r', None): {'workers': [worker('a')], 'scope': {}, 'nextCursor': 'p2', 'warnings': []},
            ('worker-list', 'r', 'p2'): {'workers': [worker('b')], 'scope': {}, 'warnings': []}})
        self.assertEqual({w['dispatchId'] for w in got}, {'a', 'b'})

    def test_still_accepts_the_older_page_object(self):
        got, _ = self.fetch({'runs': [{'id': 'r'}]}, {
            ('worker-list', 'r', None): {'workers': [worker('a')], 'page': {'hasMore': True, 'nextCursor': 'p2'}},
            ('worker-list', 'r', 'p2'): {'workers': [worker('b')], 'page': {'hasMore': False}}})
        self.assertEqual({w['dispatchId'] for w in got}, {'a', 'b'})

    def test_without_configured_runs_reads_every_run(self):
        got, _ = self.fetch({}, {
            ('run-list', None, None): {'runs': [{'id': 'r1'}], 'nextCursor': 'runs2'},
            ('run-list', None, 'runs2'): {'runs': [{'id': 'r2'}]},
            ('worker-list', 'r1', None): {'workers': [worker('a')], 'scope': {}},
            ('worker-list', 'r2', None): {'workers': [worker('b')], 'scope': {}}})
        self.assertEqual({w['dispatchId'] for w in got}, {'a', 'b'})

    def test_a_partial_read_raises(self):
        repeat = {'workers': [worker('a')], 'nextCursor': 'same'}
        for pages in (
            {('worker-list', 'r', None): repeat, ('worker-list', 'r', 'same'): repeat},
            {('worker-list', 'r', None): {'workers': [], 'page': {'hasMore': True}}},
            {('worker-list', 'r', None): {'workers': [], 'nextCursor': ''}},
        ):
            with self.subTest(pages=pages), self.assertRaises(Exception):
                self.fetch({'runs': [{'id': 'r'}]}, pages)

    def test_admission_refuses_on_a_partial_read(self):
        repeat = {'workers': [worker('a')], 'nextCursor': 'same'}
        pages = {('run-list', None, None): {'runs': [{'id': 'r'}]},
                 ('worker-list', 'r', None): repeat, ('worker-list', 'r', 'same'): repeat}
        with patch.object(fw, 'rpc', side_effect=lambda *a: pages[(
                a[1], a[a.index('--run') + 1] if '--run' in a else None,
                a[a.index('--cursor') + 1] if '--cursor' in a else None)]):
            receipt = fw.admit('fleet-1', {'host_caps': {'fleet-1': 4}})
        self.assertFalse(receipt['admitted'])


if __name__ == '__main__':
    unittest.main()
