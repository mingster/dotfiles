#!/usr/bin/env bash
# Tests for script/check-pr-body.sh (#1676): the pr-body-gate check, run before a PR opens.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/asdf-pin.sh
. "$ROOT/script/tests/lib/asdf-pin.sh"
SCRIPT="$ROOT/script/check-pr-body.sh"
TMP="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
cd "$TMP" || exit 1  # outside any checkout, so no branch diff applies unless a case sets one up
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

good() {
  cat <<'B'
Closes #5

Builder: agent=claude model=claude-sonnet-5-5

## Self-check
$ bash script/checks-local.sh 2>&1 | tail -3
all checks passed
B
}
run() { out=$(bash "$SCRIPT" "$@" 2>&1); rc=$?; }

good >"$TMP/good.md"
run "$TMP/good.md"
[ "$rc" -eq 0 ] && ok "a full body passes" || bad "full body (rc=$rc, $out)"

grep -v '^## Self-check' "$TMP/good.md" >"$TMP/nosc.md"
run "$TMP/nosc.md"
if [ "$rc" -eq 1 ] && grep -qF "## Self-check" <<<"$out"; then ok "a body with no Self-check heading is refused and names the section"; else bad "no Self-check (rc=$rc, $out)"; fi

sed '/^\$ bash/d;/^all checks/d' "$TMP/good.md" >"$TMP/empty.md"
run "$TMP/empty.md"
if [ "$rc" -eq 1 ] && grep -qF "## Self-check" <<<"$out" && grep -qi "command" <<<"$out"; then ok "an empty Self-check is refused"; else bad "empty Self-check (rc=$rc, $out)"; fi

grep -v '^Builder:' "$TMP/good.md" >"$TMP/nob.md"
run "$TMP/nob.md"
if [ "$rc" -eq 1 ] && grep -qF "Builder:" <<<"$out"; then ok "a body with no Builder line is refused and names it"; else bad "no Builder (rc=$rc, $out)"; fi

run --issue 5 "$TMP/good.md"
[ "$rc" -eq 0 ] && ok "--issue with its closing line passes" || bad "--issue pass (rc=$rc, $out)"
run --issue 6 "$TMP/good.md"
if [ "$rc" -eq 1 ] && grep -qF "Closes #6" <<<"$out"; then ok "--issue without its closing line is refused"; else bad "--issue 6 (rc=$rc, $out)"; fi

run --issue '#6' "$TMP/good.md"
[ "$rc" -eq 1 ] && ok "--issue '#6' is read as 6 and refused without its closing line" || bad "hash issue (rc=$rc, $out)"
run --issue abc "$TMP/good.md"
[ "$rc" -eq 2 ] && ok "a non numeric --issue is a usage error" || bad "abc (rc=$rc)"

mkdir "$TMP/bin"
printf '#!/usr/bin/env bash\necho "$*" >"%s/gh.args"; echo "${2##*/}"\n' "$TMP" >"$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
PATH="$TMP/bin:$PATH"
# --title runs check-pr-body-issues.sh (#1688): a body that skips a title issue fails.
run --title "fix: thing (#5)" "$TMP/good.md"
[ "$rc" -eq 0 ] && ok "--title whose issue the body closes passes" || bad "title pass (rc=$rc, $out)"
run --title "fix: thing (#5) (#7)" "$TMP/good.md"
if [ "$rc" -eq 1 ] && grep -qF "#7" <<<"$out"; then ok "--title naming an issue the body skips is refused"; else bad "title skip (rc=$rc, $out)"; fi

run --title "fix: thing (#5)" --repo o/r "$TMP/good.md"
if [ "$rc" -eq 0 ] && grep -qF "repos/o/r/issues/5" "$TMP/gh.args"; then ok "--repo is passed to the issue lookup"; else bad "--repo (rc=$rc, $(cat "$TMP/gh.args"))"; fi

