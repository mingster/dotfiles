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
echo "${GATE_OUT:---agent codex --model gpt-6.1-sol --effort medium}"
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
import json,os
from pathlib import Path
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
ON_WORKER_DONE_ADMISSION_POLICY="$tmp/missing" refuses 'missing policy refuses'
valid
GATE_RC=3 refuses 'usage gate nonzero refuses'
valid
GATE_OUT='--agent codex --model mystery' refuses 'unknown verifier family refuses'
valid
GATE_OUT='--agent claude --model claude-sonnet' refuses 'same family refuses'
# Exact-head canonical receipt safeguards remain independent of admission.
for body in \
  "Checks: FAIL head=$head" \
  "Checks: PASS head=$head|Command: bun test|Tests executed: 0|Load errors: 0" \
  "Checks: PASS head=$head|Command: bun test|Tests executed: 1|Load errors: 1" \
  "Checks: PASS head=$head|Command: bun test" \
  'Checks: PASS head=ffffffffffffffffffffffffffffffffffffffff'; do
  valid
  CHECKS_BODY="$body" python3 - "$tmp/checks.json" <<'PY'
import json,os,sys
with open(sys.argv[1],'w') as f: json.dump({'comments':[{'body':os.environ['CHECKS_BODY'].replace('|','\n')}]},f)
PY
  refuses "canonical receipt refuses: $body"
done
valid
rm -f "$tmp/briefs"/reviewer-brief.*
run --resolution --dry-run
check 'resolution dry run succeeds' "$?"
brief=$(ls "$tmp/briefs"/reviewer-brief.* | tail -1)
check 'resolution retains narrow diff and gate instructions' "$(grep -q 'git show --remerge-diff' "$brief" && grep -q 'heavy-gate.sh' "$brief"; echo $?)"
check 'resolution brief requires 1500 second admission wait' "$(grep -q 'HEAVY_GATE_TIMEOUT_SECONDS=1500' "$brief" && grep -q 'wait for admission' "$brief"; echo $?)"
valid
rm -f "$tmp/briefs"/reviewer-brief.*
run --dry-run
brief=$(ls -t "$tmp/briefs"/reviewer-brief.* | head -1)
check 'default brief retains spec standards and pending rule' "$(grep -q "repo's standards" "$brief" && grep -q 'pending is not PASS' "$brief"; echo $?)"
check 'full brief requires 1500 second admission wait' "$(grep -q 'HEAVY_GATE_TIMEOUT_SECONDS=1500' "$brief" && grep -q 'wait for admission' "$brief"; echo $?)"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
