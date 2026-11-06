#!/usr/bin/env bash
# Hook boundary tests. Admission CLI/native JSON behavior is exercised separately
# by test_qa_admission.py; here its subprocess is a controlled boundary double.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/briefs"
export FIXTURE_ROOT="$tmp" TMPDIR="$tmp/briefs" PATH="$tmp/bin:$PATH"
export ON_WORKER_DONE_USAGE_GATE="$tmp/gate" ON_WORKER_DONE_QA_ADMISSION="$tmp/admission.py"
export ON_WORKER_DONE_ADMISSION_POLICY="$tmp/policy" ORCA_CLI_COMMAND="$tmp/bin/orca"
printf '{}\n' > "$tmp/policy"
cat > "$tmp/gate" <<'GATE'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FIXTURE_ROOT/gate.log"
[ "${GATE_RC:-0}" = 0 ] || exit "$GATE_RC"
echo "${GATE_OUT:---agent antigravity --model gemini-4-argon-high}"
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
print(os.environ.get('FAKE_START_OUT', '{"ok":true}'))
sys.exit(int(os.environ.get('FAKE_START_RC', '0')))
PY
cat > "$tmp/bin/gh" <<'PY'
#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
if os.environ.get('GH_RC','0')!='0': sys.exit(int(os.environ['GH_RC']))
print((Path(os.environ['FIXTURE_ROOT'])/'checks.json').read_text())
PY
chmod +x "$tmp/gate" "$tmp/bin/orca" "$tmp/bin/gh"
head=0123456789abcdef0123456789abcdef01234567
export QA_HEAD="$head"
valid() {
  printf '%s\n' '{"environment_id":"e842b011-16a2-4b19-a845-adea377bdee5","worktree_selector":"identity:wt2:local:572c47db-7726-4298-91ee-0827c6cdf261","host":"niteking"}' > "$tmp/admission.json"
  printf '{"comments":[{"body":"Checks: PASS head=%s\\nCommand: docs-check\\nResult: exit 0\\n"}]}\n' "$head" > "$tmp/checks.json"
  rm -f "$tmp/launch.json"
}
run() { "$here/on-worker-done.sh" --repo mingster/dotfiles --pr 42 --head "$head" --author-family claude --worktree '/authorized/path with spaces' --run run_fixture "$@" > "$tmp/out" 2> "$tmp/err"; }
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok $1"; else fail=$((fail+1)); echo "FAIL $1"; cat "$tmp/err"; fi; }
refuses() { run; rc=$?; check "$1" "$([ "$rc" -ne 0 ] && [ ! -e "$tmp/launch.json" ]; echo $?)"; }
valid
run; check 'validated boundary dispatches' "$?"
python3 - "$tmp/launch.json" <<'PY'
import json,sys
args=json.load(open(sys.argv[1]))
assert args[args.index('--on')+1]=='e842b011-16a2-4b19-a845-adea377bdee5'
assert args[args.index('--worktree')+1]=='identity:wt2:local:572c47db-7726-4298-91ee-0827c6cdf261'
assert '--agent' in args
PY
check 'actual argv preserves saved ID and exact identity' "$?"
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
  "Checks: PASS head=$head|Command: bun test|Tests executed: 1|Load errors: 1" \
  "Checks: PASS head=$head|Command: bun test"; do
  valid
  CHECKS_BODY="$body" python3 - "$tmp/checks.json" <<'PY'
import json,os,sys
with open(sys.argv[1],'w') as f: json.dump({'comments':[{'body':os.environ['CHECKS_BODY'].replace('|','\n')}]},f)
PY
  refuses "canonical receipt refuses: $body"
