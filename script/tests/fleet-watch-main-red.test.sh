#!/usr/bin/env bash
# A red Checks run on main reaches the coordinator once per run id; no live Orca or gh.
set -euo pipefail
path_no_asdf=$(printf '%s\n' "${PATH//:/$'\n'}" | grep -v '/\.asdf/shims$' | paste -sd: -)
PYTHON=$(PATH="$path_no_asdf" type -P python3 2>/dev/null || true)
[ -x "$PYTHON" ] || PYTHON="$(ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}" asdf which python3 2>/dev/null || true)"
[ -x "$PYTHON" ] || { echo "missing python3" >&2; exit 1; }
# #1737: a stub gh heads PATH and logs every call. Any call fails the test, so a fixture can never reach the real gh.
GUARD_DIR=$(mktemp -d)
trap 'rm -rf "$GUARD_DIR"' EXIT
# Keep fixture lines out of ~/.orca/logs/fleet-watch.log (#1864).
if [ -z "$(printf %s "${FLEET_WATCH_LOG_PATH:-}" | tr -d '[:space:]')" ]; then
  FLEET_WATCH_LOG_PATH="$GUARD_DIR/fleet-watch-test.log"
  export FLEET_WATCH_LOG_PATH
fi
printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$GH_GUARD_LOG"' 'exit 99' > "$GUARD_DIR/gh"
chmod +x "$GUARD_DIR/gh"
: > "$GUARD_DIR/calls.log"
export GH_GUARD_LOG="$GUARD_DIR/calls.log"
export PATH="$GUARD_DIR:$PATH"
"$PYTHON" - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import importlib.util
import os
import pathlib
import sys
import types
import unittest

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('fleet_watch', root / 'fleet-watch.py')
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)

IO = dict(find_issue=lambda r, t: 1, create_issue=lambda r, t, b: 1, failing_step=lambda r, i: "")
CONFIG = {'pr_watch': {'repos': ['owner/repo']}}


def red(run_id):
    return {'databaseId': run_id, 'conclusion': 'failure', 'url': 'https://github.com/owner/repo/actions/runs/%s' % run_id}


GUARD_LOG = pathlib.Path(os.environ['GH_GUARD_LOG'])


class GhGuard(unittest.TestCase):
    """No test here may reach gh. The stub on PATH logs the call; this fails the test that made it."""

    def setUp(self):
        GUARD_LOG.write_text('')

    def tearDown(self):
        self.assertEqual(GUARD_LOG.read_text(), '', 'a test called gh')


class MainRed(GhGuard):
    def test_red_main_is_reported_once_per_run_id(self):
        state = {}
        first = watch.main_red_notices(CONFIG, state, 0, fetch=lambda repo: red(7), **IO)
        self.assertEqual(len(first), 1)
        self.assertIn('https://github.com/owner/repo/actions/runs/7', first[0])
        self.assertIsInstance(first[0], watch.Urgent)
        self.assertEqual(watch.main_red_notices(CONFIG, state, 60, fetch=lambda repo: red(7), **IO), [])
        self.assertEqual(len(watch.main_red_notices(CONFIG, state, 120, fetch=lambda repo: red(8), **IO)), 1)

    def test_green_main_is_silent_and_a_failed_fetch_keeps_state(self):
        state = {}
        green = {'databaseId': 9, 'conclusion': 'success', 'url': 'u'}
        self.assertEqual(watch.main_red_notices(CONFIG, state, 0, fetch=lambda repo: green, **IO), [])
        watch.main_red_notices(CONFIG, state, 0, fetch=lambda repo: red(7), **IO)
        self.assertEqual(watch.main_red_notices(CONFIG, state, 0, fetch=lambda repo: None, **IO), [])
        self.assertEqual(watch.main_red_notices(CONFIG, state, 0, fetch=lambda repo: red(7), **IO), [])

    def test_lookup_is_limited_to_push_events(self):
        seen = []

        def fake_run(command, **kwargs):
            seen.append(command)
            return types.SimpleNamespace(stdout='[]')

        original = watch.subprocess.run
        watch.subprocess.run = fake_run
        try:
            watch.fetch_main_checks_run('owner/repo')
        finally:
            watch.subprocess.run = original
        command = seen[0]
        self.assertEqual(command[command.index('--event') + 1], 'push')


