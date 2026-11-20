#!/usr/bin/env bash
# #1240: the agy sign-in matcher, the 6 hour host record, and the fleet-watch pass that uses them.
set -euo pipefail
path_no_asdf=$(printf '%s\n' "${PATH//:/$'\n'}" | grep -v '/\.asdf/shims$' | paste -sd: -)
PYTHON=$(PATH="$path_no_asdf" type -P python3 2>/dev/null || true)
[ -x "$PYTHON" ] || PYTHON="$(ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}" asdf which python3 2>/dev/null || true)"
[ -x "$PYTHON" ] || { echo "missing python3" >&2; exit 1; }
"$PYTHON" - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import importlib.util, json, os, pathlib, sys, tempfile, unittest
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
        return watch.agy_signin_notices(self.config, workers, read=lambda term, host: screens[term], now=now)

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

unittest.main(argv=['agy-signin'], verbosity=1)
PY
