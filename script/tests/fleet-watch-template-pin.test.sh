#!/usr/bin/env bash
# fleet-watch reports a project whose .claude/agent-team-pin lags a template change by more than 24 h,
# and a red pin bump PR, once each (#1247). Real temp git repos; no live Orca or gh.
set -euo pipefail
path_no_asdf=$(printf '%s\n' "${PATH//:/$'\n'}" | grep -v '/\.asdf/shims$' | paste -sd: -)
PYTHON=$(PATH="$path_no_asdf" type -P python3 2>/dev/null || true)
[ -x "$PYTHON" ] || PYTHON="$(ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}" asdf which python3 2>/dev/null || true)"
[ -x "$PYTHON" ] || { echo "missing python3" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
gq() { git -c user.name=t -c user.email=t@example.invalid -C "$@"; }

# dotfiles: X (template), Y (template change, a day and a half later), Z (unrelated, later still).
DF="$TMP/dotfiles"
mkdir -p "$DF/templates/agent-team" "$DF/docs"
git init -q -b main "$DF"
echo one >"$DF/templates/agent-team/team.md"
gq "$DF" add -A && GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' gq "$DF" commit -qm X
X=$(git -C "$DF" rev-parse HEAD)
echo two >"$DF/templates/agent-team/team.md"
GIT_COMMITTER_DATE='2026-01-02T00:00:00Z' gq "$DF" commit -qam Y
Y=$(git -C "$DF" rev-parse HEAD)
echo notes >"$DF/docs/notes.md"
gq "$DF" add -A && GIT_COMMITTER_DATE='2026-01-03T00:00:00Z' gq "$DF" commit -qm Z
git -C "$DF" update-ref refs/remotes/origin/main HEAD
Y_AT=$(git -C "$DF" log -1 --format=%ct "$Y")

project() { # <dir> <pin or empty>
  mkdir -p "$1/.claude"
  git init -q -b main "$1"
  [ -z "$2" ] || printf '%s\n' "$2" >"$1/.claude/agent-team-pin"
  echo p >"$1/README.md"
  gq "$1" add -A && gq "$1" commit -qm p
  git -C "$1" update-ref refs/remotes/origin/main HEAD
}
project "$TMP/lagging" "$X"
project "$TMP/current" "$Y"
project "$TMP/unpinned" ""

"$PYTHON" - "$(cd "$(dirname "$0")/.." && pwd)" "$TMP" "$Y_AT" <<'PY'
import importlib.util
import json
import pathlib
import sys
import unittest

root, tmp, y_at = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
spec = importlib.util.spec_from_file_location('fleet_watch', root / 'fleet-watch.py')
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)

CONFIG = {'repo_roots': {'o/lagging': str(tmp / 'lagging'), 'o/current': str(tmp / 'current'),
                         'o/unpinned': str(tmp / 'unpinned')}}
DAY = 24 * 3600


def run(state, now, sync_state=None):
    return watch.template_pin_notices(CONFIG, state, now, dotfiles=str(tmp / 'dotfiles'),
                                      sync_state=sync_state or str(tmp / 'none.json'),
                                      origin_of=lambda p: 'o/' + pathlib.Path(p).name)


class TemplatePin(unittest.TestCase):
    def test_stale_pin_is_reported_once_after_24_hours(self):
        state = {}
        self.assertEqual(run(state, y_at + DAY - 60), [])
        first = run(state, y_at + DAY + 60)
        self.assertEqual(len(first), 1)
        self.assertIn('o/lagging', first[0])
        self.assertIn('lags the dotfiles template change', first[0])
        self.assertEqual(run(state, y_at + DAY + 120), [])

    def test_red_bump_pr_is_reported_once(self):
        sync = tmp / 'sync.json'
        sync.write_text(json.dumps({'o/current': {'state': 'red', 'pr': 42, 'sha': 'a' * 40},
                                    'o/unpinned': {'state': 'merged', 'pr': 7, 'sha': 'a' * 40}}))
        state = {}
        first = run(state, y_at, str(sync))
        self.assertEqual(first, ['o/current: template bump PR #42 for dotfiles aaaaaaaaaaaa is red; '
                                 'fix it, then rerun script/template-sync-pr.sh'])
        self.assertEqual(run(state, y_at + 60, str(sync)), [])


unittest.main(argv=['x'], verbosity=2)
PY
