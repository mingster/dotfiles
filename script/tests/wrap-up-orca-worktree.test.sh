#!/usr/bin/env bash
# wrap-up must deregister Orca sidebar worktrees when it removes a git worktree, clean orphan entries, and respect pinned metadata.
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
here="$root/script"
tmp=$(mktemp -d); tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
real_git=$(command -v git)
mkdir -p "$tmp/bin" "$tmp/home"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'repo view --json defaultBranchRef') echo '{"defaultBranchRef":{"name":"main"}}'; exit 0 ;;
  'api repos/{owner}/{repo}/pages') echo '{"source":null}'; exit 0 ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100') echo '[]'; exit 0 ;;
esac
printf '%s\n' "${FAKE_PRS:-[]}"
FAKE
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
case "$*" in
  'worktree list --json')
    printf '{"ok":true,"result":{"worktrees":%s,"truncated":%s}}\n' "${FAKE_ORCA_WORKTREES:-[]}" "${FAKE_ORCA_TRUNCATED:-false}"
    ;;
  'worktree rm --worktree path:'*)
    path=""
    for a in "$@"; do case "$a" in path:*) path="${a#path:}" ;; esac; done
    json=0; for a in "$@"; do [ "$a" = --json ] && json=1; done
    mode=${FAKE_RM_MODE:-ok}; case "$path" in */workspaces/orphan*) ;; *) mode=ok ;; esac   # only orphan records misbehave
    case "$mode" in
      # Like the real CLI: plain mode prints the token on stderr only, --json prints the error on stdout only.
      gone) code=selector_not_found ;;
      envmissing) code=environment_not_found ;;
      slow) sleep 3; code=ok ;;
      hang) sleep 60; code=ok ;;
      garbage) [ "$json" = 1 ] && echo 'not json'; exit 1 ;;
      *) code=ok ;;
    esac
    if [ "$code" = ok ]; then [ "$json" = 1 ] && echo '{"ok":true,"result":{}}'; exit 0; fi
    if [ "$json" = 1 ]; then printf '{"ok":false,"error":{"code":"%s"}}\n' "$code"; else echo "$code" >&2; fi
    exit 1
    ;;
  'terminal list --json') printf '{"ok":true,"result":{"terminals":%s}}\n' "${FAKE_TERMINALS:-[]}" ;;
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  *run-list*) echo '{"ok":true,"result":{"runs":[{"id":"run-1"}]}}' ;;
  *worker-list*) echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}' ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/bin/gh" "$tmp/bin/orca"
export PATH="$tmp/bin:$PATH" ORCA_CLI_COMMAND="$tmp/bin/orca" HOME="$tmp/home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 WRAP_UP_RECENT_MIN=0
export WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose" WRAP_UP_CLONE_ROOT="$tmp/no-clones"
passed=0; failed=0
ok() { printf 'ok %s\n' "$1"; passed=$((passed+1)); }
bad() { printf 'FAIL %s: %s\n' "$1" "$2"; failed=$((failed+1)); }

fixture() {
  d="$tmp/repo$n"; n=$((n+1))
  mkdir -p "$d"
  export ORCA_LOG="$d/orca.log"; : > "$ORCA_LOG"
  unset FAKE_RM_MODE
  export FAKE_PRS='[]' FAKE_TERMINALS='[]' FAKE_ORCA_WORKTREES='[]'
  "$real_git" init -q --bare "$d/origin"
  "$real_git" init -q -b main "$d/wt"
  cd "$d/wt" || exit 1
  git config user.email t@example.invalid; git config user.name T
  git commit -qm initial --allow-empty
  git remote add origin "$d/origin"; git push -q -u origin main
  git branch merged; git push -q origin merged
  git worktree add -q "$d/extra" merged
  export FAKE_ORCA_WORKTREES="[{\"path\":\"$d/extra\",\"pinned\":false}]"
}

n=0
fixture
bash "$here/wrap-up.sh" --repo "$d/wt" --apply >"$d/out" 2>"$d/err" || true
[ ! -d "$d/extra" ] && ok 'apply removes git worktree' || bad 'apply removes git worktree' 'directory still exists'
grep -Fq "worktree rm --worktree path:$d/extra" "$ORCA_LOG" && ok 'apply calls orca worktree rm' \
  || bad 'apply calls orca worktree rm' "$(cat "$ORCA_LOG")"
