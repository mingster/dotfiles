#!/usr/bin/env bash
# Hook boundary tests. Admission CLI/native JSON behavior is exercised separately
# by test_qa_admission.py; here its subprocess is a controlled boundary double.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/briefs" "$tmp/wt"
export FIXTURE_ROOT="$tmp" TMPDIR="$tmp/briefs" PATH="$tmp/bin:$PATH"
export ON_WORKER_DONE_USAGE_GATE="$tmp/gate" ON_WORKER_DONE_QA_ADMISSION="$tmp/admission.py"
export ON_WORKER_DONE_ADMISSION_POLICY="$tmp/policy" ORCA_CLI_COMMAND="$tmp/bin/orca"
export ON_WORKER_DONE_CURSOR_START="$tmp/cursor-stub.sh" ORCA_TERMINAL_HANDLE=term_fixture QA_WORKTREE="$tmp/wt"
git -C "$tmp/wt" init -q
git -C "$tmp/wt" config user.email test@example.invalid
git -C "$tmp/wt" config user.name Test
printf 'fixture\n' > "$tmp/wt/README.md"
git -C "$tmp/wt" add README.md
git -C "$tmp/wt" commit -qm base
cat > "$tmp/cursor-stub.sh" <<'EOS'
#!/usr/bin/env bash
python3 -c 'import json,os,sys; json.dump(sys.argv[1:], open(os.environ["FIXTURE_ROOT"]+"/launch.json","w"))'
EOS
chmod +x "$tmp/cursor-stub.sh"
printf '{}\n' > "$tmp/policy"
cat > "$tmp/gate" <<'GATE'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FIXTURE_ROOT/gate.log"
[ "${GATE_RC:-0}" = 0 ] || exit "$GATE_RC"
echo "${GATE_OUT:---agent cursor --model grok-4.7-high}"
GATE
cat > "$tmp/admission.py" <<'PY'
import json, os, sys
from pathlib import Path
root=Path(os.environ['FIXTURE_ROOT'])
(root/'admission.args').write_text(json.dumps(sys.argv[1:]))
sys.stdout.write((root/'admission.json').read_text())
sys.exit(int(os.environ.get('ADMISSION_RC','0')))
PY
cat > "$tmp/bin/orca" <<'PY'
#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
(Path(os.environ['FIXTURE_ROOT'])/'launch.json').write_text(json.dumps(sys.argv[1:]))
print('{"ok":true}')
PY
cat > "$tmp/bin/gh" <<'PY'
#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
if os.environ.get('GH_RC','0')!='0': sys.exit(int(os.environ['GH_RC']))
if len(sys.argv) >= 4 and sys.argv[1:3] == ['pr', 'view']:
    joined = ' '.join(sys.argv)
    if 'headRefName' in joined and 'comments' not in joined:
        print((Path(os.environ['FIXTURE_ROOT'])/'pr-meta.json').read_text())
        raise SystemExit(0)