done
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
check 'brief records provider and family provenance' "$(grep -q 'Author: provider=claude family=claude' "$brief" && grep -q 'Verifier: provider=antigravity family=gemini' "$brief"; echo $?)"
check 'reviewer title supports pane color' "$(grep -q -- '--task-title "reviewer - PR 42"' "$tmp/out"; echo $?)"
check 'claude author avoids claude family' "$(grep -q -- '--avoid-family claude' "$tmp/gate.log"; echo $?)"
for author in cursor gemini antigravity; do
  valid
  GATE_OUT='--agent claude --model claude-sonnet --effort medium' run --author-family "$author" --dry-run
  check "$author author picks independent reviewer" "$?"
  check "$author author uses claude reviewer" "$(grep -q -- '--agent claude' "$tmp/out"; echo $?)"
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
# The reviewer's owner record: written when the worker starts, from the dispatch id in worker-start's output
export WORKER_DONE_OWNER_DIR="$tmp/owners"
valid; rm -rf "$tmp/owners"
FAKE_START_OUT='{"ok":true,"result":{"dispatch":{"dispatchId":"ctx_rev1"}}}' run --owner term_lead_Z
check 'reviewer start with an owner succeeds' "$?"
check 'record has the owner and the reviewer proof fields' "$([ "$(cat "$tmp/owners/ctx_rev1" 2>/dev/null)" = "$(printf 'term_lead_Z\nkind=reviewer\nrepo=mingster/dotfiles\npr=42')" ]; echo $?)"
check 'worker-start output still reaches the caller' "$(grep -q ctx_rev1 "$tmp/out"; echo $?)"
valid; rm -rf "$tmp/owners"
FAKE_START_OUT='{"ok":true,"result":{"dispatch":{"dispatchId":"ctx_rev2"}}}' run
check 'no owner: record has an empty first line' "$([ "$(head -n 1 "$tmp/owners/ctx_rev2" | wc -c)" -le 1 ] && grep -q kind=reviewer "$tmp/owners/ctx_rev2"; echo $?)"
valid; rm -rf "$tmp/owners"
run --owner term_lead_Z
check 'no dispatch id in the output: no record, still succeeds' "$([ ! -e "$tmp/owners" ] || [ -z "$(ls "$tmp/owners")" ]; echo $?)"
valid; rm -rf "$tmp/owners"
FAKE_START_OUT='{"ok":true,"result":{"dispatch":{"dispatchId":"ctx_rev3"}}}' run --dry-run --owner term_lead_Z
check 'dry run writes no record' "$([ ! -e "$tmp/owners/ctx_rev3" ]; echo $?)"
valid; rm -rf "$tmp/owners"
FAKE_START_RC=3 FAKE_START_OUT='{"ok":false,"result":{"dispatch":{"dispatchId":"ctx_rev4"}}}' run --owner term_lead_Z
rc=$?
check 'a failed start keeps its exit code and writes no record' "$([ "$rc" = 3 ] && [ ! -e "$tmp/owners/ctx_rev4" ]; echo $?)"
unset WORKER_DONE_OWNER_DIR
# Cheap checks (.agents/pre-qa-checks.conf) run at the exact head, in its worktree, before any reviewer starts.
cheap="$tmp/cheap"; mkdir -p "$cheap/.agents"
git -C "$cheap" init -q && git -C "$cheap" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
cheap_head=$(git -C "$cheap" rev-parse HEAD)
cheap_run() { run --worktree "$cheap" --head "$cheap_head" "$@"; }
cheap_conf() { printf '%s\n' "$@" > "$cheap/.agents/pre-qa-checks.conf"; }
cheap_refuses() {
  rc=$1; shift
  check "$1" "$([ "$rc" -ne 0 ] && [ ! -e "$tmp/launch.json" ]; echo $?)"
}
valid; cheap_conf '# cheap checks' '' 'echo lint ok' 'pwd > "$FIXTURE_ROOT/cheap.pwd"'
cheap_run; rc=$?
check 'cheap checks pass: reviewer starts' "$([ "$rc" = 0 ] && [ -e "$tmp/launch.json" ]; echo $?)"
check 'cheap checks run from the worktree of the head' "$([ "$(cat "$tmp/cheap.pwd")" = "$(cd "$cheap" && pwd -P)" ]; echo $?)"
for name in lint mock-contract locale; do
  valid; cheap_conf 'true' "echo $name line1; echo $name broke >&2; exit 7" 'echo never reached > "$FIXTURE_ROOT/after-fail"'
  rm -f "$tmp/after-fail"
  cheap_run; rc=$?
  cheap_refuses "$rc" "$name failure starts no reviewer"
  check "$name failure names the check and its last output" "$(grep -q "cheap check failed" "$tmp/err" && grep -q "echo $name line1" "$tmp/err" && grep -q "$name broke" "$tmp/err"; echo $?)"
  check "$name failure stops later checks" "$([ ! -e "$tmp/after-fail" ]; echo $?)"
