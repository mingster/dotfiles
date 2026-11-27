#!/usr/bin/env bash
# #1240: the agy sign-in matcher, the 6 hour host record, and the fleet-watch pass that uses them.
set -euo pipefail
path_no_asdf=$(printf '%s\n' "${PATH//:/$'\n'}" | grep -v '/\.asdf/shims$' | paste -sd: -)
PYTHON=$(PATH="$path_no_asdf" type -P python3 2>/dev/null || true)
[ -x "$PYTHON" ] || PYTHON="$(ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}" asdf which python3 2>/dev/null || true)"
[ -x "$PYTHON" ] || { echo "missing python3" >&2; exit 1; }
log_tmp=$(mktemp -d)
trap 'rm -rf "$log_tmp"' EXIT
export FLEET_WATCH_LOG_PATH="$log_tmp/fleet-watch-test.log"
export FLEET_WATCH_CONFIG="$log_tmp/no-fleet-config.json"
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

    def sweep(self, workers, screens, now):
        return watch.agy_signin_notices(self.config, workers, read=lambda term, host: screens[term], now=now,
                                        env_names=getattr(self, 'env_names', {}))

    def test_signed_out_worker_marks_host_and_notifies_once(self):
        workers = [worker('d1', 't1', host='hostb'), worker('d2', 't2', host='hostb')]
        screens = {'t1': SIGN_IN, 't2': SIGN_IN}
        first = self.sweep(workers, screens, 1000)
        self.assertEqual(len(first), 1)
        self.assertIsInstance(first[0], watch.Urgent)
        self.assertIn('script/agy-signin-host.sh hostb (not over ssh)', first[0])
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

    def test_a_remote_row_marks_the_host_name_not_the_environment_id(self):
        # #1967: the mark key is the host name placement reads.
        self.env_names = {'e5cb-env-id': 'hostb'}
        self.config = {'local_host': 'hosta', 'host_caps': {'hosta': 2, 'hostb': 2}}
        notices = self.sweep([worker('d1', 't1', host='e5cb-env-id')], {'t1': SIGN_IN}, 1000)
        self.assertEqual(len(notices), 1)
        self.assertIn('host=hostb', notices[0])
        self.assertFalse(agy.usable('antigravity', 'hostb', config=self.config, now=1001))
        self.assertTrue(agy.usable('antigravity', 'e5cb-env-id', config=self.config, now=1001))

class Wrapped(unittest.TestCase):
    def test_narrow_pane_wrapped_screen_matches(self):
        self.assertTrue(agy.is_sign_in_screen((fixtures / 'signin-screen-wrapped.txt').read_text()))

class ProbeAndClear(unittest.TestCase):
    def test_probe_result_reads_agy_models(self):
        self.assertEqual(agy.probe_result('Please sign in to view available models'), 'out')
        self.assertEqual(agy.probe_result('gemini-4-pro-high    Gemini 4 Pro (High)'), 'in')
        self.assertEqual(agy.probe_result(json.dumps({'error': 'timeout'})), '')

    def test_clear_drops_only_that_host(self):
        path = pathlib.Path(tempfile.mkdtemp()) / 'marks.json'
        agy.mark('hostb', now=0, path=path, config={})
        agy.mark('hostc', now=0, path=path, config={})
        self.assertTrue(agy.clear('HostB', path=path, config={}))
        self.assertFalse(agy.clear('hostb', path=path, config={}))
        self.assertEqual(list(json.loads(path.read_text())), ['hostc'])

FAKE_ORCA = r"""#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
case "$1 $2" in
  "worktree list") echo '{"result":{"worktrees":[{"path":"/w/main","isMainWorktree":true}]}}' ;;
  "terminal create") case "$*" in *agy-signin-probe*) echo '{"result":{"terminal":{"handle":"term_probe"}}}' ;;
                                  *) echo '{"result":{"terminal":{"handle":"term_signin"}}}' ;; esac ;;
  "terminal read") echo "{\"result\":{\"terminal\":{\"screen\":\"$FAKE_SCREEN\"}}}" ;;
  *) echo '{"result":{}}' ;;
esac
"""

