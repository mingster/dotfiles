#!/usr/bin/env bash
# fleet-watch starts template-sync-pr.sh for a pinned project that agent-team.sh check finds drifted (#1329).
# Real temp git repos; check and launch are stubs, so no live Orca, gh or agent-team.sh run.
set -euo pipefail
path_no_asdf=$(printf '%s\n' "${PATH//:/$'\n'}" | grep -v '/\.asdf/shims$' | paste -sd: -)
PYTHON=$(PATH="$path_no_asdf" type -P python3 2>/dev/null || true)
[ -x "$PYTHON" ] || PYTHON="$(ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}" asdf which python3 2>/dev/null || true)"
[ -x "$PYTHON" ] || { echo "missing python3" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Keep fixture lines out of ~/.orca/logs/fleet-watch.log (#1864).
if [ -z "$(printf %s "${FLEET_WATCH_LOG_PATH:-}" | tr -d '[:space:]')" ]; then
  FLEET_WATCH_LOG_PATH="$TMP/fleet-watch-test.log"
  export FLEET_WATCH_LOG_PATH
fi
gq() { git -c user.name=t -c user.email=t@example.invalid -C "$@"; }

DF="$TMP/dotfiles"
mkdir -p "$DF/templates/agent-team"
git init -q -b main "$DF"
echo one >"$DF/templates/agent-team/team.md"
gq "$DF" add -A && gq "$DF" commit -qm 'feat(team): change the template (#77)'
git -C "$DF" update-ref refs/remotes/origin/main HEAD

project() { # <dir> <pin or empty>
  mkdir -p "$1/.claude"
  git init -q -b main "$1"
  [ -z "$2" ] || printf '%s\n' "$2" >"$1/.claude/agent-team-pin"
  echo p >"$1/README.md"
  gq "$1" add -A && gq "$1" commit -qm p
  git -C "$1" update-ref refs/remotes/origin/main HEAD
}
project "$TMP/drifted" abc
project "$TMP/clean" abc
project "$TMP/unpinned" ""

"$PYTHON" - "$(cd "$(dirname "$0")/.." && pwd)" "$TMP" <<'PY'
import importlib.util
import pathlib
import subprocess
import sys
import unittest

root, tmp = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location('fleet_watch', root / 'fleet-watch.py')
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)

CONFIG = {'repo_roots': {n: str(tmp / n) for n in ('drifted', 'clean', 'unpinned')}}
HOUR = 3600


class Harness:
    def __init__(self):
        self.launched = []
        self.checked = []
        self.fail_launch = False

    def check(self, path):
        self.checked.append(pathlib.Path(path).name)
        return pathlib.Path(path).name != 'clean'

    def launch(self, path, verdict_from):
        if self.fail_launch:
            raise OSError('no bash')
        self.launched.append((pathlib.Path(path).name, verdict_from))

    def run(self, state, now):
        return watch.template_sync_reconcile(
            CONFIG, state, now, dotfiles=str(tmp / 'dotfiles'), check=self.check, launch=self.launch,
            origin_of=lambda p: 'o/dotfiles' if p.endswith('dotfiles') else 'o/' + pathlib.Path(p).name)


class TemplateSync(unittest.TestCase):
    def test_only_the_drifted_pinned_project_gets_a_sync_run(self):
        h = Harness()
        self.assertEqual(h.run({}, 1000), [])
        self.assertEqual(h.launched, [('drifted', 'o/dotfiles#77')])
        self.assertNotIn('unpinned', h.checked)

    def test_one_run_per_template_commit_until_the_retry_window(self):
        h, state = Harness(), {}
        h.run(state, 1000)
        h.run(state, 1000 + HOUR)
        self.assertEqual(len(h.launched), 1)
        h.run(state, 1000 + watch.TEMPLATE_SYNC_RETRY + 1)
        self.assertEqual(len(h.launched), 2)

    def test_a_clean_project_is_rechecked_only_after_the_recheck_window(self):
        # 1820: the check takes about 6 s; a clean result at the same template commit is reused.
        h, state = Harness(), {}
        h.run(state, 1000)
        h.run(state, 1000 + 300)
        self.assertEqual(h.checked.count('clean'), 1)
        h.run(state, 1000 + watch.TEMPLATE_SYNC_CLEAN_RECHECK)
        self.assertEqual(h.checked.count('clean'), 2)

    def test_a_failed_launch_is_reported_and_retried_next_pass_window(self):
        h = Harness()
        h.fail_launch = True
        notices = h.run({}, 1000)
        self.assertEqual(len(notices), 1)
        self.assertIn('o/drifted', notices[0])

    def test_an_unrelated_dotfiles_commit_does_not_start_another_run(self):
        other = tmp / 'dotfiles-unrelated'
        subprocess.run(['git', 'clone', '-q', str(tmp / 'dotfiles'), str(other)], check=True)
        g = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-C', str(other)]
        subprocess.run(['git', '-C', str(other), 'update-ref', 'refs/remotes/origin/main', 'HEAD'], check=True)
        h, state = Harness(), {}
        run = lambda now: watch.template_sync_reconcile(
            CONFIG, state, now, dotfiles=str(other), check=h.check, launch=h.launch,
            origin_of=lambda p: 'o/' + pathlib.Path(p).name)
        run(1000)
        (other / 'README.md').write_text('unrelated')
        subprocess.run(g + ['add', '-A'], check=True)
        subprocess.run(g + ['commit', '-qm', 'docs: unrelated (#78)'], check=True)
        subprocess.run(['git', '-C', str(other), 'update-ref', 'refs/remotes/origin/main', 'HEAD'], check=True)
        run(1000 + HOUR)
        self.assertEqual(len(h.launched), 1)

    def test_a_failed_launch_does_not_block_the_next_pass(self):
        h, state = Harness(), {}
        h.fail_launch = True
        h.run(state, 1000)
        h.fail_launch = False
        h.run(state, 1000 + 300)
        self.assertEqual(h.launched, [('drifted', 'o/dotfiles#77')])

    def test_the_check_reads_origin_main_not_the_checkout_on_disk(self):
        fake = tmp / 'fake-dotfiles'
        (fake / 'script').mkdir(parents=True)
        (fake / 'script' / 'agent-team.sh').write_text(
            '#!/usr/bin/env bash\n[ -f "${@: -1}/drift" ] && exit 1\nexit 0\n')
        git = lambda d, *a: subprocess.run(
            ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-C', str(d)] + list(a), check=True)
        merged = tmp / 'merged-bump'
        merged.mkdir()
        git(merged, 'init', '-q', '-b', 'main')
        (merged / 'a').write_text('a')
        git(merged, 'add', '-A')
        git(merged, 'commit', '-qm', 'clean')
        git(merged, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
        (merged / 'drift').write_text('stale checkout')
        self.assertFalse(watch._default_template_check(str(merged), str(fake)))
        stale = tmp / 'unmerged-bump'
        stale.mkdir()
        git(stale, 'init', '-q', '-b', 'main')
        (stale / 'drift').write_text('x')
        git(stale, 'add', '-A')
        git(stale, 'commit', '-qm', 'drifted')
        git(stale, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
        (stale / 'drift').unlink()
        self.assertTrue(watch._default_template_check(str(stale), str(fake)))

    def test_a_bare_log_filename_does_not_stop_the_launch(self):
        import os
        cwd = os.getcwd()
        os.chdir(tmp)
        os.environ['TEMPLATE_SYNC_RECONCILE_LOG'] = 'reconcile.log'
        try:
            watch._default_template_launch(str(tmp / 'drifted'), 'o/dotfiles#77', str(tmp / 'fake-dotfiles'))
        finally:
            os.chdir(cwd)
            del os.environ['TEMPLATE_SYNC_RECONCILE_LOG']
        self.assertTrue((tmp / 'reconcile.log').exists())

    def test_no_pr_number_in_the_template_commit_means_no_run(self):
        other = tmp / 'dotfiles-nonumber'
        subprocess.run(['git', 'clone', '-q', str(tmp / 'dotfiles'), str(other)], check=True)
        gq = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-C', str(other)]
        (other / 'templates/agent-team/team.md').write_text('two')
        subprocess.run(gq + ['commit', '-qam', 'no number'], check=True)
        subprocess.run(['git', '-C', str(other), 'update-ref', 'refs/remotes/origin/main', 'HEAD'], check=True)
        h = Harness()
        notices = watch.template_sync_reconcile(
            CONFIG, {}, 1000, dotfiles=str(other), check=h.check, launch=h.launch,
            origin_of=lambda p: 'o/' + pathlib.Path(p).name)
        self.assertEqual((notices, h.launched), ([], []))


unittest.main(argv=['x'], verbosity=2)
PY
