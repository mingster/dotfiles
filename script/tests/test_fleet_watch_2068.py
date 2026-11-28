"""#2068: a settled worker leaves no simulator, emulator or dev server behind, and the coordinator sees heavy jobs and orphans."""
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

_env_spec = importlib.util.spec_from_file_location('fleet_watch_test_env', Path(__file__).parent / 'fleet_watch_test_env.py')
fleet_watch_test_env = importlib.util.module_from_spec(_env_spec)
_env_spec.loader.exec_module(fleet_watch_test_env)

spec = importlib.util.spec_from_file_location('fleet_watch_2068', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

# A fake xcrun: `list devices booted -j` prints the devices in $FAKE_SIMS (one "udid name" per line), `shutdown <udid>` drops one.
FAKE_XCRUN = """#!/bin/sh
if [ "$1 $2" = "simctl list" ]; then
  printf '{"devices":{"iOS":['
  sep=''
  while read -r udid name; do
    [ -n "$udid" ] || continue
    printf '%s{"udid":"%s","name":"%s","state":"Booted"}' "$sep" "$udid" "$name"; sep=','
  done < "$FAKE_SIMS"
  printf ']}}'
elif [ "$1 $2" = "simctl shutdown" ]; then
  grep -v "^$3 " "$FAKE_SIMS" > "$FAKE_SIMS.new"; mv "$FAKE_SIMS.new" "$FAKE_SIMS"
fi
"""


def start_dev_server(cwd):
    """A real process named like a Next dev server, whose working directory is `cwd`."""
    child = subprocess.Popen(['bash', '-c', 'exec -a next-server sleep 120'], cwd=cwd)
    for _ in range(50):  # wait for the exec so ps shows the new name
        out = subprocess.run(['ps', '-o', 'command=', '-p', str(child.pid)], capture_output=True, text=True).stdout
        if out.startswith('next-server'):
            return child
        time.sleep(0.05)
    child.kill()
    raise AssertionError('dev server stand in did not start')


class TeardownOnRelease(unittest.TestCase):
    def setUp(self):
        fleet_watch_test_env.guard_gh_writes(self)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name).resolve()
        self.root = self.tmp / 'workspaces'
        self.worktree = self.root / 'app' / 'issue-10779'
        self.worktree.mkdir(parents=True)
        self.other = self.root / 'app' / 'issue-555'
        self.other.mkdir()
        bin_dir = self.tmp / 'bin'
        bin_dir.mkdir()
        xcrun = bin_dir / 'xcrun'
        xcrun.write_text(FAKE_XCRUN)
        xcrun.chmod(0o755)
        self.sims = self.tmp / 'sims'
        self.sims.write_text('AAAA verify-10779-se\nBBBB shared-iPhone-15\nCCCC verify-555-se\n')
        env = patch.dict(os.environ, {'PATH': '%s%s%s' % (bin_dir, os.pathsep, os.environ['PATH']), 'FAKE_SIMS': str(self.sims),
                                      'FLEET_WATCH_WORKSPACES_ROOT': str(self.root), 'FLEET_WATCH_TEARDOWN_GRACE': '1'})
        env.start()
        self.addCleanup(env.stop)
        self.children = []
        self.addCleanup(self.reap)

    def reap(self):
        for child in self.children:
            if child.poll() is None:
                child.kill()
            child.wait()

    def dev(self, cwd):
        child = start_dev_server(cwd)
        self.children.append(child)
        return child

    def booted(self):
        return sorted(line.split()[0] for line in self.sims.read_text().splitlines() if line.strip())

    def release(self, row):
        calls = []

        def rpc(*args):
            calls.append(args)
            return {}

        with patch.object(fw, 'resolve_worker_terminal', return_value=''), patch.object(fw, 'close_worker_terminal', return_value='closed'):
            result = fw.release_worker(rpc, row)
        return result, calls

    def test_release_shuts_down_the_workers_simulator_and_dev_server_and_nothing_else(self):
        mine = self.dev(self.worktree)
        theirs = self.dev(self.other)
        result, calls = self.release({'dispatchId': 'ctx_a', '_host': '', 'workspace': str(self.worktree)})
        self.assertEqual(result, 'closed')
        self.assertIn(('orchestration', 'worker-stop', '--dispatch', 'ctx_a'), calls)
        mine.wait(timeout=10)
        with self.assertRaises(OSError):
            os.kill(mine.pid, 0)  # gone: the dev server was stopped, not left running
        self.assertEqual(self.booted(), ['BBBB', 'CCCC'])  # the shared simulator and another worker's one stay up
        self.assertIsNone(theirs.poll())

    def test_teardown_reports_each_resource_it_stopped(self):
        self.dev(self.worktree)
        lines = fw.teardown_heavy_resources(str(self.worktree))
        self.assertEqual(sorted(l.split(' ', 2)[1] for l in lines), ['dev', 'simulator'])
        self.assertTrue(all(l.startswith('stopped ') for l in lines), lines)

    def test_a_path_outside_the_workspaces_folder_tears_down_nothing(self):
        outside = self.tmp / 'elsewhere' / 'issue-10779'
        outside.mkdir(parents=True)
        child = self.dev(outside)
        for path in (str(outside), str(self.root), str(self.root / 'app'), '', 'relative/issue-10779'):
            self.assertEqual(fw.teardown_heavy_resources(path), [], path)
        self.assertIsNone(child.poll())
        self.assertEqual(self.booted(), ['AAAA', 'BBBB', 'CCCC'])

    def test_a_failing_teardown_never_changes_the_release_result(self):
        with patch.object(fw, 'teardown_heavy_resources', side_effect=OSError('boom')):
            result, calls = self.release({'dispatchId': 'ctx_a', '_host': '', 'workspace': str(self.worktree)})
        self.assertEqual(result, 'closed')
        self.assertIn(('orchestration', 'worker-release', '--dispatch', 'ctx_a'), calls)

    def test_a_row_without_a_path_tears_down_nothing(self):
        self.release({'dispatchId': 'ctx_a', '_host': ''})
        self.assertEqual(self.booted(), ['AAAA', 'BBBB', 'CCCC'])

    def test_a_suffixed_worktree_name_and_an_emulator_by_directory_are_the_workers(self):
        self.sims.write_text('AAAA verify-10779-se\nBBBB shared-iPhone-15\n')
        suffixed = self.root / 'app' / 'issue-10779-fix'
        suffixed.mkdir()
        emulator = {'type': 'emu', 'id': '9', 'name': 'Pixel_8', 'pid': 0, 'age': 5, 'cwd': str(suffixed / 'android'), 'kind': 'emulator', 'command': ''}
        killed = []
        with patch.object(fw, 'stop_process', side_effect=lambda pid: killed.append(pid) or True):
            sim = fw.heavy_resources_local()
            lines = fw.teardown_heavy_resources(str(suffixed), resources=sim + [dict(emulator, pid=4242)])
        self.assertEqual(killed, [4242])
        self.assertEqual(self.booted(), ['BBBB'])
        self.assertEqual(sorted(l.split(' ', 2)[1] for l in lines), ['emulator', 'simulator'])

    def test_a_remote_worker_is_torn_down_on_its_host(self):
        sent = []

        def rpc(*args):
            sent.append(args)
            if args[:2] == ('worktree', 'list'):
                return {'worktrees': [{'path': '/r/main', 'isMainWorktree': True}]}
            if args[:2] == ('terminal', 'create'):
                return {'terminal': {'handle': 'term_x'}}
            if args[:2] == ('terminal', 'read'):
                return {'terminal': {'tail': ['stopped simulator verify-10779-se', fw.PROBE_END_LINE]}}
            return {}

        with patch.object(fw, 'close_worker_terminal', return_value='closed'):
            lines = fw.teardown_worker_resources(rpc, {'dispatchId': 'ctx_r', '_host': 'host-b', '_host_workspace': 'id::/r/workspaces/app/issue-10779'})
        self.assertEqual(lines, ['stopped simulator verify-10779-se'])
        create = next(a for a in sent if a[:2] == ('terminal', 'create'))
        command = create[create.index('--command') + 1]
        self.assertIn('--heavy-resources teardown --worktree /r/workspaces/app/issue-10779', command)


