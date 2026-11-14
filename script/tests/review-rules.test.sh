#!/usr/bin/env bash
# Review rules (#760, #866): ship.sh refuses a verifier with the builder's agent and model, and lands a different one.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/merge-fixture.sh
. "$here/tests/lib/merge-fixture.sh"
# shellcheck source=lib/asdf-pin.sh
. "$here/tests/lib/asdf-pin.sh"
mf_setup
trap mf_teardown EXIT
cd "$MF_REPO" || exit 1

pass=0 fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

new_pr() { # <n> <branch> <agent> <model>
  mf_pr_add "$1" "$2" "Body"
  local f="$MF_GH_DIR/pr-$1.json"
  jq --arg l "Builder: agent=$3 model=$4" '.body = ("## Why\nx\n\n" + $l + "\n\n## Self-check\n$ bash script/checks-local.sh\nexit 0\n") | .statusCheckRollup = [{"name":"script-tests","status":"COMPLETED","conclusion":"SUCCESS"}]' \
    "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  jq -r .headRefOid "$f"
}
verdict() { # <n> <head> <agent> <model>
  gh pr comment "$1" --repo example/repo --body "Verdict: PASS head=$2 verifier=ctx_verify author=ctx_builder agent=$3 model=$4" >/dev/null
}

h71=$(new_pr 71 same-model claude sonnet)
verdict 71 "$h71" claude sonnet
out=$(bash "$here/ship.sh" --repo example/repo --pr 71 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'same agent and model' <<<"$out" && ok "same agent/model verdict refused" || bad "same agent/model: rc=$rc $out"

h72=$(new_pr 72 other-model claude sonnet)
verdict 72 "$h72" antigravity gemini-4-argon-high
out=$(bash "$here/ship.sh" --repo example/repo --pr 72 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q '^shipped PR' <<<"$out" && ok "different agent/model verdict ships" || bad "different verifier: rc=$rc $out"

echo "passed $pass failed $fail"
[ "$fail" -eq 0 ]
