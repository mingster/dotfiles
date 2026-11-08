#!/usr/bin/env bash
# Behavioral tests for templates/agent-team/.claude/hooks/worker-budget.py (#732).
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$ROOT/templates/agent-team/.claude/hooks/worker-budget.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

WORKTREE="$TMP/orca/workspaces/proj/fullstack-dev-1"
LEAD_WT="$TMP/orca/workspaces/proj/lead-elon"
mkdir -p "$WORKTREE" "$LEAD_WT"

run_hook() {
  local cwd="$1" session="$2" transcript="$3" event="$4" tool="$5" cmd="${6:-}" resp="${7:-}"
  python3 -c 'import json,sys
payload = {
  "cwd": sys.argv[1],
  "session_id": sys.argv[2],
  "transcript_path": sys.argv[3],
  "hook_event_name": sys.argv[4],
  "tool_name": sys.argv[5],
  "tool_input": {"command": sys.argv[6]} if sys.argv[6] else {}
}
if sys.argv[7]:
  payload["tool_response"] = {"stdout": sys.argv[7]}
print(json.dumps(payload))' "$cwd" "$session" "$transcript" "$event" "$tool" "$cmd" "$resp" | HOME="$TMP" python3 "$HOOK"
}

decision() {
  python3 -c 'import json,sys
d=sys.stdin.read().strip()
print(json.loads(d)["hookSpecificOutput"].get("permissionDecision","allow") if d else "allow")' <<<"$1"
}

# 1. Turn budget warn at 120, deny at 200
T1="$TMP/t1.jsonl"
python3 -I -c 'import json,sys
with open(sys.argv[1],"w") as f:
    f.write(json.dumps({"type":"user","message":{"role":"user","content":"You are a dispatched worker.\norca orchestration send --type worker_done --task-id task_1 --dispatch-id ctx_turn1"}})+"\n")
    for i in range(int(sys.argv[2])):
        f.write(json.dumps({"type":"assistant","message":{"id":f"msg_{i}"}})+"\n")
' "$T1" 120

warn_out="$(run_hook "$WORKTREE" "s-turn1" "$T1" "PostToolUse" "Edit")"
if grep -qF "Worker budget: 120 turns" <<<"$warn_out"; then
  ok "warns at 120 turns"
else
  bad "failed to warn at 120 turns ($warn_out)"
fi

python3 -I -c 'import json,sys
with open(sys.argv[1],"a") as f:
    for i in range(120, 200):
        f.write(json.dumps({"type":"assistant","message":{"id":f"msg_{i}"}})+"\n")
' "$T1"

stop_out="$(run_hook "$WORKTREE" "s-turn1" "$T1" "PreToolUse" "Edit")"
if [ "$(decision "$stop_out")" = "deny" ]; then
  ok "denies Edit at 200 turns"
else
  bad "failed to deny Edit at 200 turns ($stop_out)"
fi

lead_out="$(run_hook "$LEAD_WT" "s-lead" "$T1" "PreToolUse" "Edit")"
if [ "$(decision "$lead_out")" = "allow" ]; then
  ok "lead-* worktree is never capped"
else
  bad "lead-* worktree was capped ($lead_out)"
fi

# 2. Post-worker_done lock for current --dispatch-id ctx_<id>, lifted by new --dispatch-id ctx_<id2>
T2="$TMP/t2.jsonl"
python3 -I -c 'import json,sys
with open(sys.argv[1],"w") as f:
    f.write(json.dumps({"type":"user","message":{"role":"user","content":"You are a dispatched worker.\nSend: orca orchestration send --from term_1 --type worker_done --task-id task_1 --dispatch-id ctx_first --outcome succeeded"}})+"\n")
    f.write(json.dumps({"type":"assistant","message":{"id":"msg_1","content":[{"type":"tool_use","name":"Edit","input":{}}]}})+"\n")
' "$T2"

# Before worker_done is sent, non-read PreToolUse calls are allowed
before_edit="$(run_hook "$WORKTREE" "s-done" "$T2" "PreToolUse" "Edit")"
before_bash="$(run_hook "$WORKTREE" "s-done" "$T2" "PreToolUse" "Bash" "git status")"
if [ "$(decision "$before_edit")" = "allow" ] && [ "$(decision "$before_bash")" = "allow" ]; then
  ok "allows non-read PreToolUse before worker_done is sent"