class Report(unittest.TestCase):
    def rows(self, **extra):
        return [dict({'dispatchId': 'ctx_a', 'state': 'ready', 'outcome': 'in_progress', 'liveness': 'live',
                      'terminalState': 'active', '_host': '', 'workspace': '/w/workspaces/app/issue-40'}, **extra)]

    def report(self, found, workers=None):
        with patch.object(fw, 'sweep_hosts', return_value=['']), patch.object(fw, 'worker_checkout_path', side_effect=lambda w: w.get('workspace') or ''):
            return fw.heavy_job_report({'local_host': 'host-a'}, 1000, self.rows() if workers is None else workers, None,
                                       lister=lambda _rpc, _host: found)

    def res(self, **kw):
        base = {'type': 'job', 'id': '1', 'name': '', 'pid': 1, 'age': 600, 'cwd': '/w/workspaces/app/issue-40', 'kind': 'build', 'command': ''}
        return dict(base, **kw)

    def test_lists_a_running_job_with_its_worker_kind_and_minutes(self):
        out = self.report([self.res()])
        self.assertEqual(out['hosts']['host-a']['jobs'], [{'worker': 'ctx_a', 'kind': 'build', 'minutes': 10}])
        self.assertEqual(out['hosts']['host-a']['orphans'], [])

    def test_head_checks_job_is_named(self):
        out = self.report([self.res(cwd='/h/orca/workspaces/app/_checks-2/src', kind='tsc')], workers=[])
        self.assertEqual(out['hosts']['host-a']['jobs'][0]['worker'], 'head-checks')

    def test_a_simulator_and_dev_server_with_no_live_worker_are_orphans(self):
        found = [self.res(type='sim', id='AAAA', name='verify-10779-se', kind='simulator', cwd='', age=0),
                 self.res(type='dev', id='7', pid=7, cwd='/w/workspaces/app/issue-10779', kind='dev server', age=7200, command='next-server')]
        out = self.report(found)
        self.assertEqual([(o['type'], o['name']) for o in out['hosts']['host-a']['orphans']],
                         [('sim', 'verify-10779-se'), ('dev', 'next-server')])

    def test_owned_resources_are_not_orphans(self):
        found = [self.res(type='sim', id='AAAA', name='verify-40-se', kind='simulator', cwd='', age=0),
                 self.res(type='dev', id='7', pid=7, kind='dev server', command='next-server')]
        out = self.report(found)['hosts']['host-a']
        self.assertEqual(out['orphans'], [])  # the live worker's simulator is its running job, its dev server is neither

    def test_a_live_workers_simulator_is_listed_as_its_job(self):
        found = [self.res(type='sim', id='AAAA', name='verify-40-se', kind='simulator', cwd='', age=1200)]
        out = self.report(found)
        self.assertEqual(out['hosts']['host-a']['jobs'], [{'worker': 'ctx_a', 'kind': 'simulator', 'minutes': 20}])

    def test_a_remote_workers_resources_match_by_host_name_not_environment_id(self):
        row = self.rows(_host='env-id-1')[0]
        found = [self.res(cwd='/w/workspaces/app/issue-40')]
        with patch.object(fw, 'sweep_hosts', return_value=['env-id-1']), patch.object(fw, 'worker_checkout_path', side_effect=lambda w: w.get('workspace') or ''):
            out = fw.heavy_job_report({'local_host': 'host-a', 'host_caps': {'host-b': 4}}, 1, [row], None,
                                      lister=lambda _r, _h: found, env_names={'env-id-1': 'host-b'})
        self.assertEqual(out['hosts']['host-b']['jobs'][0]['worker'], 'ctx_a')

    def test_an_unreadable_host_is_named(self):
        with patch.object(fw, 'sweep_hosts', return_value=['']):
            out = fw.heavy_job_report({'local_host': 'host-a'}, 1, [], None, lister=lambda _r, _h: None)
        self.assertEqual(out['unread'], ['host-a'])


