"""#2009: a pass whose pre-start steps take about 110 s still starts ready issues while seats are free.

The issue scan start used START_FINISH_BY (140 s), which the notice, PR and scan steps before it used up, so no
start fit and the fleet filled at 0 or 1 worker per pass. It now uses the pass hard end (PASS_HARD_END, with the tail),
the same rule as supply (#1889), so the 280 s precheck timeout still holds (#1838)."""
import importlib.util
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

# Load by file path so both `python3 -m unittest <file>` and `discover` work from the repo root.
# Keeps log lines off ~/.orca/logs (#1864). Must run before fleet-watch.py loads.
_env_spec = importlib.util.spec_from_file_location('fleet_watch_test_env', Path(__file__).parent / 'fleet_watch_test_env.py')
fleet_watch_test_env = importlib.util.module_from_spec(_env_spec)
_env_spec.loader.exec_module(fleet_watch_test_env)

SCRIPT = Path(__file__).parent.parent / 'fleet-watch.py'
spec = importlib.util.spec_from_file_location('fleet_watch_2009', SCRIPT)
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

sys.path.insert(0, str(Path(__file__).parent))  # sibling test modules below, for path invocation
from test_fleet_watch_1204 import fake_rpc  # noqa: E402
from test_fleet_watch_1216 import row  # noqa: E402
from test_fleet_watch_park import scan_config as park_config  # noqa: E402
from test_fleet_watch_triage import NOW as TRIAGE_NOW, pick as triage_pick  # noqa: E402

T0 = 1_800_000_000.0
ISSUES = [10640, 10650, 2008, 10234, 10477]


class Clock:
    def __init__(self, elapsed):
        self.now = T0 + elapsed

    def __call__(self):
        return self.now


def pass_at_110_seconds(start_seconds=45.0, issues=ISSUES):
    """A pass whose notice, PR and scan steps took 110 s, then one issue scan with free seats. Each start takes start_seconds."""
    clock = Clock(T0)
    starts = []

    def start(command):
        starts.append(command)
        clock.now += start_seconds
        return 0

    config = park_config('/work/app')
    with patch.object(fw.time, 'time', clock), patch.object(fw, 'rpc', side_effect=fake_rpc):
        fw.begin_pass_clock(now=T0)
        clock.now = T0 + 110.0  # the steps before the issue scan
        try:
            _n, bits = fw.issue_scan_pass(
                config, {'issue_scan_backlog_sweep_at': TRIAGE_NOW}, TRIAGE_NOW, [],
                pr_fetch=lambda _r: [], list_issues=lambda _r: [row(n) for n in issues],
                gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
                start_worker=start, act=lambda _c: 0, repo_id_lookup=lambda _h, _r: 'repo-id',
                pick_fn=triage_pick, list_backlog=lambda _r: 0,
            )
        finally:
            fw.end_pass_clock()
    return starts, bits, clock.now - T0


class IssueStartAfterSlowSteps(unittest.TestCase):
    def test_five_ready_issues_with_free_seats_start_at_least_two_workers(self):
        starts, bits, _elapsed = pass_at_110_seconds()
        self.assertGreaterEqual(len(starts), 2, bits)

    def test_the_last_start_ends_before_the_pass_hard_end(self):
        starts, bits, elapsed = pass_at_110_seconds()
        self.assertTrue(starts, bits)
        self.assertLessEqual(elapsed, fw.PASS_HARD_END, bits)

    def test_the_issues_no_start_fits_log_the_budget_hold(self):
        starts, bits, _elapsed = pass_at_110_seconds()
        started = {int(b.split('=')[1]) for b in bits if b.startswith('issue_start=')}
        held = {int(b.split('=')[1]) for b in bits if b.startswith('issue_start_budget=')}
        self.assertGreaterEqual(len(starts), 2, bits)
        self.assertGreaterEqual(len(held), 1, bits)
        self.assertEqual(len(starts) + len(held), len(ISSUES), bits)
        self.assertEqual(started | held, set(ISSUES), bits)
        self.assertFalse(started & held, bits)


if __name__ == '__main__':
    unittest.main()
