"""Issue 925: issue_scan counts live workers, places across hosts, scans dotfiles, tells the coordinator."""
import importlib.util
import json
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

NOW = 1_700_000_000.0
BODY = '## Acceptance\n- x\n\n## Out of scope\n- y\n\n## Verify\nbash script/checks-local.sh\n\n## Finish\nworker_done\n'


def worker(did, host='local', status='running', liveness=None, **extra):
    row = {'dispatchId': did, 'dispatchStatus': status, 'projection': {'host': {'id': host}}}
    if liveness:
        row['projection']['liveness'] = {'verdict': liveness}
    row.update(extra)
    return row


def issue(number, body=BODY, labels=('ready-for-agent',), comments=None):
    return {'number': number, 'title': 't', 'body': body, 'labels': [{'name': n} for n in labels],
            'comments': comments or [], 'createdAt': '2026-01-01T00:00:00Z'}


CONFIG = {
    'host_caps': {'local': 2, 'niteking': 2, 'blueDevil': 2, 'miniu': 2},
    'issue_scan': {
        'enabled': True, 'repos': ['o/a', 'o/dotfiles'], 'run': 'run_x', 'from_terminal': 'term_c',
        'host': 'local', 'hosts': ['local', 'niteking', 'blueDevil', 'miniu'],
        'agent': 'claude', 'model': 'sonnet',
        'repo_roots': {'o/a': '/tmp/a', 'o/dotfiles': '/tmp/d'},
        'host_repo_roots': {'niteking': {'o/a': '/n/a', 'o/dotfiles': '/n/d'},
                            'blueDevil': {'o/a': '/b/a'}, 'miniu': {'o/a': '/m/a'}},
        'backlog_sweep_interval_seconds': 7200,
    },
}


def run(workers, issues, state=None, config=CONFIG):
    state = {} if state is None else state
    state.setdefault('issue_scan_backlog_sweep_at', NOW)
    starts, acts = [], []

    def start(cmd):
        starts.append(cmd)
        return 0

    def act(cmd):
        acts.append(cmd)
        return 0

    notices, log = fw.issue_scan_pass(
        config, state, NOW, workers,
        list_issues=lambda repo: issues.get(repo, []), pr_fetch=lambda repo: [],
        gate_check=lambda c: True, start_worker=start, act=act,
        admit_fn=lambda h, c, w: fw.admit_live_only(h, c, w), inventory_ok=True)
    return notices, log, starts, acts, state


def full_hosts():
    rows = []
    for host in ('local', 'niteking', 'blueDevil', 'miniu'):
        rows += [worker(host + '1', host=host), worker(host + '2', host=host)]
    return rows


class LiveOnlyCount(unittest.TestCase):
    def test_stale_and_completed_workers_do_not_fill_the_cap(self):
        workers = [
            worker('d1', status='dispatched', liveness='exited'),
            worker('d2', status='dispatched', liveness='exited'),
            worker('d3', status='completed'),
            worker('d4', status='completed'),
        ]
        receipt = fw.admit('local', CONFIG, workers, live_only=True)
        self.assertEqual(receipt['occupied'], 0)
        self.assertTrue(receipt['admitted'])
        self.assertNotEqual(fw.admit('local', CONFIG, workers)['occupied'], 0)

    def test_other_hosts_workers_do_not_count_locally(self):
        workers = [worker('d%d' % i, host='niteking') for i in range(3)]
        self.assertEqual(fw.admit('local', CONFIG, workers, live_only=True)['occupied'], 0)
        self.assertEqual(fw.admit('niteking', CONFIG, workers, live_only=True)['occupied'], 3)

    def test_live_workers_count(self):
        receipt = fw.admit('local', CONFIG, [worker('d1'), worker('d2')], live_only=True)
        self.assertEqual((receipt['occupied'], receipt['admitted']), (2, False))


class Placement(unittest.TestCase):
    def test_full_local_places_on_next_host(self):
        _, log, starts, _, _ = run([worker('d1'), worker('d2')], {'o/a': [issue(5)]})
        self.assertEqual(len(starts), 1)
        cmd = starts[0]
        self.assertEqual(cmd[cmd.index('--on') + 1], 'niteking')
        self.assertEqual(cmd[cmd.index('--repo') + 1], 'path:/n/a')
        self.assertIn('issue_start=5', log)

    def test_skips_every_full_host(self):
        workers = [w for w in full_hosts() if w['projection']['host']['id'] != 'miniu']
        _, _, starts, _, _ = run(workers, {'o/a': [issue(5)]})
        self.assertEqual(starts[0][starts[0].index('--on') + 1], 'miniu')

    def test_local_first_when_free(self):
        _, _, starts, _, _ = run([], {'o/a': [issue(5)]})
        self.assertNotIn('--on', starts[0])


class Dotfiles(unittest.TestCase):
    def test_dotfiles_ready_issue_starts(self):
        _, log, starts, _, _ = run([], {'o/dotfiles': [issue(924)]})
        self.assertIn('issue_start=924', log)
        self.assertEqual(starts[0][starts[0].index('--repo') + 1], 'path:/tmp/d')

    def test_example_config_scans_dotfiles(self):
        path = Path(__file__).parent.parent / 'fleet-watch.config.example.json'
        example = json.loads(path.read_text())
        self.assertIn('mingster/dotfiles', example['issue_scan']['repos'])


class DoneWhen(unittest.TestCase):
    def test_done_when_counts_as_acceptance(self):
        for body in ('Done when: the gate passes', '## Done when\n- the gate passes', '**Done when:** it passes'):
            self.assertTrue(fw.issue_scan_eligible(issue(1, body)), body)

    def test_skipped_ready_issue_gets_one_comment(self):
        row = issue(9, 'no criteria at all')
        _, _, starts, acts, state = run([], {'o/a': [row]})
        comments = [a for a in acts if a[:3] == ['gh', 'issue', 'comment']]
        self.assertEqual(len(comments), 1)
        self.assertIn('issue-scan skipped', comments[0][-1])
        self.assertEqual(starts, [])
        _, _, _, acts2, _ = run([], {'o/a': [row]}, state=state)
        self.assertEqual([a for a in acts2 if a[:3] == ['gh', 'issue', 'comment']], [])

    def test_no_comment_when_not_ready(self):
        _, _, _, acts, _ = run([], {'o/a': [issue(9, 'x', labels=('bug',))]})
        self.assertEqual(acts, [])


class RefusalNotice(unittest.TestCase):
    def test_one_urgent_after_more_than_two_passes(self):
        state = {}
        counts = []
        for _ in range(5):
            notices, log, _, _, state = run(full_hosts(), {'o/a': [issue(5)]}, state=state)
            counts.append([n for n in notices if isinstance(n, fw.Urgent)])
            self.assertTrue(any(b.startswith('issue_scan_refused=') for b in log))
        self.assertEqual([len(x) for x in counts], [0, 0, 1, 0, 0])
        self.assertIn('miniu', counts[2][0])


if __name__ == '__main__':
    unittest.main()