# #1882: --diff turns on the Readers: rule, --asked no the Decisions: rule.
cat >"$TMP/shared.diff" <<'D'
diff --git a/lib/shared.py b/lib/shared.py
--- a/lib/shared.py
+++ b/lib/shared.py
@@ -1,2 +1,2 @@ def shared(x):
-    return x
+    return x + 1
D
run --diff "$TMP/shared.diff" "$TMP/good.md"
if [ "$rc" -eq 1 ] && grep -qF "Readers:" <<<"$out" && grep -qF "shared" <<<"$out"; then ok "--diff changing a shared function refuses a body without Readers:"; else bad "--diff no Readers (rc=$rc, $out)"; fi
{ cat "$TMP/good.md"; printf '\nReaders:\n- shared: script/tests/test_shared.py covers both callers\n'; } >"$TMP/readers.md"
run --diff "$TMP/shared.diff" "$TMP/readers.md"
[ "$rc" -eq 0 ] && ok "--diff with a Readers: section naming the function passes" || bad "--diff Readers (rc=$rc, $out)"
run --asked no "$TMP/good.md"
if [ "$rc" -eq 1 ] && grep -qF "Decisions:" <<<"$out"; then ok "--asked no refuses a body without Decisions:"; else bad "--asked no (rc=$rc, $out)"; fi
run --asked yes "$TMP/good.md"
[ "$rc" -eq 0 ] && ok "--asked yes needs no Decisions:" || bad "--asked yes (rc=$rc, $out)"
run --asked maybe "$TMP/good.md"
[ "$rc" -eq 2 ] && ok "--asked other than yes or no is a usage error" || bad "--asked maybe (rc=$rc)"

# With no --diff, a checkout's branch diff against origin/main is the diff (the PR is not open yet).
g() { git -C "$TMP/repo" -c user.name=t -c user.email=t@example.test "$@" >/dev/null 2>&1; }
git init -q --bare "$TMP/origin.git"
git init -q -b main "$TMP/repo"
mkdir "$TMP/repo/lib"
printf 'def shared(x):\n    a = x\n    b = a\n    c = b\n    return c\n' >"$TMP/repo/lib/shared.py"
g add -A; g commit -m base; g remote add origin "$TMP/origin.git"; g push origin main; g fetch origin
g checkout -b feat
printf 'def shared(x):\n    a = x\n    b = a\n    c = b\n    return c + 1\n' >"$TMP/repo/lib/shared.py"
g commit -am change
out=$(cd "$TMP/repo" && bash "$SCRIPT" "$TMP/good.md" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -qF "Readers:" <<<"$out"; then ok "no --diff: the branch diff against origin/main turns on Readers:"; else bad "git default diff (rc=$rc, $out)"; fi
out=$(cd "$TMP/repo" && bash "$SCRIPT" "$TMP/readers.md" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "no --diff: a Readers: section passes the branch diff" || bad "git default Readers (rc=$rc, $out)"

# #2065: a "# perf-paths:" line in the checkout's head-checks.conf asks for a Perf: line.
mkdir -p "$TMP/repo/.agents"
echo '# perf-paths: web/src/' >"$TMP/repo/.agents/head-checks.conf"
printf 'diff --git a/web/src/a.ts b/web/src/a.ts\n+x\n' >"$TMP/web.diff"
out=$(cd "$TMP/repo" && bash "$SCRIPT" --diff "$TMP/web.diff" "$TMP/good.md" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -qF "because the diff touches web/src/a.ts" <<<"$out"; then ok "a perf path without Perf: is refused"; else bad "perf refused (rc=$rc, $out)"; fi
{ cat "$TMP/good.md"; printf '\nPerf: n/a: no data reads changed\n'; } >"$TMP/perf.md"
out=$(cd "$TMP/repo" && bash "$SCRIPT" --diff "$TMP/web.diff" "$TMP/perf.md" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "a Perf: line passes a perf path" || bad "perf pass (rc=$rc, $out)"
# #2070: run from outside the target checkout.
run --repo-dir "$TMP/repo" --diff "$TMP/web.diff" "$TMP/good.md"
if [ "$rc" -eq 1 ] && grep -qF "because the diff touches web/src/a.ts" <<<"$out"; then ok "--repo-dir from outside the checkout refuses a missing Perf:"; else bad "repo-dir perf (rc=$rc, $out)"; fi
run --repo-dir "$TMP/repo" "$TMP/good.md"
if [ "$rc" -eq 1 ] && grep -qF "Readers:" <<<"$out"; then ok "--repo-dir without --diff reads the target checkout's branch diff"; else bad "repo-dir diff (rc=$rc, $out)"; fi
run --repo-dir "$TMP/nowhere" "$TMP/good.md"
[ "$rc" -eq 2 ] && ok "a missing --repo-dir is a usage error" || bad "repo-dir missing (rc=$rc)"

run "$TMP/missing.md"
[ "$rc" -eq 2 ] && ok "a missing file is a usage error" || bad "missing file (rc=$rc)"
run
[ "$rc" -eq 2 ] && ok "no arguments is a usage error" || bad "usage (rc=$rc)"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