else
  bad "denied PreToolUse before worker_done ($before_edit / $before_bash)"
fi

# Record worker_done in the transcript for ctx_first
python3 -I -c 'import json,sys
with open(sys.argv[1],"a") as f:
    f.write(json.dumps({"type":"assistant","message":{"id":"msg_2","content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"orca orchestration send --from term_1 --type worker_done --subject done --body ok --task-id task_1 --dispatch-id ctx_first --outcome succeeded"}}]}})+"\n")
    f.write(json.dumps({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_1","content":"{\"ok\":true}"}]}})+"\n")
' "$T2"

after_edit="$(run_hook "$WORKTREE" "s-done" "$T2" "PreToolUse" "Edit")"
after_write="$(run_hook "$WORKTREE" "s-done" "$T2" "PreToolUse" "Write")"
after_bash="$(run_hook "$WORKTREE" "s-done" "$T2" "PreToolUse" "Bash" "orca orchestration check")"
after_read="$(run_hook "$WORKTREE" "s-done" "$T2" "PreToolUse" "Read")"
after_grep="$(run_hook "$WORKTREE" "s-done" "$T2" "PreToolUse" "Grep")"

if [ "$(decision "$after_edit")" = "deny" ] \
  && [ "$(decision "$after_write")" = "deny" ] \
  && [ "$(decision "$after_bash")" = "deny" ]; then
  ok "denies non-read PreToolUse calls (Edit, Write, Bash) after worker_done for ctx_first"
else
  bad "failed to deny non-read PreToolUse after worker_done (edit=$after_edit write=$after_write bash=$after_bash)"
fi

if [ "$(decision "$after_read")" = "allow" ] && [ "$(decision "$after_grep")" = "allow" ]; then
  ok "allows read PreToolUse calls (Read, Grep) after worker_done"
else
  bad "denied read PreToolUse after worker_done (read=$after_read grep=$after_grep)"
fi

# Newer user message introduces a new --dispatch-id ctx_second -> lifts the block
python3 -I -c 'import json,sys
with open(sys.argv[1],"a") as f:
    f.write(json.dumps({"type":"user","message":{"role":"user","content":"You are a dispatched worker.\nSend: orca orchestration send --from term_1 --type worker_done --task-id task_2 --dispatch-id ctx_second --outcome succeeded"}})+"\n")
    f.write(json.dumps({"type":"assistant","message":{"id":"msg_3"}})+"\n")
' "$T2"

re_edit="$(run_hook "$WORKTREE" "s-done" "$T2" "PreToolUse" "Edit")"
re_bash="$(run_hook "$WORKTREE" "s-done" "$T2" "PreToolUse" "Bash" "git status")"
if [ "$(decision "$re_edit")" = "allow" ] && [ "$(decision "$re_bash")" = "allow" ]; then
  ok "lifts block when newer user message introduces --dispatch-id ctx_second"
else
  bad "failed to lift block on new dispatch-id (edit=$re_edit bash=$re_bash)"
fi

# Sending worker_done for ctx_second re-engages the block for ctx_second
run_hook "$WORKTREE" "s-done" "$T2" "PostToolUse" "Bash" \
  "orca orchestration send --from term_1 --type worker_done --subject done --body ok --task-id task_2 --dispatch-id ctx_second --outcome succeeded" \
  '{"ok":true}' >/dev/null

second_done_bash="$(run_hook "$WORKTREE" "s-done" "$T2" "PreToolUse" "Bash" "echo more work")"
if [ "$(decision "$second_done_bash")" = "deny" ]; then
  ok "PostToolUse worker_done for ctx_second denies subsequent Bash PreToolUse"
else
  bad "PostToolUse worker_done for ctx_second did not deny subsequent Bash ($second_done_bash)"
fi

# 3. Prose, failed worker_done, worker_done send/retry allowed, and tool_result ctx_ does not unlock
T3="$TMP/t3.jsonl"
WD_CMD="orca orchestration send --from term_1 --type worker_done --subject done --body ok --task-id task_3 --dispatch-id ctx_p1 --outcome succeeded"
python3 -I -c 'import json,sys
with open(sys.argv[1],"w") as f:
    f.write(json.dumps({"type":"user","message":{"role":"user","content":"You are a dispatched worker.\nSend: "+sys.argv[2]}})+"\n")
    f.write(json.dumps({"type":"assistant","message":{"id":"msg_p1","content":[{"type":"text","text":"I will run: "+sys.argv[2]}]}})+"\n")
' "$T3" "$WD_CMD"

prose_edit="$(run_hook "$WORKTREE" "s-p1" "$T3" "PreToolUse" "Edit")"
if [ "$(decision "$prose_edit")" = "allow" ]; then
  ok "assistant prose quoting worker_done does not lock session"
else
  bad "assistant prose quoting worker_done locked session ($prose_edit)"
fi

# Flush Bash tool_use for worker_done (before tool_result) and verify the send itself is allowed, then fail with worker_identity_changed
python3 -I -c 'import json,sys
with open(sys.argv[1],"a") as f:
    f.write(json.dumps({"type":"assistant","message":{"id":"msg_p2","content":[{"type":"tool_use","id":"tu_fail","name":"Bash","input":{"command":sys.argv[2]}}]}})+"\n")
' "$T3" "$WD_CMD"

self_send="$(run_hook "$WORKTREE" "s-p1" "$T3" "PreToolUse" "Bash" "$WD_CMD")"
if [ "$(decision "$self_send")" = "allow" ]; then
  ok "PreToolUse never denies the worker_done send itself"
else
  bad "PreToolUse denied the worker_done send itself ($self_send)"
fi

python3 -I -c 'import json,sys
with open(sys.argv[1],"a") as f:
    f.write(json.dumps({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_fail","content":"{\"ok\":false,\"error\":\"worker_identity_changed\"}"}]}})+"\n")
