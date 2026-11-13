#!/usr/bin/env bash
# shellcheck source=tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/tests/lib/asdf-pin.sh"
# Exercise the public CLI in disposable repositories only. Split from wrap-up.test.sh so the two halves run side by side in checks-local.sh;
# this half covers failed deletes, late changes, the destructive command lint, worker release and idle worktrees.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$tmp/bin"
export PATH="$tmp/bin:$PATH"
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
case "$*" in
  'worktree list --json') echo '{"ok":true,"result":{"worktrees":[]}}' ;;
  'worktree rm --worktree path:'*) exit 0 ;;
  'terminal list --json') printf '{"ok":true,"result":{"terminals":%s}}\n' "${FAKE_TERMINALS:-[]}" ;;
  'orchestration worker-show'*) printf '%s\n' "$FAKE_SHOW" ;;
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  *run-list*) echo '{"ok":true,"result":{"runs":[{"id":"run-1"}]}}' ;;
  *) printf '{"ok":true,"result":{"workers":%s,"page":{"hasMore":false}}}\n' "${FAKE_WORKERS:-[]}" ;;
esac
FAKE
chmod +x "$tmp/bin/gh" "$tmp/bin/orca"
export ORCA_CLI_COMMAND="$tmp/bin/orca"
export WRAP_UP_CLONE_ROOT="$tmp/no-clones" WRAP_UP_ORCA_APP_BIN="$tmp/no-app"
export WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose"
# Fixture worktrees are all new; 0 turns the recent-activity guard off except in its own case.
export WRAP_UP_RECENT_MIN=0
# State the first half of wrap-up.test.sh leaves for these cases.
real=$(cd "$tmp" && pwd -P)
export ORCA_TERMINAL_HANDLE=t-own
export FAKE_SHOW="{\"result\":{\"dispatch\":{\"status\":\"dispatched\"},\"terminal\":{\"cwd\":\"$tmp/live\"}}}"
cat > "$tmp/bin/fake-ssh" <<'FAKE'
#!/usr/bin/env bash
# Drops ssh options, records the host, fails for the host named down, otherwise runs the remote command here.
while [ "${1:-}" = -o ]; do shift 2; done
host=$1; shift
echo "$host" >> "$FAKE_SSH_LOG"
[ "$host" != down ] || { echo 'ssh: connect to host down: No route to host' >&2; exit 255; }
# ssh joins its words and the remote login shell parses them. A real remote host has its own lock state.
export WRAP_UP_STATE_DIR="${WRAP_UP_STATE_DIR:-$HOME/.local/state/agent-team}-remote"
exec sh -c "$*"
FAKE
chmod +x "$tmp/bin/fake-ssh"
export WRAP_UP_FLEET_SSH="$tmp/bin/fake-ssh" FAKE_SSH_LOG="$tmp/ssh.log" DOTFILES_DIR="$(cd "$here/.." && pwd)"
: > "$FAKE_SSH_LOG"
export WRAP_UP_FLEET_CONFIG="$tmp/fleet.json"
cd "$tmp"
# #394: a failed single delete warns, counts as kept and the run goes on. The git shim fails the calls whose arguments match
# FAKE_GIT_FAIL (space separated globs) and, on the first call matching FAKE_GIT_LATE_ON (default: a worktree removal),
# checks out FAKE_GIT_LATE in a new worktree (a worker starting after the preview). FAKE_INV_FAIL makes every worktree
# list fail once a call matching FAKE_INV_ON has run. FAKE_FLIP_DIR swaps in its lsof and ps (process state changing) on
# the first call matching FAKE_FLIP_ON after one matching FAKE_FLIP_ARM. Everything runs in a disposable clone.
export REAL_GIT="$(command -v git)"
mkdir -p "$tmp/gitshim"
cat > "$tmp/gitshim/git" <<'FAKE'
#!/usr/bin/env bash
if [ -n "${FAKE_GIT_LATE:-}" ] && [ ! -e "$FAKE_GIT_LATE_PATH" ]; then
  case "$*" in ${FAKE_GIT_LATE_ON:-worktree remove*}) "$REAL_GIT" worktree add -q "$FAKE_GIT_LATE_PATH" "$FAKE_GIT_LATE" ;; esac
fi
if [ -n "${FAKE_FLIP_DIR:-}" ] && [ ! -e "$FAKE_FLIP_DIR/flipped" ]; then
  case "$*" in $FAKE_FLIP_ARM) : > "$FAKE_FLIP_DIR/armed" ;; esac
  if [ -e "$FAKE_FLIP_DIR/armed" ]; then
    case "$*" in $FAKE_FLIP_ON) cp "$FAKE_FLIP_DIR/lsof" "$FAKE_FLIP_DIR/ps" "$FAKE_FLIP_BIN/"; : > "$FAKE_FLIP_DIR/flipped" ;; esac
  fi
fi
for pat in ${FAKE_GIT_FAIL:-}; do
  case "$*" in *$pat*) echo "fatal: simulated failure for $pat" >&2; exit 1 ;; esac
done
if [ -n "${FAKE_INV_FAIL:-}" ]; then
  case "$*" in ${FAKE_INV_ON:-*for-each-ref*refs/heads}) : > "$FAKE_INV_FAIL" ;; esac
  if [ -e "$FAKE_INV_FAIL" ] && [ "${1:-}" = worktree ] && [ "${2:-}" = list ]; then echo 'fatal: simulated inventory failure' >&2; exit 1; fi
fi
exec "$REAL_GIT" "$@"
FAKE
chmod +x "$tmp/gitshim/git"
git init -q --bare "$tmp/origin3"
git clone -q "$tmp/origin3" "$tmp/crepo" 2>/dev/null
git -C "$tmp/crepo" config user.email test@example.invalid
git -C "$tmp/crepo" config user.name Test
git -C "$tmp/crepo" checkout -qb main
echo c > "$tmp/crepo/file"; git -C "$tmp/crepo" add file; git -C "$tmp/crepo" commit -qm initial
git -C "$tmp/crepo" push -q -u origin main
echo '.next' >> "$tmp/crepo/.git/info/exclude"
for b in lb-stuck lb-ok late; do git -C "$tmp/crepo" branch "$b"; done
for b in rok rstuck; do git -C "$tmp/crepo" push -q origin "main:refs/heads/$b"; done
git -C "$tmp/crepo" worktree add -qb wt-stuck "$tmp/c-wt-stuck"
git -C "$tmp/crepo" worktree add -qb wt-ok "$tmp/c-wt-ok"
cd "$tmp/crepo"
status=0
PATH="$tmp/gitshim:$PATH" FAKE_GIT_FAIL="worktree*c-wt-stuck branch*lb-stuck push*rstuck" \
  FAKE_GIT_LATE=late FAKE_GIT_LATE_PATH="$tmp/c-late" \
  bash "$here/wrap-up.sh" --apply > "$tmp/output" 2> "$tmp/stderr" || status=$?
[ "$status" -ne 0 ] || { echo "recorded failures must exit non-zero"; exit 1; }
grep -Eq "^Failures" "$tmp/output" || { echo "failures not listed"; cat "$tmp/output"; exit 1; }
test -d "$tmp/c-wt-stuck"; test ! -d "$tmp/c-wt-ok"
grep -Fq "Warning: could not remove worktree $real/c-wt-stuck" "$tmp/stderr"
grep -Fq 'Kept worktree' "$tmp/output"
echo 'ok a failed worktree remove warns, is kept, and the run continues'
git show-ref --verify --quiet refs/heads/lb-stuck; if git show-ref --verify --quiet refs/heads/lb-ok; then exit 1; fi
grep -Fq 'Warning: could not delete local lb-stuck; kept.' "$tmp/stderr"
echo 'ok a failed local branch delete warns and the other branches still go'
git show-ref --verify --quiet refs/heads/late
grep -Fq 'Warning: local late is checked out in a worktree now; kept.' "$tmp/stderr"
echo 'ok a branch checked out after the preview is kept with a warning'
git --git-dir="$tmp/origin3" show-ref --verify --quiet refs/heads/rstuck
if git --git-dir="$tmp/origin3" show-ref --verify --quiet refs/heads/rok; then echo 'good remote branch kept after batch failure'; exit 1; fi
grep -Fq 'Warning: could not delete remote rstuck; kept.' "$tmp/stderr"
echo 'ok a failed remote delete warns and the rest of the batch is deleted one by one'
grep -Fq 'removed worktrees=1 orca records=' "$tmp/output" && grep -Fq 'deleted local=2 deleted remote=1 ' "$tmp/output" || { echo 'counts wrong'; cat "$tmp/output"; exit 1; }
grep -q '^temp removed=' "$tmp/output" && grep -q '^chrome clones removed=' "$tmp/output"
echo 'ok failures count as kept and later steps still run'
# The fleet path (--worktrees-only) takes the same failures.
git worktree add -q -b wt-stuck2 "$tmp/c-wt-stuck2"
status=0
PATH="$tmp/gitshim:$PATH" FAKE_GIT_FAIL="worktree*c-wt-stuck2" bash "$here/wrap-up.sh" --worktrees-only --apply > "$tmp/output" 2> "$tmp/stderr" || status=$?
[ "$status" -ne 0 ] || { echo "--worktrees-only must exit non-zero on a failed delete"; exit 1; }
test -d "$tmp/c-wt-stuck2"
grep -Fq "Warning: could not remove worktree $real/c-wt-stuck2" "$tmp/stderr"
grep -q '^removed worktrees=[0-9]* orca records=[0-9]* deleted local=' "$tmp/output"
echo 'ok --worktrees-only survives a failed delete'
# #393: build caches in kept worktrees. Unmerged branches keep their worktrees. Fake lsof/ps stand in for the process checks.
cat > "$tmp/bin/lsof" <<'FAKE'
#!/usr/bin/env bash
case "${*: -1}" in *c-busy*) echo 4242 ;; esac
FAKE
cat > "$tmp/bin/ps" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_PS:-}"
FAKE
chmod +x "$tmp/bin/lsof" "$tmp/bin/ps"
for n in free busy cmd cmd-other; do
  git worktree add -q -b "u-$n" "$tmp/c-$n"
  git -C "$tmp/c-$n" commit -q --allow-empty -m "u-$n"
  mkdir -p "$tmp/c-$n/.next/cache" "$tmp/c-$n/web/.next" "$tmp/c-$n/.turbo"
  echo data > "$tmp/c-$n/.next/cache/blob"; echo data > "$tmp/c-$n/web/.next/x"; echo data > "$tmp/c-$n/.turbo/t"