print((Path(os.environ['FIXTURE_ROOT'])/'checks.json').read_text())
PY
chmod +x "$tmp/gate" "$tmp/bin/orca" "$tmp/bin/gh"
head=0123456789abcdef0123456789abcdef01234567
export QA_HEAD="$head"
valid() {
  unset GATE_OUT GATE_RC
  printf '%s\n' '{"environment_id":"e842b011-16a2-4b19-a845-adea377bdee5","worktree_selector":"identity:wt2:local:572c47db-7726-4298-91ee-0827c6cdf261","host":"niteking"}' > "$tmp/admission.json"
  printf '{"comments":[{"body":"Checks: PASS head=%s\\nCommand: docs-check\\nResult: exit 0\\n"}]}\n' "$head" > "$tmp/checks.json"
  printf '%s\n' '{"headRefName":"feature/worker-pr"}' > "$tmp/pr-meta.json"
  rm -f "$tmp/launch.json"
}
run() { "$here/on-worker-done.sh" --repo mingster/dotfiles --pr 42 --head "$head" --author-family claude --worktree "$QA_WORKTREE" --run run_fixture "$@" > "$tmp/out" 2> "$tmp/err"; }
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok $1"; else fail=$((fail+1)); echo "FAIL $1"; cat "$tmp/err"; fi; }
refuses() { run; rc=$?; check "$1" "$([ "$rc" -ne 0 ] && [ ! -e "$tmp/launch.json" ]; echo $?)"; }
valid
run --dry-run; check 'dry run succeeds' "$?"
check 'T658-8 start-cursor-worker uses PR head as base-branch' "$(grep -Fq -- '--base-branch' "$tmp/out" && grep -Fq 'feature/worker-pr' "$tmp/out"; echo $?)"
check 'reviewer title supports pane color' "$(grep -Fq -- '--title' "$tmp/out" && grep -Fq 'reviewer' "$tmp/out" && grep -Fq '42' "$tmp/out"; echo $?)"
valid
run; check 'validated boundary dispatches' "$?"
valid
run --dry-run; check 'dry run succeeds' "$?"
check 'dry run never dispatches' "$([ ! -e "$tmp/launch.json" ]; echo $?)"
# Every malformed success response must fail before the real launch subprocess.
for payload in \
  '{}' '[]' 'not-json' \
  '{"environment_id":"LOCAL","worktree_selector":"identity:wt2:local:id","host":"niteking"}' \
  '{"environment_id":"","worktree_selector":"identity:wt2:local:id","host":"niteking"}' \
  '{"environment_id":"saved id","worktree_selector":"identity:wt2:local:id","host":"niteking"}' \
  '{"environment_id":"saved","worktree_selector":"/some/path","host":"niteking"}' \
  '{"environment_id":"saved","worktree_selector":"id:oldpath","host":"niteking"}' \
  '{"environment_id":"saved","worktree_selector":"identity:wt2:local:id extra","host":"niteking"}' \
  '{"environment_id":"saved","worktree_selector":"identity:wt2:local:id"}'; do
  valid; printf '%s\n' "$payload" > "$tmp/admission.json"
  refuses "malformed admission result: $payload"
done
valid
ADMISSION_RC=1 refuses 'admission nonzero refuses even with valid stdout'
valid
ON_WORKER_DONE_ADMISSION_POLICY='' run
check 'absent optional policy reaches validated admission' "$?"
valid
GATE_RC=3 refuses 'usage gate nonzero refuses'
valid
GATE_OUT='--agent antigravity --model mystery' refuses 'unknown verifier family refuses'
valid
GATE_OUT='--agent claude --model claude-sonnet' refuses 'same family refuses'
# Exact-head canonical receipt safeguards remain independent of admission.
for body in \
  "Checks: FAIL head=$head" \
  "Checks: PASS head=$head|Command: bun test|Tests executed: 0|Load errors: 0" \
  "Checks: PASS head=$head|Command: bun test|Tests executed: 1|Load errors: 1"; do
  valid
  CHECKS_BODY="$body" python3 - "$tmp/checks.json" <<'PY'
import json,os,sys
with open(sys.argv[1],'w') as f: json.dump({'comments':[{'body':os.environ['CHECKS_BODY'].replace('|','\n')}]},f)
PY
  refuses "canonical receipt refuses: $body"
