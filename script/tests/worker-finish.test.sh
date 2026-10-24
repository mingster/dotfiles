#!/usr/bin/env bash
# Tests for worker-finish.sh: head-checks gate before anything is released, closed or removed.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null WORKER_PANE_CLOSE="$tmp/none"
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

git init -q "$tmp/main" && git -C "$tmp/main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
cat > "$tmp/orca" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
EOS
cat > "$tmp/checks-pass" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$CHECKS_LOG"; echo "head-checks: PASS"; exit 0
EOS
cat > "$tmp/checks-fail" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$CHECKS_LOG"; echo "head-checks: FAIL"; exit 1
EOS
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
[ -n "${GH_STATE:-}" ] && echo "$GH_STATE"
EOS
chmod +x "$tmp/orca" "$tmp/checks-pass" "$tmp/checks-fail" "$tmp/bin/gh"
export ORCA_CLI_COMMAND="$tmp/orca" ORCA_LOG="$tmp/orca.log" CHECKS_LOG="$tmp/checks.log" PATH="$tmp/bin:$PATH"

newwt() { git -C "$tmp/main" worktree add -q "$tmp/$1" -b "$1"; }
run() { (cd "${REPO:-$tmp/main}" && "$@") >"$tmp/out" 2>"$tmp/err"; echo $? >"$tmp/rc"; }
reset() { : > "$ORCA_LOG"; : > "$CHECKS_LOG"; }

# 1. failing checks refuse, touch nothing
newwt w1; reset
HEAD_CHECKS="$tmp/checks-fail" run bash "$here/worker-finish.sh" --worktree "$tmp/w1" --dispatch d1
[ "$(cat "$tmp/rc")" = 1 ] && ok || bad "failing checks exit 1"
grep -q "worker-finish: head-checks failed, refusing worker_done" "$tmp/err" && ok || bad "failing checks message"
[ -d "$tmp/w1" ] && ok || bad "failing checks keep worktree"
[ ! -s "$ORCA_LOG" ] && ok || bad "failing checks leave dispatch untouched"
grep -q -- "--repo .*w1 --ref HEAD --base origin/main" "$CHECKS_LOG" && ok || bad "checks called with repo, ref, base"

# 2. passing checks proceed
reset
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/worker-finish.sh" --worktree "$tmp/w1" --dispatch d1
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "passing checks exit 0"
[ ! -d "$tmp/w1" ] && ok || bad "passing checks remove worktree"
grep -q "worker-release --dispatch d1" "$ORCA_LOG" && ok || bad "passing checks release dispatch"

# 3. skip flag needs a reason, prints it, skips the checks
newwt w2; reset
HEAD_CHECKS="$tmp/checks-fail" run bash "$here/worker-finish.sh" --worktree "$tmp/w2" --skip-head-checks
[ "$(cat "$tmp/rc")" = 2 ] && ok || bad "skip without reason exits 2"
[ -d "$tmp/w2" ] && ok || bad "skip without reason keeps worktree"
HEAD_CHECKS="$tmp/checks-fail" run bash "$here/worker-finish.sh" --worktree "$tmp/w2" --skip-head-checks ""
[ "$(cat "$tmp/rc")" = 2 ] && ok || bad "skip with empty reason exits 2"
HEAD_CHECKS="$tmp/checks-fail" run bash "$here/worker-finish.sh" --worktree "$tmp/w2" --skip-head-checks "docs only"
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "skip with reason exits 0"
grep -q "docs only" "$tmp/out" "$tmp/err" && ok || bad "skip prints the reason"
[ ! -s "$CHECKS_LOG" ] && ok || bad "skip does not run checks"

# 4. DRY_RUN prints, runs nothing
newwt w3; reset
DRY_RUN=1 HEAD_CHECKS="$tmp/checks-fail" run bash "$here/worker-finish.sh" --worktree "$tmp/w3" --dispatch d3
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "dry run exit 0"
grep -q "\[dry-run\].*checks-fail" "$tmp/out" && ok || bad "dry run prints the checks command"
[ -d "$tmp/w3" ] && [ ! -s "$CHECKS_LOG" ] && ok || bad "dry run executes nothing"

# 5. missing head-checks script refuses, touches nothing
newwt w4; reset
HEAD_CHECKS="$tmp/does-not-exist" run bash "$here/worker-finish.sh" --worktree "$tmp/w4" --dispatch d4
[ "$(cat "$tmp/rc")" = 1 ] && ok || bad "missing checks exit 1"
grep -q "worker-finish: head-checks failed, refusing worker_done" "$tmp/err" && ok || bad "missing checks message"
[ -d "$tmp/w4" ] && ok || bad "missing checks keep worktree"
[ ! -s "$ORCA_LOG" ] && ok || bad "missing checks leave dispatch untouched"

# 6. post-merge: a head already in origin/main, or a merged PR, skips the checks without blocking
git init -q -b main "$tmp/up" && git -C "$tmp/up" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git clone -q "$tmp/up" "$tmp/m2"
git -C "$tmp/m2" worktree add -q "$tmp/w5" -b w5 origin/main 2>/dev/null
git -C "$tmp/w5" -c user.name=t -c user.email=t@t commit -q --allow-empty -m work
git -C "$tmp/up" fetch -q "$tmp/m2" w5 && git -C "$tmp/up" merge -q --ff-only FETCH_HEAD
reset
REPO="$tmp/m2" HEAD_CHECKS="$tmp/checks-fail" run bash "$here/worker-finish.sh" --worktree "$tmp/w5" --dispatch d5
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "merged head exits 0"
grep -q "skipping head-checks, HEAD is already in origin/main" "$tmp/out" && ok || bad "merged head prints one skip line"
[ ! -s "$CHECKS_LOG" ] && ok || bad "merged head does not run checks"
[ ! -d "$tmp/w5" ] && ok || bad "merged head removes worktree"
git -C "$tmp/m2" worktree add -q "$tmp/w6" -b w6 origin/main 2>/dev/null
git -C "$tmp/w6" -c user.name=t -c user.email=t@t commit -q --allow-empty -m squashed
reset
REPO="$tmp/m2" GH_STATE=OPEN HEAD_CHECKS="$tmp/checks-fail" run bash "$here/worker-finish.sh" --worktree "$tmp/w6" --dispatch d6
[ "$(cat "$tmp/rc")" = 1 ] && ok || bad "unmerged head with open PR still runs failing checks"
[ -s "$CHECKS_LOG" ] && [ -d "$tmp/w6" ] && ok || bad "unmerged head runs checks and keeps worktree"
reset
REPO="$tmp/m2" GH_STATE=MERGED HEAD_CHECKS="$tmp/checks-fail" run bash "$here/worker-finish.sh" --worktree "$tmp/w6" --dispatch d6
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "merged PR exits 0"
grep -q "skipping head-checks, its PR is already merged" "$tmp/out" && ok || bad "merged PR prints one skip line"
[ ! -s "$CHECKS_LOG" ] && ok || bad "merged PR does not run checks"

echo "worker-finish tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
