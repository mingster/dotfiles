"""#1199: a pass lists pull requests once, and stops starting workers after Orca fences one."""
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

import test_fleet_watch_park as park  # noqa: E402
from test_fleet_watch_park import HEAD, REPO, verifier_pr  # noqa: E402

FENCED = fw.BabysitStartResult(
    1,
    'consumer_fenced: worker-start needs the coordinator bound to the Run or a worker on an active Dispatch in it',
)


class SharedPrList(unittest.TestCase):
    def test_babysit_reads_the_list_the_pass_already_fetched(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'config.json'
            config.write_text(json.dumps({
                'runs': [{'id': 'r', 'terminal': 't', 'waiter_pattern': 'fleet-watch-test-waiter-absent'}],
            }))

            def rpc(*args):
                return {'messages': []} if args[1] == 'inbox' else {'workers': [], 'terminals': [], 'tasks': []}

            with patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(Path(directory) / 's.json')]), \
                    patch.object(fw, 'rpc', side_effect=rpc), \
                    patch.object(fw.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), \
                    patch.object(fw, 'fetch_prs', return_value=[]) as fetch_prs, \
                    patch.object(fw, 'babysit_pass', return_value=([], [], [])) as babysit, \
                    patch.object(fw, 'deliver_notices', return_value=None):
                self.assertEqual(fw.main(), 0)
                pr_fetch = babysit.call_args.kwargs['pr_fetch']
                fetch_prs.reset_mock()
                pr_fetch('o/other')
                pr_fetch('o/other')
                self.assertEqual(fetch_prs.call_count, 1, 'the second read comes from the pass cache')
                self.assertIsNot(pr_fetch, fw.fetch_open_prs)


class FencedStartsInOnePass(unittest.TestCase):
    def run_pass(self, root, first_result):
        config = {
            'issue_scan': {'run': 'run_live', 'from_terminal': 'term_live', 'repo_roots': {REPO: root}},
            'babysit': {'repos': [REPO], 'startup': '/bin/true'},
        }
        second = dict(verifier_pr(HEAD), number=8, headRefName='c')
        starts = []

        def start_worker(command):
            starts.append(command)
            return first_result

        notices, _lines, log = fw.babysit_pass(
            config, {}, [], pr_fetch=lambda _repo: [verifier_pr(HEAD), second],
            start_worker=start_worker,
            pick=lambda _role: {'selected': {'provider': 'cursor', 'model': 'm', 'eligible': True}},
            owner_check=lambda _pr: None,
        )
        return notices, log, starts

    def test_after_a_fence_the_remaining_candidates_skip_the_start_and_still_get_a_handoff(self):
        with tempfile.TemporaryDirectory() as root:
            notices, log, starts = self.run_pass(root, FENCED)
        self.assertEqual(len(starts), 1, 'only the first candidate reaches worker-startup.sh')
        texts = [str(notice) for notice in notices]
        self.assertEqual(len(texts), 2, texts)
        self.assertTrue(texts[0].startswith('handoff verifier %s#7' % REPO), texts)
        self.assertTrue(texts[1].startswith('handoff verifier %s#8' % REPO), texts)
        self.assertIn('--name verify-8', texts[1])

    def test_another_failure_does_not_stop_the_next_candidate(self):
        with tempfile.TemporaryDirectory() as root:
            _notices, _log, starts = self.run_pass(root, park.failure_result()[0])
        self.assertEqual(len(starts), 2)


if __name__ == '__main__':
    unittest.main()