done
export FAKE_PS="node $real/c-cmd/node_modules/.bin/next dev"
bash "$here/wrap-up.sh" --dry-run > "$tmp/output"
grep -Eq "^Remove build cache $real/c-free/\.next \([0-9]+ KB\)$" "$tmp/output"
grep -Eq "^Remove build cache $real/c-free/web/\.next \([0-9]+ KB\)$" "$tmp/output"
test -d "$tmp/c-free/.next" || { echo 'preview deleted a cache'; exit 1; }
echo 'ok preview lists top level and one level down build caches and deletes nothing'
grep -Fq "Kept build cache $real/c-busy/.next (held open by a running process)" "$tmp/output"
grep -Fq "Kept build cache $real/c-cmd/.next (a process command line names it)" "$tmp/output"
if grep -Fq "Kept build cache $real/c-cmd-other" "$tmp/output"; then echo 'process naming c-cmd also kept c-cmd-other'; exit 1; fi
grep -Fq 'build caches removed=4 kept=4 bytes=' "$tmp/output" || { echo 'cache counts wrong'; grep 'build' "$tmp/output"; exit 1; }
echo 'ok a worktree with a running process or a command line naming it keeps its caches'
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test ! -d "$tmp/c-free/.next" && test ! -d "$tmp/c-free/web/.next" && test ! -d "$tmp/c-cmd-other/.next"
test -d "$tmp/c-busy/.next" && test -d "$tmp/c-cmd/web/.next" && test -d "$tmp/c-free/.turbo"
echo 'ok apply removes idle caches only and leaves other directories alone'
WRAP_UP_BUILD_CACHE_DIRS='.turbo .next' bash "$here/wrap-up.sh" --apply > "$tmp/output"
test ! -d "$tmp/c-free/.turbo" && test -d "$tmp/c-busy/.turbo"
echo 'ok WRAP_UP_BUILD_CACHE_DIRS picks the directory names'
bash "$here/wrap-up.sh" --worktrees-only --dry-run | grep -q '^build caches removed=' || { echo 'no cache line under --worktrees-only'; exit 1; }
echo 'ok --worktrees-only reports build caches'
# Review fixes for #393/#394. Each case runs in the disposable clone above.
mkkept() { # <dir name>: a kept worktree (unmerged branch) with an idle .next
  git worktree add -q -b "u-$1" "$tmp/$1"
  git -C "$tmp/$1" commit -q --allow-empty -m "u-$1"
  mkdir -p "$tmp/$1/.next"; echo data > "$tmp/$1/.next/x"
}
# 1. Cache removal never leaves the worktree: no ../ names, no symlinked ancestor, no symlinked cache.
mkkept c-esc
mkdir -p "$tmp/outside-a/cache" "$tmp/outside-b/.next" "$tmp/outside-c" "$tmp/c-esc/web/.next"
echo keep > "$tmp/outside-a/cache/f"; echo keep > "$tmp/outside-b/.next/f"; echo keep > "$tmp/outside-c/f"
ln -s "$tmp/outside-b" "$tmp/c-esc/link"
rm -rf "$tmp/c-esc/.next"; ln -s "$tmp/outside-c" "$tmp/c-esc/.next"
WRAP_UP_BUILD_CACHE_DIRS='../outside-a/cache' bash "$here/wrap-up.sh" --apply > "$tmp/output" 2> "$tmp/stderr"
test -f "$tmp/outside-a/cache/f" || { echo 'a ../ cache name deleted a directory outside the worktree'; exit 1; }
bash "$here/wrap-up.sh" --apply > "$tmp/output" 2> "$tmp/stderr"
test -f "$tmp/outside-b/.next/f" || { echo 'a symlinked ancestor let the cache removal leave the worktree'; exit 1; }
test -f "$tmp/outside-c/f" || { echo 'a symlinked .next was followed'; exit 1; }
test ! -d "$tmp/c-esc/web/.next" || { echo 'the real cache inside the worktree was not removed'; exit 1; }
echo 'ok cache removal refuses ../ names, symlinked ancestors and symlinked caches, and still removes real ones'
# 2. A command line may quote or escape the worktree path.
for n in q-dq q-sq q-esc q-sib q-sib-other; do mkkept "$n"; done
git worktree add -q -b u-qsp "$tmp/c q-sp"; git -C "$tmp/c q-sp" commit -q --allow-empty -m qsp
mkdir -p "$tmp/c q-sp/.next" "$tmp/c q-esc2"; echo data > "$tmp/c q-sp/.next/x"
export FAKE_PS="node --project=\"$real/q-dq\" next dev
node '$real/q-sq' dev
node --root $real/q-esc/ dev
node -r \"$real/c q-sp\" dev
node $real/q-sib dev"
bash "$here/wrap-up.sh" --apply > "$tmp/output" 2> "$tmp/stderr"
for n in q-dq q-sq q-esc q-sib "c q-sp"; do
  test -d "$tmp/$n/.next" || { echo "a command line naming $n (quoted or escaped) did not protect its cache"; exit 1; }
done
test ! -d "$tmp/q-sib-other/.next" || { echo 'a sibling path prefix was matched'; exit 1; }
export FAKE_PS="node --project=$real/c\\ q-sp dev"
bash "$here/wrap-up.sh" --apply > "$tmp/output" 2> "$tmp/stderr"
test -d "$tmp/c q-sp/.next" || { echo 'a shell escaped path did not protect the cache'; exit 1; }
unset FAKE_PS
echo 'ok quoted and escaped paths in a command line protect the cache; siblings are not matched'
# 3. A failed stale local delete counts as kept.
old=$(GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' git commit-tree -p main -m old "$(printf '100644 blob %s\tstale\n' "$(echo x | git hash-object -w --stdin)" | git mktree)")
git branch stale-stuck "$old"; git branch stale-ok "$old"; git push -q origin stale-stuck stale-ok # pushed: a local only branch is now kept
status=0
PATH="$tmp/gitshim:$PATH" FAKE_GIT_FAIL="branch*stale-stuck" bash "$here/wrap-up.sh" --apply --stale > "$tmp/output" 2> "$tmp/stderr" || status=$?
[ "$status" -ne 0 ] || { echo "a failed stale delete must exit non-zero"; exit 1; }
git show-ref --verify --quiet refs/heads/stale-stuck
if git show-ref --verify --quiet refs/heads/stale-ok; then echo 'the good stale branch was not deleted'; exit 1; fi
grep -Fq 'Warning: could not delete local stale-stuck; kept.' "$tmp/stderr"
grep -Fq 'Kept local stale-stuck (delete failed)' "$tmp/output" || { echo 'failed stale delete not counted as kept'; exit 1; }
grep -Fq 'stale=2 stale deleted=1' "$tmp/output" || { echo 'stale deleted count wrong'; grep 'stale' "$tmp/output"; exit 1; }
echo 'ok a failed stale local delete counts as kept, not deleted'
# 4. A failed checkout inventory aborts deletion for the repo, never deletes blind.
git branch inv-b; git push -q origin inv-b
status=0
PATH="$tmp/gitshim:$PATH" FAKE_INV_FAIL="$tmp/inv-flag" bash "$here/wrap-up.sh" --apply > "$tmp/output" 2> "$tmp/stderr" || status=$?
[ "$status" -ne 0 ] || { echo 'a failed worktree inventory still exited 0'; exit 1; }
grep -Fq 'Warning: could not list worktrees' "$tmp/stderr" || { echo 'no inventory warning'; cat "$tmp/stderr"; exit 1; }
git show-ref --verify --quiet refs/heads/inv-b || { echo 'a branch was deleted without an inventory'; exit 1; }
git --git-dir="$tmp/origin3" show-ref --verify --quiet refs/heads/inv-b || { echo 'a remote branch was deleted without an inventory'; exit 1; }
echo 'ok a failed worktree inventory aborts with a warning and a non-zero exit, deleting nothing'
# 5. A failing lsof or ps never lets a cache or worktree be deleted: unknown counts as in use.
find "$tmp" -mindepth 2 -maxdepth 3 -name .next -type d -prune -exec rm -rf {} + 2>/dev/null || true
mkkept c-lsof
mkdir -p "$tmp/c-lsof/web"
cat > "$tmp/bin/lsof" <<'FAKE'
#!/usr/bin/env bash
exit 2
FAKE
cat > "$tmp/bin/ps" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_PS:-}"
FAKE
bash "$here/wrap-up.sh" --apply > "$tmp/output" 2> "$tmp/stderr"
test -d "$tmp/c-lsof/.next" || { echo 'a failing lsof let the cache be deleted'; cat "$tmp/output"; exit 1; }
grep -Fq "Kept build cache $real/c-lsof/.next (lsof failed)" "$tmp/output" || { echo 'lsof failure kept the cache without a reason'; cat "$tmp/output"; exit 1; }
grep -Fq 'build caches removed=0 kept=1 bytes=0' "$tmp/output" || { echo 'lsof failure not counted as kept=1'; grep 'build' "$tmp/output"; exit 1; }
cat > "$tmp/bin/lsof" <<'FAKE'
#!/usr/bin/env bash
echo 'lsof: WARNING: something went wrong' >&2
FAKE
bash "$here/wrap-up.sh" --apply > "$tmp/output" 2> "$tmp/stderr"
test -d "$tmp/c-lsof/.next" || { echo 'lsof error output let the cache be deleted'; exit 1; }
echo 'ok a failing lsof (bad status or error output) keeps the cache and counts it as kept'
# The worktree removal paths share the helper: a failing lsof keeps a merged worktree too.
git worktree add -q -b m-lsof "$tmp/m-lsof"
bash "$here/wrap-up.sh" --apply --worktrees-only > "$tmp/output" 2> "$tmp/stderr"
test -d "$tmp/m-lsof" || { echo 'a failing lsof let --worktrees-only remove a worktree'; cat "$tmp/output"; exit 1; }
echo 'ok a failing lsof keeps worktrees under --worktrees-only'
cat > "$tmp/bin/lsof" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
cat > "$tmp/bin/ps" <<'FAKE'
#!/usr/bin/env bash
echo 'ps: failure' >&2
exit 1
FAKE
bash "$here/wrap-up.sh" --apply > "$tmp/output" 2> "$tmp/stderr"
test -d "$tmp/c-lsof/.next" || { echo 'a failing ps let the cache be deleted'; exit 1; }
echo 'ok a failing ps keeps the cache'
rm -f "$tmp/bin/lsof" "$tmp/bin/ps"
# 6. One table: every path that deletes because "nothing runs here" x every way lsof or ps can fail. Each must keep and
# count the item as kept. A fresh disposable repo keeps the counts exact.
git init -q --bare "$tmp/origin4"
git clone -q "$tmp/origin4" "$tmp/trepo" 2>/dev/null
cd "$tmp/trepo"
git config user.email test@example.invalid; git config user.name Test
git checkout -qb main; echo t > file; git add file; git commit -qm initial; git push -q -u origin main
echo '.next' >> .git/info/exclude
told=$(GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' git commit-tree -p main -m old "$(printf '100644 blob %s\tstale\n' "$(echo y | git hash-object -w --stdin)" | git mktree)")
export WRAP_UP_CLONE_ROOT="$tmp/t-clones" WRAP_UP_LOOSE_ROOT="$tmp/t-loose"
tclone="$tmp/t-clones/com.google.Chrome.code_sign_clone/code_sign_clone.t1"
ttemp="$tmp/t-loose/12-t.log"
tfixtures() { # recreate whatever a failing case deleted
  git worktree prune
  [ -d "$tmp/t-wt" ] || git worktree add -q -B t-wt "$tmp/t-wt" main
  [ -d "$tmp/t-wto" ] || git worktree add -q -B t-wto "$tmp/t-wto" main
  [ -d "$tmp/t-stale" ] || git worktree add -q -B t-stale "$tmp/t-stale" "$told"
  git push -q -f origin t-stale # pushed: a local only branch is kept, so this fixture must not be one
  if [ ! -d "$tmp/t-cache" ]; then
    git worktree add -q -B t-cache "$tmp/t-cache" main; git -C "$tmp/t-cache" commit -q --allow-empty -m t-cache
  fi
  mkdir -p "$tmp/t-cache/.next" "$tmp/t-loose" "$tclone"; echo data > "$tmp/t-cache/.next/x"
  [ -f "$ttemp" ] || { echo log > "$ttemp"; touch -t 202001010000 "$ttemp"; }
}
tfake() { # <mode>: write the failing lsof or ps; the other one answers "nothing here"
  local lsof_body='exit 1' ps_body='echo "init"'
  case "$1" in
    lsof-status) lsof_body='exit 2' ;;
    lsof-stderr) lsof_body='echo "lsof: WARNING: can not stat" >&2; exit 1' ;;
    ps-status) ps_body='exit 1' ;;
    ps-stderr) ps_body='echo "init"; echo "ps: warning" >&2' ;;
  esac
  printf '#!/usr/bin/env bash\n%s\n' "$lsof_body" > "$tmp/bin/lsof"
  printf '#!/usr/bin/env bash\n%s\n' "$ps_body" > "$tmp/bin/ps"
  chmod +x "$tmp/bin/lsof" "$tmp/bin/ps"
}
t_cases=0; t_failed=0
tcheck() { # <mode> <path> <command...>
  local mode=$1 what=$2; shift 2
  t_cases=$((t_cases+1))
  if "$@"; then echo "ok   $mode keeps $what"; else echo "FAIL $mode deleted or did not count $what"; t_failed=$((t_failed+1)); fi
}
has() { grep -Fq -- "$1" "$tmp/output"; }
kept_wt() { test -d "$tmp/$1" && has "Kept worktree $real/$1 (" && has 'removed worktrees=0 orca records='; }
kept_stale() { test -d "$tmp/t-stale" && git show-ref --verify --quiet refs/heads/t-stale && has "Kept worktree $real/t-stale (" && has 'stale deleted=0'; }
kept_cache() { test -d "$tmp/t-cache/.next" && has 'build caches removed=0 kept=1 '; }
kept_clone() { test -d "$tclone" && has 'chrome clones removed=0 kept=1'; }
kept_temp() { test -f "$ttemp" && has 'temp removed=0 kept=1 '; }
for mode in lsof-status lsof-stderr ps-status ps-stderr; do
  tfixtures; tfake "$mode"
  bash "$here/wrap-up.sh" --apply --stale > "$tmp/output" 2> "$tmp/stderr" || true
  tcheck "$mode" 'worktree (--apply)' kept_wt t-wt
  tcheck "$mode" 'stale branch (--apply --stale)' kept_stale
  tcheck "$mode" 'build cache' kept_cache
  tcheck "$mode" 'Chrome clone' kept_clone
  tcheck "$mode" 'temp item' kept_temp
  tfixtures
  bash "$here/wrap-up.sh" --apply --worktrees-only > "$tmp/output" 2> "$tmp/stderr" || true
  tcheck "$mode" 'worktree (--worktrees-only)' kept_wt t-wto
