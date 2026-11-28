"""With no picked agent, fleet-watch starts on Claude (provider priority 2026-11-16), never Grok."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

REPO = 'acme/app'


def arg(command, flag):
    return command[command.index(flag) + 1]


class AgentFallback(unittest.TestCase):
    def config(self, **scan):
        root = tempfile.mkdtemp()
        return {'issue_scan': {'run': 'run_x', 'from_terminal': 'term_c', 'repo_roots': {REPO: root},
                               'role': 'fullstack-dev', **scan}}

    def test_issue_start_falls_back_to_claude(self):
        command = fw.build_issue_start_command(self.config(), REPO, {'number': 4, 'body': 'x'})
        self.assertEqual(arg(command, '--agent'), 'claude')

    def test_rework_start_falls_back_to_claude(self):
        pr = {'number': 4, 'headRefOid': 'a' * 40, 'comments': []}
        command = fw.build_rework_start_command(self.config(), REPO, pr)
        self.assertEqual(arg(command, '--agent'), 'claude')

    def test_sweep_falls_back_to_claude(self):
        command = fw.build_backlog_sweep_command(self.config(), REPO, 'architect-pm')
        self.assertEqual(arg(command, '--agent'), 'claude')

    def test_architect_sweep_never_inherits_a_grok_or_cursor_builder_pick(self):
        for agent in ('grok', 'cursor'):
            command = fw.build_backlog_sweep_command(self.config(agent=agent), REPO, 'architect-pm')
            self.assertEqual(arg(command, '--agent'), 'claude', agent)

    def test_other_sweep_role_keeps_the_picked_agent(self):
        command = fw.build_backlog_sweep_command(self.config(agent='grok'), REPO, 'sales-marketing')
        self.assertEqual(arg(command, '--agent'), 'grok')


if __name__ == '__main__':
    unittest.main()