done
valid; cheap_conf 'seq 1 50; exit 1'
cheap_run
check 'failure report keeps only the last lines' "$(grep -qx 50 "$tmp/err" && ! grep -qx 1 "$tmp/err"; echo $?)"
valid; cheap_conf 'sleep 30'
ON_WORKER_DONE_CHECK_TIMEOUT=1 cheap_run; rc=$?
cheap_refuses "$rc" 'timeout starts no reviewer'
check 'timeout is reported as a failure naming the check' "$(grep -q 'timed out' "$tmp/err" && grep -q 'sleep 30' "$tmp/err"; echo $?)"
valid; rm -f "$cheap/.agents/pre-qa-checks.conf"
cheap_run; rc=$?
check 'no config behaves as today' "$([ "$rc" = 0 ] && [ -e "$tmp/launch.json" ]; echo $?)"
valid; cheap_conf 'echo ok'
git -C "$cheap" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
cheap_run; rc=$?
cheap_refuses "$rc" 'a head that moved starts no reviewer'
check 'moved head is named in the refusal' "$(grep -q 'head moved' "$tmp/err"; echo $?)"
cheap_head=$(git -C "$cheap" rev-parse HEAD)
valid; cheap_conf 'echo ok'
cheap_run --dry-run; rc=$?
check 'dry run runs the cheap checks too' "$rc"
valid; cheap_conf 'exit 1'
cheap_run --dry-run; rc=$?
check 'dry run refuses on a failed check' "$([ "$rc" -ne 0 ]; echo $?)"
# Checks start: once the cheap checks pass, head-checks.sh starts detached beside QA, once per repo, PR and head.
cat > "$tmp/hc" <<'HC'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE_ROOT/hc.log"
echo "hc ran"
if [ "${HC_HOLD:-0}" = 1 ]; then while [ ! -e "$FIXTURE_ROOT/hc-release" ]; do sleep 0.05; done; fi
exit "${HC_RC:-0}"
HC
chmod +x "$tmp/hc"
export ON_WORKER_DONE_HEAD_CHECKS="$tmp/hc" ON_WORKER_DONE_CHECKS_DIR="$tmp/markers" ON_WORKER_DONE_CHECKS_LOG_DIR="$tmp/hclogs"
hc_valid() {
  valid; cheap_conf 'true'
  printf '{"headRefOid":"%s","comments":%s}\n' "${HC_REMOTE_HEAD:-$cheap_head}" "${1:-[]}" > "$tmp/checks.json"
  rm -rf "$tmp/hc.log" "$tmp/markers" "$tmp/hclogs" "$tmp/hc-release"
}
hc_lines() { [ -f "$tmp/hc.log" ] && wc -l < "$tmp/hc.log" | tr -d ' ' || echo 0; }
hc_wait() { for _ in $(seq 1 100); do [ "$(hc_lines)" -ge "$1" ] && return 0; sleep 0.05; done; return 1; }
hc_settle() { sleep 0.5; }
until_cleared() { for _ in $(seq 1 100); do [ "$(hc_marker_count)" = 0 ] && return 0; sleep 0.05; done; return 1; }
until_logged() { for _ in $(seq 1 50); do grep -qs "$1" "$tmp"/hclogs/* && return 0; sleep 0.05; done; return 1; }
hc_marker_count() { ls "$tmp/markers" 2>/dev/null | wc -l | tr -d ' '; }

hc_valid
cheap_run; rc=$?
check 'ready: reviewer still starts' "$([ "$rc" = 0 ] && [ -e "$tmp/launch.json" ]; echo $?)"
check 'ready: Checks start' "$(hc_wait 1; echo $?)"
check 'Checks start names the worktree and the PR' "$([ "$(cat "$tmp/hc.log")" = "--repo $cheap --pr 42" ]; echo $?)"
check 'lead is told Checks started, with the log path' "$(grep -q "^Checks started head=$cheap_head pr=42 log=$tmp/hclogs/" "$tmp/out"; echo $?)"
check 'detached output lands in the logged file' "$(until_logged 'hc ran'; echo $?)"
cheap_run; rc=$?
hc_settle
check 'repeat call starts no second run' "$([ "$rc" = 0 ] && [ "$(hc_lines)" = 1 ]; echo $?)"
check 'repeat call tells the lead why' "$(grep -q "^Checks not started head=$cheap_head: already started" "$tmp/out"; echo $?)"

hc_valid
race() { "$here/on-worker-done.sh" --repo mingster/dotfiles --pr 42 --head "$cheap_head" --author-family claude --worktree "$cheap" --run run_fixture > "$tmp/race.$1" 2>&1; }
race 1 & race 2 & race 3 & race 4 &
wait
hc_wait 1; hc_settle
check 'four racing calls start exactly one run' "$([ "$(hc_lines)" = 1 ] && [ "$(hc_marker_count)" = 1 ]; echo $?)"
check 'only one racing call reports the Checks start' "$([ "$(cat "$tmp"/race.* | grep -c '^Checks started')" = 1 ]; echo $?)"

hc_valid; cheap_conf 'exit 1'
cheap_run
hc_settle
check 'cheap check failure starts no Checks' "$([ "$(hc_lines)" = 0 ] && [ "$(hc_marker_count)" = 0 ]; echo $?)"
hc_valid; cheap_conf 'exit 1'
cheap_run --resolution
hc_settle
check 'cheap check failure on a resolution starts no Checks' "$([ "$(hc_lines)" = 0 ]; echo $?)"

hc_valid "[{\"body\":\"Checks: PASS head=$cheap_head\\nCommand: docs-check\\n\"}]"
cheap_run
hc_settle
check 'existing PASS comment for the head starts nothing' "$([ "$(hc_lines)" = 0 ] && [ "$(hc_marker_count)" = 0 ]; echo $?)"
check 'existing comment is named to the lead' "$(grep -q "^Checks not started head=$cheap_head: a Checks comment already exists" "$tmp/out"; echo $?)"
hc_valid "[{\"body\":\"Checks: FAIL head=$cheap_head\"}]"
cheap_run
hc_settle
check 'existing FAIL comment for the head starts nothing' "$([ "$(hc_lines)" = 0 ]; echo $?)"
hc_valid '[{"body":"Checks: PASS head=ffffffffffffffffffffffffffffffffffffffff\nCommand: docs-check\n"}]'
cheap_run
check 'a comment for another head does not block the start' "$(hc_wait 1; echo $?)"

HC_REMOTE_HEAD=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee hc_valid
cheap_run; rc=$?
hc_settle
check 'PR head moved: no Checks, reviewer path untouched' "$([ "$rc" = 0 ] && [ "$(hc_lines)" = 0 ] && [ "$(hc_marker_count)" = 0 ]; echo $?)"
check 'PR head moved is named to the lead' "$(grep -q "^Checks not started head=$cheap_head: the PR head moved" "$tmp/out"; echo $?)"
hc_valid; rm -f "$cheap/.agents/pre-qa-checks.conf"
run --worktree "$cheap" --head dddddddddddddddddddddddddddddddddddddddd
hc_settle
check 'worktree moved, no cheap config: no Checks' "$([ "$(hc_lines)" = 0 ] && grep -q "^Checks not started head=dddd.*worktree" "$tmp/out"; echo $?)"

hc_valid
HC_RC=3 cheap_run
check 'failing run is attempted' "$(hc_wait 1; echo $?)"
check 'a failed start clears the marker' "$(until_cleared; echo $?)"
cheap_run
check 'retry after a failed start runs again' "$(hc_wait 2; echo $?)"
hc_valid
ON_WORKER_DONE_HEAD_CHECKS="$tmp/missing-head-checks" cheap_run
check 'a start that cannot spawn clears the marker' "$(until_cleared; echo $?)"

hc_valid
cheap_run --dry-run; rc=$?
hc_settle
check 'dry run starts no Checks and takes no marker' "$([ "$rc" = 0 ] && [ "$(hc_lines)" = 0 ] && [ "$(hc_marker_count)" = 0 ]; echo $?)"
check 'dry run prints the Checks command' "$(grep -q "^Checks would start: .*--repo $cheap --pr 42" "$tmp/out"; echo $?)"
cheap_run
check 'a real run after a dry run still starts' "$(hc_wait 1; echo $?)"

hc_valid
cheap_run --resolution
check 'a resolution run starts Checks the same way' "$(hc_wait 1; echo $?)"

hc_valid
GATE_RC=3 cheap_run; rc=$?
check 'reviewer unavailable: Checks still start' "$([ "$rc" -ne 0 ] && hc_wait 1; echo $?)"

hc_valid
HC_HOLD=1 cheap_run; rc=$?
check 'a running Checks does not delay the reviewer start' "$([ "$rc" = 0 ] && [ -e "$tmp/launch.json" ] && [ ! -e "$tmp/hc-release" ]; echo $?)"
check 'and the run is still going when on-worker-done returns' "$(hc_wait 1 && pgrep -f "$tmp/hc" >/dev/null; echo $?)"
touch "$tmp/hc-release"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