done
echo "process check table: $t_cases cases, $t_failed failed"
[ "$t_failed" -eq 0 ] || exit 1
# Control: when lsof and ps both answer cleanly, the same fixtures go.
tfixtures; tfake clean
bash "$here/wrap-up.sh" --apply --stale > "$tmp/output" 2> "$tmp/stderr"
test ! -d "$tmp/t-wt" && test ! -d "$tmp/t-stale" && test ! -d "$tmp/t-cache/.next" && test ! -d "$tclone" && test ! -f "$ttemp" \
  || { echo 'clean lsof and ps did not let the idle fixtures go'; cat "$tmp/output"; exit 1; }
rm -f "$tmp/bin/lsof" "$tmp/bin/ps"
echo 'ok a clean lsof and ps still let idle items go'
# 7. Review fixes: stale deletion re-reads the worktree inventory, and the empty scratch parent goes through in_use.
r_failed=0
rcheck() { # <what> <command...>
  local what=$1; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; r_failed=$((r_failed+1)); fi
}
# a. A remote-only stale branch checked out in a new worktree after selection is kept; ps exit 1 is reported for it.
git push -q origin "$told:refs/heads/r-stale"; git tag r-stale-copy "$told" # a second copy, so r-stale is not the last copy
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/lsof"; printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/ps"
chmod +x "$tmp/bin/lsof" "$tmp/bin/ps"
PATH="$tmp/gitshim:$PATH" FAKE_GIT_LATE=r-stale FAKE_GIT_LATE_PATH="$tmp/r-late" FAKE_GIT_LATE_ON='log -1*origin/r-stale' \
  bash "$here/wrap-up.sh" --apply --stale > "$tmp/output" 2> "$tmp/stderr" || true
late_kept() {
  git --git-dir="$tmp/origin4" show-ref --verify --quiet refs/heads/r-stale && has "Kept stale r-stale (checked out in $real/r-late, ps failed)" \
    && ! grep -Fq 'Delete stale r-stale' "$tmp/output"
}
rcheck "a stale remote branch checked out after selection is kept with the new worktree in_use reason" late_kept
git worktree remove --force "$tmp/r-late" 2>/dev/null || true
git branch -D r-stale >/dev/null 2>&1 || true
git push -q origin "$told:refs/heads/r-stale" 2>/dev/null || true
# b. A failed worktree inventory before stale deletion deletes no stale branch and keeps every remaining candidate.
git branch s-inv1 "$told"; git branch s-inv2 "$told"
printf '#!/usr/bin/env bash\necho init\n' > "$tmp/bin/ps"
rm -f "$tmp/inv-flag4"
PATH="$tmp/gitshim:$PATH" FAKE_INV_FAIL="$tmp/inv-flag4" FAKE_INV_ON='log -1*' \
  bash "$here/wrap-up.sh" --apply --stale > "$tmp/output" 2> "$tmp/stderr" || true
inv_kept() {
  git show-ref --verify --quiet refs/heads/s-inv1 && git show-ref --verify --quiet refs/heads/s-inv2 \
    && git --git-dir="$tmp/origin4" show-ref --verify --quiet refs/heads/r-stale \
    && has 'Kept stale r-stale (worktree inventory unavailable)' && has 'Kept stale s-inv1 (worktree inventory unavailable)' \
    && has 'Kept stale s-inv2 (worktree inventory unavailable)' && has 'stale deleted=0' \
    && grep -Fq 'Warning: could not list worktrees; deleting no more stale branches.' "$tmp/stderr"
}
rcheck 'a failed inventory before stale deletion keeps every remaining candidate' inv_kept
# c. An empty scratch slug parent held as a cwd, with lsof exit 2 plus error output and ps exit 1, is kept and counted.
tparent="$tmp/t-scratch/-gone-slug-parent"
mkdir -p "$tparent"
(cd "$tparent" && exec sleep 120) &
holder=$!
printf '#!/usr/bin/env bash\necho "lsof: WARNING: can not stat" >&2\nexit 2\n' > "$tmp/bin/lsof"
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/ps"
WRAP_UP_SCRATCH_ROOT="$tmp/t-scratch" bash "$here/wrap-up.sh" --apply > "$tmp/output" 2> "$tmp/stderr" || true
parent_kept() { test -d "$tparent" && kill -0 "$holder" && has "Kept temp $tparent (lsof failed)" && has 'temp removed=0 kept=1 '; }
rcheck 'an empty scratch parent with failing lsof and ps is kept and counted' parent_kept
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
rm -f "$tmp/bin/lsof" "$tmp/bin/ps"
echo "review fix cases: 3 cases, $r_failed failed"
[ "$r_failed" -eq 0 ] || exit 1
# 8. Review fixes, round 5. A fresh disposable repo keeps the counts exact.
git init -q --bare "$tmp/origin5"
git clone -q "$tmp/origin5" "$tmp/frepo" 2>/dev/null
cd "$tmp/frepo"
git config user.email test@example.invalid; git config user.name Test
git checkout -qb main; echo f > file; git add file; git commit -qm initial; git push -q -u origin main
fold=$(GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' git commit-tree -p main -m old "$(printf '100644 blob %s\tstale\n' "$(echo z | git hash-object -w --stdin)" | git mktree)")
export WRAP_UP_CLONE_ROOT="$tmp/f-none" WRAP_UP_LOOSE_ROOT="$tmp/f-none" WRAP_UP_SCRATCH_ROOT="$tmp/f-none"
f_cases=0; f_failed=0
fcheck() { # <what> <command...>
  local what=$1; shift
  f_cases=$((f_cases+1))
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; f_failed=$((f_failed+1)); fi
}
fprobe() { # <dir> <lsof body> <ps body>
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$1/lsof"; printf '#!/usr/bin/env bash\n%s\n' "$3" > "$1/ps"
  chmod +x "$1/lsof" "$1/ps"
}
# a. P1: a stale worktree passes in_use at selection, then its probe turns busy or unknown before removal (the process
# state flips at the first worktree inventory after the subject lookup). The worktree and both refs stay, counted as kept.
for mode in lsof-status-stderr ps-status ps-stderr lsof-holder; do
  case "$mode" in
    lsof-status-stderr) busy_lsof='echo "lsof: WARNING: can not stat" >&2; exit 2'; busy_ps='echo init'; want='lsof failed' ;;
    ps-status) busy_lsof='exit 1'; busy_ps='exit 1'; want='ps failed' ;;
    ps-stderr) busy_lsof='exit 1'; busy_ps='echo init; echo "ps: warning" >&2'; want='ps failed' ;;
    lsof-holder) busy_lsof='echo 4242'; busy_ps='echo init'; want='held open by a running process' ;;
  esac
  git worktree prune
  [ -d "$tmp/f-stale" ] || git worktree add -q -B f-stale "$tmp/f-stale" "$fold"
  git push -q -f origin "$fold:refs/heads/f-stale"
  fprobe "$tmp/bin" 'exit 1' 'echo init'
  rm -rf "$tmp/flip"; fprobe "$tmp/flip" "$busy_lsof" "$busy_ps"
  PATH="$tmp/gitshim:$PATH" FAKE_FLIP_DIR="$tmp/flip" FAKE_FLIP_BIN="$tmp/bin" FAKE_FLIP_ARM='rev-list --count*' FAKE_FLIP_ON='worktree list*' \
    bash "$here/wrap-up.sh" --apply --stale > "$tmp/output" 2> "$tmp/stderr" || true
  stale_wt_kept() {
    test -e "$tmp/flip/flipped" && test -d "$tmp/f-stale" && git show-ref --verify --quiet refs/heads/f-stale \
      && git --git-dir="$tmp/origin5" show-ref --verify --quiet refs/heads/f-stale \
      && has "Kept worktree $real/f-stale ($want)" && has 'stale deleted=0'
  }
  fcheck "$mode turning busy after selection keeps the stale worktree and its refs" stale_wt_kept
