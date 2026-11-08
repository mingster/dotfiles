#!/usr/bin/env bash
# Hermetic tests for script/ship.sh (ticket T3, issue #717).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$here/tests/lib/asdf-pin.sh"
# shellcheck disable=SC1091
. "$here/tests/lib/merge-fixture.sh"

mf_setup
trap mf_teardown EXIT
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
    ctx_author)
      printf '{"ok":true,"result":{"dispatchId":"%s","agent":"claude","model":"sonnet"}}\n' "$id"
      exit 0 ;;
    ctx_verifier)
      printf '{"ok":true,"result":{"dispatchId":"%s","agent":"claude","model":"opus"}}\n' "$id"
      exit 0 ;;
    *)
      printf '{"ok":false,"error":{"code":"dispatch_not_found","message":"Dispatch %s was not found."}}\n' "$id"
      exit 1 ;;
  esac
fi
echo "fake-orca: unsupported: $*" >&2
exit 1
EOS
chmod +x "$MF_DIR/fake-orca"
export ORCA_CLI_COMMAND="$MF_DIR/fake-orca"

pass=0 fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

set_checks() { # <pr> <json array>
  local f="$MF_GH_DIR/pr-$1.json"
  jq --argjson c "$2" '.statusCheckRollup = $c' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

green_checks='[{"name":"script-tests","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"shellcheck","status":"COMPLETED","conclusion":"SUCCESS"}]'

post_verdict() { # <pr> <result> <head> [verifier] [author]
  local n=$1 res=$2 h=$3 v=${4:-ctx_verifier} a=${5:-ctx_author}
  gh pr comment "$n" --repo example/repo --body "Verdict: $res head=$h verifier=$v author=$a" >/dev/null
}

mf_self_review() { # <pr> <head>
  local pr_n=$1 head_sha=$2 f
  f="$MF_GH_DIR/pr-${pr_n}.json"
  jq --arg h "$head_sha" '.body = ((.body // "") + "\n\n## Self-review\n" + $h + "\n")' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

run_ship() { # <args...>
  SHIP_OUT=$(bash "$here/ship.sh" "$@" 2>&1)
  SHIP_RC=$?
}

# 1. PASS at head merges with --squash --match-head-commit and reads back MERGED
mf_pr_add 1 feat-pass "Body"
h1=$(jq -r .headRefOid "$MF_GH_DIR/pr-1.json")
mf_self_review 1 "$h1"
set_checks 1 "$green_checks"
post_verdict 1 PASS "$h1"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1
if [ "$SHIP_RC" -eq 0 ] && [[ "$SHIP_OUT" =~ ^shipped\ PR\ 1\ as\ [0-9a-f]{40}$ ]] \
  && grep -q "gh pr merge 1 --repo example/repo --squash --match-head-commit $h1" "$MF_GH_LOG" \
  && [ "$(jq -r .state "$MF_GH_DIR/pr-1.json")" = MERGED ]; then
  ok "PASS at head merges and reads back"
else
  bad "PASS at head merges and reads back" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 2. Verdict at an older head with the same patch-id merges
"$MF_REAL_GIT" -C "$MF_REPO" fetch -q origin
mf_pr_add 2 feat-rebase "Body"
old_h2=$(jq -r .headRefOid "$MF_GH_DIR/pr-2.json")
"$MF_REAL_GIT" -C "$MF_REPO" checkout -q -B main origin/main
echo unrelated > "$MF_REPO/unrelated-main.txt"
"$MF_REAL_GIT" -C "$MF_REPO" add unrelated-main.txt
"$MF_REAL_GIT" -C "$MF_REPO" commit -q -m "advance main"
"$MF_REAL_GIT" -C "$MF_REPO" push -q origin main
"$MF_REAL_GIT" -C "$MF_REPO" fetch -q origin
new_base=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse origin/main)
"$MF_REAL_GIT" -C "$MF_REPO" checkout -q -B feat-rebase "$new_base"
"$MF_REAL_GIT" -C "$MF_REPO" cherry-pick "$old_h2" >/dev/null
"$MF_REAL_GIT" -C "$MF_REPO" push -q -f origin feat-rebase
"$MF_REAL_GIT" -C "$MF_REPO" checkout -q main
new_h2=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse feat-rebase)
jq --arg h "$new_h2" --arg b "$new_base" '.headRefOid = $h | .baseRefOid = $b' "$MF_GH_DIR/pr-2.json" > "$MF_GH_DIR/pr-2.tmp" && mv "$MF_GH_DIR/pr-2.tmp" "$MF_GH_DIR/pr-2.json"
mf_self_review 2 "$new_h2"
set_checks 2 "$green_checks"
post_verdict 2 "PASS+NOTES" "$old_h2"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 2
if [ "$old_h2" != "$new_h2" ] && [ "$SHIP_RC" -eq 0 ] && [[ "$SHIP_OUT" =~ ^shipped\ PR\ 2\ as\ [0-9a-f]{40}$ ]] \
  && grep -q "gh pr merge 2 --repo example/repo --squash --match-head-commit $new_h2" "$MF_GH_LOG"; then
  ok "verdict at an older head with the same patch id merges"
else
  bad "verdict at an older head with the same patch id merges" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 3. Different patch-id refuses