' "$T3"
run_hook "$WORKTREE" "s-p1" "$T3" "PostToolUse" "Bash" "$WD_CMD" '{"ok":false,"error":"worker_identity_changed"}' >/dev/null

after_fail_bash="$(run_hook "$WORKTREE" "s-p1" "$T3" "PreToolUse" "Bash" "orca orchestration send --from term_1 --type status --subject s --body b")"
if [ "$(decision "$after_fail_bash")" = "allow" ]; then
  ok "failed worker_done (worker_identity_changed) does not lock session"
else
  bad "failed worker_done locked session ($after_fail_bash)"
fi

# Successful worker_done locks non-read tools, allows worker_done retry, and is not unlocked by a tool_result mentioning another --dispatch-id
python3 -I -c 'import json,sys
with open(sys.argv[1],"a") as f:
    f.write(json.dumps({"type":"assistant","message":{"id":"msg_p3","content":[{"type":"tool_use","id":"tu_ok","name":"Bash","input":{"command":sys.argv[2]}}]}})+"\n")
    f.write(json.dumps({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_ok","content":"{\"ok\":true}"}]}})+"\n")
    f.write(json.dumps({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_other","content":"printed --dispatch-id ctx_from_tool_result"}]}})+"\n")
' "$T3" "$WD_CMD"

retry_send="$(run_hook "$WORKTREE" "s-p1" "$T3" "PreToolUse" "Bash" "$WD_CMD")"
tr_unlock_edit="$(run_hook "$WORKTREE" "s-p1" "$T3" "PreToolUse" "Edit")"
if [ "$(decision "$retry_send")" = "allow" ] && [ "$(decision "$tr_unlock_edit")" = "deny" ]; then
  ok "allows worker_done retry and tool_result with --dispatch-id ctx_ does not unlock"
else
  bad "retry_send=$(decision "$retry_send") tr_unlock_edit=$(decision "$tr_unlock_edit")"
fi

# 4. Default non-JSON output of orca orchestration send locks on success, not on error/worker_identity_changed
T4="$TMP/t4.jsonl"
WD_CMD4="orca orchestration send --from term_1 --type worker_done --subject done --body ok --task-id task_4 --dispatch-id ctx_nonjson --outcome succeeded"
NONJSON_OK=$'messageId=msg_abc123 lifecycle=completed autoReleaseAt=2026-11-09T01:00:00Z\nNext: Recorded. End your turn.'
NONJSON_ERR="Error: worker_identity_changed (expected term_1)"
python3 -I -c 'import json,sys
with open(sys.argv[1],"w") as f:
    f.write(json.dumps({"type":"user","message":{"role":"user","content":"You are a dispatched worker.\nSend: "+sys.argv[2]}})+"\n")
    f.write(json.dumps({"type":"assistant","message":{"id":"msg_nj1","content":[{"type":"tool_use","id":"tu_nj_err","name":"Bash","input":{"command":sys.argv[2]}}]}})+"\n")
    f.write(json.dumps({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_nj_err","content":sys.argv[3]}]}})+"\n")
' "$T4" "$WD_CMD4" "$NONJSON_ERR"
run_hook "$WORKTREE" "s-nj" "$T4" "PostToolUse" "Bash" "$WD_CMD4" "$NONJSON_ERR" >/dev/null
nj_after_err="$(run_hook "$WORKTREE" "s-nj" "$T4" "PreToolUse" "Edit")"

python3 -I -c 'import json,sys
with open(sys.argv[1],"a") as f:
    f.write(json.dumps({"type":"assistant","message":{"id":"msg_nj2","content":[{"type":"tool_use","id":"tu_nj_ok","name":"Bash","input":{"command":sys.argv[2]}}]}})+"\n")
    f.write(json.dumps({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_nj_ok","content":sys.argv[3]}]}})+"\n")
' "$T4" "$WD_CMD4" "$NONJSON_OK"
nj_after_transcript="$(run_hook "$WORKTREE" "s-nj" "$T4" "PreToolUse" "Edit")"

T4B="$TMP/t4b.jsonl"
python3 -I -c 'import json,sys
with open(sys.argv[1],"w") as f:
    f.write(json.dumps({"type":"user","message":{"role":"user","content":"You are a dispatched worker.\nSend: "+sys.argv[2]}})+"\n")
' "$T4B" "$WD_CMD4"
run_hook "$WORKTREE" "s-nj-post" "$T4B" "PostToolUse" "Bash" "$WD_CMD4" "$NONJSON_OK" >/dev/null
nj_after_post="$(run_hook "$WORKTREE" "s-nj-post" "$T4B" "PreToolUse" "Edit")"

if [ "$(decision "$nj_after_err")" = "allow" ] \
  && [ "$(decision "$nj_after_transcript")" = "deny" ] \
  && [ "$(decision "$nj_after_post")" = "deny" ]; then
  ok "accepts default non-JSON worker_done output while rejecting non-JSON error/worker_identity_changed"
else
  bad "non-JSON handling failed (err=$(decision "$nj_after_err") transcript=$(decision "$nj_after_transcript") post=$(decision "$nj_after_post"))"
fi

# 5. WORKER_DONE_RE matches after newline, &&, ||, or ;
T5="$TMP/t5.jsonl"
WD_CMD5="orca orchestration send --from term_1 --type worker_done --subject done --body ok --task-id task_5 --dispatch-id ctx_chain --outcome succeeded"
python3 -I -c 'import json,sys
with open(sys.argv[1],"w") as f:
    f.write(json.dumps({"type":"user","message":{"role":"user","content":"You are a dispatched worker.\nSend: "+sys.argv[2]}})+"\n")
' "$T5" "$WD_CMD5"

chain_ok=1
idx=0
for chained in \
  "cd /tmp && $WD_CMD5" \
  "true || $WD_CMD5" \
  "echo hi; $WD_CMD5" \
  $'cd /tmp\n'"$WD_CMD5"; do
  idx=$((idx + 1))
  s_id="s-chain-$idx"
  pre_self="$(run_hook "$WORKTREE" "$s_id" "$T5" "PreToolUse" "Bash" "$chained")"
  run_hook "$WORKTREE" "$s_id" "$T5" "PostToolUse" "Bash" "$chained" '{"ok":true}' >/dev/null
  post_edit="$(run_hook "$WORKTREE" "$s_id" "$T5" "PreToolUse" "Edit")"
  pre_retry="$(run_hook "$WORKTREE" "$s_id" "$T5" "PreToolUse" "Bash" "$chained")"
  if [ "$(decision "$pre_self")" != "allow" ] || [ "$(decision "$post_edit")" != "deny" ] || [ "$(decision "$pre_retry")" != "allow" ]; then
    chain_ok=0
  fi
done

if [ "$chain_ok" -eq 1 ]; then
  ok "matches worker_done after &&, ||, ;, and newline"
else
  bad "failed to match worker_done after command separators or newline"
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