class HostScript(unittest.TestCase):
    """#1967: agy-signin-host.sh signs in through an Orca terminal on the host, never ssh."""
    def run_script(self, screen):
        tmp = pathlib.Path(tempfile.mkdtemp())
        for name, body in (('orca', FAKE_ORCA), ('ssh', '#!/bin/sh\necho ssh "$@" >> "$FAKE_LOG"; exit 9\n')):
            (tmp / name).write_text(body)
            (tmp / name).chmod(0o755)
        marks = tmp / 'marks.json'
        agy.mark('hostb', now=None, path=marks, config={})
        env = dict(os.environ, ORCA_CLI_COMMAND=str(tmp / 'orca'), FAKE_LOG=str(tmp / 'log'), FAKE_SCREEN=screen,
                   PATH='%s:%s' % (tmp, os.environ['PATH']), AGY_UNAVAILABLE_STATE=str(marks))
        done = subprocess.run(['bash', str(root / 'agy-signin-host.sh'), 'hostb'], env=env, capture_output=True,
                              text=True, timeout=30)
        return done, (tmp / 'log').read_text().splitlines(), json.loads(marks.read_text())

    def test_signed_in_probe_clears_the_mark_and_no_ssh_runs(self):
        done, calls, marks = self.run_script('gemini-4-pro-high    Gemini 4 Pro')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn('term_signin', done.stdout)
        self.assertFalse([c for c in calls if c.startswith('ssh')])
        creates = [c for c in calls if c.startswith('terminal create')]
        self.assertEqual(len(creates), 2)
        self.assertTrue(all('--environment hostb' in c for c in creates))
        self.assertIn('--title agy-signin ', creates[0])
        self.assertTrue(any(c.startswith('terminal close') and 'term_probe' in c for c in calls))
        self.assertEqual(marks, {})

    def test_signed_out_probe_keeps_the_mark(self):
        done, _calls, marks = self.run_script('Please sign in to view available models')
        self.assertEqual(done.returncode, 1)
        self.assertEqual(list(marks), ['hostb'])

class FakeHost:
    """Fake orca for one probe: worktree list, terminal create, wait, read, close. Records every call."""
    def __init__(self, screen='', wait_error=False):
        self.screen, self.wait_error, self.calls = screen, wait_error, []
    def __call__(self, *args):
        self.calls.append(args)
        if args[:2] == ('worktree', 'list'):
            return {'worktrees': [{'path': '/w/main', 'isMainWorktree': True}]}
        if args[:2] == ('terminal', 'create'):
            return {'terminal': {'handle': 'term_probe'}}
        if args[:2] == ('terminal', 'wait') and self.wait_error:
            raise watch.OrcaReadError('timeout')
        if args[:2] == ('terminal', 'read'):
            return self.screen
        return {}
    def closed(self):
        return [c for c in self.calls if c[:2] == ('terminal', 'close')]