done
fprobe "$tmp/bin" 'exit 1' 'echo init'
git worktree remove --force "$tmp/f-stale" 2>/dev/null || true; git branch -D f-stale >/dev/null 2>&1 || true
git push -q origin --delete f-stale 2>/dev/null || true
# b. P2: a remote-only merged branch checked out during its own remote eligibility lookup keeps its remote ref.
git push -q origin "main:refs/heads/f-late"
PATH="$tmp/gitshim:$PATH" FAKE_GIT_LATE=f-late FAKE_GIT_LATE_PATH="$tmp/f-late" FAKE_GIT_LATE_ON='merge-base --is-ancestor refs/remotes/origin/f-late*' \
  bash "$here/wrap-up.sh" --apply > "$tmp/output" 2> "$tmp/stderr" || true
remote_late_kept() {
  test -d "$tmp/f-late" && git --git-dir="$tmp/origin5" show-ref --verify --quiet refs/heads/f-late \
    && has "Kept remote f-late (checked out in $real/f-late" && has 'deleted remote=0 '
}
fcheck 'a remote branch checked out during its eligibility lookup is kept' remote_late_kept
git worktree remove --force "$tmp/f-late" 2>/dev/null || true; git branch -D f-late >/dev/null 2>&1 || true; git push -q origin --delete f-late 2>/dev/null || true
# c. P2: the same during a failing batch push; the one by one fallback re-reads the inventory before each retry.
git push -q origin "main:refs/heads/f-retry" "main:refs/heads/f-stuck"
PATH="$tmp/gitshim:$PATH" FAKE_GIT_FAIL='push*f-stuck' FAKE_GIT_LATE=f-retry FAKE_GIT_LATE_PATH="$tmp/f-retry" FAKE_GIT_LATE_ON='push origin --delete*' \
  bash "$here/wrap-up.sh" --apply > "$tmp/output" 2> "$tmp/stderr" || true
retry_kept() {
  test -d "$tmp/f-retry" && git --git-dir="$tmp/origin5" show-ref --verify --quiet refs/heads/f-retry \
    && git --git-dir="$tmp/origin5" show-ref --verify --quiet refs/heads/f-stuck \
    && has "Kept remote f-retry (checked out in $real/f-retry" && has 'Kept remote f-stuck (delete failed)' && has 'deleted remote=0 '
}
fcheck 'a remote branch checked out during a failed batch push is kept by the fallback retry' retry_kept
rm -f "$tmp/bin/lsof" "$tmp/bin/ps"
# 9. Lint: every destructive command in wrap-up.sh sits inside a guarded_* function; only the mktemp EXIT trap is exempt.
lint_hits=$(awk -v allow="trap 'rm -rf \"\$tmp\"; release_apply_lock' EXIT" '
  /^guarded_[a-z_]*\(\) *\{/ { inside = 1 }
  inside { if ($0 ~ /^\}/) inside = 0; next }
  /^[[:space:]]*#/ || $0 == allow { next }
  /worktree remove|branch +(-[A-Za-z]*[dD]|--delete)|push .*(--delete| :)|(^|[^[:alnum:]_.-])(rm|rmdir|unlink)( |$)|find .*-delete|update-ref +-d/ { print NR ": " $0 }
' "$here/wrap-up.sh")
lint_clean() {
  [ -z "$lint_hits" ] || { printf 'unguarded destructive command at wrap-up.sh:%s\n' "$lint_hits"; return 1; }
  for g in guarded_worktree_remove guarded_local_branch_delete guarded_remote_branch_delete guarded_rm; do
    grep -q "^$g() {" "$here/wrap-up.sh" || { echo "missing $g"; return 1; }
  done
}
fcheck 'every destructive command in wrap-up.sh runs through a guarded function' lint_clean
echo "round 5 review fix cases: $f_cases cases, $f_failed failed"
[ "$f_failed" -eq 0 ] || exit 1
# A worker already in terminalState release_unknown has a recorded terminal that no longer resolves.
# Asking worker-release again returns the same receipt, so the round must leave it alone and still
# release a finished worker and close that worker's terminal. A second round must not retry it.
unset FAKE_GIT_FAIL FAKE_GIT_LATE FAKE_GIT_LATE_PATH FAKE_GIT_LATE_ON FAKE_INV_FAIL FAKE_INV_ON FAKE_FLIP_DIR FAKE_FLIP_ARM FAKE_FLIP_ON
git init -q --bare "$tmp/origin-ru"
git init -q -b main "$tmp/repo-ru"
git -C "$tmp/repo-ru" config user.email test@example.invalid
git -C "$tmp/repo-ru" config user.name Test
git -C "$tmp/repo-ru" commit -qm c --allow-empty
git -C "$tmp/repo-ru" remote add origin "$tmp/origin-ru"
git -C "$tmp/repo-ru" push -q -u origin main
mkdir -p "$tmp/ru"
cat > "$tmp/bin/orca-ru" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/calls"
case "$*" in
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  *'terminal close'*)
    printf '%s\n' "$*" >> "$FAKE_DIR/closed"
    echo '{"ok":true}' ;;
  *'terminal list'*|*'terminal show'*) printf '%s\n' "$(cat "$FAKE_DIR/terminals")" ;;
  *worker-release*)
    printf '%s\n' "$*" >> "$FAKE_DIR/releases"
    echo '{"ok":true,"result":{"state":"released"}}' ;;
  *worker-show*) echo '{"ok":true,"result":{"state":"in_progress","liveness":"sleep"}}' ;;
  *run-list*) echo '{"ok":true,"result":{"runs":[{"id":"run-1"}]}}' ;;
  *worker-list*) printf '%s\n' "$(cat "$FAKE_DIR/workers")" ;;
  *'worktree list'*) echo '{"ok":true,"result":{"worktrees":[]}}' ;;
  *) echo "unexpected: $*" >> "$FAKE_DIR/unexpected"; exit 1 ;;
esac
FAKE
chmod +x "$tmp/bin/orca-ru"
export FAKE_DIR="$tmp/ru" ORCA_CLI_COMMAND="$tmp/bin/orca-ru" ORCA_TERMINAL_HANDLE=t-own
cat > "$tmp/ru/workers" <<'JSON'
{"ok":true,"result":{"workers":[
  {"dispatchId":"d-unknown","state":"succeeded","liveness":"unverifiable","terminalState":"release_unknown","terminal":"t-stale","workspace":"repo::/nowhere/stale"},
  {"dispatchId":"d-sleep","state":"in_progress","liveness":"sleep","terminalState":"reclaimable","terminal":"t-sleep","workspace":"repo::/nowhere/sleep"},
  {"dispatchId":"d-live","state":"ready","liveness":"live","terminalState":"reclaimable","terminal":"t-live","workspace":"repo::/nowhere/live"}
]}}
JSON
cat > "$tmp/ru/terminals" <<'JSON'
{"ok":true,"result":{"terminals":[
  {"handle":"t-sleep","worktreePath":"/nowhere/sleep","connected":true,"writable":true,"agentIdentity":null,"lastOutputAt":1},
  {"handle":"t-live","worktreePath":"/nowhere/live","connected":true,"writable":true,"agentIdentity":null,"lastOutputAt":1}
]}}
JSON
: > "$tmp/ru/calls"; : > "$tmp/ru/releases"; : > "$tmp/ru/closed"
bash "$here/wrap-up.sh" --apply --repo "$tmp/repo-ru" > "$tmp/output" 2> "$tmp/stderr" || echo "rc=$?" >> "$tmp/stderr"
bash "$here/wrap-up.sh" --apply --repo "$tmp/repo-ru" > "$tmp/output2" 2> "$tmp/stderr2" || echo "rc=$?" >> "$tmp/stderr2"
ru_fail() { echo "FAIL $1"; cat "$tmp/output" "$tmp/stderr" "$tmp/ru/releases" "$tmp/ru/closed"; exit 1; }
grep -Fq 'Release worker d-sleep (local, liveness sleep)' "$tmp/output" || ru_fail 'finished sleep worker not released'
grep -Fq 'Close terminal t-sleep (local, settled dispatch)' "$tmp/output" || ru_fail 'finished terminal not closed'
grep -Fq 'terminal close --terminal t-sleep' "$tmp/ru/closed" || ru_fail 'apply did not close the finished terminal'
! grep -Fq 'Release worker d-unknown' "$tmp/output" "$tmp/output2" || ru_fail 'release_unknown worker was planned again'
! grep -Fq 'worker-release --dispatch d-unknown' "$tmp/ru/releases" || ru_fail 'release_unknown worker was retried'
grep -Fq 'worker-release --dispatch d-sleep' "$tmp/ru/releases" || ru_fail 'finished worker release was not called'
! grep -Fq 'Close terminal t-live' "$tmp/output" || ru_fail 'live terminal was closed'
grep -Fxq 'workers needing no action=1' "$tmp/output" || ru_fail 'release_unknown row was not listed once as needing no action'
grep -Fxq 'workers needing no action=1' "$tmp/output2" || ru_fail 'second round did not list the release_unknown row once'
echo 'ok a release_unknown worker is not retried; the finished one is released and its terminal closed'

# Scheduled idle shells, and a dispatch that has ended but was not released.
# lastOutputAt is milliseconds. 1 is long idle; a fresh stamp is still inside 60 minutes.
now_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
mid_ms=$((now_ms - 1800000))
mkdir -p "$tmp/idle"
cat > "$tmp/bin/orca-idle" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/calls"
case "$*" in
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  *'terminal close'*) printf '%s\n' "$*" >> "$FAKE_DIR/closed"; echo '{"ok":true}' ;;
  *'terminal list'*|*'terminal show'*) cat "$FAKE_DIR/terminals" ;;
  *worker-release*) printf '%s\n' "$*" >> "$FAKE_DIR/releases"; echo 'release failed' >&2; exit 1 ;;
  *worker-show*) echo '{"ok":true,"result":{"state":"in_progress","liveness":"live","outcome":"worker_done"}}' ;;
  *run-list*) echo '{"ok":true,"result":{"runs":[{"id":"run-1","coordinator_handle":"t-coord"}]}}' ;;
  *worker-list*) cat "$FAKE_DIR/workers" ;;
  *'worktree list'*) echo '{"ok":true,"result":{"worktrees":[]}}' ;;
  *) echo "unexpected: $*" >> "$FAKE_DIR/unexpected"; exit 1 ;;
