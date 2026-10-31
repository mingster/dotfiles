#!/usr/bin/env bash
# Shell hook for Cursor (beforeShellExecution) and Antigravity (PreToolUse run_command):
# run the usage gate on every Orca worker-start. The decision lives in script/usage-gate-hook.py;
# this adapter only translates the hook formats. Fails open like the gate itself.
set -uo pipefail

GATE_HOOK="${USAGE_GATE_HOOK:-$HOME/dotfiles/script/usage-gate-hook.py}"

input="$(cat || true)"
format=cursor
command=""
if command -v jq >/dev/null 2>&1 && [[ -n "$input" ]]; then
	if jq -e '.toolCall' <<<"$input" >/dev/null 2>&1; then
		format=antigravity
		command="$(jq -r 'select(.toolCall.name == "run_command") | .toolCall.args.CommandLine // ""' <<<"$input" 2>/dev/null)"
	else
		command="$(jq -r '.command // ""' <<<"$input" 2>/dev/null)"
	fi
fi

allow() {
	if [[ "$format" == antigravity ]]; then
		printf '{"decision":"allow"}\n'
	else
		printf '{"permission":"allow"}\n'
	fi
	exit 0
}

[[ "$command" == *worker-start* ]] || allow
[[ -f "$GATE_HOOK" ]] || allow

verdict="$(jq -nc --arg c "$command" '{tool_name:"Bash",tool_input:{command:$c}}' | python3 "$GATE_HOOK")"
reason="$(jq -r 'select(.hookSpecificOutput.permissionDecision == "deny") | .hookSpecificOutput.permissionDecisionReason' <<<"$verdict" 2>/dev/null)"
[[ -n "$reason" ]] || allow

if [[ "$format" == antigravity ]]; then
	jq -nc --arg r "$reason" '{decision:"deny", reason:$r}'
	exit 0
fi
jq -nc --arg r "$reason" '{permission:"deny", user_message:$r, agent_message:$r}'
exit 2
