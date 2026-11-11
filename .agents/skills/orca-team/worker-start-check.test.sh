#!/usr/bin/env bash
# worker-start-check.sh must fail when the first screen is the Antigravity sign-in step.
# A normal Antigravity screen still passes. Uses a fake orca; no network.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
# SCREEN_FILE is the fake terminal screen (one line per row).
case "$*" in
  *"orchestration worker-show"*)
    printf '%s\n' "{\"ok\":true,\"result\":{\"dispatchId\":\"ctx_agy\",\"state\":\"${SHOW_STATE:-ready}\",\"liveness\":\"live\",\"terminal\":\"term_agy\"}}"
    ;;
  *"terminal read"*)
    python3 -c '
import json, os
tail = open(os.environ["SCREEN_FILE"]).read().splitlines()
print(json.dumps({"ok": True, "result": {"terminal": {"tail": tail}}}))
'
    ;;
  *)
    printf 'unexpected orca: %s\n' "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$tmp/bin/orca"

pass=0
fail=0
check() { # name expected_nonzero(0|1) output_regex screen_text
  printf '%s\n' "$4" >"$tmp/screen.txt"
  out=$(PATH="$tmp/bin:$PATH" SCREEN_FILE="$tmp/screen.txt" SHOW_STATE="${SHOW_STATE:-ready}" \
    bash "$here/worker-start-check.sh" ctx_agy 2>&1)
  code=$?
  nonzero=0
  [ "$code" -ne 0 ] && nonzero=1
  if [ "$nonzero" = "$2" ] && printf '%s\n' "$out" | grep -qE "$3"; then
    pass=$((pass + 1))
    echo "ok   $1"
  else
    fail=$((fail + 1))
    echo "FAIL $1 (exit $code)"
    printf '%s\n' "$out"
  fi
}

check "antigravity sign-in screen fails" 1 'sign-in step' \
  'You are currently not signed in. Select login method'

check "sign-in prompt split across lines fails" 1 'sign-in step' \
  'You are currently not signed in.
Select login method'

check "normal antigravity screen passes" 0 'ctx_agy ready' \
  'Working on the assigned task
Running the checks
>'

check "quoted login text on a working screen passes" 0 'ctx_agy ready' \
  'The task quotes "You are currently not signed in. Select login method" and then continues.
Working on the assigned task
>'

SHOW_STATE=failed
check "failed dispatch still fails" 1 'FAILED ctx_agy failed' 'Working on the assigned task'
unset SHOW_STATE

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
