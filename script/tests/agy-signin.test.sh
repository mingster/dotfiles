#!/usr/bin/env bash
# #1240: the agy sign-in matcher, the 6 hour host record, and the fleet-watch pass that uses them.
set -euo pipefail
path_no_asdf=$(printf '%s\n' "${PATH//:/$'\n'}" | grep -v '/\.asdf/shims$' | paste -sd: -)
PYTHON=$(PATH="$path_no_asdf" type -P python3 2>/dev/null || true)
[ -x "$PYTHON" ] || PYTHON="$(ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}" asdf which python3 2>/dev/null || true)"
[ -x "$PYTHON" ] || { echo "missing python3" >&2; exit 1; }
"$PYTHON" - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import importlib.util, json, os, pathlib, subprocess, sys, tempfile, unittest
from unittest import mock
root = pathlib.Path(sys.argv[1])
def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, root / filename)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module
agy = load('agy_signin', 'agy-signin.py')
watch = load('fleet_watch', 'fleet-watch.py')
fixtures = root / 'tests' / 'fixtures' / 'agy'
SIGN_IN = (fixtures / 'signin-screen.txt').read_text()
WORKING = (fixtures / 'working-screen.txt').read_text()
HOUR = 3600

class Matcher(unittest.TestCase):
    def test_sign_in_screen_matches(self):
        self.assertTrue(agy.is_sign_in_screen(SIGN_IN))

    def test_orca_terminal_read_document_matches(self):
        doc = json.dumps({'ok': True, 'result': {'terminal': {'tail': SIGN_IN.splitlines()}}})
        self.assertTrue(agy.is_sign_in_screen(doc))

    def test_working_screen_does_not_match(self):
        self.assertFalse(agy.is_sign_in_screen(WORKING))

    def test_empty_screen_does_not_match(self):
        self.assertFalse(agy.is_sign_in_screen(''))

    def test_each_phrase_matches_on_its_own(self):
        for line in ('not signed in', 'Please sign in to continue', 'Authentication failed', 'authentication required'):
            self.assertTrue(agy.is_sign_in_screen(line), line)

class Record(unittest.TestCase):
    def setUp(self):
        self.path = pathlib.Path(tempfile.mkdtemp()) / 'agy-unavailable.json'

    def test_mark_blocks_six_hours_then_expires(self):
        self.assertFalse(agy.is_unavailable('hostb', 1000, self.path))
        agy.mark('hostb', 1000, self.path)
        self.assertTrue(agy.is_unavailable('HostB', 1000 + 6 * HOUR - 1, self.path))
        self.assertFalse(agy.is_unavailable('hostb', 1000 + 6 * HOUR + 1, self.path))

    def test_one_notice_per_host_per_six_hours(self):
        self.assertTrue(agy.mark('hostb', 1000, self.path))
        self.assertFalse(agy.mark('hostb', 1000 + HOUR, self.path))
        self.assertFalse(agy.mark('hostb', 1000 + 6 * HOUR - 1, self.path))
        self.assertTrue(agy.mark('hostb', 1000 + 6 * HOUR + 1, self.path))
        self.assertTrue(agy.mark('hostc', 1000 + HOUR, self.path))

def worker(dispatch, terminal, agent='antigravity', host=None, state=None):
    row = {'dispatchId': dispatch, 'terminal': terminal, 'agent': agent, 'dispatchStatus': 'dispatched',
           'projection': {'outcome': 'in_progress'}}
    if host:
        row['projection']['host'] = {'id': host}
        row['server'] = {'name': host}
    if state:
        row['state'] = state
    return row