grep -Fq 'removed worktrees=1 orca records=1' "$d/out" && ok 'apply counts orca records' \
  || bad 'apply counts orca records' "$(cat "$d/out")"

fixture
export FAKE_ORCA_WORKTREES="[{\"path\":\"$d/extra\",\"pinned\":true}]"
out=$(bash "$here/wrap-up.sh" --repo "$d/wt" --dry-run 2>&1) || true
echo "$out" | grep -Fq 'pinned in Orca' && ok 'pinned Orca worktree kept' \
  || bad 'pinned Orca worktree kept' "$out"
[ -d "$d/extra" ] && ok 'pinned worktree not removed on dry-run preview path' || bad 'pinned kept on disk'

fixture
mkdir -p "$tmp/workspaces/existing"
export FAKE_ORCA_WORKTREES="[{\"repoId\":\"repo-a\",\"isMainWorktree\":true,\"path\":\"$d/wt\",\"pinned\":false},{\"repoId\":\"repo-a\",\"isMainWorktree\":false,\"path\":\"$tmp/workspaces/orphan\",\"pinned\":false},{\"repoId\":\"repo-b\",\"isMainWorktree\":false,\"path\":\"$tmp/workspaces/other-orphan\",\"pinned\":false},{\"repoId\":\"repo-a\",\"isMainWorktree\":false,\"path\":\"$tmp/workspaces/existing\",\"pinned\":false},{\"repoId\":\"repo-a\",\"hostId\":\"remote-1\",\"isMainWorktree\":false,\"path\":\"$tmp/workspaces/remote-wt\",\"pinned\":false}]"
bash "$here/wrap-up.sh" --repo "$d/wt" --apply >"$d/out" 2>"$d/err" || true
grep -Fq "Remove orca record $tmp/workspaces/orphan (git worktree already gone)" "$d/out" && ok 'orphan Orca record reported' \
  || bad 'orphan Orca record reported' "$(cat "$d/out")"
grep -Fq "worktree rm --worktree path:$tmp/workspaces/orphan" "$ORCA_LOG" && ok 'orphan Orca record removed' \
  || bad 'orphan Orca record removed' "$(cat "$ORCA_LOG")"
grep -Fq "worktree rm --worktree path:$tmp/workspaces/other-orphan" "$ORCA_LOG" \
  && bad 'record with another repoId kept' "$(cat "$ORCA_LOG")" || ok 'record with another repoId kept'
grep -Fq "worktree rm --worktree path:$tmp/workspaces/existing" "$ORCA_LOG" \
  && bad 'record with existing dir kept' "$(cat "$ORCA_LOG")" || ok 'record with existing dir kept'
grep -Fq "worktree rm --worktree path:$tmp/workspaces/remote-wt" "$ORCA_LOG" \
  && bad 'record on another host kept' "$(cat "$ORCA_LOG")" || ok 'record on another host kept'
grep -Fq "worktree rm --worktree path:$d/wt" "$ORCA_LOG" \
  && bad 'isMainWorktree record kept' "$(cat "$ORCA_LOG")" || ok 'isMainWorktree record kept'

fixture
export FAKE_ORCA_WORKTREES="[{\"repoId\":\"repo-other\",\"isMainWorktree\":true,\"path\":\"$tmp/other-main\",\"pinned\":false},{\"repoId\":\"repo-other\",\"isMainWorktree\":false,\"path\":\"$tmp/workspaces/orphan2\",\"pinned\":false}]"
bash "$here/wrap-up.sh" --repo "$d/wt" --apply >"$d/out" 2>"$d/err" || true
grep -Fq "worktree rm --worktree path:$tmp/workspaces/orphan2" "$ORCA_LOG" \
  && bad 'orphan sweep skipped when no main record matches' "$(cat "$ORCA_LOG")" || ok 'orphan sweep skipped when no main record matches'
grep -Fq 'Orca orphan sweep skipped' "$d/out" && ok 'orphan sweep skip prints one line' \
  || bad 'orphan sweep skip prints one line' "$(cat "$d/out")"

