#!/usr/bin/env bash
# #1116: an idle worker with an unread orchestration message gets a terminal nudge, at most twice.
set -euo pipefail
path_no_asdf=$(printf '%s\n' "${PATH//:/$'\n'}" | grep -v '/\.asdf/shims$' | paste -sd: -)
PYTHON=$(PATH="$path_no_asdf" type -P python3 2>/dev/null || true)
[ -x "$PYTHON" ] || PYTHON="$(ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}" asdf which python3 2>/dev/null || true)"
[ -x "$PYTHON" ] || { echo "missing python3" >&2; exit 1; }
"$PYTHON" - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import importlib.util, pathlib, subprocess, sys, unittest
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('fleet_watch', root/'fleet-watch.py')
watch = importlib.util.module_from_spec(spec); spec.loader.exec_module(watch)

HANDLE = 'term_idle'
WORKER = {'dispatchId': 'ctx_1', 'dispatchStatus': 'dispatched', 'terminalState': 'active',
          'terminal': HANDLE, 'projection': {'outcome': 'in_progress'}}
MSG = {'id': 'msg_1', 'to': HANDLE, 'handled': False}

class Rec:
    def __init__(self, fail=None):
        self.calls, self.fail = [], fail
    def __call__(self, *args):
        self.calls.append(args)
        if self.fail:
            raise self.fail
        return {}

def run(state, now, rec, workers=(WORKER,), msgs=(MSG,), last=1):
    return watch.unread_nudge_pass(state, now, list(workers), {HANDLE: last}, list(msgs), rec)

class Nudge(unittest.TestCase):
    def test_one_nudge_at_5_minutes_a_second_at_10_then_none(self):
        state, rec = {}, Rec()
        run(state, 300, rec)
        self.assertEqual(rec.calls, [])
        run(state, 301, rec)
        self.assertEqual(rec.calls, [('terminal', 'send', '--terminal', HANDLE, '--text', watch.UNREAD_NUDGE_TEXT, '--enter')])
        run(state, 450, rec)
        self.assertEqual(len(rec.calls), 1)
        run(state, 601, rec)
        self.assertEqual(len(rec.calls), 2)
        run(state, 5000, rec)
        self.assertEqual(len(rec.calls), 2)

    def test_working_worker_is_never_nudged(self):
        rec = Rec()
        busy = dict(WORKER, projection={'outcome': 'in_progress', 'liveness': {'verdict': 'live'}})
        run({}, 9999, rec, workers=[busy])
        self.assertEqual(rec.calls, [])

    def test_recent_output_is_not_idle(self):
        rec = Rec()
        run({}, 400, rec, last=200)
        self.assertEqual(rec.calls, [])

    def test_no_unread_message_no_nudge(self):
        rec = Rec()
        run({}, 9999, rec, msgs=[dict(MSG, handled=True), dict(MSG, id='m2', to='term_other')])
        self.assertEqual(rec.calls, [])

    def test_not_writable_is_skipped_and_not_retried(self):
        err = RuntimeError('terminal_not_writable')
        state, rec = {}, Rec(fail=err)
        bits = run(state, 301, rec)
        self.assertEqual(bits, ['nudge_not_writable=' + HANDLE])
        run(state, 900, rec)
        run(state, 1500, rec)
        self.assertEqual(len(rec.calls), 1)

if __name__ == '__main__':
    unittest.main(argv=['x'])
PY
