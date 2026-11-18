import importlib.util
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)


class StaleWorktrees(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config = {'repo_roots': [self.tmp.name]}

    def notices(self, code, out):
        return fw.stale_worktree_notices(self.config, run=lambda *a, **k: SimpleNamespace(returncode=code, stdout=out))

    def test_one_line_per_stale_worktree(self):
        got = self.notices(1, '/w/a pr-merged 0\n/w/b missing-directory 0\n')
        self.assertEqual(len(got), 2)
        self.assertIn('/w/a pr-merged 0', got[0])

    def test_clean_is_quiet(self):
        self.assertEqual(self.notices(0, ''), [])

    def test_checker_error_is_quiet(self):
        self.assertEqual(self.notices(2, 'usage\n'), [])


if __name__ == '__main__':
    unittest.main()
