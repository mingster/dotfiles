import importlib.util
import unittest
from pathlib import Path
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

LOCAL_LINE = 'reaped pid=101 age=5h41m cmd=bun test src/lib/order cwd=/w/a (KILL)'
REMOTE_LINE = 'reaped pid=202 age=1h00m cmd=bunx playwright test cwd=/w/b (TERM)'


class Result:
    def __init__(self, out):
        self.stdout = out
        self.returncode = 0


class OrphanReaper(unittest.TestCase):
    def setUp(self):
        self.config = {'orphan_reaper': {'enabled': True}, 'local_host': 'mini', 'host_caps': {'mini': 4, 'remote-a': 4}}
        self.local_runs = []
        self.rpc_calls = []

    def run_local(self, command, **kwargs):
        self.local_runs.append(command)
        return Result(LOCAL_LINE + '\nnot a kill line\n')

    def rpc(self, *args):
        self.rpc_calls.append(args)
        if args[:2] == ('worktree', 'list'):
            return {'worktrees': [{'path': '/w/main', 'isMainWorktree': True}]}
        if args[:2] == ('terminal', 'create'):
            return {'terminal': {'handle': 'term_x'}}
        if args[:2] == ('terminal', 'read'):
            return {'terminal': {'tail': [REMOTE_LINE, '$ ']}}
        return {}

    def test_runs_on_each_host_and_reports_kill_lines(self):
        notices = fw.orphan_reaper_notices(self.config, rpc_call=self.rpc, run=self.run_local)
        self.assertEqual(len(self.local_runs), 1)
        self.assertTrue(self.local_runs[0][1].endswith('reap-orphan-tests.sh'))
        self.assertEqual(notices, ['mini: orphan test runner ' + LOCAL_LINE, 'remote-a: orphan test runner ' + REMOTE_LINE])
        created = [c for c in self.rpc_calls if c[:2] == ('terminal', 'create')][0]
        self.assertIn('remote-a', created)
        self.assertIn('reap-orphan-tests.sh', created[-1])
        self.assertIn(('terminal', 'close', '--environment', 'remote-a', '--terminal', 'term_x'), self.rpc_calls)

    def test_off_without_the_config_block(self):
        self.config.pop('orphan_reaper')
        self.assertEqual(fw.orphan_reaper_notices(self.config, rpc_call=self.rpc, run=self.run_local), [])
        self.assertEqual((self.local_runs, self.rpc_calls), ([], []))

    def test_unreachable_host_is_skipped(self):
        def failing(*args):
            raise fw.OrcaReadError('orca CLI failed')
        notices = fw.orphan_reaper_notices(self.config, rpc_call=failing, run=self.run_local)
        self.assertEqual(notices, ['mini: orphan test runner ' + LOCAL_LINE])


if __name__ == '__main__':
    unittest.main()
