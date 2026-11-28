import sys
import importlib.util
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)


class ChangelogFragments(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name, 'changelog.d')
        self.dir.mkdir()
        self.config = {'repo_roots': [self.tmp.name]}
        self.state = {}

    def fill(self, count):
        for index in range(count):
            self.dir.joinpath('%d-x.md' % index).write_text('x\n')

    def run_pass(self):
        return fw.changelog_fragment_notices(self.config, self.state, origin_of=lambda path: 'o/app')

    def test_fifty_is_quiet(self):
        self.fill(50)
        self.dir.joinpath('README.md').write_text('how\n')
        self.assertEqual(self.run_pass(), [])

    def test_fifty_one_notices_once(self):
        self.fill(51)
        first = self.run_pass()
        self.assertEqual(len(first), 1)
        self.assertIn('o/app: changelog.d holds 51 uncompiled fragments (limit 50)', first[0])
        self.assertEqual(self.run_pass(), [])

    def test_repeats_only_when_the_count_doubles(self):
        self.fill(60)
        self.run_pass()
        self.fill(119)
        self.assertEqual(self.run_pass(), [])
        self.fill(120)
        self.assertEqual(len(self.run_pass()), 1)

    def test_release_resets_the_notice(self):
        self.fill(60)
        self.run_pass()
        for f in self.dir.glob('*.md'):
            f.unlink()
        self.assertEqual(self.run_pass(), [])
        self.fill(51)
        self.assertEqual(len(self.run_pass()), 1)

    def test_config_limit_overrides_the_default(self):
        self.config['changelog_fragment_warn'] = 5
        self.fill(6)
        self.assertEqual(len(self.run_pass()), 1)


if __name__ == '__main__':
    unittest.main()
