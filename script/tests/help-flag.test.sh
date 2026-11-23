#!/usr/bin/env bash
# -h and --help print usage on stdout and exit 0 before any other state is read, for the scripts of #1611 to #1614.
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
  check-stale-worktrees check-appdir approval-write orca-reply check-docs-updated; do
  for flag in -h --help; do
    rc=0
    out=$(cd "$tmp/cwd" && HOME="$tmp/home" PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=a/b \
      bash "$ROOT/script/$script.sh" "$flag" 2>"$tmp/err") || rc=$?
    if [ "$rc" -eq 0 ] && grep -qi 'usage' <<<"$out" && [ ! -s "$tmp/err" ] && [ ! -e "$tmp/gh-calls" ]; then
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
  "coordinator-publication:--author-dispatch" "coordinator-publication:--from" "coordinator-publication:--force"; do
  script=${pair%%:*} flag=${pair#*:}
  helped=$(bash "$ROOT/script/$script.sh" --help 2>/dev/null)
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
