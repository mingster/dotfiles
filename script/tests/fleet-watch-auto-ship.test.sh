#!/usr/bin/env bash
# The babysit fallback ships a PR whose Verdict PASS is at the head and 15 minutes old, once per head (#1679). Fakes only.
set -euo pipefail
path_no_asdf=$(printf '%s\n' "${PATH//:/$'\n'}" | grep -v '/\.asdf/shims$' | paste -sd: -)
PYTHON=$(PATH="$path_no_asdf" type -P python3 2>/dev/null || true)
[ -x "$PYTHON" ] || PYTHON="$(ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}" asdf which python3 2>/dev/null || true)"
[ -x "$PYTHON" ] || { echo "missing python3" >&2; exit 1; }
"$PYTHON" - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import importlib.util
import pathlib
import sys
import time
import unittest

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('fleet_watch', root / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

REPO = 'owner/app'
NOW = 1_700_000_000.0
HEAD = 'a' * 40
OLD = 'b' * 40


def stamp(seconds_ago):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(NOW - seconds_ago))


def pr(verdict_head, age):
    return {
        'number': 5, 'state': 'OPEN', 'isDraft': False, 'headRefOid': HEAD, 'headRefName': 'b-5',
        'mergeable': 'MERGEABLE', 'labels': [],
        'statusCheckRollup': [{'name': 'c', 'status': 'COMPLETED', 'conclusion': 'SUCCESS', 'isRequired': True}],
        'comments': [{'body': 'Verdict: PASS head=%s verifier=ctx_v author=ctx_a' % verdict_head, 'createdAt': stamp(age)}],
    }


CONFIG = {
    'issue_scan': {'enabled': True, 'repos': [REPO], 'run': 'r', 'from_terminal': 't', 'host': 'local',
                   'agent': 'cursor', 'model': 'm', 'repo_roots': {REPO: '/tmp/app'}},
    'host_caps': {'local': 4},
}


def scan(prs, state, code=0, reason=''):
    starts = []

    def start(command):
        starts.append(command)
        return fw.BabysitStartResult(code, reason)

    notices, log = fw.issue_scan_pass(
        CONFIG, state, NOW, [], list_issues=lambda _r: [], pr_fetch=lambda _r: prs,
        gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': 0, 'reason': 'ok'},
        start_worker=start, start_detached=lambda _c: fw.BabysitStartResult(0))
    starts = [c for c in starts if any(str(p).endswith('ship.sh') for p in c)]
    return starts, notices, log


class AutoShip(unittest.TestCase):
    def test_pass_at_head_ships_after_fifteen_minutes(self):
        starts, _n, log = scan([pr(HEAD, 16 * 60)], {})
        self.assertEqual(len(starts), 1)
        self.assertIn('ship_start=%s' % HEAD[:8], log)

    def test_a_real_verdict_line_with_agent_and_model_counts(self):
        row = pr(HEAD, 3600)
        row['comments'][0]['body'] += ' agent=claude model=claude-opus-5-5'
        starts, _n, _l = scan([row], {})
        self.assertEqual(len(starts), 1)
        self.assertEqual(fw.classify_open_pr(row), 'ready')

    def test_pass_younger_than_fifteen_minutes_waits_for_the_verifier(self):
        state = {}
        starts, _n, _l = scan([pr(HEAD, 5 * 60)], state)
        self.assertEqual(starts, [])
        starts, _n, _l = scan([pr(HEAD, 16 * 60)], state)
        self.assertEqual(len(starts), 1)

    def test_pass_at_an_old_head_does_not_ship(self):
        starts, _n, _l = scan([pr(OLD, 3600)], {})
        self.assertEqual(starts, [])

    def test_ships_once_per_head(self):
        state = {}
        scan([pr(HEAD, 3600)], state)
        starts, _n, _l = scan([pr(HEAD, 3600)], state)
        self.assertEqual(starts, [])

    def test_refusal_is_reported_once_and_not_retried(self):
        state = {}
        _s, notices, _l = scan([pr(HEAD, 3600)], state, code=1, reason='ship: refused: Checks on main is red')
        self.assertEqual(sum('refused: Checks on main is red' in str(n) for n in notices), 1)
        starts, notices, _l = scan([pr(HEAD, 3600)], state, code=1, reason='ship: refused: Checks on main is red')
        self.assertEqual((starts, notices), ([], []))


if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
