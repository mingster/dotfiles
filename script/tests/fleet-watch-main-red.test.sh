#!/usr/bin/env bash
# A red Checks run on main reaches the coordinator once per run id; no live Orca or gh.
set -euo pipefail
path_no_asdf=$(printf '%s\n' "${PATH//:/$'\n'}" | grep -v '/\.asdf/shims$' | paste -sd: -)
PYTHON=$(PATH="$path_no_asdf" type -P python3 2>/dev/null || true)
[ -x "$PYTHON" ] || PYTHON="$(ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}" asdf which python3 2>/dev/null || true)"
[ -x "$PYTHON" ] || { echo "missing python3" >&2; exit 1; }
"$PYTHON" - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import importlib.util
import pathlib
import sys
import unittest

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('fleet_watch', root / 'fleet-watch.py')
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)

CONFIG = {'pr_watch': {'repos': ['owner/repo']}}


def red(run_id):
    return {'databaseId': run_id, 'conclusion': 'failure', 'url': 'https://example.test/runs/%s' % run_id}


class MainRed(unittest.TestCase):
    def test_red_main_is_reported_once_per_run_id(self):
        state = {}
        first = watch.main_red_notices(CONFIG, state, 0, fetch=lambda repo: red(7))
        self.assertEqual(len(first), 1)
        self.assertIn('https://example.test/runs/7', first[0])
        self.assertIsInstance(first[0], watch.Urgent)
        self.assertEqual(watch.main_red_notices(CONFIG, state, 60, fetch=lambda repo: red(7)), [])
        self.assertEqual(len(watch.main_red_notices(CONFIG, state, 120, fetch=lambda repo: red(8))), 1)

    def test_green_main_is_silent_and_a_failed_fetch_keeps_state(self):
        state = {}
        green = {'databaseId': 9, 'conclusion': 'success', 'url': 'u'}
        self.assertEqual(watch.main_red_notices(CONFIG, state, 0, fetch=lambda repo: green), [])
        watch.main_red_notices(CONFIG, state, 0, fetch=lambda repo: red(7))
        self.assertEqual(watch.main_red_notices(CONFIG, state, 0, fetch=lambda repo: None), [])
        self.assertEqual(watch.main_red_notices(CONFIG, state, 0, fetch=lambda repo: red(7)), [])


if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