esac
FAKE
chmod +x "$tmp/bin/orca-idle"
export FAKE_DIR="$tmp/idle" ORCA_CLI_COMMAND="$tmp/bin/orca-idle" ORCA_TERMINAL_HANDLE=t-own
jq -n --argjson now "$now_ms" '{ok:true,result:{workers:[
  {dispatchId:"d-ended",state:"in_progress",liveness:"live",outcome:"worker_done",terminalState:"reclaimable",terminal:"t-ended",workspace:"repo::/nowhere/ended"},
  {dispatchId:"d-gone",state:"in_progress",liveness:"live",terminalState:"release_unknown",terminal:"t-missing",workspace:"repo::/nowhere/shared"},
  {dispatchId:"d-stopped",state:"in_progress",liveness:"exited",terminalState:"reclaimable",terminal:"t-stopped",workspace:"repo::/nowhere/stopped"},
  {dispatchId:"d-live",state:"ready",liveness:"live",outcome:"in_progress",terminalState:"active",terminal:"t-live",workspace:"repo::/nowhere/live"},
  {dispatchId:"d-rel",state:"succeeded",liveness:"exited",terminalState:"reclaimable",terminal:"t-rel",workspace:"repo::/nowhere/rel"}
]}}' > "$tmp/idle/workers"
jq -n --argjson now "$now_ms" --argjson mid "$mid_ms" '{ok:true,result:{terminals:[
  {handle:"t-old",worktreePath:"/nowhere/old",connected:true,writable:true,agentIdentity:null,lastOutputAt:1,title:"shell"},
  {handle:"t-fresh",worktreePath:"/nowhere/fresh",connected:true,writable:true,agentIdentity:null,lastOutputAt:$now,title:"shell"},
  {handle:"t-mid",worktreePath:"/nowhere/mid",connected:true,writable:true,agentIdentity:null,lastOutputAt:$mid,title:"shell"},
  {handle:"t-lead",worktreePath:"/nowhere/lead-keep",connected:true,writable:true,agentIdentity:null,lastOutputAt:1,title:"shell"},
  {handle:"t-coord",worktreePath:"/nowhere/coord",connected:true,writable:true,agentIdentity:null,lastOutputAt:1,title:"shell"},
  {handle:"t-ended",worktreePath:"/nowhere/ended",connected:true,writable:true,agentIdentity:null,lastOutputAt:1,title:"shell"},
  {handle:"t-shared",worktreePath:"/nowhere/shared",connected:true,writable:true,agentIdentity:null,lastOutputAt:1,title:"shell"},
  {handle:"t-stopped",worktreePath:"/nowhere/stopped",connected:true,writable:true,agentIdentity:null,lastOutputAt:1,title:"shell"},
  {handle:"t-live",worktreePath:"/nowhere/live",connected:true,writable:true,agentIdentity:"claude",lastOutputAt:$now,title:"agent"},
  {handle:"t-pane",worktreePath:"/nowhere/live",connected:true,writable:true,agentIdentity:null,lastOutputAt:1,title:"worker-pane.sh d-live"}
]}}' > "$tmp/idle/terminals"
: > "$tmp/idle/calls"; : > "$tmp/idle/releases"; : > "$tmp/idle/closed"
git init -q --bare "$tmp/origin-idle"
git init -q -b main "$tmp/repo-idle"
git -C "$tmp/repo-idle" config user.email test@example.invalid
git -C "$tmp/repo-idle" config user.name Test
git -C "$tmp/repo-idle" commit -qm c --allow-empty
git -C "$tmp/repo-idle" remote add origin "$tmp/origin-idle"
git -C "$tmp/repo-idle" push -q -u origin main
WRAP_UP_SCHEDULED_CHILD=1 WRAP_UP_TOTAL_TIMEOUT=30 WRAP_UP_RELEASE_BUDGET=5 \
  bash "$here/wrap-up.sh" --apply --repo "$tmp/repo-idle" > "$tmp/output" 2> "$tmp/stderr" || echo "rc=$?" >> "$tmp/stderr"
idle_fail() { echo "FAIL $1"; cat "$tmp/output" "$tmp/stderr" "$tmp/idle/releases" "$tmp/idle/closed"; exit 1; }
grep -Fq 'Close terminal t-old (local, no dispatch, no agent, idle)' "$tmp/output" || idle_fail 'idle shell not closed'
grep -Fq 'Kept terminal t-fresh ' "$tmp/output" || idle_fail 'recent shell closed'
! grep -Fq 'Close terminal t-fresh ' "$tmp/output" || idle_fail 'recent shell closed'
grep -Fq 'Kept terminal t-mid (local, no dispatch, no agent, output within 60 minutes)' "$tmp/output" || idle_fail 'shell inside 60 minutes closed'
grep -Fq 'Kept terminal t-lead (local, lead worktree)' "$tmp/output" || idle_fail 'lead shell closed'
grep -Fq 'Kept terminal t-coord (local, coordinator)' "$tmp/output" || idle_fail 'coordinator closed'
grep -Fq 'Kept terminal t-live (local, live dispatch)' "$tmp/output" || idle_fail 'live worker closed'
grep -Fq 'Kept terminal t-pane (local, live dispatch)' "$tmp/output" || idle_fail 'live worker pane closed'
grep -Fq 'Close terminal t-ended (local, settled dispatch)' "$tmp/output" || idle_fail 'ended dispatch still live'
! grep -Fq 'Kept terminal t-ended (local, live dispatch)' "$tmp/output" || idle_fail 'worker_done kept the terminal'
grep -Fq 'Close terminal t-stopped (local, settled dispatch)' "$tmp/output" || idle_fail 'exited worker kept the terminal'
grep -Fq 'Close terminal t-shared (local, settled dispatch on this path)' "$tmp/output" \
  || grep -Fq 'Close terminal t-shared (local, no dispatch, no agent, idle)' "$tmp/output" \
  || idle_fail 'gone terminal still protected the shell'
! grep -Fq 'Kept terminal t-shared (local, live dispatch)' "$tmp/output" || idle_fail 'terminal gone counted as live'
grep -Fq 'terminal close --terminal t-ended' "$tmp/idle/closed" || idle_fail 'apply did not close the ended terminal'
grep -Fq 'releasing d-rel on local failed' "$tmp/stderr" || idle_fail 'release failure was not recorded'
close_at=$(grep -n 'Close terminal t-ended ' "$tmp/output" | head -n 1 | cut -d: -f1)
rel_at=$(grep -n 'Release worker d-rel ' "$tmp/output" | head -n 1 | cut -d: -f1)
[ -n "$close_at" ] && [ -n "$rel_at" ] && [ "$close_at" -lt "$rel_at" ] || idle_fail 'close waited for release'
echo 'ok scheduled round closes idle shells and ended dispatches even when release fails'

# An idle shell in a live dispatch's worktree stays open. A shell somewhere else still closes.
# terminal show after a real close has no state field: connected false is closed, connected true is still open.
mkdir -p "$tmp/sib"
cat > "$tmp/bin/orca-sib" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/calls"
args=("$@"); h=''
for i in "${!args[@]}"; do [ "${args[$i]}" = --terminal ] && h=${args[$((i+1))]}; done
case "$*" in
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  *'terminal close'*) printf '%s\n' "$*" >> "$FAKE_DIR/closed"; echo '{"ok":true,"result":{"close":{"ok":true}}}'; exit 0 ;;
  *'terminal show'*)
    if [ "$h" = t-stuck ]; then
      printf '{"ok":true,"result":{"terminal":{"handle":"%s","connected":true,"writable":true}}}\n' "$h"
    else
      printf '{"ok":true,"result":{"terminal":{"handle":"%s","connected":false,"writable":false,"orphaned":true}}}\n' "$h"
    fi ;;
  *'terminal list'*) cat "$FAKE_DIR/terminals" ;;
  *worker-release*) echo '{"ok":true,"result":{"state":"released"}}' ;;
  *worker-show*) echo '{"ok":true,"result":{"state":"ready","liveness":"live","outcome":"in_progress","workspace":"repo::/live/wt","terminal":{"cwd":"/live/wt"}}}' ;;
  *run-list*) echo '{"ok":true,"result":{"runs":[{"id":"run-1","coordinator_handle":"t-coord"}]}}' ;;
  *worker-list*) cat "$FAKE_DIR/workers" ;;
  *'worktree list'*) echo '{"ok":true,"result":{"worktrees":[]}}' ;;
  *) echo "unexpected: $*" >> "$FAKE_DIR/unexpected"; exit 1 ;;
esac
FAKE
chmod +x "$tmp/bin/orca-sib"
export FAKE_DIR="$tmp/sib" ORCA_CLI_COMMAND="$tmp/bin/orca-sib" ORCA_TERMINAL_HANDLE=t-own
jq -n '{ok:true,result:{workers:[
  {dispatchId:"d-live",state:"ready",liveness:"live",outcome:"in_progress",terminalState:"active",terminal:"t-agent",workspace:"repo::/live/wt"}
],page:{hasMore:false}}}' > "$tmp/sib/workers"
jq -n --argjson now "$now_ms" '{ok:true,result:{terminals:[
  {handle:"t-agent",worktreePath:"/live/wt",connected:true,writable:true,agentIdentity:"claude",lastOutputAt:$now,title:"agent"},
  {handle:"t-term1",worktreePath:"/live/wt",connected:true,writable:true,agentIdentity:null,lastOutputAt:1,title:"Terminal 1"},
  {handle:"t-setup",worktreePath:"/live/wt",connected:true,writable:true,agentIdentity:null,lastOutputAt:1,title:"Setup"},
  {handle:"t-cwd",worktreePath:"/elsewhere/idle",cwd:"/live/wt/src",connected:true,writable:true,agentIdentity:null,lastOutputAt:1,title:"shell"},
  {handle:"t-prefix",worktreePath:"/live/wt-other",connected:true,writable:true,agentIdentity:null,lastOutputAt:1,title:"shell"},
  {handle:"t-idle",worktreePath:"/elsewhere/other",connected:true,writable:true,agentIdentity:null,lastOutputAt:1,title:"shell"},
  {handle:"t-stuck",worktreePath:"/elsewhere/stuck",connected:true,writable:true,agentIdentity:null,lastOutputAt:1,title:"shell"}
]}}' > "$tmp/sib/terminals"
git init -q --bare "$tmp/origin-sib"
git init -q -b main "$tmp/repo-sib"
git -C "$tmp/repo-sib" config user.email test@example.invalid
git -C "$tmp/repo-sib" config user.name Test
git -C "$tmp/repo-sib" commit -qm c --allow-empty
git -C "$tmp/repo-sib" remote add origin "$tmp/origin-sib"
git -C "$tmp/repo-sib" push -q -u origin main
sib_fail() { echo "FAIL $1"; cat "$tmp/sib-out" "$tmp/sib-err" "$tmp/sib/closed" "$tmp/sib/unexpected" 2>/dev/null; exit 1; }
sib_round() { # <scheduled|manual>
  : > "$tmp/sib/calls"; : > "$tmp/sib/closed"; : > "$tmp/sib/unexpected"
  if [ "$1" = scheduled ]; then
    WRAP_UP_SCHEDULED_CHILD=1 WRAP_UP_TOTAL_TIMEOUT=60 \
      bash "$here/wrap-up.sh" --apply --repo "$tmp/repo-sib" > "$tmp/sib-out" 2> "$tmp/sib-err" || true
  else
    env -u WRAP_UP_SCHEDULED_CHILD WRAP_UP_TOTAL_TIMEOUT=60 \
      bash "$here/wrap-up.sh" --apply --repo "$tmp/repo-sib" > "$tmp/sib-out" 2> "$tmp/sib-err" || true
  fi
  for keep in t-term1 t-setup t-cwd t-agent; do
    grep -Fq "Kept terminal $keep (local, live dispatch)" "$tmp/sib-out" || sib_fail "$1 kept $keep"
    ! grep -Fq "Close terminal $keep " "$tmp/sib-out" || sib_fail "$1 closed $keep"
  done
  if [ "$1" = scheduled ]; then
    grep -Fq 'Close terminal t-idle (local, no dispatch, no agent, idle)' "$tmp/sib-out" || sib_fail 'scheduled left an idle shell elsewhere'
    grep -Fq 'Close terminal t-prefix (local, no dispatch, no agent, idle)' "$tmp/sib-out" || sib_fail 'scheduled kept a prefix lookalike'
  else
    grep -Fq 'Close terminal t-idle (local, no dispatch, no agent)' "$tmp/sib-out" || sib_fail 'manual left an idle shell elsewhere'
    ! grep -Fq 'Close terminal t-idle (local, no dispatch, no agent, idle)' "$tmp/sib-out" || sib_fail 'manual used the scheduled idle reason'
    grep -Fq 'Close terminal t-prefix (local, no dispatch, no agent)' "$tmp/sib-out" || sib_fail 'manual kept a prefix lookalike'
  fi
  grep -Fq 'terminal close --terminal t-idle' "$tmp/sib/closed" || sib_fail "$1 did not close the idle shell"
  grep -Fq 'terminal close --terminal t-stuck' "$tmp/sib/closed" || sib_fail "$1 did not try the stuck shell"
  ! grep -Fq 'closing t-idle on local failed' "$tmp/sib-err" || sib_fail "$1 reported a finished close as failed"
  ! grep -Fq 'terminal t-idle (local):' "$tmp/sib-out" || sib_fail "$1 recorded a failure for a finished close"
  grep -Fq 'closing t-stuck on local failed' "$tmp/sib-err" || sib_fail "$1 hid a terminal that stayed open"
  grep -Fq 'terminal still open after close: t-stuck' "$tmp/sib-out" || sib_fail "$1 did not record the stuck terminal"
  grep -Fq 'terminals closed=2 kept=4' "$tmp/sib-out" || sib_fail "$1 close count"
}
sib_round manual
sib_round scheduled
echo 'ok idle shells in a live worktree stay; a finished close is closed and a live one is a failure'

