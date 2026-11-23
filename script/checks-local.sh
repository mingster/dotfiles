#!/usr/bin/env bash
# Run what .github/workflows/checks.yml runs, for the files this branch changed.
# Usage: checks-local.sh [--list-only] [--base <ref>]   (base defaults to origin/main)
# Same file selection as the script-tests job, every hook test, then the shellcheck job. A temp HOME
# with the asdf pins keeps a test that forgets to pin asdf failing here, as it does in CI.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
base=origin/main
list_only=()
while [ $# -gt 0 ]; do
  case "$1" in
    --list-only) list_only=(--list-only); shift ;;
    --base) base=${2:?--base needs a ref}; shift 2 ;;
    *) echo "Usage: $0 [--list-only] [--base <ref>]" >&2; exit 2 ;;
  esac
done

# The no project names test needs a private pattern file and skips without one. HOME is swapped below, so look now.
names_file="${NO_PROJECT_NAMES_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/project-names.pattern}"
export NO_PROJECT_NAMES_FILE="$names_file"
skipped_note() { [ -f "$names_file" ] || echo "SKIPPED no-project-names.test.sh (no pattern file; CI runs this)"; }
# shellcheck source=lib/hooks-changed.sh
. "$here/lib/hooks-changed.sh"
# shellcheck source=tests/lib/asdf-pin.sh
. "$here/tests/lib/asdf-pin.sh"
cd "$root"
changed=()
while IFS= read -r f; do changed+=("$f"); done < <(git diff --diff-filter=d --name-only "$(git merge-base "$base" HEAD)")
# Names in the branch commits, the changed files and the PR text fail here, so a worker sees them before the push.
# A missing pattern file fails too (it is on every fleet host). Run before the HOME swap: gh reads its login from HOME.
if [ "${#list_only[@]}" -eq 0 ]; then
  name_args=(--show-match --changed "$base" --commits "$base..HEAD")
  pr_text=$(mktemp -d)
  if gh pr view --json title,body >"$pr_text/pr.json" 2>/dev/null; then
    jq -r .title "$pr_text/pr.json" >"$pr_text/pr-title.txt"
    jq -r .body "$pr_text/pr.json" >"$pr_text/pr-body.txt"
    name_args+=(--file "$pr_text/pr-title.txt" --file "$pr_text/pr-body.txt")
  fi
  bash script/check-project-names.sh "${name_args[@]}" || { rm -rf "$pr_text"; exit 1; }
  # A PR that closes a 'main red: <run id>' issue needs 'Fixes main: <run id>' in its body (#1677).
  if [ -f "$pr_text/pr-body.txt" ]; then
    main_fix_args=(--body-file "$pr_text/pr-body.txt")
    while IFS= read -r issue_no; do
      [ -n "$issue_no" ] || continue
      issue_title=$(gh issue view "$issue_no" --json title --jq .title 2>/dev/null || true)
      main_fix_args+=(--issue-title "$issue_title")
    done < <(grep -Eio '(closes|fixes|refs) #[0-9]+' "$pr_text/pr-body.txt" | grep -Eo '[0-9]+' | sort -u)
    bash script/check-main-fix.sh "${main_fix_args[@]}" || { rm -rf "$pr_text"; exit 1; }
  fi
  rm -rf "$pr_text"
  bash script/check-commit-trailers.sh --commits "$base..HEAD"
fi
HOME=$(mktemp -d)
export HOME
trap 'rm -rf "$HOME"' EXIT
# Overlap the selected script tests. One-by-one, ship.test.sh and the wrap-up suite
# already take longer than 15 minutes. CI leaves SELECT_SCRIPT_TESTS_JOBS unset and stays serial.
# The tests mostly wait on forks, so 8 on a 10 core Mac beat 4 and 6 for the wrap-up change set (#1024).
export SELECT_SCRIPT_TESTS_JOBS=${SELECT_SCRIPT_TESTS_JOBS:-8}
# Its release budget is a few seconds and assumes a quiet machine.
export SELECT_SCRIPT_TESTS_SERIAL=${SELECT_SCRIPT_TESTS_SERIAL:-'*wrap-up-scheduled-cleanup.test.sh'}
# The longest tests start first; at the end of the queue wrap-up.test.sh alone added minutes.
export SELECT_SCRIPT_TESTS_FIRST=${SELECT_SCRIPT_TESTS_FIRST:-'script/wrap-up.test.sh script/wrap-up-guards.test.sh script/tests/ship.test.sh script/tests/wrap-up-fleet-release.test.sh script/tests/wrap-up-after-merge.test.sh'}
# On macOS the skip-listed tests tagged "rerun on macOS" run here, and a failure fails this script (#1414).
# Entries tagged for another host stay skipped. CHECKS_LOCAL_OS overrides uname for the test.
if [ "${CHECKS_LOCAL_OS:-$(uname -s)}" = Darwin ] && [ -f script/script-test-skip.list ]; then
  grep -v 'rerun on macOS$' script/script-test-skip.list >"$HOME/script-test-skip.list" || true
  export SELECT_SCRIPT_TESTS_SKIP="$HOME/script-test-skip.list"
fi
bash script/select-changed-script-tests.sh ${list_only[@]+"${list_only[@]}"} "${changed[@]+"${changed[@]}"}"
[ "${#list_only[@]}" -eq 0 ] || { skipped_note; exit 0; }
# Hook gate tests read brief-lint and the hook files. Run all of them when one of those changed.
# They take about a minute and only a hook, brief-lint.sh or this script can break them (#1200).
if hooks_changed ${changed[@]+"${changed[@]}"}; then
  python3 -m unittest discover -s templates/agent-team/.claude/hooks/tests -p 'test_*.py'
  bash script/check-guard-false-positives.sh
fi
bash script/check-dotfiles-fresh.sh
bash script/check-appdir.sh
bash script/shellcheck-dotfiles.sh
skipped_note
