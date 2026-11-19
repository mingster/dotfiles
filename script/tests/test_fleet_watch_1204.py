"""#1204: fleet-watch runs from the coordinator terminal, so its own starts carry no --from and name the repo by id."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_park import REPO, issue_row, scan_config  # noqa: E402

REPOS = {'repos': [{'id': 'repo-1', 'path': '/work/app'}]}


def fake_rpc(*args):
    if args[:2] == ('repo', 'list'):
        return REPOS
    raise fw.OrcaReadError('unexpected %s' % (args,))


def live_worker(title):
    return {'_task_title': title, 'dispatchStatus': 'dispatched', 'terminalState': 'active',
            'projection': {'liveness': {'verdict': 'alive'}}}


class OwnStarts(unittest.TestCase):
    def issue_pass(self, root, workers):
        starts = []
        state = {'issue_scan_backlog_sweep_at': 1}
        with patch.object(fw, 'rpc', side_effect=fake_rpc):
            fw.issue_scan_pass(
                scan_config(root), state, 1, workers,
                pr_fetch=lambda _r: [], list_issues=lambda _r: [issue_row(5, '2026-01-01T00:00:00Z')],
                gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
                start_worker=lambda command: starts.append(command) or 0,
            )
        return starts

    def test_issue_start_has_no_from_and_names_the_repo_by_id(self):
        starts = self.issue_pass('/work/app', [])
        self.assertEqual(len(starts), 1)
        self.assertNotIn('--from', starts[0])
        self.assertNotIn('term_coord', starts[0])
        self.assertEqual(starts[0][starts[0].index('--repo') + 1], 'id:repo-1')

    def test_unknown_checkout_keeps_the_path_selector(self):
        starts = self.issue_pass('/work/other', [])
        self.assertEqual(starts[0][starts[0].index('--repo') + 1], 'path:/work/other')

    def test_live_worker_on_the_same_issue_and_role_blocks_the_start(self):
        with patch.object(fw, 'rpc', side_effect=fake_rpc):
            probe = fw.build_issue_start_command(scan_config('/work/app'), REPO, issue_row(5, 'x'))
        title = probe[probe.index('--title') + 1]
        self.assertEqual(self.issue_pass('/work/app', [live_worker(title)]), [])

    def test_live_worker_on_the_same_issue_other_role_blocks_the_start(self):
        """#1216: the #<n>| prefix decides, whatever the role or suffix."""
        self.assertEqual(self.issue_pass('/work/app', [live_worker('#5|qa-sdet')]), [])

    def test_live_worker_on_another_issue_does_not_block(self):
        self.assertEqual(len(self.issue_pass('/work/app', [live_worker('#6|qa-sdet')])), 1)

    def test_babysit_and_rework_commands_have_no_from(self):
        config = scan_config('/work/app')
        config['babysit'] = {'enabled': True, 'startup_script': '/x/worker-startup.sh', 'run': 'run_x',
                             'from_terminal': 'term_coord', 'repo_roots': {REPO: '/work/app'}}
        pr_row = {'number': 7, 'headRefOid': 'a' * 40, 'headRefName': 'b', 'title': 't', 'body': ''}
        with patch.object(fw, 'rpc', side_effect=fake_rpc), patch.object(fw, 'pr_base_ref', return_value='main'):
            for command in (fw.build_rework_start_command(config, REPO, pr_row),
                            fw.build_babysit_command(config, REPO, pr_row, 'verifier', 'claude', 'm', ('grok', 'g'))):
                if command is None:
                    continue
                self.assertNotIn('--from', command)
                self.assertEqual(command[command.index('--repo') + 1], 'id:repo-1')


if __name__ == '__main__':
    unittest.main()
