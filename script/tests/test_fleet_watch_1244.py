"""#1244: one issue_scan pass fills every free seat the host caps and the usage gate allow."""
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fleet_watch_1244', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_1204 import fake_rpc  # noqa: E402
from test_fleet_watch_park import scan_config  # noqa: E402
from test_fleet_watch_1216 import row  # noqa: E402


def run(issues, config, admit_fn, gate_check=lambda _c: True, codes=None):
    starts = []
    codes = list(codes or [])

    def start(command):
        starts.append(command)
        return codes.pop(0) if codes else 0

    state = {'issue_scan_backlog_sweep_at': 1}
    with patch.object(fw, 'rpc', side_effect=fake_rpc):
        _n, bits = fw.issue_scan_pass(
            config, state, 1, [], pr_fetch=lambda _r: [], list_issues=lambda _r: list(issues),
            gate_check=gate_check, admit_fn=admit_fn, start_worker=start,
            act=lambda _c: 0, repo_id_lookup=lambda _h, _r: 'repo-id',
        )
    return starts, bits


def local_admit(_h, _c, _w):
    return {'admitted': True, 'occupied': 0}


class FillSeats(unittest.TestCase):
    def two_host_config(self):
        config = scan_config('/work/app')
        config['host_caps'] = {'local': 4, 'host-a': 1, 'host-b': 1}
        config['local_host'] = 'local'
        config['host_repos'] = {}
        return config

    def test_two_hosts_with_one_free_seat_each_start_exactly_two(self):
        def admit(host, _c, _w):
            if host == 'local':
                return {'admitted': False, 'reason': 'load', 'occupied': 4}
            return {'admitted': True, 'occupied': 0, 'cap': 1}

        with patch.object(fw, '_host_maps_repo', return_value=True):
            starts, bits = run([row(n) for n in range(1, 6)], self.two_host_config(), admit)
        self.assertEqual(len(starts), 2, bits)

    def test_local_cap_limits_a_pass(self):
        config = scan_config('/work/app')
        config['host_caps'] = {'local': 3}
        starts, _bits = run([row(n) for n in range(1, 6)], config, lambda *_a: {'admitted': True, 'occupied': 1})
        self.assertEqual(len(starts), 2)

    def test_usage_gate_refusing_after_the_first_start_yields_one(self):
        answers = iter([True, False])
        starts, bits = run(
            [row(n) for n in range(1, 6)], scan_config('/work/app'), local_admit,
            gate_check=lambda _c: next(answers, False))
        self.assertEqual(len(starts), 1)
        self.assertTrue(any(b.startswith('issue_scan_gate=') for b in bits), bits)

    def test_failed_start_does_not_block_the_next_candidate(self):
        starts, bits = run([row(1), row(2), row(3)], scan_config('/work/app'), local_admit, codes=[1])
        self.assertEqual(len(starts), 3)
        self.assertTrue(any(b.startswith('issue_start_fail=') for b in bits), bits)

    def test_deferred_start_moves_on(self):
        code = sorted(fw.BABYSIT_DEFERRED_EXITS)[0]
        starts, bits = run([row(1), row(2)], scan_config('/work/app'), local_admit, codes=[code])
        self.assertEqual(len(starts), 2)


if __name__ == '__main__':
    unittest.main()
