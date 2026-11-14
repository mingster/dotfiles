import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import asdf_pin  # noqa: E402

asdf_pin.pin()  # before any test sets HOME

ROOT = Path(__file__).resolve().parents[2]
FW_PATH = ROOT / 'script' / 'fleet-watch.py'

spec = importlib.util.spec_from_file_location('fleet_watch', FW_PATH)
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)


class CoordinatorOverflowAdmitTests(unittest.TestCase):
    def test_admit_rejects_coordinator_when_load_per_core_exceeds_threshold_and_names_first_admitted_overflow_host(self):
        config = {
            'local_host': 'coord-box',
            'host_caps': {
                'coord-box': 4,
                'overflow-a': 1,
                'overflow-b': 2,
            },
        }
        workers = [
            {
                'dispatchId': 'w_a1',
                'dispatchStatus': 'running',
                'projection': {'role': 'builder', 'host': {'id': 'overflow-a'}},
            }
        ]
        with patch.dict(os.environ, {
            'FLEET_WATCH_TEST_LOAD_PER_CORE': '0.85',
            'FLEET_WATCH_TEST_FREE_GB': '12.0',
        }):
            receipt = fw.admit('local', config, workers=workers)
        self.assertFalse(receipt['admitted'])
        self.assertEqual(receipt.get('overflow_host'), 'overflow-b')
        self.assertIn('overflow-b', receipt.get('reason', ''))
        self.assertIn('start-remote-worker.sh --on overflow-b', receipt.get('reason', ''))

    def test_admit_rejects_coordinator_when_free_memory_below_4gb(self):
        config = {
            'host_caps': {
                'local': 4,
                'overflow-a': 2,
            },
        }
        with patch.dict(os.environ, {
            'FLEET_WATCH_TEST_LOAD_PER_CORE': '0.30',
            'FLEET_WATCH_TEST_FREE_GB': '3.5',
        }):
            receipt = fw.admit('local', config, workers=[])
        self.assertFalse(receipt['admitted'])
        self.assertEqual(receipt.get('overflow_host'), 'overflow-a')
        self.assertIn('overflow-a', receipt.get('reason', ''))
        self.assertIn('3.50 GB < 4.0 GB', receipt.get('reason', ''))

    def test_admit_reports_none_overflow_host_when_all_remote_hosts_full(self):
        config = {
            'host_caps': {
                'local': 4,
                'overflow-a': 1,
            },
        }
        workers = [
            {
                'dispatchId': 'w_a1',
                'dispatchStatus': 'running',
                'projection': {'role': 'builder', 'host': {'id': 'overflow-a'}},
            }
        ]
        with patch.dict(os.environ, {
            'FLEET_WATCH_TEST_LOAD_PER_CORE': '0.70',
            'FLEET_WATCH_TEST_FREE_GB': '8.0',
        }):
            receipt = fw.admit('local', config, workers=workers)
        self.assertFalse(receipt['admitted'])
        self.assertIsNone(receipt.get('overflow_host'))
        self.assertIn('no remote overflow host has free capacity', receipt.get('reason', ''))

    def test_admit_allows_coordinator_when_load_and_memory_and_cap_are_healthy(self):
        config = {
            'host_caps': {
                'local': 4,
                'overflow-a': 2,
            },
        }
        with patch.dict(os.environ, {
            'FLEET_WATCH_TEST_LOAD_PER_CORE': '0.50',
            'FLEET_WATCH_TEST_FREE_GB': '8.0',
        }):
            receipt = fw.admit('local', config, workers=[])
        self.assertTrue(receipt['admitted'])
        self.assertIsNone(receipt.get('overflow_host'))

    def test_vm_stat_and_meminfo_parsers_compute_free_gb(self):
        vm_out = (
            'Mach Virtual Memory Statistics: (page size of 16384 bytes)\n'
            'Pages free:                               100000.\n'
            'Pages active:                             200000.\n'
            'Pages inactive:                            50000.\n'
            'Pages speculative:                         13840.\n'
        )
        # (100000 + 50000 + 13840) * 16384 / 1024^3 = 2.5 GiB
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop('FLEET_WATCH_TEST_FREE_GB', None)
            with patch.object(fw.sys, 'platform', 'darwin'):
                gb = fw.coordinator_free_gb(vm_stat_runner=lambda: vm_out)
                self.assertAlmostEqual(gb, 2.5, places=2)
            with tempfile.TemporaryDirectory() as tmp:
                meminfo = Path(tmp) / 'meminfo'
                meminfo.write_text('MemTotal:       16777216 kB\nMemAvailable:    3145728 kB\n')
                with patch.object(fw.sys, 'platform', 'linux'):
                    gb_linux = fw.coordinator_free_gb(meminfo_path=str(meminfo))
                    self.assertAlmostEqual(gb_linux, 3.0, places=2)

    def test_cli_admit_local_json_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / 'config.json'
            cfg.write_text(json.dumps({
                'host_caps': {'local': 4, 'overflow-a': 2},
            }))
            env = dict(
                os.environ,
                FLEET_WATCH_TEST_LOAD_PER_CORE='0.85',
                FLEET_WATCH_TEST_FREE_GB='8.0',
            )
            proc = subprocess.run(
                [sys.executable, str(FW_PATH), '--admit-local', '--config', str(cfg), '--json'],
                capture_output=True, text=True, env=env, timeout=15,
            )
            self.assertEqual(proc.returncode, 1)
            payload = json.loads(proc.stdout)
            self.assertFalse(payload['admitted'])
            self.assertEqual(payload['overflow_host'], 'overflow-a')

    def _run_hook(self, command, fw_config, load_per_core='0.20', free_gb='12.0'):
        hook_path = ROOT / 'script' / 'usage-gate-hook.py'
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            state_dir = tmp_path / 'state'
            state_dir.mkdir()
            now = time.time()
            (state_dir / 'claude-rate-limits.json').write_text(json.dumps({
                'seven_day': {'used_percentage': 10.0, 'resets_at': now + 86400},
                '_written_at': now,
            }))
            presets_path = tmp_path / 'presets.json'
            presets_path.write_text(json.dumps({
                'roles': {
                    'fullstack-dev': {
                        'tier': 'workhorse',
                        'chain': [{'provider': 'claude', 'model': 'sonnet'}],
                    }
                }
            }))
            cfg_path = tmp_path / 'fleet-watch.json'
            cfg_path.write_text(json.dumps(fw_config))
            env = dict(
                os.environ,
                HOME=str(tmp_path),
                USAGE_GATE_STATE=str(state_dir),
                USAGE_GATE_ORCA='false',
                USAGE_GATE_PRESETS=str(presets_path),
                FLEET_WATCH_CONFIG=str(cfg_path),
                FLEET_WATCH_TEST_LOAD_PER_CORE=str(load_per_core),
                FLEET_WATCH_TEST_FREE_GB=str(free_gb),
            )
            proc = subprocess.run(
                [sys.executable, str(hook_path)],
                input=json.dumps({'tool_name': 'Bash', 'tool_input': {'command': command}}),
                capture_output=True, text=True, env=env, timeout=15,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            if not proc.stdout.strip():
                return None
            return json.loads(proc.stdout)['hookSpecificOutput']

    def test_usage_gate_hook_denies_local_start_when_load_high_and_names_overflow_host(self):
        out = self._run_hook(
            'orca orchestration worker-start --task t --agent claude --spec ok',
            {'host_caps': {'local': 4, 'overflow-a': 2, 'overflow-b': 2}},
            load_per_core='0.85',
            free_gb='12.0',
        )
        self.assertIsNotNone(out)
        self.assertEqual(out['permissionDecision'], 'deny')
        self.assertIn('overflow-a', out['permissionDecisionReason'])
        self.assertIn('script/start-remote-worker.sh --on overflow-a', out['permissionDecisionReason'])

    def test_usage_gate_hook_denies_local_start_when_free_memory_low(self):
        out = self._run_hook(
            'orca orchestration worker-start --task t --agent claude --spec ok',
            {'host_caps': {'local': 4, 'overflow-a': 0, 'overflow-b': 2}},
            load_per_core='0.30',
            free_gb='2.5',
        )
        self.assertIsNotNone(out)
        self.assertEqual(out['permissionDecision'], 'deny')
        self.assertIn('overflow-b', out['permissionDecisionReason'])
        self.assertIn('script/start-remote-worker.sh --on overflow-b', out['permissionDecisionReason'])

    def test_usage_gate_hook_names_only_a_host_mapped_for_the_repo(self):
        out = self._run_hook(
            'orca orchestration worker-start --task t --agent claude --spec ok --repo path:/tmp/dotfiles',
            {
                'host_caps': {'local': 4, 'overflow-a': 2, 'overflow-b': 2},
                'worker_placement': {'repos': {
                    'overflow-a': {'/tmp/other': 'id:other'},
                    'overflow-b': {'/tmp/dotfiles': 'id:dots'},
                }},
            },
            load_per_core='0.85',
            free_gb='12.0',
        )
        self.assertIsNotNone(out)
        self.assertEqual(out['permissionDecision'], 'deny')
        self.assertIn('overflow-b', out['permissionDecisionReason'])
        self.assertNotIn('overflow-a', out['permissionDecisionReason'])

    def test_usage_gate_hook_reports_no_overflow_host_when_none_available(self):
        out = self._run_hook(
            'orca orchestration worker-start --task t --agent claude --spec ok',
            {'host_caps': {'local': 4, 'overflow-a': 0}},
            load_per_core='0.85',
            free_gb='12.0',
        )
        self.assertIsNotNone(out)
        self.assertEqual(out['permissionDecision'], 'deny')
        self.assertIn('no remote overflow host has free capacity', out['permissionDecisionReason'])


if __name__ == '__main__':
    unittest.main()
