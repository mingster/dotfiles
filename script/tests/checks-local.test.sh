#!/usr/bin/env bash
# Tests for script/checks-local.sh: on a fixture diff it selects the same tests as the
# script-tests job (select-changed-script-tests.sh on the diff file list).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail=0
r="$tmp/repo"
mkdir -p "$r/script/tests/lib" "$r/script/lib"
cp "$src/script/checks-local.sh" "$src/script/select-changed-script-tests.sh" "$r/script/"
cp "$src/script/tests/lib/asdf-pin.sh" "$r/script/tests/lib/"
cp "$src/script/lib/hooks-changed.sh" "$r/script/lib/"
git -C "$r" init -q -b main
git -C "$r" -c user.email=t@t -c user.name=t add -A
git -C "$r" -c user.email=t@t -c user.name=t commit -qm base
git -C "$r" checkout -qb topic
printf '#!/usr/bin/env bash\n' >"$r/script/foo.sh"
printf '#!/usr/bin/env bash\n' >"$r/script/tests/foo.test.sh"
printf '#!/usr/bin/env bash\n' >"$r/script/tests/bar.test.sh"
git -C "$r" add -A
git -C "$r" -c user.email=t@t -c user.name=t commit -qm change

: >"$tmp/some.pattern"
got=$(NO_PROJECT_NAMES_FILE="$tmp/some.pattern" bash "$r/script/checks-local.sh" --list-only --base main 2>&1)
want=$(bash "$r/script/select-changed-script-tests.sh" --list-only \
  script/foo.sh script/tests/bar.test.sh script/tests/foo.test.sh 2>&1)
if [ -n "$got" ] && [ "$got" = "$want" ]; then
  echo "ok: selection matches the workflow's"
else
  echo "FAIL: selection differs"; echo "got:"; echo "$got"; echo "want:"; echo "$want"; fail=1
fi

# 940. The summary repeats the no-project-names SKIPPED line when no pattern file is set.
got=$(NO_PROJECT_NAMES_FILE="$tmp/none.pattern" bash "$r/script/checks-local.sh" --list-only --base main 2>&1)
if grep -qxF 'SKIPPED no-project-names.test.sh (no pattern file; CI runs this)' <<<"$got"; then
  echo "ok: summary repeats SKIPPED"
else
  echo "FAIL: summary lacks SKIPPED line"; echo "$got"; fail=1
fi
got=$(NO_PROJECT_NAMES_FILE="$tmp/some.pattern" bash "$r/script/checks-local.sh" --list-only --base main 2>&1)
if grep -q SKIPPED <<<"$got"; then echo "FAIL: SKIPPED shown with a pattern file"; fail=1; else echo "ok: no SKIPPED with a pattern file"; fi

# 1200. The hook tests run only when a hook, brief-lint.sh or checks-local.sh changed.
. "$src/script/lib/hooks-changed.sh"
hc() { hooks_changed "$@" && echo yes || echo no; }
for c in "docs/readme.md script/ship.sh:no" "templates/agent-team/.claude/hooks/guard.py:yes" ".claude/hooks/x.sh docs/a.md:yes" "script/brief-lint.sh:yes" "script/checks-local.sh:yes" ":no"; do
  files=${c%:*}; want=${c##*:}
  # shellcheck disable=SC2086
  got=$(hc $files)
  if [ "$got" = "$want" ]; then echo "ok: hooks_changed '$files' is $want"; else echo "FAIL: hooks_changed '$files' got $got want $want"; fail=1; fi
done
if grep -q '^if hooks_changed ' "$src/script/checks-local.sh" && ! grep -B1 'unittest discover' "$src/script/checks-local.sh" | grep -qv 'hooks_changed\|unittest'; then
  echo "ok: checks-local gates the hook tests on hooks_changed"
else echo "FAIL: checks-local does not gate the hook tests"; fail=1; fi

# 1414. On Darwin the macOS-only skip-listed tests run; heavy-gate ones stay skipped until isolated. Elsewhere all stay skipped.
r2="$tmp/repo2"
cp -R "$r" "$r2"
git -C "$r2" checkout -q topic
printf '#!/usr/bin/env bash\n' >"$r2/script/tests/mac-only.test.sh"
printf '#!/usr/bin/env bash\n' >"$r2/script/tests/lock-user.test.sh"
cat >"$r2/script/script-test-skip.list" <<'LIST'
# comment
script/tests/mac-only.test.sh needs macOS hdiutil; rerun on macOS
script/tests/lock-user.test.sh uses heavy-gate host lock; rerun on coordinator host
LIST
git -C "$r2" add -A
git -C "$r2" -c user.email=t@t -c user.name=t commit -qm skip
darwin=$(env -u SELECT_SCRIPT_TESTS_SKIP NO_PROJECT_NAMES_FILE="$tmp/some.pattern" CHECKS_LOCAL_OS=Darwin bash "$r2/script/checks-local.sh" --list-only --base main 2>&1)
linux=$(env -u SELECT_SCRIPT_TESTS_SKIP NO_PROJECT_NAMES_FILE="$tmp/some.pattern" CHECKS_LOCAL_OS=Linux bash "$r2/script/checks-local.sh" --list-only --base main 2>&1)
if grep -qxF 'Selected: script/tests/mac-only.test.sh' <<<"$darwin" && grep -qxF 'Skipped: script/tests/lock-user.test.sh' <<<"$darwin"; then
  echo "ok: Darwin selects the macOS test and skips the unisolated heavy-gate test"
else echo "FAIL: Darwin selection"; echo "$darwin"; fail=1; fi
if grep -qxF 'Skipped: script/tests/mac-only.test.sh' <<<"$linux" && grep -qxF 'Skipped: script/tests/lock-user.test.sh' <<<"$linux"; then
  echo "ok: non Darwin skips both"
else echo "FAIL: non Darwin selection"; echo "$linux"; fail=1; fi

# 1414. The three heavy-gate tests point HOME (and so the heavy-gate lock) at a temp dir before they touch anything.
for t in heavy-gate fleet-watch-heavy-gate heavy-guard-hook; do
  if grep -q '^HOME=$(mktemp -d)' "$src/script/tests/$t.test.sh"; then echo "ok: $t.test.sh uses a temp HOME"
  else echo "FAIL: $t.test.sh does not set a temp HOME"; fail=1; fi
done
# Once isolated and passing, the three heavy-gate tests run on macOS (heavy-gate.test.sh joined after #1665).
if [ "$(grep -c '^script/tests/.*heavy.*rerun on macOS$' "$src/script/script-test-skip.list")" -eq 3 ]; then echo "ok: isolated heavy-gate tests tagged for macOS"
else echo "FAIL: heavy-gate skip entries not tagged for macOS"; fail=1; fi

[ "$fail" -eq 0 ]
