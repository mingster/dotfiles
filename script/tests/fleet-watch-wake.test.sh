#!/usr/bin/env bash
# #970: the coordinator waits up to 60 minutes per waiter, so fleet-watch must not alarm on a live waiter,
# must still alarm on a dead one after 10 minutes, and must reach the run terminal as inbox mail (which wakes `check --wait`).
set -euo pipefail
path_no_asdf=$(printf '%s\n' "${PATH//:/$'\n'}" | grep -v '/\.asdf/shims$' | paste -sd: -)
PYTHON=$(PATH="$path_no_asdf" type -P python3 2>/dev/null || true)
[ -x "$PYTHON" ] || PYTHON="$(ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}" asdf which python3 2>/dev/null || true)"
[ -x "$PYTHON" ] || { echo "missing python3" >&2; exit 1; }
"$PYTHON" - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import importlib.util, pathlib, sys, unittest
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('fleet_watch', root/'fleet-watch.py')
watch = importlib.util.module_from_spec(spec); spec.loader.exec_module(watch)

CONFIG = {'runs': [{'id': 'r1', 'terminal': 'term_coord', 'waiter_pattern': 'w1'}]}
UNREAD = [{'run_id': 'r1', 'read': 0}]
MINUTE = 60

class LongWaiter(unittest.TestCase):
    def test_live_waiter_with_unread_mail_never_alarms_across_a_60_minute_wait(self):
        state = {}
        for minutes in range(0, 121, 5):
            self.assertEqual(watch.alerts(CONFIG, state, minutes * MINUTE, UNREAD, [], {'r1': True}), [])
        self.assertNotIn('r1', state)

    def test_dead_waiter_alarms_once_at_10_minutes(self):
        state = {}
        self.assertEqual(watch.alerts(CONFIG, state, 0, UNREAD, [], {'r1': False}), [])
        self.assertEqual(watch.alerts(CONFIG, state, 9 * MINUTE, UNREAD, [], {'r1': False}), [])
        notices = watch.alerts(CONFIG, state, 10 * MINUTE, UNREAD, [], {'r1': False})
        self.assertEqual(len(notices), 1)
        self.assertIn('inbox waiter absent', notices[0])
        self.assertEqual(watch.alerts(CONFIG, state, 40 * MINUTE, UNREAD, [], {'r1': False}), [])

class WakePath(unittest.TestCase):
    def deliver(self, notice, state, now):
        calls = []
        watch.deliver_notices(CONFIG, state, [notice], lambda *a: calls.append(a) or {}, now=now, owner_of=lambda author: None)
        return [(c[c.index('--to') + 1], c[c.index('--body') + 1]) for c in calls if c[:2] == ('orchestration', 'send')]

    def test_urgent_notice_reaches_the_coordinator_inbox_at_once(self):
        got = self.deliver(watch.Urgent('failed dispatch d1'), {'notice_sent_at': {'term_coord': 100}}, 101)
        self.assertEqual(got, [('term_coord', 'failed dispatch d1')])

    def test_ordinary_notice_reaches_the_inbox_within_one_digest_interval(self):
        state = {}
        self.assertEqual(self.deliver('ship dotfiles #1 abc', state, 1000), [('term_coord', 'ship dotfiles #1 abc')])
        self.assertEqual(self.deliver('rework dotfiles #2 def', state, 1000 + 599), [])
        self.assertEqual(self.deliver('rework dotfiles #3 123', state, 1000 + 600)[0][0], 'term_coord')
        self.assertLessEqual(watch.DIGEST_SECONDS, 10 * MINUTE)

if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