orphan_fixture() {
  fixture
  export FAKE_ORCA_WORKTREES="[{\"repoId\":\"repo-a\",\"isMainWorktree\":true,\"path\":\"$d/wt\",\"pinned\":false},{\"repoId\":\"repo-a\",\"isMainWorktree\":false,\"path\":\"$tmp/workspaces/orphan\",\"pinned\":false}]"
}
rm_calls() { grep -c "worktree rm --worktree path:$tmp/workspaces/orphan" "$ORCA_LOG"; }
no_ledger() { ! grep -Eq 'orca worktree rm|timed out|time limit' "$d/err"; }

# selector_not_found: already removed. One call, no warning, counted.
orphan_fixture; export FAKE_RM_MODE=gone
bash "$here/wrap-up.sh" --repo "$d/wt" --apply >"$d/out" 2>"$d/err"; rc=$?
[ "$rc" -eq 0 ] && ok 'selector_not_found keeps the round ok' || bad 'selector_not_found keeps the round ok' "rc=$rc $(cat "$d/err")"
[ "$(rm_calls)" = 1 ] && ok 'selector_not_found is one call, no retry' || bad 'selector_not_found is one call, no retry' "$(cat "$ORCA_LOG")"
grep 'worktree rm' "$ORCA_LOG" | grep -Fq -- '--json' && ok 'rm is called with --json' || bad 'rm is called with --json' "$(cat "$ORCA_LOG")"
grep -Fq 'Warning' "$d/err" && bad 'selector_not_found prints no warning' "$(cat "$d/err")" || ok 'selector_not_found prints no warning'
grep -Fq 'orca records=2' "$d/out" && ok 'selector_not_found counts as removed' || bad 'selector_not_found counts as removed' "$(cat "$d/out")"

# Another error code or unparseable output: retried once, then kept with the warning. Never a failed round.
for mode in envmissing garbage; do
  orphan_fixture; export FAKE_RM_MODE=$mode
  bash "$here/wrap-up.sh" --repo "$d/wt" --apply >"$d/out" 2>"$d/err"; rc=$?
  [ "$rc" -eq 0 ] && ok "$mode: exit 0" || bad "$mode: exit 0" "rc=$rc $(cat "$d/err")"
  [ "$(rm_calls)" = 2 ] && ok "$mode: retried once" || bad "$mode: retried once" "$(cat "$ORCA_LOG")"
  grep -Fq "Warning: could not deregister Orca worktree for orca record $tmp/workspaces/orphan" "$d/err" && ok "$mode: warning names the record" \
    || bad "$mode: warning names the record" "$(cat "$d/err")"
  grep -Fq 'Kept orca record' "$d/out" && ok "$mode: kept" || bad "$mode: kept" "$(cat "$d/out")"
  grep -Fq 'orca records=1' "$d/out" && ok "$mode: not counted removed" || bad "$mode: not counted removed" "$(cat "$d/out")"
done

# A call that runs its full own timeout is a keep, not a failed round.
orphan_fixture; export FAKE_RM_MODE=slow
WRAP_UP_CALL_TIMEOUT=1 bash "$here/wrap-up.sh" --repo "$d/wt" --apply >"$d/out" 2>"$d/err"; rc=$?
[ "$rc" -eq 0 ] && ok 'rm timeout: exit 0' || bad 'rm timeout: exit 0' "rc=$rc $(grep -A3 Failures "$d/out")"
no_ledger && ok 'rm timeout: failure ledger empty' || bad 'rm timeout: failure ledger empty' "$(cat "$d/err")"
grep -Fq "Warning: could not deregister Orca worktree for orca record $tmp/workspaces/orphan" "$d/err" && ok 'rm timeout: warning names the record' \
  || bad 'rm timeout: warning names the record' "$(cat "$d/err")"


