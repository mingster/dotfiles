#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# -h and --help print usage on stdout and exit 0 before any other state is read, for the scripts of #1611 to #1614 and #1624.
# A stub gh that records every call proves no gh call happens. HOME and cwd are throwaways.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/cwd"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/gh-calls"\nexit 1\n' "$tmp" > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
PASS=0
FAIL=0
for script in pr-review post-verdict head-checks coordinator-publication secrets-sync secrets-gate-setup \
  check-stale-worktrees check-appdir approval-write orca-reply check-docs-updated \
  ship remote-heavy start-cursor-worker check-hook-paths grok-trust secrets-gate; do
  for flag in -h --help; do
    rc=0
    out=$(cd "$tmp/cwd" && HOME="$tmp/home" PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=a/b \
      bash "$ROOT/script/$script.sh" "$flag" 2>"$tmp/err") || rc=$?
    if [ "$rc" -eq 0 ] && grep -qi 'usage' <<<"$out" && [ ! -s "$tmp/err" ] && [ ! -e "$tmp/gh-calls" ] \
      && [ -z "$(ls -A "$tmp/home")$(ls -A "$tmp/cwd")" ]; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1)); echo "FAIL: $script $flag rc=$rc out=$(head -c 120 <<<"$out") err=$(head -c 120 "$tmp/err")"
    fi
  done
done
# Flags the headers must name (#1612, #1613).
for pair in "post-verdict:--corrects" "post-verdict:--supersedes" \
  "head-checks:--repo" "head-checks:--pr" "head-checks:--ref" "head-checks:--base" "head-checks:--config" "head-checks:--train-heads" \
  "coordinator-publication:--repo" "coordinator-publication:--branch" "coordinator-publication:--body-file" \
  "coordinator-publication:--title" "coordinator-publication:--worktree" "coordinator-publication:--run" \
  "coordinator-publication:--author-family" "coordinator-publication:--author-provider" "coordinator-publication:--author-model" \
  "coordinator-publication:--author-dispatch" "coordinator-publication:--from" "coordinator-publication:--force" \
  "ship:--repo" "ship:--pr" "ship:--dry-run" "ship:--environment" "ship:--mechanical" "ship:--verdict-from" "ship:--help" \
  "remote-heavy:--host" "remote-heavy:--repo-dir" "remote-heavy:--dir" "remote-heavy:--sub" "remote-heavy:--weight" "remote-heavy:--memory-mb" \
  "remote-heavy:--gate" "remote-heavy:--max-wait" "remote-heavy:--fetch" "remote-heavy:--into" "remote-heavy:--help" \
  "start-cursor-worker:--run" "start-cursor-worker:--spec" "start-cursor-worker:--title" "start-cursor-worker:--model" "start-cursor-worker:--from" \
  "start-cursor-worker:--on" "start-cursor-worker:--role" "start-cursor-worker:--worktree-path" "start-cursor-worker:--name" \
  "start-cursor-worker:--repo" "start-cursor-worker:--base-branch" "start-cursor-worker:--help" \
  "check-hook-paths:--help" "grok-trust:--help" "secrets-gate:--help" "secrets-gate:--dry-run"; do
  script=${pair%%:*} flag=${pair#*:}
  helped=$(cd "$tmp/cwd" && HOME="$tmp/home" bash "$ROOT/script/$script.sh" --help 2>/dev/null)
  header=$(sed -n '1,/^set /p' "$ROOT/script/$script.sh")
  if grep -qF -e "$flag" <<<"$helped" && grep -qF -e "$flag" <<<"$header"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $script usage or header misses $flag"
  fi
done
# A first argument that is not a PR number is refused with usage on stderr, before any gh call (#1611).
for bad in abc 12x -x; do
  rc=0
  (cd "$tmp/cwd" && HOME="$tmp/home" PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=a/b bash "$ROOT/script/pr-review.sh" "$bad" >"$tmp/out" 2>"$tmp/err") || rc=$?
  if [ "$rc" -eq 2 ] && grep -qi 'usage' "$tmp/err" && [ ! -e "$tmp/gh-calls" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: pr-review $bad rc=$rc err=$(head -c 120 "$tmp/err")"
  fi
done
# A leading dash word is no operand (#1614).
for script in approval-write check-stale-worktrees; do
  rc=0
  bash "$ROOT/script/$script.sh" --bogus >"$tmp/out" 2>"$tmp/err" || rc=$?
  if [ "$rc" -eq 2 ] && ! grep -q 'approval-root-setup\|not a git repo' "$tmp/err"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $script --bogus rc=$rc err=$(head -c 160 "$tmp/err")"
  fi
done
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
