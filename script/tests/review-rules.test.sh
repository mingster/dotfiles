#!/usr/bin/env bash
# Review rules (#760): same agent/model refusal and coordinator Cursor verdict gates.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/merge-fixture.sh
. "$here/tests/lib/merge-fixture.sh"
# shellcheck source=lib/asdf-pin.sh
. "$here/tests/lib/asdf-pin.sh"
mf_setup
trap 'mf_teardown; rm -f "$here/lead-merge.local.json"' EXIT
cd "$MF_REPO" || exit 1

cat > "$MF_DIR/fake-orca" <<'EOS'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "orchestration worker-show" ]; then
  id=""
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --dispatch) id=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$id" in
    ctx_builder) printf '%s\n' '{"ok":true,"result":{"agent":"cursor","model":"composer-2.5"}}'; exit 0 ;;
    ctx_same) printf '%s\n' '{"ok":true,"result":{"agent":"claude","model":"sonnet"}}'; exit 0 ;;
    ctx_verify) printf '%s\n' '{"ok":true,"result":{"agent":"claude","model":"sonnet"}}'; exit 0 ;;
    ctx_verifier) printf '%s\n' '{"ok":true,"result":{"agent":"claude","model":"sonnet"}}'; exit 0 ;;
    *)
      printf '{"ok":false,"error":{"code":"dispatch_not_found"}}\n'
      exit 1 ;;
  esac
fi
if [ "$1 $2" = "orchestration run-list" ]; then
  echo '{"ok":true,"result":{"runs":[{"id":"run_a","coordinator_handle":"term_coord"}],"nextCursor":null}}'
  exit 0
fi
if [ "$1 $2" = "orchestration worker-list" ]; then
  echo '{"ok":true,"result":{"workers":[{"dispatchId":"ctx_builder"},{"dispatchId":"ctx_verify"},{"dispatchId":"ctx_same"},{"dispatchId":"ctx_verifier"}],"nextCursor":null}}'
  exit 0
fi
echo "fake-orca: unsupported: $*" >&2
exit 1
EOS
chmod +x "$MF_DIR/fake-orca"
export ORCA_CLI_COMMAND="$MF_DIR/fake-orca"
printf '{"coordinator_ids":["term_coord"]}\n' > "$here/lead-merge.local.json" # gitignored; removed on EXIT

pass=0 fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

set_checks() {
  local f="$MF_GH_DIR/pr-$1.json"
  jq --argjson c '[{"name":"script-tests","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"shellcheck","status":"COMPLETED","conclusion":"SUCCESS"}]' \
    '.statusCheckRollup = $c' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

pr_body() { # <n> <head> <builder line>
  local n=$1 h=$2 b=${3:-}
  jq --arg h "$h" --arg b "$b" '.body = ("## Why\nx\n\n## Self-review\n" + $h + "\n\n" + $b)' "$MF_GH_DIR/pr-$n.json" > "$MF_GH_DIR/pr-$n.tmp" && mv "$MF_GH_DIR/pr-$n.tmp" "$MF_GH_DIR/pr-$n.json"
}

mf_pr_add 71 same-model "Body"
h71=$(jq -r .headRefOid "$MF_GH_DIR/pr-71.json")
pr_body 71 "$h71" 'Builder: dispatch=ctx_builder agent=claude model=sonnet'
set_checks 71
gh pr comment 71 --repo example/repo --body "Verdict: PASS head=$h71 verifier=ctx_same author=ctx_verify" >/dev/null
out=$(bash "$here/ship.sh" --repo example/repo --pr 71 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'agent=claude model=sonnet' <<<"$out" && ok "same agent/model verdict refused" || bad "same agent/model: rc=$rc $out"

mf_pr_add 72 cursor-coord "Body"
h72=$(jq -r .headRefOid "$MF_GH_DIR/pr-72.json")
pr_body 72 "$h72" 'Builder: dispatch=ctx_builder agent=cursor model=composer-2.5'
set_checks 72
gh pr comment 72 --repo example/repo --body "Verdict: PASS head=$h72 verifier=term_coord author=unknown" >/dev/null
out=$(bash "$here/ship.sh" --repo example/repo --pr 72 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q '^shipped PR' <<<"$out" && ok "coordinator verdict on Cursor PR ships" || bad "coordinator ship: rc=$rc $out"

mf_pr_add 73 forged-coord "Body"
h73=$(jq -r .headRefOid "$MF_GH_DIR/pr-73.json")
pr_body 73 "$h73" 'Builder: dispatch=ctx_builder agent=cursor model=composer-2.5'
set_checks 73
gh pr comment 73 --repo example/repo --body "Verdict: PASS head=$h73 verifier=term_forge author=unknown" >/dev/null
out=$(bash "$here/ship.sh" --repo example/repo --pr 73 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -qi 'not a known dispatch\|not a coordinator' <<<"$out" && ok "forged coordinator verifier refused" || bad "forged coord: rc=$rc $out"

echo "passed $pass failed $fail"
[ "$fail" -eq 0 ]
