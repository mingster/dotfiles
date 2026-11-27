"""Shared test env for fleet-watch main(); keeps pass logs off the real default path."""
import atexit
import os
import tempfile
from pathlib import Path
from unittest.mock import patch


def _isolate_default_log():
    """Point FLEET_WATCH_LOG_PATH at a temp file when unset or blank, so no test line reaches
    ~/.orca/logs/fleet-watch.log (#1864). Children and later imports inherit it."""
    if (os.environ.get('FLEET_WATCH_LOG_PATH') or '').strip():
        return
    tmp = tempfile.TemporaryDirectory(prefix='fleet-watch-test-log-')
    atexit.register(tmp.cleanup)
    os.environ['FLEET_WATCH_LOG_PATH'] = str(Path(tmp.name) / 'fleet-watch-test.log')


_isolate_default_log()

# gh verbs that change GitHub state. A test that reaches one of them through a real gh fails.
GH_WRITE_VERBS = frozenset({
    ('issue', 'create'), ('issue', 'edit'), ('issue', 'close'), ('issue', 'reopen'), ('issue', 'comment'),
    ('pr', 'create'), ('pr', 'edit'), ('pr', 'merge'), ('pr', 'comment'), ('pr', 'review'),
    ('pr', 'close'), ('pr', 'ready'), ('run', 'rerun'), ('run', 'cancel'),
    ('release', 'create'), ('label', 'create'),
})

_GH_STUB = """#!/bin/sh
echo "$1 $2" >> "$GH_STUB_LOG"
case "$1 $2" in
  %s)
    echo "gh stub: write refused in tests" >&2
    exit 97 ;;
esac
echo "gh stub: no network in tests" >&2
exit 1
"""


def guard_gh_writes(test):
    """For one test: put a gh stub first on PATH. It logs each call, refuses GH_WRITE_VERBS with exit 97,
    and fails any read. The test fails at cleanup when a write verb was logged."""
    tmp = tempfile.TemporaryDirectory()
    test.addCleanup(tmp.cleanup)
    bin_dir = Path(tmp.name) / 'bin'
    bin_dir.mkdir()
    patterns = '|'.join('"%s %s"' % verb for verb in sorted(GH_WRITE_VERBS))
    gh = bin_dir / 'gh'
    gh.write_text(_GH_STUB % patterns)
    gh.chmod(0o755)
    log = Path(tmp.name) / 'gh-calls.log'
    log.touch()
    patcher = patch.dict(os.environ, {
        'PATH': '%s%s%s' % (bin_dir, os.pathsep, os.environ.get('PATH', '')),
        'GH_STUB_LOG': str(log),
    })
    patcher.start()
    test.addCleanup(patcher.stop)

    def assert_no_writes():
        calls = [tuple(line.split()[:2]) for line in log.read_text().splitlines() if line.strip()]
        writes = ['gh %s' % ' '.join(call) for call in calls if call in GH_WRITE_VERBS]
        test.assertEqual(writes, [], 'test reached a real gh write')

    test.addCleanup(assert_no_writes)


def isolated_main_env(tmp_dir):
    """Set HOME and FLEET_WATCH_LOG_PATH under tmp_dir for fleet-watch main() tests."""
    p = Path(tmp_dir)
    log_path = p / 'fleet-watch-test.log'
    return patch.dict(os.environ, {'HOME': str(p), 'FLEET_WATCH_LOG_PATH': str(log_path)}, clear=False)


def redirect_main_log_under(dir_path):
    """Only FLEET_WATCH_LOG_PATH under dir_path; leaves HOME unchanged (for tests that depend on it)."""
    log_path = Path(dir_path) / 'fleet-watch-test.log'
    return patch.dict(os.environ, {'FLEET_WATCH_LOG_PATH': str(log_path)}, clear=False)



def quiet_host(test, fw):
    """For one test: stub the coordinator load and free memory reads, so admit() never sees the real host."""
    for name, value in (('coordinator_load_per_core', 0.1), ('coordinator_free_gb', 64.0)):
        patcher = patch.object(fw, name, return_value=value)
        patcher.start()
        test.addCleanup(patcher.stop)


# The printed live count comes from `check-fleet-status.py --count`, which reads the real fleet (#2022).
# `false` fails, so a test sees no real count and keeps the count of the worker rows it passes in.
os.environ.setdefault('FLEET_WATCH_REAL_COUNT_COMMAND', 'false')
