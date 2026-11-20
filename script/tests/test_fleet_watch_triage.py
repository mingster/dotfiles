"""Idle seats with no ready issue start one triage worker per repo, at most once per interval."""
import importlib.util
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fleet_watch_triage', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_1204 import fake_rpc  # noqa: E402
from test_fleet_watch_park import scan_config  # noqa: E402
from test_fleet_watch_1216 import row  # noqa: E402

NOW = 100000.0


def pick(_role, avoid_family=None):
    return {'selected': {'provider': 'claude', 'model': 'opus'}}


def run(issues, backlog, state=None, interval_hours=None, occupied=0):
    starts = []
    config = scan_config('/work/app')
    if interval_hours is not None:
        config['issue_scan']['triage_interval_hours'] = interval_hours
    state = {'issue_scan_backlog_sweep_at': NOW} if state is None else state

    def start(command):
        starts.append(command)
        return 0

    with patch.object(fw, 'rpc', side_effect=fake_rpc):
        _n, bits = fw.issue_scan_pass(
            config, state, NOW, [], pr_fetch=lambda _r: [], list_issues=lambda _r: list(issues),
            gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': occupied},
            start_worker=start, act=lambda _c: 0, repo_id_lookup=lambda _h, _r: 'repo-id',
            pick_fn=pick, list_backlog=lambda _r: backlog,
        )
    triage = [c for c in starts if 'triage-architect-pm' in c]
    return triage, bits, state


class TriageWorker(unittest.TestCase):
    def test_starts_when_idle_with_backlog(self):
        triage, bits, state = run([], backlog=3)
        self.assertEqual(len(triage), 1, bits)
        self.assertIn('triage_start=3', bits)
        self.assertEqual(triage[0][triage[0].index('--agent') + 1], 'claude')
        self.assertEqual(list(state['issue_scan_triage_at'].values()), [NOW])

    def test_skips_with_no_backlog(self):
        triage, bits, _state = run([], backlog=0)
        self.assertEqual(triage, [])
        self.assertIn('triage_skip_no_backlog', bits)

    def test_skips_when_a_ready_issue_started(self):
        triage, bits, _state = run([row(1)], backlog=3)
        self.assertEqual(triage, [])
        self.assertIn('issue_start=1', bits)

    def test_respects_the_interval(self):
        state = {'issue_scan_backlog_sweep_at': NOW, 'issue_scan_triage_at': {scan_config('/w')['issue_scan']['repos'][0]: NOW - 3600}}
        triage, bits, _state = run([], backlog=3, state=state)
        self.assertEqual(triage, [])
        self.assertIn('triage_skip_recent', bits)
        state['issue_scan_triage_at'] = {k: NOW - 7300 for k in state['issue_scan_triage_at']}
        triage, _bits, _state = run([], backlog=3, state=state)
        self.assertEqual(len(triage), 1)

    def test_generated_spec_passes_brief_lint(self):
        triage, _bits, _state = run([], backlog=3)
        spec = Path(triage[0][triage[0].index('--spec') + 1])
        repo = Path(__file__).resolve().parents[2]
        result = subprocess.run(['bash', str(repo / 'script/brief-lint.sh'), str(spec), str(repo)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Setup: none', spec.read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