class Pass(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        patcher = mock.patch.dict(os.environ, {'AGY_UNAVAILABLE_STATE': str(pathlib.Path(self.tmp) / 'agy-unavailable.json')})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.config = {'local_host': 'hosta'}
        self.stopped = []

    def sweep(self, workers, screens, now):
        return watch.agy_signin_notices(self.config, workers, read=lambda term, host: screens[term], now=now,
                                        stop=lambda dispatch, host: self.stopped.append((dispatch, host)))

    def test_signed_out_workers_are_stopped_and_the_host_marked_in_the_same_pass(self):
        # 1820: fleet-watch starts skip the 60 s screen wait, so this sweep stops every signed out worker.
        workers = [worker('d1', 't1', host='hostb'), worker('d2', 't2', host='hostb'), worker('d3', 't3', host='hostc'),
                   worker('d4', 't4')]
        notices = self.sweep(workers, {'t1': SIGN_IN, 't2': SIGN_IN, 't3': WORKING, 't4': SIGN_IN}, 1000)
        self.assertEqual(self.stopped, [('d1', 'hostb'), ('d2', 'hostb'), ('d4', '')])
        self.assertTrue(agy.is_unavailable('hostb', 1000))
        self.assertTrue(agy.is_unavailable('hosta', 1000))
        self.assertFalse(agy.is_unavailable('hostc', 1000))
        self.assertEqual(len(notices), 2)

    def test_a_remote_row_without_a_terminal_is_read_through_worker_show(self):
        # 1820 review: a remote server record row carries no terminal handle.
        row = worker('d1', '', host='hostb')
        shown = []
        notices = watch.agy_signin_notices(
            self.config, [row], read=lambda term, host: SIGN_IN if term == 't9' else WORKING, now=1000,
            stop=lambda dispatch, host: self.stopped.append((dispatch, host)),
            show=lambda dispatch, host: shown.append((dispatch, host)) or {'worker': {'terminal': 't9'}})
        self.assertEqual(shown, [('d1', 'hostb')])
        self.assertEqual(self.stopped, [('d1', 'hostb')])
        self.assertTrue(agy.is_unavailable('hostb', 1000))
        self.assertEqual(len(notices), 1)

    def test_a_failed_stop_still_marks_the_host(self):
        def stop(_dispatch, _host):
            raise OSError('orca down')
        notices = watch.agy_signin_notices(self.config, [worker('d1', 't1', host='hostb')],
                                           read=lambda term, host: SIGN_IN, now=1000, stop=stop)
        self.assertEqual(len(notices), 1)
        self.assertTrue(agy.is_unavailable('hostb', 1000))

    def test_signed_out_worker_marks_host_and_notifies_once(self):
        workers = [worker('d1', 't1', host='hostb'), worker('d2', 't2', host='hostb')]
        screens = {'t1': SIGN_IN, 't2': SIGN_IN}
        first = self.sweep(workers, screens, 1000)
        self.assertEqual(len(first), 1)
        self.assertIsInstance(first[0], watch.Urgent)
        self.assertIn('sign in to agy on hostb', first[0])
        self.assertTrue(agy.is_unavailable('hostb', 1000 + HOUR))
        self.assertEqual(self.sweep(workers, screens, 1000 + 5 * 60), [])
        self.assertEqual(len(self.sweep(workers, screens, 1000 + 6 * HOUR + 1)), 1)

    def test_working_worker_and_other_agents_are_left_alone(self):
        workers = [worker('d1', 't1', host='hostb'), worker('d2', 't2', agent='claude', host='hostc')]
        self.assertEqual(self.sweep(workers, {'t1': WORKING, 't2': SIGN_IN}, 1000), [])
        self.assertFalse(agy.is_unavailable('hostb'))
        self.assertFalse(agy.is_unavailable('hostc'))

    def test_settled_worker_is_not_read(self):
        workers = [worker('d1', 't1', host='hostb', state='succeeded')]
        self.assertEqual(self.sweep(workers, {'t1': SIGN_IN}, 1000), [])

    def test_two_hosts_get_one_notice_each(self):
        workers = [worker('d1', 't1', host='hostb'), worker('d2', 't2', host='hostc')]
        notices = self.sweep(workers, {'t1': SIGN_IN, 't2': SIGN_IN}, 1000)
        self.assertEqual(len(notices), 2)

class Cli(unittest.TestCase):
    """The command line: help, mistyped commands, and the exit codes callers read."""
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state = pathlib.Path(self.tmp) / 'agy-unavailable.json'
        self.env = dict(os.environ, AGY_UNAVAILABLE_STATE=str(self.state))

    def cli(self, *args, stdin=''):
        return subprocess.run([sys.executable, str(root / 'agy-signin.py'), *args],
                              input=stdin, capture_output=True, text=True, env=self.env, timeout=30)

    def test_help_prints_the_docstring_on_stdout_and_exits_zero(self):
        for args in (('-h',), ('--help',), ('mark', '--help')):
            proc = self.cli(*args)
            self.assertEqual(proc.returncode, 0, args)
            self.assertIn('agy-signin.py match', proc.stdout, args)
            self.assertEqual(proc.stderr, '', args)
        self.assertFalse(self.state.exists())

    def test_mistyped_or_incomplete_commands_print_the_docstring_on_stderr_and_exit_two(self):
        for args in ((), ('bogus',), ('unavailable',), ('mark',)):
            proc = self.cli(*args)
            self.assertEqual(proc.returncode, 2, args)
            self.assertIn('agy-signin.py match', proc.stderr, args)
            self.assertEqual(proc.stdout, '', args)

    def test_match_exit_codes(self):
        self.assertEqual(self.cli('match', stdin=SIGN_IN).returncode, 0)
        self.assertEqual(self.cli('match', stdin=WORKING).returncode, 1)

    def test_mark_then_unavailable_round_trip(self):
        self.assertEqual(self.cli('unavailable', 'hostb').returncode, 1)
        first = self.cli('mark', 'hostb')
        self.assertEqual((first.returncode, first.stdout.strip()), (0, 'notify'))
        self.assertEqual(self.cli('mark', 'hostb').stdout.strip(), 'known')
        self.assertEqual(self.cli('unavailable', 'hostb').returncode, 0)
        self.assertEqual(self.cli('unavailable', 'hostc').returncode, 1)

unittest.main(argv=['agy-signin'], verbosity=1)
PY
