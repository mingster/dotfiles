"""An unchanged triage backlog never starts a second triage, even under the urgent work order (#1723)."""
import datetime
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
from test_fleet_watch_triage import NOW, fw, run

ORDER = {'min_active': 3, 'target_workers': 8}


def stamp(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).isoformat().replace('+00:00', 'Z')


class TriageUnchanged(unittest.TestCase):
    def test_urgent_same_backlog_twice_starts_one(self):
        backlog = {7: stamp(NOW - 5000)}
        state = {'issue_scan_backlog_sweep_at': NOW}
        first, _bits, state = run([], backlog=backlog, state=state, order=ORDER)
        self.assertEqual(len(first), 1)
        second, bits, _state = run([], backlog=backlog, state=state, order=ORDER, now=NOW + 60)
        self.assertEqual(second, [])
        self.assertIn('triage_skip_unchanged', bits)

    def test_updated_issue_starts_again_under_urgent(self):
        state = {'issue_scan_backlog_sweep_at': NOW}
        run([], backlog={7: stamp(NOW - 5000)}, state=state, order=ORDER)
        triage, bits, _state = run([], backlog={7: stamp(NOW + 30)}, state=state, order=ORDER, now=NOW + 60)
        self.assertEqual(len(triage), 1, bits)

    def test_new_issue_starts_again_under_urgent(self):
        state = {'issue_scan_backlog_sweep_at': NOW}
        run([], backlog={7: stamp(NOW - 5000)}, state=state, order=ORDER)
        triage, bits, _state = run([], backlog={7: stamp(NOW - 5000), 8: stamp(NOW - 10)}, state=state, order=ORDER,
                                   now=NOW + 60)
        self.assertEqual(len(triage), 1, bits)

    def test_fetch_returns_updated_at_by_number(self):
        class Out:
            stdout = '[{"number": 7, "updatedAt": "2026-01-01T00:00:00Z"}]'

        got = fw.fetch_triage_backlog('o/r', run=lambda *_a, **_k: Out())
        self.assertEqual(got, {7: '2026-01-01T00:00:00Z'})


if __name__ == '__main__':
    unittest.main()
