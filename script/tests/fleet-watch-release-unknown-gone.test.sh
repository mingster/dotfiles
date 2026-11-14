#!/usr/bin/env bash
# A settled release_unknown row leaves the host cap only when the worker is proven gone.
set -euo pipefail
path_no_asdf=$(printf '%s\n' "${PATH//:/$'\n'}" | grep -v '/\.asdf/shims$' | paste -sd: -)
PYTHON=$(PATH="$path_no_asdf" type -P python3 2>/dev/null || true)
[ -x "$PYTHON" ] || PYTHON="$(ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}" asdf which python3 2>/dev/null || true)"
[ -x "$PYTHON" ] || { echo "missing python3" >&2; exit 1; }
"$PYTHON" - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import importlib.util, os, pathlib, shutil, subprocess, sys, tempfile, time, unittest
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('fleet_watch', root/'fleet-watch.py')
watch = importlib.util.module_from_spec(spec); spec.loader.exec_module(watch)
_spec_env = importlib.util.spec_from_file_location('fleet_watch_test_env', root/'tests'/'fleet_watch_test_env.py')
_fwe = importlib.util.module_from_spec(_spec_env); _spec_env.loader.exec_module(_fwe)
quiet_host = _fwe.quiet_host

def occupying(receipt):
    return {row['dispatchId'] for row in receipt['resources']}

def worker(dispatch, path, **kw):
    host = kw.pop('host', 'local')
    outcome = kw.pop('outcome', None)
    row = {
        'dispatchId': dispatch,
        'workerState': kw.pop('workerState', 'succeeded'),
        'dispatchStatus': kw.pop('dispatchStatus', 'completed'),
        'terminalState': kw.pop('terminalState', 'release_unknown'),
        'projection': {'host': {'id': host}, 'workspace': {'id': 'repo::' + path}},
    }
    if outcome is not None:
        row['projection']['outcome'] = outcome
    row.update(kw)
    return row

def git(path, *args):
    subprocess.check_call(['git', '-C', path, '-c', 'user.email=t@t', '-c', 'user.name=t', *args], stdout=subprocess.DEVNULL)

def make_clean(path):
    os.makedirs(path)
    git(path, 'init', '-q', '-b', 'main')
    with open(os.path.join(path, 'README'), 'w', encoding='utf-8') as handle:
        handle.write('x\n')
    git(path, 'add', 'README')
    git(path, 'commit', '-q', '-m', 'init')

def make_dirty(path):
    make_clean(path)
    with open(os.path.join(path, 'dirty.txt'), 'w', encoding='utf-8') as handle:
        handle.write('y\n')

def wait_until(predicate):
    deadline = time.time() + 2
    while time.time() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError('process was not visible')

HOLD = [sys.executable, '-c', 'import time; time.sleep(30)']

def command_of(pid):
    out = subprocess.run(['ps', '-p', str(pid), '-ww', '-o', 'command='], capture_output=True, text=True, timeout=5)
    return out.stdout or ''