done
# Case 9 (#658): bun test only in Command text (dispatcher) without bun output still starts QA.
valid
CHECKS_BODY="Checks: PASS head=$head|Command: python3 run-scoped-tests.py --runner \"bun test --isolate\" --components lint|Result: exit 0|Command: bash script/tests/foo.test.sh|Result: exit 0|Tests executed: 2|Load errors: 0"
CHECKS_BODY="$CHECKS_BODY" python3 - "$tmp/checks.json" <<'PY'
import json,os,sys
with open(sys.argv[1],'w') as f: json.dump({'comments':[{'body':os.environ['CHECKS_BODY'].replace('|','\n')}]},f)
PY
run --dry-run
check 'T658-9 dispatcher bun test in Command without bun output starts QA' "$?"
# Case 9 refuse: bun test v in block output without Tests executed metadata.
valid
CHECKS_BODY="Checks: PASS head=$head|Command: bun test|Result: exit 0|bun test v1.2.3 (abc)"
CHECKS_BODY="$CHECKS_BODY" python3 - "$tmp/checks.json" <<'PY'
import json,os,sys
with open(sys.argv[1],'w') as f: json.dump({'comments':[{'body':os.environ['CHECKS_BODY'].replace('|','\n')}]},f)
PY
refuses 'T658-9 bun test v without Tests executed refuses'
# No receipt at the exact head: QA starts and the brief says Checks are pending.
pending_case() {
  valid
  printf '%s\n' "$2" > "$tmp/checks.json"
  rm -f "$tmp/briefs"/reviewer-brief.*
  run --dry-run
  rc=$?
  check "$1 starts QA" "$rc"
  brief=$(ls -t "$tmp/briefs"/reviewer-brief.* 2>/dev/null | head -1)
  check "$1 brief says Checks are pending" "$([ -n "$brief" ] && grep -q 'Checks are pending' "$brief"; echo $?)"
}
pending_case 'no receipt at all' '{"comments":[]}'
pending_case 'unrelated comment only' '{"comments":[{"body":"looks good"}]}'
pending_case 'receipt for another head' '{"comments":[{"body":"Checks: PASS head=ffffffffffffffffffffffffffffffffffffffff\nCommand: docs-check\n"}]}'
pending_case 'FAIL receipt for another head' '{"comments":[{"body":"Checks: FAIL head=ffffffffffffffffffffffffffffffffffffffff"}]}'
valid
printf '{"comments":[{"body":"Checks: FAIL head=ffffffffffffffffffffffffffffffffffffffff"},{"body":"Checks: PASS head=%s\\nCommand: docs-check\\n"}]}\n' "$head" > "$tmp/checks.json"
rm -f "$tmp/briefs"/reviewer-brief.*
run --dry-run
brief=$(ls -t "$tmp/briefs"/reviewer-brief.* | head -1)
check 'PASS at exact head amid other heads starts' "$?"
check 'PASS at exact head is not marked pending' "$(grep -q 'Checks are pending' "$brief"; echo $((1-$?)))"
# A failed comment read is not a missing receipt.
valid
GH_RC=1 refuses 'gh failure refuses'
check 'gh failure names unreadable receipts' "$(grep -q 'cannot read head-checks receipts' "$tmp/err"; echo $?)"
valid
printf 'not-json\n' > "$tmp/checks.json"
refuses 'unparseable comments refuse'
check 'unparseable comments name unreadable receipts' "$(grep -q 'cannot read head-checks receipts' "$tmp/err"; echo $?)"
valid
printf '{"comments":[{"body":"Checks: PASS head=ffffffffffffffffffffffffffffffffffffffff"},{"body":"Checks: FAIL head=%s"}]}\n' "$head" > "$tmp/checks.json"
refuses 'FAIL at exact head refuses despite PASS at another head'
# Footer: pending is not a failure, a FAIL still stops the review.
valid
printf '{"comments":[]}\n' > "$tmp/checks.json"
rm -f "$tmp/briefs"/reviewer-brief.*
run --dry-run
brief=$(ls -t "$tmp/briefs"/reviewer-brief.* | head -1)
check 'footer lets a pending receipt through' "$(grep -q 'not a failure' "$brief"; echo $?)"
check 'footer stops the review on FAIL' "$(grep -q 'If it is Checks: FAIL, stop the review' "$brief"; echo $?)"
valid
printf '{"comments":[{"body":"Checks: FAIL head=%s"}]}\n' "$head" > "$tmp/checks.json"
run
check 'Checks FAIL prints needs-author' "$(grep -q '^needs-author$' "$tmp/out"; echo $?)"
check 'Checks FAIL refusal names status' "$(grep -q 'Checks: FAIL' "$tmp/err"; echo $?)"
valid
rm -f "$tmp/briefs"/reviewer-brief.*
run --resolution --dry-run
check 'resolution dry run succeeds' "$?"
brief=$(ls "$tmp/briefs"/reviewer-brief.* | tail -1)
check 'resolution retains narrow diff and receipt instructions' "$(grep -q 'git show --remerge-diff' "$brief" && grep -q 'Never rerun bun test' "$brief"; echo $?)"
valid
rm -f "$tmp/briefs"/reviewer-brief.*
run --dry-run
brief=$(ls -t "$tmp/briefs"/reviewer-brief.* | head -1)
check 'default brief retains spec standards and receipt rule' "$(grep -q "repo's standards" "$brief" && grep -q 'Never rerun bun test' "$brief"; echo $?)"
# Retain the original author-family, argument and Verdict contract coverage.
check 'full brief asks for Dual-Axis review' "$(grep -q 'code-review skill (Dual-Axis)' "$brief"; echo $?)"
re='^Verdict: PASS\|PASS\+NOTES\|FAIL head=[0-9a-f]{40} verifier=<your dispatch id> author=unknown$'
check 'brief has exact-head Verdict template' "$(grep -E "$re" "$brief" | grep -q "head=$head"; echo $?)"
check 'brief records provider and family provenance' "$(grep -q 'Author: provider=claude family=claude' "$brief" && grep -q 'Verifier: provider=cursor family=grok' "$brief"; echo $?)"
check 'claude author avoids claude family' "$(grep -q -- '--avoid-family claude' "$tmp/gate.log"; echo $?)"
for author in cursor gemini antigravity; do
  valid
  export GATE_OUT='--agent claude --model claude-sonnet --effort medium'
  run --author-family "$author" --dry-run
  rc=$?
  unset GATE_OUT
  check "$author author picks independent reviewer" "$rc"
  check "$author author never uses composer-2.5" "$( ! grep -Fq -- '--model composer-2.5' "$tmp/out"; echo $?)"
  if [ "$author" = cursor ]; then
    check "$author author avoids composer" "$(grep -q -- '--avoid-family composer' "$tmp/gate.log"; echo $?)"
  else
    check "$author author avoids gemini" "$(grep -q -- '--avoid-family gemini' "$tmp/gate.log"; echo $?)"
  fi
