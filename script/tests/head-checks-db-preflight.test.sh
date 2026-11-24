#!/usr/bin/env bash
# #1745: a "# db-preflight: <command>" line runs once before the first database step, under its own Command line.
# A failure ends the run as INFRA with an `infra:` line (#1746 files the red gate); a pass leaves the database step
# under its own Command line, so a later failure names the database step. The forge is a stub; no live gh.
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd -P)
runner="$here/head-checks.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state" "$tmp/home"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
s=$GH_STATE
case "$1 $2" in
  "pr view") printf '{"headRefOid":"%s","baseRefOid":"%s"}\n' "$GH_HEAD" "$GH_BASE" ;;
  "pr comment") cp "${@: -1}" "$s/receipt" ;;
  "issue list") if [ -f "$s/issue" ]; then echo '[{"number":41,"title":"red gate: test-database"}]'; else echo '[]'; fi ;;
  "issue create") printf "%s\n" "${*//$'\n'/ }" >> "$s/creates"; touch "$s/issue"; echo https://github.com/o/r/issues/41 ;;
  "issue comment") printf "%s\n" "${*//$'\n'/ }" >> "$s/comments" ;;
  *) echo "gh stub: unexpected $*" >&2; exit 1 ;;
esac
GH
chmod +x "$tmp/bin/gh"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/pgok"; chmod +x "$tmp/bin/pgok"

repo="$tmp/repo"
mkdir -p "$repo/.agents"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@example.invalid
git -C "$repo" config user.name t
echo base > "$repo/code.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm base
base=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" update-ref refs/remotes/origin/main "$base"

run_case() { # run_case <name> <conf text> -> receipt in $tmp/state/receipt
  local name=$1 conf=$2 head
  printf '%s\n' "$conf" > "$repo/.agents/head-checks.conf"
  echo "$name" > "$repo/code.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$name"
  head=$(git -C "$repo" rev-parse HEAD)
  rm -f "$tmp/state/receipt" "$tmp/state/issue" "$tmp/state/creates" "$tmp/state/comments" "$tmp/db-ran"
  set +e
  env PATH="$tmp/bin:$PATH" GH_STATE="$tmp/state" GH_HEAD="$head" GH_BASE="$base" HOME="$tmp/home" \
    HEAD_CHECKS_DB_PROBE="$tmp/bin/pgok" HEAD_CHECKS_WAIT_SECONDS=0 HEAD_CHECKS_SLOTS=1 \
    /bin/bash "$runner" --repo "$repo" --pr 7 >"$tmp/out" 2>&1
  rc=$?
  set -e
}
fail() { echo "FAIL: $*"; echo "--- out"; cat "$tmp/out" 2>/dev/null; echo "--- receipt"; cat "$tmp/state/receipt" 2>/dev/null; exit 1; }
last_command() { grep '^Command: ' "$tmp/state/receipt" | tail -1; }
db_step="echo ran >> $tmp/db-ran; exit 1 # db"

run_case preflight-fails "# db-preflight: echo 'shard is 3 migrations behind' >&2; exit 3
$db_step"
[ "$rc" -eq 1 ] || fail "a failing preflight should exit 1, got $rc"
head -1 "$tmp/state/receipt" | grep -q '^Checks: INFRA head=' || fail "receipt is not INFRA"
grep -q '^infra: shared database behind main, not this PR$' "$tmp/state/receipt" || fail "receipt lacks the infra line"
grep -q 'shard is 3 migrations behind' "$tmp/state/receipt" || fail "receipt lacks the preflight output"
[ ! -f "$tmp/db-ran" ] || fail "the database step ran after a failed preflight"
[ "$(last_command)" = "Command: echo 'shard is 3 migrations behind' >&2; exit 3" ] || fail "the failure is not under the preflight Command line: $(last_command)"
grep -q '^blocked by red gate #41 (test-database)$' "$tmp/state/receipt" || fail "receipt lacks the red gate line"
echo "ok a failing preflight stops the run as INFRA under its own Command line and files the red gate"

run_case preflight-passes "# db-preflight: exit 0
$db_step"
[ "$rc" -eq 1 ] || fail "the failing database step should exit 1, got $rc"
head -1 "$tmp/state/receipt" | grep -q '^Checks: FAIL head=' || fail "receipt is not FAIL"
[ -f "$tmp/db-ran" ] || fail "the database step did not run after a passing preflight"
[ "$(last_command)" = "Command: $db_step" ] || fail "the failure is not under the database step Command line: $(last_command)"
grep -q '^Command: exit 0$' "$tmp/state/receipt" || fail "the preflight has no Command line"
! grep -q 'red gate' "$tmp/state/receipt" || fail "a database step failure was blamed on a gate"
echo "ok a passing preflight leaves the database step under its own Command line"

run_case no-db-step "# db-preflight: exit 3
exit 0"
[ "$rc" -eq 0 ] || fail "a preflight with no database step must not run, got rc=$rc"
echo "ok the preflight does not run when no step needs the database"