def cwd_visible(pid, path):
    if sys.platform == 'darwin':
        out = subprocess.run(['lsof', '-n', '-P', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'], capture_output=True, text=True, timeout=5)
        return path in (out.stdout or '')
    link = '/proc/%s/cwd' % pid
    try:
        return os.readlink(link) == path
    except OSError:
        return False

class ReleaseUnknownGone(unittest.TestCase):
    def setUp(self):
        quiet_host(self, watch)
        self.tmp = tempfile.mkdtemp(prefix='fleet-gone-')
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.procs = []
        self.addCleanup(self.stop_procs)

    def stop_procs(self):
        for proc in self.procs:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=5)

    def spawn(self, args, cwd):
        proc = subprocess.Popen(args, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.procs.append(proc)
        return proc

    def admit(self, workers, cap=4, host='local'):
        return watch.admit(host, {'host_caps': {host: cap}}, workers)

    def test_gone_worker_is_cleared(self):
        removed = os.path.join(self.tmp, 'removed-worker')
        clean = os.path.join(self.tmp, 'clean-worker')
        live = os.path.join(self.tmp, 'live-worker')
        make_clean(clean)
        os.makedirs(live)
        sibling = self.spawn(HOLD + [removed + '-extra'], self.tmp)
        wait_until(lambda: removed + '-extra' in command_of(sibling.pid))
        workers = [
            worker('gone-removed', removed),
            worker('gone-clean', clean),
            worker('still-live', live, workerState='ready', dispatchStatus='running', terminalState='active', outcome='in_progress'),
        ]
        receipt = self.admit(workers, cap=4)
        self.assertEqual(receipt['cap'], 4)
        self.assertEqual(occupying(receipt), {'still-live'})
        self.assertEqual(receipt['occupied'], 1)
        self.assertTrue(receipt['admitted'])
        self.assertEqual(receipt['live_count'], 1)
        self.assertEqual(receipt['retained_count'], 0)

    def test_live_process_in_workspace_stays(self):
        named = os.path.join(self.tmp, 'named-worker')
        seated = os.path.join(self.tmp, 'cwd-worker')
        make_clean(seated)
        by_arg = self.spawn(HOLD + [named], self.tmp)
        by_cwd = self.spawn(HOLD, seated)
        wait_until(lambda: named in command_of(by_arg.pid))
        wait_until(lambda: cwd_visible(by_cwd.pid, seated))
        workers = [worker('by-arg', named), worker('by-cwd', seated)]
        receipt = self.admit(workers, cap=1)
        self.assertEqual(occupying(receipt), {'by-arg', 'by-cwd'})
        self.assertEqual(receipt['occupied'], 2)
        self.assertEqual(receipt['cap'], 1)
        self.assertFalse(receipt['admitted'])
        self.assertNotIn('release_unknown', receipt['reason'])

    def test_dirty_worktree_stays(self):
        dirty = os.path.join(self.tmp, 'dirty-worker')
        make_dirty(dirty)
        receipt = self.admit([worker('dirty', dirty)], cap=1)
        self.assertEqual(occupying(receipt), {'dirty'})
        self.assertEqual(receipt['occupied'], 1)
        self.assertEqual(receipt['retained_count'], 1)
        self.assertEqual(receipt['cap'], 1)
        self.assertFalse(receipt['admitted'])
        row = receipt['resources'][0]
        self.assertEqual(row['category'], 'retained')
        self.assertFalse(row['evidence']['released'])
        self.assertNotIn('release_unknown', receipt['reason'])

    def test_unsettled_row_stays(self):
        missing = os.path.join(self.tmp, 'unsettled-worker')
        running = worker('running', missing, workerState='ready', dispatchStatus='running', terminalState='release_unknown', outcome='in_progress')
        receipt = self.admit([running], cap=1)
        self.assertEqual(occupying(receipt), {'running'})
        self.assertEqual(receipt['occupied'], 1)
        self.assertEqual(receipt['live_count'], 1)
        self.assertFalse(receipt['admitted'])
        veto = worker('veto', os.path.join(self.tmp, 'veto-worker'), workerState='ready', dispatchStatus='release_unknown', terminalState='release_unknown', outcome='in_progress')
        vetoed = self.admit([veto], cap=4)
        self.assertEqual(occupying(vetoed), {'veto'})
        self.assertIn('release_unknown', vetoed['reason'])
        self.assertFalse(vetoed['admitted'])

    def test_remote_and_retained_rows_stay(self):
        missing = os.path.join(self.tmp, 'remote-worker')
        remote = worker('remote', missing, host='fleet-1')
        remote_receipt = self.admit([remote], cap=1, host='fleet-1')
        self.assertEqual(occupying(remote_receipt), {'remote'})
        self.assertEqual(remote_receipt['occupied'], 1)
        self.assertEqual(remote_receipt['cap'], 1)
        kept = os.path.join(self.tmp, 'retained-worker')
        gone = os.path.join(self.tmp, 'gone-beside-retained')
        retained = worker('retained', kept, terminalState='retained')
        cleared = worker('cleared', gone)
        both = self.admit([retained, cleared], cap=4)
        self.assertEqual(occupying(both), {'retained'})
        self.assertEqual(both['cap'], 4)
        self.assertEqual(both['occupied'], 1)
        self.assertEqual(both['retained_count'], 1)
        self.assertEqual(both['resources'][0]['evidence']['released'], False)

if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