class Probe(unittest.TestCase):
    """#1968: one agy models probe per pass marks a signed out host before a worker is wasted there."""
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        patcher = mock.patch.dict(os.environ, {'AGY_UNAVAILABLE_STATE': str(self.tmp / 'agy.json')})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.config = {'local_host': 'hosta', 'host_caps': {'hosta': 2, 'hostb': 2}}

    def probe_with(self, fake):
        return lambda host: watch.agy_probe(host, rpc_call=fake, local=watch._is_local_coordinator_host(host, self.config))

    def test_sign_in_line_marks_hostb_and_placement_skips_it(self):
        fake = FakeHost({'terminal': {'screen': 'Please sign in to view available models'}})
        state = {'agy_probe': {'hosta': {'at': 1000, 'result': 'in'}}}
        notices = watch.agy_probe_notices(self.config, state, 1000, probe=self.probe_with(fake))
        self.assertEqual(len(notices), 1)
        self.assertIn('host=hostb', notices[0])
        self.assertEqual(state['agy_probe']['hostb']['result'], 'out')
        self.assertTrue(all('hostb' in c for c in fake.calls))
        self.assertEqual(len(fake.closed()), 1)
        # pick --agent antigravity asks this same check (worker-placement.test.sh covers the pick itself).
        self.assertFalse(agy.usable('antigravity', 'hostb', self.config, now=1001))
        self.assertTrue(agy.usable('antigravity', 'hosta', self.config, now=1001))

    def test_no_answer_writes_no_cache_and_the_host_is_due_next_pass(self):
        for fake in (FakeHost({}), FakeHost({'terminal': {'tail': []}}), FakeHost(wait_error=True)):
            state = {'agy_probe': {'hosta': {'at': 1000, 'result': 'in'}}}
            self.assertEqual(watch.agy_probe_notices(self.config, state, 1000, probe=self.probe_with(fake)), [])
            self.assertNotIn('hostb', state['agy_probe'])
            self.assertEqual(len(fake.closed()), 1, 'closed on success and on a wait timeout')
        self.assertFalse((self.tmp / 'agy.json').exists())

    def test_a_failed_mark_writes_no_cache(self):
        state = {'agy_probe': {'hosta': {'at': 1000, 'result': 'in'}}}
        with mock.patch.object(watch._agy_signin(), 'mark', side_effect=OSError('disk full')):
            self.assertEqual(watch.agy_probe_notices(self.config, state, 1000, probe=lambda h: 'out'), [])
        self.assertNotIn('hostb', state['agy_probe'])

    def test_one_host_per_pass_longest_ago_first_each_every_30_minutes(self):
        seen = []
        probe = lambda h: seen.append(h) or 'in'
        state = {}
        for t in (0, 1, 2, 1801):
            watch.agy_probe_notices(self.config, state, t, probe=probe)
        self.assertEqual(seen, ['hosta', 'hostb', 'hosta'])

    def test_a_local_host_caps_key_probes_with_no_environment_flag(self):
        config = {'local_host': 'hosta', 'host_caps': {'local': 1}}
        fake = FakeHost({'terminal': {'screen': 'gemini-4-pro-high    Gemini 4 Pro'}})
        probe = lambda h: watch.agy_probe(h, rpc_call=fake, local=watch._is_local_coordinator_host(h, config))
        watch.agy_probe_notices(config, {}, 1000, probe=probe)
        self.assertTrue(fake.calls)
        self.assertFalse([c for c in fake.calls if '--environment' in c])

    def test_main_probes_before_the_first_phase_that_starts_a_worker(self):
        src = (root / 'fleet-watch.py').read_text()
        main = src[src.index('def _main('):]
        self.assertLess(main.index("run_phase('agy_probe'"), main.index("run_phase('idle_seat'"))
        self.assertLess(main.index("run_phase('idle_seat'"), main.index("run_phase('supply_first'"))

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

    def test_usable_cli_exit_codes(self):
        # 1966: antigravity on a marked host is 1, claude on the same host is 0.
        self.cli('mark', 'hostb')
        self.assertEqual(self.cli('usable', '--agent', 'antigravity', '--host', 'hostb').returncode, 1)
        self.assertEqual(self.cli('usable', '--agent', 'claude', '--host', 'hostb').returncode, 0)
        self.assertEqual(self.cli('usable', '--agent', 'antigravity', '--host', 'hostc').returncode, 0)
        self.assertEqual(self.cli('usable', '--agent', 'antigravity').returncode, 2)

    def test_usable_cli_reads_local_host_from_config(self):
        # 1966: a mark on local is found for the config local_host, and the other way round.
        config = pathlib.Path(self.tmp) / 'fleet.json'
        config.write_text(json.dumps({'local_host': 'HostA'}))
        self.env['FLEET_WATCH_CONFIG'] = str(config)
        self.cli('mark', 'local')
        self.assertEqual(self.cli('usable', '--agent', 'antigravity', '--host', 'hosta').returncode, 1)
        self.assertEqual(self.cli('usable', '--agent', 'antigravity', '--host', '', '--config', str(config)).returncode, 1)


class HostKey(unittest.TestCase):
    """1966: the key a mark writes is the key placement reads."""
    def setUp(self):
        self.path = pathlib.Path(tempfile.mkdtemp()) / 'agy-unavailable.json'

    def test_mark_written_mixed_case_is_found_lowercase(self):
        agy.mark('HostB', now=0, path=self.path)
        self.assertFalse(agy.usable('antigravity', 'hostb', config={}, now=1, path=self.path))
        self.assertTrue(agy.usable('claude', 'hostb', config={}, now=1, path=self.path))

    def test_local_names_map_to_config_local_host(self):
        config = {'local_host': 'HostA'}
        this = agy.socket.gethostname().split('.')[0]
        for name in ('', 'local', 'hosta', this):
            self.assertEqual(agy.host_key(name, config), 'hosta', name)
        self.assertEqual(agy.host_key('', {}), 'local')
        self.assertEqual(agy.host_key('HostC', config), 'hostc')
        agy.mark('local', now=0, path=self.path, config=config)
        self.assertFalse(agy.usable('antigravity', 'HostA', config=config, now=1, path=self.path))

unittest.main(argv=['agy-signin'], verbosity=1)
PY