# git worktree remove can exit non-zero after the worktree is already gone. That is removed, not a failure.
real_git=$(command -v git)
cat > "$tmp/bin/git" <<'FAKE'
#!/usr/bin/env bash
case " $* " in
  *" worktree remove "*)
    "$REAL_GIT" "$@"
    rc=$?
    [ "$rc" -eq 0 ] || exit "$rc"
    exit 1
    ;;
esac
exec "$REAL_GIT" "$@"
FAKE
chmod +x "$tmp/bin/git"
export REAL_GIT="$real_git" ORCA_CLI_COMMAND="$tmp/bin/orca"
unset WRAP_UP_SCHEDULED_CHILD FAKE_TERMINALS FAKE_WORKERS || true
git init -q --bare "$tmp/origin-lie"
git init -q -b main "$tmp/repo-lie"
git -C "$tmp/repo-lie" config user.email test@example.invalid
git -C "$tmp/repo-lie" config user.name Test
git -C "$tmp/repo-lie" commit -qm c --allow-empty
git -C "$tmp/repo-lie" remote add origin "$tmp/origin-lie"
git -C "$tmp/repo-lie" push -q -u origin main
git -C "$tmp/repo-lie" worktree add -q "$tmp/lie-wt" -b lie
env -u WRAP_UP_SCHEDULED_CHILD bash "$here/wrap-up.sh" --apply --repo "$tmp/repo-lie" > "$tmp/lie-out" 2> "$tmp/lie-err" || true
test ! -d "$tmp/lie-wt"
! grep -Fq 'remove failed' "$tmp/lie-out" "$tmp/lie-err"
grep -Fq 'removed worktrees=1' "$tmp/lie-out"
rm -f "$tmp/bin/git"
echo 'ok a worktree remove that exits non-zero after the tree is gone counts as removed'

# Every run, manual or scheduled, closes a sleep-liveness terminal, and a prompt idle for 60 minutes when
# no unsettled dispatch owns it. A dispatch that is running, ready, pending or waiting stays,
# at a prompt or on a working screen. A progress line, a heading and a wait are not prompts.
# An agent with no dispatch record is an owner session and stays. The agent list preview is old
# scrollback; the current screen comes from terminal show.
unset WRAP_UP_SCHEDULED_CHILD || true
now_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
owner_ms=$((now_ms - 1800000))
quiet_ms=$((now_ms - 7200000))
mkdir -p "$tmp/asleep"
cat > "$tmp/bin/orca-asleep" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/calls"
args=("$@"); h=''
for i in "${!args[@]}"; do [ "${args[$i]}" = --terminal ] && h=${args[$((i+1))]}; done
case "$*" in
  'environment list'*)
    if [ -f "$FAKE_DIR/envs" ]; then cat "$FAKE_DIR/envs"; else echo '{"ok":true,"result":{"environments":[]}}'; fi ;;
  *'terminal close'*) printf '%s\n' "$*" >> "$FAKE_DIR/closed"; echo '{"ok":true}' ;;
  *'terminal show'*)
    printf '%s\n' "$h" >> "$FAKE_DIR/shows"
    if [ -f "$FAKE_DIR/screen-$h.json" ]; then cat "$FAKE_DIR/screen-$h.json"
    else jq -c --arg h "$h" '{ok:true, result:{terminal: (.result.terminals[] | select(.handle == $h))}}' "$FAKE_DIR/terminals"
    fi ;;
  *'terminal list'*)
    case "$*" in
      *'--environment '*) if [ -f "$FAKE_DIR/env-terminals" ]; then cat "$FAKE_DIR/env-terminals"; else cat "$FAKE_DIR/terminals"; fi ;;
      *) cat "$FAKE_DIR/terminals" ;;
    esac ;;
  *worker-release*) printf '%s\n' "$*" >> "$FAKE_DIR/releases"; echo '{"ok":true}' ;;
  *worker-show*) echo '{"ok":true,"result":{"state":"ready","liveness":"live","outcome":"in_progress"}}' ;;
  *run-list*) echo '{"ok":true,"result":{"runs":[{"id":"run-1","coordinator_handle":"t-coord"}]}}' ;;
  *worker-list*) cat "$FAKE_DIR/workers" ;;
  *'worktree list'*) echo '{"ok":true,"result":{"worktrees":[]}}' ;;
  *) echo "unexpected: $*" >> "$FAKE_DIR/unexpected"; echo '{"ok":true,"result":{}}' ;;
esac
FAKE
chmod +x "$tmp/bin/orca-asleep"
export FAKE_DIR="$tmp/asleep" ORCA_CLI_COMMAND="$tmp/bin/orca-asleep" ORCA_TERMINAL_HANDLE=t-own
jq -n --argjson now "$now_ms" '{ok:true,result:{workers:[
  {dispatchId:"d-sleep",state:"ready",liveness:"live",outcome:"in_progress",terminalState:"active",terminal:"t-sleep",workspace:"repo::/nowhere/asleep"},
  {dispatchId:"d-agent",state:"ready",liveness:"live",outcome:"in_progress",terminalState:"active",terminal:"t-agent",workspace:"repo::/nowhere/agent"},
  {dispatchId:"d-shell",state:"ready",liveness:"live",outcome:"in_progress",terminalState:"active",terminal:"t-shell",workspace:"repo::/nowhere/shell"},
  {dispatchId:"d-run",state:"ready",liveness:"live",outcome:"in_progress",terminalState:"active",terminal:"t-run",workspace:"repo::/nowhere/running"},
  {dispatchId:"d-quiet",state:"in_progress",dispatchStatus:"running",liveness:"live",outcome:"in_progress",terminalState:"active",terminal:"t-quiet",workspace:"repo::/nowhere/quiet"},
  {dispatchId:"d-pend",state:"in_progress",dispatchStatus:"pending",liveness:"live",outcome:"in_progress",terminalState:"active",terminal:"t-pend",workspace:"repo::/nowhere/pend"},
  {dispatchId:"d-hold",state:"in_progress",dispatchStatus:"waiting",liveness:"live",outcome:"in_progress",terminalState:"active",terminal:"t-hold",workspace:"repo::/nowhere/hold"}
]}}' > "$tmp/asleep/workers"
jq -n --argjson now "$now_ms" --argjson owner "$owner_ms" --argjson quiet "$quiet_ms" '{ok:true,result:{terminals:[
  {handle:"t-sleep",worktreePath:"/nowhere/asleep",connected:true,writable:true,liveness:"sleep",agentIdentity:"claude",lastOutputAt:$now,preview:"compiling objects",title:"agent"},
  {handle:"t-agent",worktreePath:"/nowhere/agent",connected:true,writable:true,liveness:"live",agentIdentity:"claude",lastOutputAt:1,preview:"still working",title:"agent"},
  {handle:"t-shell",worktreePath:"/nowhere/shell",connected:true,writable:true,agentIdentity:null,lastOutputAt:1,preview:"~/work $\n❯",title:"shell"},
  {handle:"t-run",worktreePath:"/nowhere/running",connected:true,writable:true,liveness:"live",agentIdentity:"claude",lastOutputAt:$now,preview:"compiling objects",title:"agent"},
  {handle:"t-owner",worktreePath:"/nowhere/owner",connected:true,writable:true,agentIdentity:null,lastOutputAt:$owner,preview:"~/work $\n❯",title:"shell"},
  {handle:"t-coord",worktreePath:"/nowhere/coord",connected:true,writable:true,agentIdentity:null,lastOutputAt:1,preview:"~/work $\n❯",title:"shell"},
  {handle:"t-quiet",worktreePath:"/nowhere/quiet",connected:true,writable:true,liveness:"live",agentIdentity:"claude",lastOutputAt:$quiet,preview:"building\nlinking 45% complete\nrunning integration suite",title:"agent"},
  {handle:"t-pend",worktreePath:"/nowhere/pend",connected:true,writable:true,liveness:"live",agentIdentity:"claude",lastOutputAt:1,preview:"~/work $\n❯",title:"agent"},
  {handle:"t-hold",worktreePath:"/nowhere/hold",connected:true,writable:true,liveness:"live",agentIdentity:"claude",lastOutputAt:1,preview:"~/work $\n❯",title:"agent"},
  {handle:"t-scroll",worktreePath:"/nowhere/scroll",connected:true,writable:true,liveness:"live",agentIdentity:"claude",lastOutputAt:1,preview:"building\nlinking 45% complete\nrunning integration suite",title:"agent"},
  {handle:"t-hash",worktreePath:"/nowhere/hash",connected:true,writable:true,liveness:"live",agentIdentity:"claude",lastOutputAt:1,preview:"tests running\n# 3 of 40 done",title:"agent"},
  {handle:"t-wait",worktreePath:"/nowhere/wait",connected:true,writable:true,liveness:"live",agentIdentity:"claude",lastOutputAt:1,agentWait:true,preview:"still working",title:"agent"},
  {handle:"t-prompt",worktreePath:"/nowhere/prompt",connected:true,writable:true,liveness:"live",agentIdentity:null,lastOutputAt:1,preview:"~/work $\n❯",title:"shell"},
  {handle:"t-mine",worktreePath:"/nowhere/mine",connected:true,writable:true,liveness:"live",agentIdentity:"claude",lastOutputAt:1,preview:"~/work $\n❯",title:"claude"},
  {handle:"t-mine-asleep",worktreePath:"/nowhere/mine-asleep",connected:true,writable:true,liveness:"sleep",agentIdentity:"claude",lastOutputAt:1,preview:"~/work $\n❯",title:"claude"}
]}}' > "$tmp/asleep/terminals"
jq -n '{ok:true,result:{terminal:{handle:"t-agent",connected:true,writable:true,liveness:"live",agentIdentity:"claude",lastOutputAt:1,preview:"still working\n⏵⏵ bypass permissions on (shift+tab to cycle)\n"}}}' > "$tmp/asleep/screen-t-agent.json"
: > "$tmp/asleep/calls"; : > "$tmp/asleep/shows"; : > "$tmp/asleep/closed"; : > "$tmp/asleep/releases"; : > "$tmp/asleep/unexpected"
git init -q --bare "$tmp/origin-asleep"
git init -q -b main "$tmp/repo-asleep"
git -C "$tmp/repo-asleep" config user.email test@example.invalid
git -C "$tmp/repo-asleep" config user.name Test
git -C "$tmp/repo-asleep" commit -qm c --allow-empty
git -C "$tmp/repo-asleep" remote add origin "$tmp/origin-asleep"
git -C "$tmp/repo-asleep" push -q -u origin main
asleep_fail() { echo "FAIL $1"; cat "$tmp/asleep-out" "$tmp/asleep-err" "$tmp/asleep/shows" "$tmp/asleep/unexpected" 2>/dev/null; exit 1; }
env -u WRAP_UP_SCHEDULED_CHILD WRAP_UP_TOTAL_TIMEOUT=60 \
  bash "$here/wrap-up.sh" --dry-run --repo "$tmp/repo-asleep" > "$tmp/asleep-out" 2> "$tmp/asleep-err" || true