mf_pr_add 3 feat-diff "Body"
old_h3=$(jq -r .headRefOid "$MF_GH_DIR/pr-3.json")
"$MF_REAL_GIT" -C "$MF_REPO" checkout -q feat-diff
echo changed >> "$MF_REPO/feat-diff.txt"
"$MF_REAL_GIT" -C "$MF_REPO" commit -q -am "change patch"
"$MF_REAL_GIT" -C "$MF_REPO" push -q -f origin feat-diff
"$MF_REAL_GIT" -C "$MF_REPO" checkout -q main
new_h3=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse feat-diff)
jq --arg h "$new_h3" '.headRefOid = $h' "$MF_GH_DIR/pr-3.json" > "$MF_GH_DIR/pr-3.tmp" && mv "$MF_GH_DIR/pr-3.tmp" "$MF_GH_DIR/pr-3.json"
mf_self_review 3 "$new_h3"
set_checks 3 "$green_checks"
post_verdict 3 PASS "$old_h3"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 3
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -qi "patch-id" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "different patch id refuses"
else
  bad "different patch id refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 4. FAIL verdict refuses
mf_pr_add 4 feat-fail "Body"
h4=$(jq -r .headRefOid "$MF_GH_DIR/pr-4.json")
set_checks 4 "$green_checks"
post_verdict 4 PASS "$h4"
post_verdict 4 FAIL "$h4"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 4
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -q "FAIL" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "FAIL refuses"
else
  bad "FAIL refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 5. Pending check refuses
mf_pr_add 5 feat-pending "Body"
h5=$(jq -r .headRefOid "$MF_GH_DIR/pr-5.json")
set_checks 5 '[{"name":"script-tests","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"shellcheck","status":"IN_PROGRESS","conclusion":null}]'
post_verdict 5 PASS "$h5"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 5
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -qi "check" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "pending check refuses"
else
  bad "pending check refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 6. No verdict refuses
mf_pr_add 6 feat-noverdict "Body"
set_checks 6 "$green_checks"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 6
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -qi "verdict" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "no verdict refuses"
else
  bad "no verdict refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 7. Merge read-back not MERGED fails
mf_pr_add 7 feat-readback "Body"
h7=$(jq -r .headRefOid "$MF_GH_DIR/pr-7.json")
mf_self_review 7 "$h7"
set_checks 7 "$green_checks"
post_verdict 7 PASS "$h7"
mkdir -p "$MF_DIR/noop-merge"
cat > "$MF_DIR/noop-merge/gh" <<EOS
#!/usr/bin/env bash
if [ "\$1 \$2" = "pr merge" ]; then
  echo "gh \$*" >> "$MF_GH_LOG"
  exit 0
fi
exec "$MF_BIN/gh" "\$@"
EOS
chmod +x "$MF_DIR/noop-merge/gh"
: > "$MF_GH_LOG"
SHIP_OUT=$(PATH="$MF_DIR/noop-merge:$PATH" bash "$here/ship.sh" --repo example/repo --pr 7 2>&1)
SHIP_RC=$?
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -q "not MERGED" <<<"$SHIP_OUT"; then
  ok "merge read back not MERGED fails"
else
  bad "merge read back not MERGED fails" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 8. Protected path without approval refuses (and with approval merges)
mf_pr_add 8 feat-protected "Body" AGENTS.md
h8=$(jq -r .headRefOid "$MF_GH_DIR/pr-8.json")
mf_self_review 8 "$h8"
set_checks 8 "$green_checks"
post_verdict 8 PASS "$h8"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 8
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -q "Owner-approved" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "protected path without approval refuses"
else
  bad "protected path without approval refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 9. --dry-run merges nothing
mf_pr_add 9 feat-dry "Body"
h9=$(jq -r .headRefOid "$MF_GH_DIR/pr-9.json")
mf_self_review 9 "$h9"
set_checks 9 "$green_checks"
post_verdict 9 PASS "$h9"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 9 --dry-run
if [ "$SHIP_RC" -eq 0 ] && grep -qi "dry-run" <<<"$SHIP_OUT" \
  && ! grep -q "^shipped PR" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG" \
  && [ "$(jq -r .state "$MF_GH_DIR/pr-9.json")" = OPEN ]; then
  ok "--dry-run merges nothing"
else
  bad "--dry-run merges nothing" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 10. Unknown verifier dispatch refuses
mf_pr_add 10 feat-forged "Body"
h10=$(jq -r .headRefOid "$MF_GH_DIR/pr-10.json")
mf_self_review 10 "$h10"
set_checks 10 "$green_checks"
post_verdict 10 PASS "$h10" ctx_forged ctx_author
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 10
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -Fq "verdict verifier ctx_forged is not a known dispatch" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "unknown verifier dispatch refuses"
else
  bad "unknown verifier dispatch refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 11. Edited FAIL still blocks an older PASS
mf_pr_add 11 feat-edited-fail "Body"
h11=$(jq -r .headRefOid "$MF_GH_DIR/pr-11.json")
set_checks 11 "$green_checks"
post_verdict 11 PASS "$h11"
post_verdict 11 FAIL "$h11"
mf_comment_flag 11 1 edited true
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 11
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -Fq "newest Verdict on PR 11 is FAIL" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "edited FAIL still blocks older PASS"
else
  bad "edited FAIL still blocks older PASS" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 12. Empty statusCheckRollup refuses
mf_pr_add 12 feat-nochecks "Body"
h12=$(jq -r .headRefOid "$MF_GH_DIR/pr-12.json")
set_checks 12 '[]'
post_verdict 12 PASS "$h12"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 12
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -Fq "no checks reported at head $h12" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "empty statusCheckRollup refuses"
else
  bad "empty statusCheckRollup refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 13. Stale self-review refuses
mf_pr_add 13 feat-stale-self "Body"
h13=$(jq -r .headRefOid "$MF_GH_DIR/pr-13.json")
mf_self_review 13 "0000000000000000000000000000000000000000"
set_checks 13 "$green_checks"
post_verdict 13 PASS "$h13"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 13
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "no self-review at head $h13" <<<"$SHIP_OUT"; then
  ok "stale self-review refuses"
else
  bad "stale self-review refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
