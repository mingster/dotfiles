#!/usr/bin/env python3
"""Worker duration log, report, limit flags and hung PR check jobs (#1978)."""
import importlib.util
import io
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPT / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fw = load('fleet_watch_1978', 'fleet-watch.py')
wd = load('worker_durations_1978', 'worker-durations.py')

NOW = 1_800_000_000.0


def worker(did, title, **extra):
    row = {'dispatchId': did, '_task_title': title, 'state': 'running'}
    row.update(extra)
    return row


class Base(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.log = Path(tmp.name) / 'durations.jsonl'
        self.state = {}

    def tick(self, now, workers, messages=(), config=None, size=('size:S',)):
        return fw.worker_duration_pass(
            config or {}, self.state, now, workers, list(messages),
            repo_of=lambda w: 'o/r', labels_of=lambda repo, number: list(size), log_path=self.log)


class DurationLog(Base):
    def test_start_and_worker_done_are_logged_and_reported_per_role_and_size(self):
        for index, minutes in enumerate((10, 20, 30, 40, 100)):
            did = 'ctx_%d' % index
            wd.main(['start', '--dispatch', did, '--title', '#5|fullstack-dev', '--agent', 'claude', '--log', str(self.log)])
            started = wd.read(self.log)[did]['started']
            self.tick(started + 1, [worker(did, '#5|fullstack-dev')])
            done = {'type': 'worker_done', 'payload': {'dispatchId': did}}
            self.tick(started + minutes * 60, [worker(did, '#5|fullstack-dev')], [done])
            self.tick(started + 9999, [worker(did, '#5|fullstack-dev')], [done])
        self.assertEqual([r[:3] for r in wd.report(wd.read(self.log))], [('fullstack-dev', 'S', 5)])
        out = io.StringIO()
        with redirect_stdout(out):
            wd.main(['--log', str(self.log)])
        self.assertEqual(out.getvalue().splitlines()[1].split(), ['fullstack-dev', 'S', '5', '30', '100'])

    def test_unrecorded_worker_starts_at_first_sight_and_ends_on_release(self):
        self.tick(NOW, [worker('ctx_a', '#5|qa-sdet')], size=('P1',))
        self.tick(NOW + 600, [worker('ctx_a', '#5|qa-sdet', state='released')])
        row = wd.read(self.log)['ctx_a']
        self.assertEqual((row['ended'] - row['started'], row['size'], row['outcome']), (600, 'M', 'released'))

    def test_settled_worker_never_seen_live_is_not_logged(self):
        self.tick(NOW, [worker('ctx_a', '#5|qa-sdet', state='completed')])
        self.assertEqual(wd.read(self.log), {})


class Limits(Base):
    def test_soft_then_hard_are_flagged_once_each(self):
        rows = [worker('ctx_a', '#5|fullstack-dev')]
        self.assertEqual(self.tick(NOW, rows)[0], [])
        self.assertEqual(self.tick(NOW + 59 * 60, rows)[0], [])
        soft = self.tick(NOW + 61 * 60, rows)[0]
        self.assertEqual(len(soft), 1)
        self.assertIn('soft limit', soft[0])
        self.assertIsInstance(soft[0], fw.Urgent)
        self.assertEqual(self.tick(NOW + 70 * 60, rows)[0], [])
        hard = self.tick(NOW + 91 * 60, rows)[0]
        self.assertEqual(len(hard), 1)
        self.assertIn('hard limit', hard[0])
        self.assertIn('release it', hard[0])
        self.assertEqual(self.tick(NOW + 120 * 60, rows)[0], [])

    def test_exempt_workers_are_not_flagged(self):
        rows = [worker('ctx_%d' % i, title) for i, title in enumerate(
            ('#1|elon', '#2|coordinator', '#3|support-csm', '#4|release-manager', '#5|qa-sdet|regression'))]
        self.tick(NOW, rows)
        self.assertEqual(self.tick(NOW + 500 * 60, rows)[0], [])

    def test_config_sets_limits_per_role_and_size(self):
        config = {'worker_limits': {'types': {'fullstack-dev/S': {'soft_minutes': 20, 'hard_minutes': 30}}}}
        rows = [worker('ctx_a', '#5|fullstack-dev')]
        self.tick(NOW, rows, config=config)
        self.assertIn('of 20 min', self.tick(NOW + 21 * 60, rows, config=config)[0][0])


class NestedRows(Base):
    def row(self, title=None):
        row = {'dispatchId': 'ctx_n', 'dispatchStatus': 'dispatched', 'terminalState': 'active',
               'projection': {'role': 'worker', 'outcome': 'in_progress', 'liveness': {'verdict': 'live'},
                              'provider': {'id': 'claude'}}}
        if title:
            row['_task_title'] = title
        return row

    def test_nested_row_ends_when_dispatch_completes(self):
        self.tick(NOW, [self.row('#5|fullstack-dev')])
        self.tick(NOW + 120, [dict(self.row('#5|fullstack-dev'), dispatchStatus='completed')])
        row = wd.read(self.log)['ctx_n']
        self.assertEqual((row['role'], row['agent'], row['ended'] - row['started']), ('fullstack-dev', 'claude', 120))

    def test_missing_task_title_uses_the_logged_start_title(self):
        wd.main(['start', '--dispatch', 'ctx_n', '--title', '#5|release-manager', '--log', str(self.log)])
        started = wd.read(self.log)['ctx_n']['started']
        self.assertEqual(self.tick(started + 500 * 60, [self.row()])[0], [])


class HungChecks(unittest.TestCase):
    def setUp(self):
        self.state, self.calls = {}, []

    def tick(self, now, status, started, code=0, history=()):
        check = {'name': 'script-tests', 'status': status,
                 'startedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(started)),
                 'detailsUrl': 'https://github.com/o/r/actions/runs/77/job/1'}
        prs = [{'number': 9, 'state': 'OPEN', 'statusCheckRollup': [check]}] + list(history)
        return fw.ci_hang_pass({'babysit': {'repos': ['o/r']}}, self.state, now, fetch=lambda repo: prs,
                               act=lambda cmd: self.calls.append(cmd[2]) or code)[0]

    def test_cancel_and_rerun_once_then_flag_the_second_hang(self):
        self.assertEqual(self.tick(NOW, 'IN_PROGRESS', NOW - 29 * 60), [])
        self.assertEqual(self.calls, [])
        self.tick(NOW, 'IN_PROGRESS', NOW - 31 * 60)
        self.assertEqual(self.calls, ['cancel'])
        self.tick(NOW + 60, 'IN_PROGRESS', NOW - 31 * 60)  # cancel still pending
        self.tick(NOW + 300, 'COMPLETED', NOW - 31 * 60)
        self.assertEqual(self.calls, ['cancel', 'rerun'])
        flagged = self.tick(NOW + 3000, 'IN_PROGRESS', NOW + 400)
        self.assertEqual(len(flagged), 1)
        self.assertIn('o/r #9 run 77', flagged[0])
        self.assertEqual(self.tick(NOW + 3300, 'IN_PROGRESS', NOW + 400), [])
        self.assertEqual(self.calls, ['cancel', 'rerun'])

    @staticmethod
    def history(minutes, count):
        stamp = lambda t: time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(t))
        return [{'number': 100 + i, 'state': 'MERGED', 'statusCheckRollup': [
            {'name': 'script-tests', 'status': 'COMPLETED', 'conclusion': 'SUCCESS',
             'startedAt': stamp(NOW - 86400 + i * 3600), 'completedAt': stamp(NOW - 86400 + i * 3600 + minutes * 60),
             'detailsUrl': 'https://github.com/o/r/actions/runs/%d/job/1' % (500 + i)}]} for i in range(count)]

    def test_p90_of_21_minutes_keeps_a_25_minute_run_and_cancels_past_31_and_a_half(self):
        history = self.history(21, 10)
        self.assertEqual(fw.ci_job_limit_seconds(history, 'script-tests'), 1.5 * 21 * 60)
        self.tick(NOW, 'IN_PROGRESS', NOW - 25 * 60, history=history)
        self.assertEqual(self.calls, [])
        self.tick(NOW, 'IN_PROGRESS', NOW - 31 * 60 - 20, history=history)
        self.assertEqual(self.calls, [])
        self.tick(NOW, 'IN_PROGRESS', NOW - 31 * 60 - 40, history=history)
        self.assertEqual(self.calls, ['cancel'])

    def test_fewer_than_10_samples_uses_30_minutes(self):
        self.assertEqual(fw.ci_job_limit_seconds(self.history(5, 9), 'script-tests'), 30 * 60)
        self.assertEqual(fw.ci_job_limit_seconds(self.history(5, 10), 'other-check'), 30 * 60)
        self.tick(NOW, 'IN_PROGRESS', NOW - 29 * 60, history=self.history(5, 9))
        self.assertEqual(self.calls, [])

    def test_failed_cancel_is_tried_again(self):
        self.tick(NOW, 'IN_PROGRESS', NOW - 31 * 60, code=1)
        self.tick(NOW + 300, 'IN_PROGRESS', NOW - 31 * 60)
        self.assertEqual(self.calls, ['cancel', 'cancel'])


if __name__ == '__main__':
    unittest.main()
