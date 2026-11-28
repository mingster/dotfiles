"""#2078: a remote host with no heavy jobs reads as an empty list, not `unread`; a host that really cannot be read stays unread."""
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch_2078', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

HOST = 'remote-a'
SIM_LINE = 'HR|sim|||1200|/w/app/issue-40|simulator|AAAA-UDID|EOR'


class RemoteList(unittest.TestCase):
    """The probe terminal's output and the Orca replies have the shapes the live CLI returns (see orphan_reaper test)."""

    def setUp(self):
        self.calls = []
        self.reads = [{'terminal': {'handle': 'term_x', 'status': 'exited',
                                    'tail': ['$ python3 "$HOME/dotfiles/script/fleet-watch.py" --heavy-resources list ', 'HR-END', '$ ']}}]

    def rpc(self, *args):
        self.calls.append(args)
        if args[:2] == ('worktree', 'list'):
            return {'worktrees': [{'path': '/w/main', 'isMainWorktree': True}]}
        if args[:2] == ('terminal', 'create'):
            return {'terminal': {'handle': 'term_x'}}
        if args[:2] == ('terminal', 'read'):
            return self.reads.pop(0) if len(self.reads) > 1 else self.reads[0]
        return {}

    def test_a_host_with_no_heavy_jobs_reports_an_empty_list(self):
        self.assertEqual(fw.heavy_resources_on(self.rpc, HOST), [])

    def test_a_host_with_a_running_simulator_reports_it(self):
        self.reads = [{'terminal': {'handle': 'term_x', 'status': 'exited',
                                    'tail': ['$ python3 "$HOME/dotfiles/script/fleet-watch.py" --heavy-resources list ', SIM_LINE, 'HR-END', '$ ']}}]
        found = fw.heavy_resources_on(self.rpc, HOST)
        self.assertEqual([(r['type'], r['id']) for r in found], [('sim', 'AAAA-UDID')])

    def test_a_probe_that_outlasts_the_orca_call_cap_is_still_read(self):
        # rpc() caps each Orca call at 15 s. A `terminal wait` that outlasts it raised OrcaReadError and the host read as unread.
        def capped(*args):
            if args[:2] == ('terminal', 'wait'):
                raise fw.OrcaReadError('orca CLI failed')
            return self.rpc(*args)
        self.reads = [{'terminal': {'handle': 'term_x', 'status': 'running', 'tail': ['$ ']}}] * 3 + [
            {'terminal': {'handle': 'term_x', 'status': 'exited', 'tail': ['HR-END']}}]
        with patch.object(fw.time, 'sleep'):
            self.assertEqual(fw.heavy_resources_on(capped, HOST), [])

    def test_a_probe_that_never_finishes_is_unread(self):
        self.reads = [{'terminal': {'handle': 'term_x', 'status': 'running', 'tail': ['$ ']}}]
        with patch.object(fw, 'PROBE_DEADLINE_SECONDS', 0), patch.object(fw.time, 'sleep'):
            self.assertIsNone(fw.heavy_resources_on(self.rpc, HOST))

    def test_a_real_failure_still_reports_unread(self):
        def failing(*args):
            if args[:2] == ('terminal', 'create'):
                raise fw.OrcaReadError('orca CLI failed')
            return self.rpc(*args)
        self.assertIsNone(fw.heavy_resources_on(failing, HOST))

    def test_output_without_the_end_marker_reports_unread(self):
        # e.g. the remote fleet-watch.py exits with an argparse error before it prints the list
        self.reads = [{'terminal': {'handle': 'term_x', 'status': 'exited',
                                    'tail': ['usage: fleet-watch.py [-h]', 'fleet-watch.py: error: argument --heavy-resources']}}]
        self.assertIsNone(fw.heavy_resources_on(self.rpc, HOST))

    def test_the_probe_terminal_is_closed_after_the_read(self):
        fw.heavy_resources_on(self.rpc, HOST)
        self.assertIn(('terminal', 'close', '--environment', HOST, '--terminal', 'term_x'), self.calls)


if __name__ == '__main__':
    unittest.main()
