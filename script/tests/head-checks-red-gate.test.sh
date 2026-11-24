#!/usr/bin/env bash
# #1746: a gate that breaks on its own (`infra:` in a failed step's output) files one deduped
# `red gate: <tool>` issue and the Checks receipt says `blocked by red gate #<n>`. A plain test failure
# files nothing. The forge is a stub; no live gh.
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd -P)
runner="$here/head-checks.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
s=$GH_STATE
case "$1 $2" in
  "pr view") printf '{"headRefOid":"%s","baseRefOid":"%s"}\n' "$GH_HEAD" "$GH_BASE" ;;
  "pr comment") cp "${@: -1}" "$s/receipt" ;;
  "issue list") if [ -f "$s/issue" ]; then echo '[{"number":41,"title":"red gate: run-scoped-tests"}]'; else echo '[]'; fi ;;
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

run_case() { # run_case <name> <conf line> -> receipt in $tmp/state/receipt
  local name=$1 conf=$2 head
  printf '%s\n' "$conf" > "$repo/.agents/head-checks.conf"
  echo "$name" > "$repo/code.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$name"
  head=$(git -C "$repo" rev-parse HEAD)
  rm -f "$tmp/state/receipt"
  set +e
  env PATH="$tmp/bin:$PATH" GH_STATE="$tmp/state" GH_HEAD="$head" GH_BASE="$base" HOME="$tmp/home" \
    HEAD_CHECKS_DB_PROBE="$tmp/bin/pgok" HEAD_CHECKS_WAIT_SECONDS=0 HEAD_CHECKS_SLOTS=1 \
    /bin/bash "$runner" --repo "$repo" --pr 7 >"$tmp/out" 2>&1
  rc=$?
  set -e
}
fail() { echo "FAIL: $*"; echo "--- out"; cat "$tmp/out" 2>/dev/null; echo "--- receipt"; cat "$tmp/state/receipt" 2>/dev/null; exit 1; }

run_case infra-first "printf 'infra: run-scoped-tests: usage error (exit 2)\n' >&2; exit 2"
[ "$rc" -eq 1 ] || fail "infra failure should exit 1, got $rc"
head -1 "$tmp/state/receipt" | grep -q '^Checks: INFRA head=' || fail "receipt is not INFRA"
grep -q '^blocked by red gate #41 (run-scoped-tests)$' "$tmp/state/receipt" || fail "receipt lacks the blocked line"
[ "$(wc -l < "$tmp/state/creates")" -eq 1 ] || fail "expected one issue create"
grep -q -- '--title red gate: run-scoped-tests' "$tmp/state/creates" || fail "wrong title"
grep -q -- '--label P1 --label ready-for-agent' "$tmp/state/creates" || fail "wrong labels"
echo "ok first infra failure files one P1 ready-for-agent issue and the receipt names it"

run_case infra-second "printf 'infra: run-scoped-tests: internal error\n' >&2; exit 70"
[ "$(wc -l < "$tmp/state/creates")" -eq 1 ] || fail "a second failure opened a second issue"
[ "$(wc -l < "$tmp/state/comments")" -eq 1 ] || fail "second failure should comment once"
grep -q '^blocked by red gate #41' "$tmp/state/receipt" || fail "second receipt lacks the blocked line"
echo "ok a second failure of the same tool updates the open issue"

run_case plain-failure "printf 'not ok 1 a real test failed\n'; exit 1"
head -1 "$tmp/state/receipt" | grep -q '^Checks: FAIL head=' || fail "plain failure is not FAIL"
! grep -q 'blocked by red gate' "$tmp/state/receipt" || fail "plain failure was blamed on a gate"
[ "$(wc -l < "$tmp/state/creates")" -eq 1 ] && [ "$(wc -l < "$tmp/state/comments")" -eq 1 ] || fail "plain failure touched the red gate issue"
echo "ok a test failure files nothing"

# A receipt cut to the cap keeps the blocked line, or fleet-watch would rerun the PR against the broken gate.
export HEAD_CHECKS_RECEIPT_CAP=1500
# Over 40 log lines sit after the blocked line, so only the metadata group can keep it.
many=$(for i in $(seq 1 20); do printf 'echo step-%s\n' "$i"; done)
run_case infra-long "$many
printf 'infra: run-scoped-tests: usage error (exit 2)\n' >&2; exit 2"
grep -q 'Receipt cut to fit' "$tmp/state/receipt" || fail "receipt was not cut, the case proves nothing"
grep -q '^blocked by red gate #41 (run-scoped-tests)$' "$tmp/state/receipt" || fail "the cut receipt lost the blocked line"
echo "ok a cut receipt keeps the blocked line"
