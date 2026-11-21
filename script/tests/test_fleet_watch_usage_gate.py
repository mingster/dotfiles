"""fleet-watch passes --auto to the usage gate, logs each refusal and tells the coordinator once (#987)."""
import importlib.util
import json
import os
import sys
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

    def test_issue_scan_with_no_agent_is_gated_as_claude(self):
        seen = []
        fw.default_issue_scan_gate({'issue_scan': {}}, run=lambda c, **k: seen.append(c) or proc(0, {}))
        self.assertEqual(seen[0][seen[0].index('--provider') + 1], 'claude')

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


GATE_WRAPPER = '''
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location('ug', sys.argv[1])
ug = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ug)
reading = lambda: {'pct': 10, 'resets_at': time.time() + 86400, 'observed_at': time.time()}
ug.READERS.update({'claude': reading, 'cursor': reading, 'antigravity': lambda: None})
ug.live_workers = lambda provider: []
ug.antigravity_models = lambda: None
ug.refresh_reading = lambda provider: None
sys.exit(ug.main(sys.argv[2:]))
'''


class ProviderPause(Base):
    """A paused provider is never the verifier fleet-watch starts; after the date it is allowed again (#1115)."""

    def pick_verifier(self, until):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        gate = Path(__file__).parent.parent / 'usage-gate.py'
        config = json.loads(gate.with_name('usage-gate.config.json').read_text())
        config['pauses'] = [{'provider': 'grok', 'until': until, 'reason': 'owner rule'}]
        (root / 'config.json').write_text(json.dumps(config))
        (root / 'wrapper.py').write_text(GATE_WRAPPER)
        cli = root / 'usage-gate'
        cli.write_text('#!/bin/sh\nexec %s %s %s "$@"\n' % (sys.executable, root / 'wrapper.py', gate))
        cli.chmod(0o755)
        env = {'USAGE_GATE_CLI': str(cli), 'USAGE_GATE_CONFIG': str(root / 'config.json'),
               'USAGE_GATE_STATE': str(root / 'state'),
               'USAGE_GATE_PRESETS': str(gate.parent.parent / '.orca' / 'presets.json')}
        with mock.patch.dict(os.environ, env):
            data = fw.pick_role('qa-sdet', avoid_family='claude')
            return fw.choose_pick(data, avoid=('claude', 'sonnet'))

    def test_a_paused_grok_is_not_picked_as_the_verifier(self):
        agent, model, _tag = self.pick_verifier('2999-01-01')
        self.assertNotIn('grok', model)
        self.assertNotEqual(agent, 'grok')

    def test_a_claude_built_pr_gets_a_verifier_from_the_roomier_family_once_the_pause_ends(self):
        agent, model, _tag = self.pick_verifier('2000-01-01')
        self.assertEqual((agent, model), ('grok', 'grok-4.7'))  # no reading for Antigravity, idle Grok ranks first


if __name__ == '__main__':
    unittest.main()