# The repo deadline runs out during the first record's rm: that call is cut by the budget, so it is unknown (no keep,
# no warning about the record, nothing in the ledger). The next record finds no time left: one stop warning, no call.
orphan_fixture; export FAKE_RM_MODE=hang
export FAKE_ORCA_WORKTREES="[{\"repoId\":\"repo-a\",\"isMainWorktree\":true,\"path\":\"$d/wt\",\"pinned\":false},{\"repoId\":\"repo-a\",\"isMainWorktree\":false,\"path\":\"$tmp/workspaces/orphan\",\"pinned\":false},{\"repoId\":\"repo-a\",\"isMainWorktree\":false,\"path\":\"$tmp/workspaces/orphan-b\",\"pinned\":false}]"
echo dirty > "$d/wt/untracked-file"   # a dirty main checkout skips the final pull, which the spent deadline would fail
WRAP_UP_TOTAL_TIMEOUT=8 bash "$here/wrap-up.sh" --repo "$d/wt" --apply >"$d/out" 2>"$d/err"; rc=$?
[ "$rc" -eq 0 ] && ok 'spent deadline: exit 0' || bad 'spent deadline: exit 0' "rc=$rc $(grep -A3 Failures "$d/out") $(cat "$d/err")"
[ "$(grep -c 'worktree rm --worktree path:.*workspaces/orphan' "$ORCA_LOG")" = 1 ] && ok 'spent deadline: no rm call once time is gone' || bad 'spent deadline: no rm call once time is gone' "$(cat "$ORCA_LOG")"
[ "$(grep -c 'the rest waits for the next run' "$d/err")" = 1 ] && ok 'spent deadline: one warning' || bad 'spent deadline: one warning' "$(cat "$d/err")"
grep -Fq 'orphan-b (git worktree' "$d/out" && bad 'spent deadline: no Remove line after the stop' "$(cat "$d/out")" || ok 'spent deadline: no Remove line after the stop'
grep -Fq 'could not deregister' "$d/err" && bad 'budget cut is not a keep' "$(cat "$d/err")" || ok 'budget cut is not a keep'
grep -Fq 'Kept orca record' "$d/out" && bad 'budget cut has no keep count' "$(cat "$d/out")" || ok 'budget cut has no keep count'

# A record on another host is removed with --environment <hostId>.
orphan_fixture
export FAKE_ORCA_WORKTREES="[{\"repoId\":\"repo-a\",\"hostId\":\"h2\",\"isMainWorktree\":true,\"path\":\"$d/wt\",\"pinned\":false},{\"repoId\":\"repo-a\",\"hostId\":\"h2\",\"isMainWorktree\":false,\"path\":\"$tmp/workspaces/orphan\",\"pinned\":false}]"
bash "$here/wrap-up.sh" --repo "$d/wt" --apply >"$d/out" 2>"$d/err" || true
grep -Fq "path:$tmp/workspaces/orphan --environment h2 --json" "$ORCA_LOG" && ok 'non-local host uses --environment' || bad 'non-local host uses --environment' "$(cat "$ORCA_LOG")"

fixture
export FAKE_ORCA_WORKTREES=''
cat > "$tmp/bin/orca-fail-list" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
case "$*" in
  'worktree list --json') exit 1 ;;
  'terminal list --json') printf '{"ok":true,"result":{"terminals":[]}}\n' ;;
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  *run-list*) echo '{"ok":true,"result":{"runs":[{"id":"run-1"}]}}' ;;
  *worker-list*) echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}' ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/bin/orca-fail-list"
export PATH="$tmp/bin:$PATH" ORCA_CLI_COMMAND="$tmp/bin/orca-fail-list"
out=$(bash "$here/wrap-up.sh" --repo "$d/wt" --dry-run 2>&1) || true
echo "$out" | grep -Fq "Remove worktree $d/extra" && bad 'no removal when orca worktree list fails' "$out" \
  || ok 'no removal when orca worktree list fails'
echo "$out" | grep -Fq 'Orca pin lookup failed' && ok 'kept when orca pin lookup failed' \
  || bad 'kept when orca pin lookup failed' "$out"

# A truncated worktree list can hide a pinned worktree, so it counts as unreadable and nothing is removed.
fixture
export ORCA_CLI_COMMAND="$tmp/bin/orca"
export FAKE_ORCA_WORKTREES="[{\"path\":\"$d/extra\",\"pinned\":false}]" FAKE_ORCA_TRUNCATED=true
out=$(bash "$here/wrap-up.sh" --repo "$d/wt" --dry-run 2>&1) || true
unset FAKE_ORCA_TRUNCATED
echo "$out" | grep -Fq "Remove worktree $d/extra" && bad 'no removal when orca worktree list is truncated' "$out" \
  || ok 'no removal when orca worktree list is truncated'
echo "$out" | grep -Fq 'Orca pin lookup failed' && ok 'kept when orca pin list is truncated' \
  || bad 'kept when orca pin list is truncated' "$out"

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