done
for code in 3 4; do
  valid
  GATE_RC=$code refuses "usage gate exit $code never launches"
  check "usage gate exit $code explains independence unavailable" "$(grep -q 'cross-family unavailable' "$tmp/err"; echo $?)"
done
for args in 'claude claude-sonnet claude claude-sonnet' \
            'antigravity claude-sonnet claude claude-sonnet' \
            'antigravity gpt-4o cursor gpt-5.6-sol-medium' \
            'antigravity unknown-model cursor gpt-5.6-sol-medium' \
            'antigravity gemini-3.8-flash cursor mystery-model'; do
  read -r author model verifier verifier_model <<< "$args"
  valid
  GATE_OUT="--agent $verifier --model $verifier_model" run --author-provider "$author" --author-model "$model"
  rc=$?
  check "same or unknown family refuses: $args" "$([ "$rc" -ne 0 ] && [ ! -e "$tmp/launch.json" ] && grep -q 'cross-family unavailable' "$tmp/err"; echo $?)"
done
for args in '--pr x' '--author-family gpt' '--head invalid'; do
  valid
  # Intentional splitting supplies the invalid option and value as two arguments.
  # shellcheck disable=SC2086
  run $args
  rc=$?
  check "invalid CLI refuses: $args" "$([ "$rc" -ne 0 ] && [ ! -e "$tmp/launch.json" ]; echo $?)"
done
"$here/on-worker-done.sh" --dry-run --repo o/n --pr 42 > "$tmp/out" 2> "$tmp/err"
check 'missing required CLI arguments refuse' "$([ $? -ne 0 ]; echo $?)"
# #671: Orca registers the main checkout only; Cursor --repo path: must not be a linked worktree root.
main_root="$tmp/wt"
linked_root="$tmp/linked-wt"
git -C "$main_root" worktree add -q "$linked_root" -b linked-feature-671
expected_repo="path:$(dirname "$(cd -P "$(git -C "$linked_root" rev-parse --path-format=absolute --git-common-dir)" && pwd)")"
export QA_WORKTREE="$linked_root"
unset GATE_OUT GATE_RC
valid
run --dry-run
check 'linked worktree uses main checkout for --repo path' "$(grep -Fq -- "--repo $expected_repo" "$tmp/out"; echo $?)"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
