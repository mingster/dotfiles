#!/usr/bin/env bash
# Tests for usage-gate.sh. Run: bash ide/cursor/hooks/usage-gate.test.sh
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/usage-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0

# Stub of usage-gate-hook.py: denies a command that mentions "blocked-agent", echoes its input to a file.
cat >"$TMP/stub.py" <<PY
import json, sys
d = json.load(sys.stdin)
open("$TMP/seen.json", "w").write(json.dumps(d))
if "blocked-agent" in d["tool_input"]["command"]:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
        "permissionDecision": "deny", "permissionDecisionReason": "Usage gate blocked blocked-agent."}}))
PY

check() { # <label> <input json> <expected exit> <jq filter> <expected value>
	local out code got
	rm -f "$TMP/seen.json"
	out="$(USAGE_GATE_HOOK="$TMP/stub.py" bash "$HOOK" <<<"$2")"
	code=$?
	got="$(jq -r "$4" <<<"$out" 2>/dev/null)"
	if [[ "$code" -ne "$3" || "$got" != "$5" ]]; then
		echo "FAIL $1: exit $code (want $3), '$4' = '$got' (want '$5') [$out]"
		FAILS=$((FAILS + 1))
	else
		echo "ok   $1"
	fi
}

WS='orca orchestration worker-start --agent blocked-agent --spec x'
OK='orca orchestration worker-start --agent fine-agent --spec x'

check "cursor: blocked provider is denied" "$(jq -nc --arg c "$WS" '{command:$c,cwd:"/"}')" 2 '.permission' deny
check "cursor: deny carries the gate reason" "$(jq -nc --arg c "$WS" '{command:$c}')" 2 '.agent_message' 'Usage gate blocked blocked-agent.'
check "cursor: allowed provider passes" "$(jq -nc --arg c "$OK" '{command:$c}')" 0 '.permission' allow
check "cursor: unrelated command passes" '{"command":"ls -la"}' 0 '.permission' allow
check "cursor: unrelated command never reaches the gate" '{"command":"git status"}' 0 '.permission' allow
[[ ! -e "$TMP/seen.json" ]] && echo "ok   unrelated command skipped the gate" || { echo "FAIL unrelated command reached the gate"; FAILS=$((FAILS + 1)); }

check "antigravity: blocked provider is denied" "$(jq -nc --arg c "$WS" '{toolCall:{name:"run_command",args:{CommandLine:$c}}}')" 0 '.decision' deny
check "antigravity: deny carries the gate reason" "$(jq -nc --arg c "$WS" '{toolCall:{name:"run_command",args:{CommandLine:$c}}}')" 0 '.reason' 'Usage gate blocked blocked-agent.'
check "antigravity: allowed provider passes" "$(jq -nc --arg c "$OK" '{toolCall:{name:"run_command",args:{CommandLine:$c}}}')" 0 '.decision' allow
check "antigravity: other tool passes" '{"toolCall":{"name":"view_file","args":{"AbsolutePath":"/x"}}}' 0 '.decision' allow

check "empty input passes" '' 0 '.permission' allow

out="$(USAGE_GATE_HOOK="$TMP/missing.py" bash "$HOOK" <<<"$(jq -nc --arg c "$WS" '{command:$c}')")"
if [[ "$(jq -r .permission <<<"$out")" == allow ]]; then echo "ok   gate script missing passes"; else echo "FAIL gate script missing: $out"; FAILS=$((FAILS + 1)); fi

[[ "$FAILS" -eq 0 ]] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
