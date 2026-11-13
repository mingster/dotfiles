"""fleet-watch passes --auto to the usage gate, logs each refusal and tells the coordinator once (#987)."""
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

NOW = 1_700_000_000.0


def proc(code, body=None):
    return mock.Mock(returncode=code, stdout=json.dumps(body) if body is not None else '')


class Base(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.log = Path(tmp.name) / 'fleet-watch.log'
        patcher = mock.patch.dict(os.environ, {'FLEET_WATCH_LOG_PATH': str(self.log)})
        patcher.start()
        self.addCleanup(patcher.stop)
        fw.USAGE_GATE_REFUSALS.clear()
        fw.USAGE_GATE_CALLS[0] = 0

    def lines(self):
        return self.log.read_text().splitlines() if self.log.exists() else []


class Refusals(Base):
    def test_issue_scan_gate_is_called_as_automatic_and_logs_the_refusal(self):
        seen = []
        def run(command, **kwargs):
            seen.append(command)
            return proc(4, {'provider': 'claude', 'verdict': 'unknown', 'reading_age_min': 190.5,
                            'reason': 'no fresh provider reading; last good reading 190.5m old', 'headroom': 49})
        self.assertFalse(fw.default_issue_scan_gate({'issue_scan': {'agent': 'claude', 'model': 'sonnet'}}, run=run))
        self.assertIn('--auto', seen[0])
        (line,) = self.lines()
        for part in ('provider=claude', 'verdict=unknown', 'reading_age_min=190.5', 'last good reading 190.5m old'):
            self.assertIn(part, line)
        self.assertEqual(fw.USAGE_GATE_REFUSALS[0]['headroom'], 49)

    def test_an_allowed_gate_logs_nothing(self):
        self.assertTrue(fw.default_issue_scan_gate({'issue_scan': {'agent': 'claude'}}, run=lambda c, **k: proc(0, {})))
        self.assertEqual(self.lines(), [])

    def test_pick_is_called_as_automatic_and_logs_refusals_only_when_nothing_is_picked(self):
        seen = []
        refused = {'selected': None, 'candidates': [
            {'provider': 'cursor', 'verdict': 'blocked', 'reason': 'daily cap', 'reading_age_min': 0, 'headroom': 30},
            {'provider': 'claude', 'verdict': 'unknown', 'reason': 'no reading', 'headroom': None, 'last_headroom': 55}]}
        def run(command, **kwargs):
            seen.append(command)
            return proc(3, refused)
        with mock.patch.dict(os.environ, {'USAGE_GATE_CLI': '/bin/usage-gate'}):
            fw.pick_role('qa-sdet', run=run)
            fw.pick_role('fullstack-dev', run=run)  # same refusals again: still one line each per pass
        self.assertIn('--auto', seen[0])
        self.assertEqual(len(self.lines()), 2)
        self.assertEqual([r['headroom'] for r in fw.USAGE_GATE_REFUSALS], [30, 55])
        self.log.unlink()
        fw.USAGE_GATE_REFUSALS.clear()
        picked = {**refused, 'selected': {'provider': 'claude', 'model': 'opus'}}
        fw.pick_role('qa-sdet', run=lambda c, **k: proc(0, picked))
        self.assertEqual(self.lines(), [])


class Notice(Base):
    def refuse(self, headroom):
        fw.USAGE_GATE_CALLS[0] += 1
        fw.record_gate_refusal('claude', 'unknown', 'no reading', 190, headroom)

    def test_settings_come_from_the_committed_config(self):
        self.assertEqual(fw.usage_gate_settings(), (30.0, 20.0))

    def test_one_notice_after_30_minutes_with_over_20_points_of_headroom(self):
        state = {}
        self.refuse(49)
        self.assertEqual(fw.usage_gate_notices(state, NOW), [])
        self.refuse(49)
        self.assertEqual(fw.usage_gate_notices(state, NOW + 29 * 60), [])
        self.refuse(49)
        (notice,) = fw.usage_gate_notices(state, NOW + 30 * 60)
        self.assertIn('claude unknown', notice)
        self.assertIsInstance(notice, fw.Urgent)
        self.refuse(49)
        self.assertEqual(fw.usage_gate_notices(state, NOW + 60 * 60), [])  # not one per pass

    def test_low_headroom_never_notifies(self):
        state = {}
        for minutes in (0, 31, 90):
            self.refuse(20)
            self.assertEqual(fw.usage_gate_notices(state, NOW + minutes * 60), [])
        self.refuse(None)
        self.assertEqual(fw.usage_gate_notices(state, NOW + 120 * 60), [])

    def test_an_allowed_pass_resets_the_clock(self):
        state = {}
        self.refuse(49)
        fw.usage_gate_notices(state, NOW)
        fw.USAGE_GATE_CALLS[0] += 1  # the gate was asked and refused nothing
        fw.usage_gate_notices(state, NOW + 20 * 60)
        self.refuse(49)
        self.assertEqual(fw.usage_gate_notices(state, NOW + 40 * 60), [])  # clock restarted at 40
        self.refuse(49)
        self.assertEqual(len(fw.usage_gate_notices(state, NOW + 71 * 60)), 1)


if __name__ == '__main__':
    unittest.main()