class MainRedFixer(GhGuard):
    """#1677: a new red run id files or reuses one P1 issue and puts it ahead of the issue queue."""

    def fakes(self, existing=None):
        calls = {'create': [], 'find': [], 'step': []}

        def find(repo, title):
            calls['find'].append(title)
            return existing

        def create(repo, title, body):
            calls['create'].append((repo, title, body))
            return 501

        def step(repo, run_id):
            calls['step'].append(run_id)
            return 'script-tests / run tests'

        return calls, dict(find_issue=find, create_issue=create, failing_step=step)

    def test_first_detect_files_one_p1_issue_with_the_failing_step(self):
        calls, io = self.fakes()
        state = {}
        notices = watch.main_red_notices(CONFIG, state, 0, fetch=lambda repo: red(7), **io)
        self.assertEqual(len(calls['create']), 1)
        repo, title, body = calls['create'][0]
        self.assertEqual((repo, title), ('owner/repo', 'main red: 7'))
        self.assertIn('script-tests / run tests', body)
        self.assertIn('Fixes main: 7', body)
        self.assertIn('## Acceptance', body)
        self.assertTrue(watch.issue_scan_has_acceptance(body))
        self.assertTrue(any('#501' in str(n) for n in notices))

    def test_the_issue_body_passes_the_brief_lint_the_issue_scan_runs(self):
        import tempfile
        body = watch.main_red_issue_body('7', 'https://example.test/runs/7', 'script-tests / run tests')
        with tempfile.NamedTemporaryFile('w', suffix='.md') as spec:
            spec.write('Refs owner/repo#9\n\n%s\n\n## Verify\nbash script/checks-local.sh\n\n## Finish\ndone\n' % body)
            spec.flush()
            self.assertEqual(watch.brief_lint_missing(spec.name), [])

    def test_repeat_detect_makes_no_second_issue(self):
        calls, io = self.fakes()
        state = {}
        watch.main_red_notices(CONFIG, state, 0, fetch=lambda repo: red(7), **io)
        watch.main_red_notices(CONFIG, state, 60, fetch=lambda repo: red(7), **io)
        self.assertEqual(len(calls['create']), 1)
        self.assertEqual(calls['step'], ['7'])

    def test_green_then_a_new_red_id_files_a_new_issue(self):
        calls, io = self.fakes()
        state = {}
        green = {'databaseId': 9, 'conclusion': 'success', 'url': 'u'}
        watch.main_red_notices(CONFIG, state, 0, fetch=lambda repo: red(7), **io)
        watch.main_red_notices(CONFIG, state, 60, fetch=lambda repo: green, **io)
        self.assertEqual(len(calls['create']), 1)
        watch.main_red_notices(CONFIG, state, 120, fetch=lambda repo: red(8), **io)
        self.assertEqual([c[1] for c in calls['create']], ['main red: 7', 'main red: 8'])

    def test_a_run_url_off_github_files_nothing_and_looks_nothing_up(self):
        calls, io = self.fakes()
        for url in ('https://example.test/runs/7', 'https://github.com.evil.test/runs/7',
                    'https://evil.test/github.com/runs/7', '', None):
            run = dict(red(7), url=url)
            notices = watch.main_red_notices(CONFIG, {}, 0, fetch=lambda repo: run, **io)
            self.assertEqual(len(notices), 1, url)
            self.assertIn('fixer issue not filed', notices[0], url)
        self.assertEqual((calls['create'], calls['find'], calls['step']), ([], [], []))

    def test_a_github_run_url_still_files(self):
        calls, io = self.fakes()
        watch.main_red_notices(CONFIG, {}, 0, fetch=lambda repo: red(7), **io)
        self.assertEqual(len(calls['create']), 1)

    def test_the_gh_guard_catches_a_real_call(self):
        watch.subprocess.run(['gh', 'issue', 'create'], capture_output=True)
        self.assertIn('issue create', GUARD_LOG.read_text())
        GUARD_LOG.write_text('')

    def test_an_open_issue_with_the_title_is_reused(self):
        calls, io = self.fakes(existing=77)
        watch.main_red_notices(CONFIG, {}, 0, fetch=lambda repo: red(7), **io)
        self.assertEqual(calls['create'], [])

    def test_a_failed_issue_create_retries_on_the_next_pass(self):
        made = []
        io = dict(find_issue=lambda r, t: None, failing_step=lambda r, i: 'step',
                  create_issue=lambda r, t, b: (made.append(t), None)[1])
        state = {}
        watch.main_red_notices(CONFIG, state, 0, fetch=lambda repo: red(7), **io)
        watch.main_red_notices(CONFIG, state, 60, fetch=lambda repo: red(7), **io)
        self.assertEqual(len(made), 2)

    def test_main_red_issue_sorts_ahead_of_every_other_issue(self):
        def row(repo, number, title, labels):
            return repo, {'number': number, 'title': title, 'labels': [{'name': n} for n in labels],
                          'createdAt': '2026-01-01T00:00:00Z'}
        queue = [row('mingster/dotfiles', 1, 'plain P0', ['P0']),
                 row('owner/app', 2, 'main red: 7', ['P1'])]
        queue.sort(key=lambda pair: watch.issue_scan_queue_key(*pair))
        self.assertEqual(queue[0][1]['number'], 2)


if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