grep -Fq 'Close terminal t-sleep (local, sleep)' "$tmp/asleep-out" || asleep_fail 'manual kept a sleep-liveness terminal'
grep -Fq 'Close terminal t-mine-asleep (local, sleep)' "$tmp/asleep-out" || asleep_fail 'manual kept a sleeping owner session'
grep -Fq 'Close terminal t-prompt (local, idle at prompt)' "$tmp/asleep-out" || asleep_fail 'manual kept an idle prompt'
grep -Fq 'Kept terminal t-mine (local, owner session)' "$tmp/asleep-out" || asleep_fail 'manual closed an owner session'
grep -Fq 'Kept terminal t-agent (local, live dispatch)' "$tmp/asleep-out" || asleep_fail 'manual closed an idle agent'
grep -Fq 'Kept terminal t-shell (local, live dispatch)' "$tmp/asleep-out" || asleep_fail 'manual closed an idle shell'
grep -Fq 'Kept terminal t-run (local, live dispatch)' "$tmp/asleep-out" || asleep_fail 'manual closed a running dispatch'
: > "$tmp/asleep/shows"
WRAP_UP_SCHEDULED_CHILD=1 WRAP_UP_TOTAL_TIMEOUT=60 \
  bash "$here/wrap-up.sh" --dry-run --repo "$tmp/repo-asleep" > "$tmp/asleep-out" 2> "$tmp/asleep-err" || true
grep -Fq 'Close terminal t-sleep (local, sleep)' "$tmp/asleep-out" || asleep_fail 'sleep liveness terminal stayed open'
grep -Fq 'Kept terminal t-agent (local, live dispatch)' "$tmp/asleep-out" || asleep_fail 'ready dispatch at a prompt was closed'
grep -Fq 'Kept terminal t-shell (local, live dispatch)' "$tmp/asleep-out" || asleep_fail 'ready dispatch at a shell prompt was closed'
grep -Fq 'Kept terminal t-quiet (local, live dispatch)' "$tmp/asleep-out" || asleep_fail 'running dispatch idle on a progress line was closed'
grep -Fq 'Kept terminal t-pend (local, live dispatch)' "$tmp/asleep-out" || asleep_fail 'pending dispatch was closed'
grep -Fq 'Kept terminal t-hold (local, live dispatch)' "$tmp/asleep-out" || asleep_fail 'waiting dispatch was closed'
grep -Fq 'Kept terminal t-scroll (local, owner session)' "$tmp/asleep-out" || asleep_fail 'progress line was closed as a prompt'
grep -Fq 'Kept terminal t-hash (local, owner session)' "$tmp/asleep-out" || asleep_fail 'heading line was closed as a prompt'
grep -Fq 'Kept terminal t-wait (local, owner session)' "$tmp/asleep-out" || asleep_fail 'agent wait was closed as a prompt'
grep -Fq 'Close terminal t-prompt (local, idle at prompt)' "$tmp/asleep-out" || asleep_fail 'idle prompt with no dispatch stayed open'
grep -Fq 'Kept terminal t-mine (local, owner session)' "$tmp/asleep-out" || asleep_fail 'scheduled closed an owner session'
grep -Fq 'Kept terminal t-owner (local, no dispatch, no agent, output within 60 minutes)' "$tmp/asleep-out" || asleep_fail 'recent owner shell closed'
grep -Fq 'Kept terminal t-run (local, live dispatch)' "$tmp/asleep-out" || asleep_fail 'running dispatch closed'
grep -Fq 'Kept terminal t-coord (local, coordinator)' "$tmp/asleep-out" || asleep_fail 'coordinator closed'
grep -Fxq t-agent "$tmp/asleep/shows" || asleep_fail 'scheduled round did not read the agent screen'
! grep -Fq 'Close terminal t-run ' "$tmp/asleep-out" || asleep_fail 'running dispatch closed'
! grep -Fq 'Close terminal t-quiet ' "$tmp/asleep-out" || asleep_fail 'running dispatch idle on a progress line was closed'
echo 'ok a scheduled round closes sleep and an idle prompt with no dispatch, and keeps an unsettled dispatch'

# A connected agent with no dispatch stays on a fleet host too. A settled worker stays when the
# screen already read shows a question, a pending ask, or an escalation. A bare prompt is still closed.
echo '{"ok":true,"result":{"environments":[{"id":"env-a"}]}}' > "$tmp/asleep/envs"
q_mail='note (question) ─
❯'
esc_mail='note (escalation) ─
❯'
ask_sent='Question msg_1 sent.
❯'
ask_wait='Question msg_2 is still pending after 1000.
❯'
ask_timeout='ask timeout after 1000ms; question msg_3 is still pending
❯'
prompt='~/work $
❯'
jq -n --arg q "$q_mail" --arg e "$esc_mail" --arg a "$ask_sent" --arg w "$ask_wait" --arg to "$ask_timeout" --arg p "$prompt" \
  '{ok:true,result:{terminals:[
    {handle:"t-fleet",worktreePath:"/nowhere/fleet",connected:true,writable:true,liveness:"live",agentIdentity:"agent",lastOutputAt:1,preview:$p,title:"agent"},
    {handle:"t-question",worktreePath:"/nowhere/question",connected:true,writable:true,liveness:"live",agentIdentity:"agent",lastOutputAt:1,preview:$q,title:"agent"},
    {handle:"t-escalation",worktreePath:"/nowhere/escalation",connected:true,writable:true,liveness:"live",agentIdentity:"agent",lastOutputAt:1,preview:$e,title:"agent"},
    {handle:"t-ask",worktreePath:"/nowhere/ask",connected:true,writable:true,liveness:"live",agentIdentity:"agent",lastOutputAt:1,preview:$a,title:"agent"},
    {handle:"t-ask-wait",worktreePath:"/nowhere/ask-wait",connected:true,writable:true,liveness:"live",agentIdentity:"agent",lastOutputAt:1,preview:$w,title:"agent"},
    {handle:"t-ask-timeout",worktreePath:"/nowhere/ask-timeout",connected:true,writable:true,liveness:"live",agentIdentity:"agent",lastOutputAt:1,preview:$to,title:"agent"},
    {handle:"t-agentwait",worktreePath:"/nowhere/agentwait",connected:true,writable:true,liveness:"live",agentIdentity:"agent",lastOutputAt:1,preview:"still working",title:"agent"},
    {handle:"t-idle-done",worktreePath:"/nowhere/idle-done",connected:true,writable:true,liveness:"live",agentIdentity:"agent",lastOutputAt:1,preview:$p,title:"agent"},
    {handle:"t-null-wait",worktreePath:"/nowhere/null-wait",connected:true,writable:true,liveness:"live",agentIdentity:"agent",lastOutputAt:1,agentWait:null,preview:$p,title:"agent"},
    {handle:"t-sleep-q",worktreePath:"/nowhere/sleep-q",connected:true,writable:true,liveness:"sleep",agentIdentity:"agent",lastOutputAt:1,preview:$q,title:"agent"}
  ]}}' > "$tmp/asleep/env-terminals"
