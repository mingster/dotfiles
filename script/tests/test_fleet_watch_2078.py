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


class RemoteShell:
    """A fake Orca for one remote probe. Like the live CLI, the terminal stays `running` after the command ends (its
    shell is still open), the tail echoes the typed command, and the output appears once the probe has finished
    (after `reads_until_done` reads; None means never)."""

    def __init__(self, output, reads_until_done=0):
        self.output = output
        self.reads_until_done = reads_until_done
        self.calls = []
        self.command = ''

    def __call__(self, *args):
        self.calls.append(args)
        if args[:2] == ('worktree', 'list'):
            return {'worktrees': [{'path': '/w/main', 'isMainWorktree': True}]}
        if args[:2] == ('terminal', 'create'):
            self.command = args[args.index('--command') + 1]
            return {'terminal': {'handle': 'term_x'}}
        if args[:2] == ('terminal', 'read'):
            tail = ['$ ' + self.command]
            if self.reads_until_done is not None and self.reads_until_done <= 0:
                tail += self.output + [fw.PROBE_END_LINE, '$ ']
            elif self.reads_until_done is not None:
                self.reads_until_done -= 1
            return {'terminal': {'handle': 'term_x', 'status': 'running', 'tail': tail}}
        return {}


class RemoteList(unittest.TestCase):

    def test_a_host_with_no_heavy_jobs_reports_an_empty_list(self):
        rpc = RemoteShell(['HR-END'])
        self.assertEqual(fw.heavy_resources_on(rpc, HOST), [])

    def test_a_host_with_a_running_simulator_reports_it(self):
        rpc = RemoteShell([SIM_LINE, 'HR-END'])
        found = fw.heavy_resources_on(rpc, HOST)
        self.assertEqual([(r['type'], r['id']) for r in found], [('sim', 'AAAA-UDID')])

    def test_the_probe_is_sent_with_the_end_line_after_it(self):
        rpc = RemoteShell(['HR-END'])
        fw.heavy_resources_on(rpc, HOST)
        self.assertTrue(rpc.command.endswith('; echo ' + fw.PROBE_END_LINE))

    def test_a_probe_that_takes_longer_than_the_orca_call_cap_is_still_read(self):
        # rpc() caps each Orca call at 15 s. The old `terminal wait` never returned on a remote shell, so the cap
        # raised OrcaReadError and the host read as unread. No wait is made now.
        shell = RemoteShell(['HR-END'], reads_until_done=3)

        def capped(*args):
            if args[:2] == ('terminal', 'wait'):
                raise fw.OrcaReadError('orca CLI failed')
            return shell(*args)
        with patch.object(fw.time, 'sleep'):
            self.assertEqual(fw.heavy_resources_on(capped, HOST), [])
        self.assertFalse([c for c in shell.calls if c[:2] == ('terminal', 'wait')])

    def test_a_probe_that_never_finishes_is_unread(self):
        rpc = RemoteShell(['HR-END'], reads_until_done=None)
        with patch.object(fw, 'PROBE_DEADLINE_SECONDS', 0), patch.object(fw.time, 'sleep'):
            self.assertIsNone(fw.heavy_resources_on(rpc, HOST))

    def test_a_failed_create_still_reports_unread(self):
        def failing(*args):
            if args[:2] == ('terminal', 'create'):
                raise fw.OrcaReadError('orca CLI failed')
            return RemoteShell([])(*args)
        self.assertIsNone(fw.heavy_resources_on(failing, HOST))

    def test_output_without_the_heavy_list_end_marker_reports_unread(self):
        # e.g. the remote fleet-watch.py exits with an argparse error before it prints the list
        rpc = RemoteShell(['usage: fleet-watch.py [-h]', 'fleet-watch.py: error: argument --heavy-resources'])
        self.assertIsNone(fw.heavy_resources_on(rpc, HOST))

    def test_the_probe_terminal_is_closed_after_the_read(self):
        rpc = RemoteShell(['HR-END'])
        fw.heavy_resources_on(rpc, HOST)
        self.assertIn(('terminal', 'close', '--environment', HOST, '--terminal', 'term_x'), rpc.calls)


if __name__ == '__main__':
    unittest.main()
