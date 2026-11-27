"""#2012: a ready issue whose local seats are full goes to a remote host with a free seat.

The issue scan placed on remote hosts only when local admission itself was refused. When local admission passed
but the local cap ran out partway through the pass (occupied, including retained workers, plus this pass's starts),
the scan deferred every remaining ready issue as host_cap, even with free seats on the remote hosts."""
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)
import test_fleet_watch_1042 as base  # noqa: E402  shared fixtures (issue body, scan config, gh guard)

spec = importlib.util.spec_from_file_location('fleet_watch_2012', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

REPO = base.REPO
NOW = base.NOW
BODY = (
    'Refs mingster/dotfiles#9\n\n'
    '## Acceptance\n- [ ] prove it\n\n'
    '## Out of scope\nother files\n\n'
    '## Verify\nbash script/checks-local.sh\n\n'
    '## Finish\n'
    'Self-review, run orca worktree set --worktree active --workspace-status in-review, then worker_done.\n'
)


def issue(number):
    return {
        'number': number, 'title': 't%d' % number, 'body': BODY,
        'labels': [{'name': 'ready-for-agent'}], 'comments': [], 'createdAt': '2026-01-01T00:00:00Z',
    }


def config_with_three_hosts():
    config = base.scan_config({'local': 4, 'niteking': 4, 'blueDevil': 4})
    config['worker_placement'] = {
        'repos': {
            'niteking': {REPO: 'id:nk'},
            'blueDevil': {REPO: 'id:bd'},
        },
    }
    return config


class LocalFullSpillsToRemoteSeats(unittest.TestCase):
    def setUp(self):
        base.fleet_env.guard_gh_writes(self)
        gh = patch.object(fw, 'run_gh', return_value=0)
        gh.start()
        self.addCleanup(gh.stop)

    def run_pass(self):
        starts = []
        placed = []

        def admit(host, _config, _workers):
            if host == 'local':
                # Two retained workers hold local seats; no live worker, so the seats view shows 0/4.
                return {'admitted': True, 'cap': 4, 'occupied': 2, 'live_count': 0, 'retained_count': 2}
            return {'admitted': True, 'cap': 4, 'occupied': 0, 'live_count': 0, 'retained_count': 0}

        def start(command):
            starts.append(command)
            placed.append(command[command.index('--on') + 1] if '--on' in command else 'local')
            return 0

        _notices, log = fw.issue_scan_pass(
            config_with_three_hosts(), {'issue_scan_backlog_sweep_at': NOW}, NOW, [],
            list_issues=lambda _repo: [issue(n) for n in range(7001, 7011)],
            pr_fetch=lambda _repo: [],
            gate_check=lambda _c: True,
            admit_fn=admit,
            start_worker=start,
            repo_id_lookup=lambda host, _repo: 'id-%s' % host,
        )
        return starts, placed, log

    def test_a_pass_with_local_full_and_free_remote_seats_starts_more_than_two(self):
        starts, _placed, log = self.run_pass()
        self.assertGreater(len(starts), 2, log)

    def test_the_starts_land_on_the_remote_hosts_with_free_seats(self):
        starts, placed, log = self.run_pass()
        remote = [h for h in placed if h != 'local']
        self.assertTrue(remote, log)
        self.assertLessEqual(len(remote), 8, log)
        self.assertTrue(set(remote) <= {'niteking', 'blueDevil'}, log)


if __name__ == '__main__':
    unittest.main()