_wp_spec = importlib.util.spec_from_file_location('worker_placement_2068', Path(__file__).parent.parent / 'worker-placement.py')
wp = importlib.util.module_from_spec(_wp_spec)
_wp_spec.loader.exec_module(wp)


class SettledHeavyWorker(unittest.TestCase):
    def busy(self, released):
        claim = {'host': 'host-b', 'at': 100.0, 'dispatch': 'ctx_1', 'heavy': True, 'id': 'c1'}
        return wp.heavy_busy_hosts({}, ['host-b'], [claim], released, {'ctx_1'}, None, now=100.0 + 3600)

    def test_a_live_heavy_worker_holds_its_host(self):
        self.assertEqual(list(self.busy(set())), ['host-b'])

    def test_a_settled_heavy_worker_frees_its_host_though_the_inventory_still_lists_it(self):
        self.assertEqual(self.busy({'ctx_1'}), {})


class RemoteReadback(unittest.TestCase):
    def test_every_resource_type_survives_the_terminal_read(self):
        found = [
            {'type': 'sim', 'id': 'AAAA', 'name': 'verify-1-se', 'pid': 0, 'age': 0, 'cwd': '', 'kind': 'simulator', 'command': ''},
            {'type': 'dev', 'id': '7', 'name': '', 'pid': 7, 'age': 90, 'cwd': '/w/a', 'kind': 'dev server', 'command': 'next-server'},
            {'type': 'job', 'id': '8', 'name': '', 'pid': 8, 'age': 60, 'cwd': '/w/b', 'kind': 'build', 'command': 'bun run build'},
        ]
        lines = fw.format_heavy_resources(found)
        # a terminal read wraps long lines; the parser joins the rows first
        wrapped = [chunk for line in lines for chunk in (line[:30], line[30:])]
        self.assertEqual(fw.parse_heavy_resources(wrapped), found)
        self.assertIsNone(fw.parse_heavy_resources(lines[:-1]))


class Classify(unittest.TestCase):
    def test_programs_not_words(self):
        for command, want in (
            ('xcodebuild -scheme App test', ('job', 'xcodebuild')),
            ('bash bin/build-and-test.sh', ('job', 'xcodebuild')),
            ('bun run build', ('job', 'build')),
            ('node /w/node_modules/.bin/next build', ('job', 'build')),
            ('node /w/node_modules/.bin/next dev', ('dev', 'dev server')),
            ('next-server (v14.2.3)', ('dev', 'dev server')),
            ('bun run dev', ('dev', 'dev server')),
            ('bun test --isolate', ('job', 'tests')),
            ('bunx playwright test', ('job', 'playwright')),
            ('/Users/u/Library/Android/sdk/emulator/qemu-system-aarch64 -avd Pixel_8', ('emu', 'emulator')),
            ('claude --print "run next build and bun test"', ('', '')),
            ('vim next.config.js', ('', '')),
        ):
            self.assertEqual(fw.classify_process(command), want, command)


if __name__ == '__main__':
    unittest.main()