jq -n '{ok:true,result:{workers:[
  {dispatchId:"d-question",state:"succeeded",outcome:"worker_done",terminalState:"released",terminal:"t-question",workspace:"repo::/nowhere/question"},
  {dispatchId:"d-escalation",state:"succeeded",outcome:"worker_done",terminalState:"released",terminal:"t-escalation",workspace:"repo::/nowhere/escalation"},
  {dispatchId:"d-ask",state:"succeeded",outcome:"worker_done",terminalState:"released",terminal:"t-ask",workspace:"repo::/nowhere/ask"},
  {dispatchId:"d-ask-wait",state:"succeeded",outcome:"worker_done",terminalState:"released",terminal:"t-ask-wait",workspace:"repo::/nowhere/ask-wait"},
  {dispatchId:"d-ask-timeout",state:"succeeded",outcome:"worker_done",terminalState:"released",terminal:"t-ask-timeout",workspace:"repo::/nowhere/ask-timeout"},
  {dispatchId:"d-agentwait",state:"succeeded",outcome:"worker_done",terminalState:"released",terminal:"t-agentwait",workspace:"repo::/nowhere/agentwait"},
  {dispatchId:"d-idle-done",state:"succeeded",outcome:"worker_done",terminalState:"released",terminal:"t-idle-done",workspace:"repo::/nowhere/idle-done"},
  {dispatchId:"d-null-wait",state:"succeeded",outcome:"worker_done",terminalState:"released",terminal:"t-null-wait",workspace:"repo::/nowhere/null-wait"},
  {dispatchId:"d-sleep-q",state:"succeeded",outcome:"worker_done",terminalState:"released",terminal:"t-sleep-q",workspace:"repo::/nowhere/sleep-q"}
]}}' > "$tmp/asleep/workers"
jq -n --arg p "$prompt" '{ok:true,result:{terminal:{handle:"t-agentwait",connected:true,writable:true,liveness:"live",agentIdentity:"agent",lastOutputAt:1,preview:$p,agentWait:{reason:"prompt-text",source:"prompt-text"}}}}' > "$tmp/asleep/screen-t-agentwait.json"
human_fail() { echo "FAIL $1"; cat "$tmp/asleep-out" "$tmp/asleep-err" 2>/dev/null; exit 1; }
check_human() {
  local when=$1
  grep -Fq "Kept terminal t-fleet (env-a, owner session)" "$tmp/asleep-out" || human_fail "$when closed a fleet agent with no dispatch"
  ! grep -Fq 'Close terminal t-fleet ' "$tmp/asleep-out" || human_fail "$when closed a fleet agent with no dispatch"
  grep -Fq 'Kept terminal t-question (env-a, waiting on a human)' "$tmp/asleep-out" || human_fail "$when closed a question"
  grep -Fq 'Kept terminal t-escalation (env-a, waiting on a human)' "$tmp/asleep-out" || human_fail "$when closed an escalation"
  grep -Fq 'Kept terminal t-ask (env-a, waiting on a human)' "$tmp/asleep-out" || human_fail "$when closed an ask"
  grep -Fq 'Kept terminal t-ask-wait (env-a, waiting on a human)' "$tmp/asleep-out" || human_fail "$when closed a pending ask"
  grep -Fq 'Kept terminal t-ask-timeout (env-a, waiting on a human)' "$tmp/asleep-out" || human_fail "$when closed an ask that timed out"
  grep -Fq 'Kept terminal t-agentwait (env-a, waiting on a human)' "$tmp/asleep-out" || human_fail "$when closed a screen marked waiting"
  grep -Fq 'Close terminal t-idle-done (env-a, idle at prompt)' "$tmp/asleep-out" || human_fail "$when kept a finished worker at its prompt"
  grep -Fq 'Close terminal t-null-wait (env-a, idle at prompt)' "$tmp/asleep-out" || human_fail "$when kept a screen that is not waiting"
  grep -Fq 'Close terminal t-sleep-q (env-a, sleep)' "$tmp/asleep-out" || human_fail "$when kept a sleeping terminal"
}
env -u WRAP_UP_SCHEDULED_CHILD WRAP_UP_TOTAL_TIMEOUT=60 \
  bash "$here/wrap-up.sh" --dry-run --repo "$tmp/repo-asleep" > "$tmp/asleep-out" 2> "$tmp/asleep-err" || true
check_human manual
WRAP_UP_SCHEDULED_CHILD=1 WRAP_UP_TOTAL_TIMEOUT=60 \
  bash "$here/wrap-up.sh" --dry-run --repo "$tmp/repo-asleep" > "$tmp/asleep-out" 2> "$tmp/asleep-err" || true
check_human scheduled
echo 'ok a fleet agent with no dispatch stays, and a screen waiting on a human stays'
# Issue 953: --apply removes every non-main Orca worktree with no terminal; branches stay, dirty ones are reported.
idle="$tmp/idle953"; mkdir -p "$idle"
git init -q -b main "$idle/repo"
git -C "$idle/repo" config user.email test@example.invalid
git -C "$idle/repo" config user.name Test
echo i > "$idle/repo/file"; git -C "$idle/repo" add file; git -C "$idle/repo" commit -qm initial
git init -q --bare "$idle/origin"
git -C "$idle/repo" remote add origin "$idle/origin"
git -C "$idle/repo" push -q -u origin main
for n in gone live dirty; do
  git -C "$idle/repo" worktree add -qb "i-$n" "$idle/i-$n"
  echo "$n" > "$idle/i-$n/$n.txt"; git -C "$idle/i-$n" add "$n.txt"; git -C "$idle/i-$n" commit -qm "$n"
done
echo changed >> "$idle/i-dirty/dirty.txt"
irepo=$(cd "$idle/repo" && pwd -P); igone=$(cd "$idle/i-gone" && pwd -P); ilive=$(cd "$idle/i-live" && pwd -P); idirty=$(cd "$idle/i-dirty" && pwd -P)
cat > "$tmp/bin/orca-idle953" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'worktree list --json') cat "$FAKE_DIR/wts.json" ;;
  'terminal list --json')
    if [ -n "${FAKE_TRUNC_HOST:-}" ] && [ "$(tail -1 "$FAKE_SSH_LOG" 2>/dev/null)" = "$FAKE_TRUNC_HOST" ]; then
      printf '{"ok":true,"result":{"terminals":[],"truncated":true}}\n'
    else cat "$FAKE_DIR/terms.json"; fi ;;
  'worktree rm --worktree '*) echo "$*" >> "$FAKE_DIR/rm.log"; tail -1 "$FAKE_SSH_LOG" >> "$FAKE_DIR/rm-host.log" 2>/dev/null; case "$*" in *"id:${FAKE_RM_FAIL:-none}"*) exit 1 ;; esac ;;
  *) printf '{"ok":true,"result":{"workers":[],"terminals":[],"runs":[],"page":{"hasMore":false}}}\n' ;;
esac
FAKE
chmod +x "$tmp/bin/orca-idle953"
export FAKE_DIR="$idle" ORCA_CLI_COMMAND="$tmp/bin/orca-idle953"
printf '{"ok":true,"result":{"worktrees":[{"id":"w-main","path":"%s","isMainWorktree":true},{"id":"w-gone","path":"%s"},{"id":"w-live","path":"%s"},{"id":"w-dirty","path":"%s"}]}}\n' \
  "$irepo" "$igone" "$ilive" "$idirty" > "$idle/wts.json"
printf '{"ok":true,"result":{"terminals":[{"handle":"t1","worktreePath":"%s"},{"handle":"t2","worktreePath":"%s"}]}}\n' "$ilive" "$irepo" > "$idle/terms.json"
idle_fail() { echo "FAIL idle worktree sweep: $1"; tail -15 "$tmp/output" "$tmp/stderr" 2>/dev/null; exit 1; }
: > "$idle/rm.log"
bash "$here/wrap-up.sh" --dry-run --worktrees-only --repo "$irepo" > "$tmp/output" 2> "$tmp/stderr" || true
[ ! -s "$idle/rm.log" ] || idle_fail 'a dry run removed something'
has "Remove idle worktree $igone" || idle_fail 'a dry run did not list the idle worktree'
bash "$here/wrap-up.sh" --apply --worktrees-only --repo "$irepo" > "$tmp/output" 2> "$tmp/stderr" || true
grep -Fxq 'worktree rm --worktree id:w-gone --force' "$idle/rm.log" || idle_fail 'the no terminal worktree was not removed with --force'
[ "$(wc -l < "$idle/rm.log" | tr -d ' ')" = 1 ] || idle_fail "only the no terminal worktree may go: $(cat "$idle/rm.log")"
! grep -Fq 'delete-branch' "$idle/rm.log" || idle_fail 'a branch was deleted'
has "Kept idle worktree $idirty (uncommitted changes)" || idle_fail 'the dirty worktree is not named in the report'
echo 'ok idle worktrees go, a terminal, main and dirty ones stay, and a dry run removes nothing'
# One host failing must not stop the next.
printf '{"hosts":[{"host":"down","repo_dir":"%s"},{"host":"alpha","repo_dir":"%s"}]}\n' "$irepo" "$irepo" > "$tmp/fleet.json"
: > "$idle/rm.log"; : > "$FAKE_SSH_LOG"
bash "$here/wrap-up.sh" --apply --fleet > "$tmp/output" 2> "$tmp/stderr" || true
grep -Fxq alpha "$FAKE_SSH_LOG" || idle_fail 'the host after a failing one was not reached'
grep -Fxq 'worktree rm --worktree id:w-gone --force' "$idle/rm.log" || idle_fail 'the host after a failing one was not swept'
echo 'ok a failing host does not stop the sweep on the next'
# A failing remove is reported and does not stop the rest.
printf '{"ok":true,"result":{"worktrees":[{"id":"w-main","path":"%s","isMainWorktree":true},{"id":"w-bad","path":"%s/nope1"},{"id":"w-gone","path":"%s"}]}}\n' "$irepo" "$idle" "$igone" > "$idle/wts.json"
: > "$idle/rm.log"
FAKE_RM_FAIL=w-bad bash "$here/wrap-up.sh" --apply --worktrees-only --repo "$irepo" > "$tmp/output" 2> "$tmp/stderr" || true
grep -Fxq 'worktree rm --worktree id:w-gone --force' "$idle/rm.log" || idle_fail 'a failed remove stopped the next one'
grep -Fq 'idle worktree' "$tmp/stderr" || idle_fail 'a failed remove was not reported'
echo 'ok a failed remove is reported and the next worktree still goes'
# A truncated terminal list proves nothing, so that host removes nothing and the next host still runs.
printf '{"hosts":[{"host":"short","repo_dir":"%s"},{"host":"alpha","repo_dir":"%s"}]}\n' "$irepo" "$irepo" > "$tmp/fleet.json"
printf '{"ok":true,"result":{"worktrees":[{"id":"w-main","path":"%s","isMainWorktree":true},{"id":"w-gone","path":"%s"}]}}\n' "$irepo" "$igone" > "$idle/wts.json"
: > "$idle/rm.log"; : > "$idle/rm-host.log"; : > "$FAKE_SSH_LOG"
FAKE_TRUNC_HOST=short bash "$here/wrap-up.sh" --apply --fleet > "$tmp/output" 2> "$tmp/stderr" || true
grep -Fxq alpha "$FAKE_SSH_LOG" || idle_fail 'the host after a truncated one was not reached'
! grep -Fxq short "$idle/rm-host.log" || idle_fail 'the host with a truncated terminal list removed a worktree'
grep -Fxq alpha "$idle/rm-host.log" || idle_fail 'the host after a truncated one did not sweep'
grep -Fq 'cannot read the terminal list' "$tmp/output" "$tmp/stderr" || idle_fail 'the truncated list was not reported'
: > "$idle/rm.log"; : > "$FAKE_SSH_LOG"; echo local >> "$FAKE_SSH_LOG"
FAKE_TRUNC_HOST=local bash "$here/wrap-up.sh" --apply --worktrees-only --repo "$irepo" > "$tmp/output" 2> "$tmp/stderr" || true
[ ! -s "$idle/rm.log" ] || idle_fail 'a truncated terminal list still removed a worktree'
echo 'ok a truncated terminal list removes nothing on that host and the next host still runs'
