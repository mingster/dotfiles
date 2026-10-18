#!/usr/bin/env bash
# worker-watch.sh <run_id>
# Flags Orca workers stopped by a provider limit or network error (STOPPED), at an
# empty input prompt without busy markers (IDLE), waiting on a dialog (BLOCKED_DIALOG)
# near full context (LOW_CONTEXT) or a long Codex session (LONG_SESSION).
# Heartbeats and a live terminal do not prove progress, so read the screen.
# Exit 0 all OK, 4 any STOPPED, IDLE, BLOCKED_DIALOG, LOW_CONTEXT or LONG_SESSION, 2 usage or orca error.
set -u

[ $# -eq 1 ] && [ -n "$1" ] || { echo "usage: worker-watch.sh <run_id>" >&2; exit 2; }
run="$1"

list=$(orca orchestration worker-list --run "$run" --json 2>/dev/null) \
  || { echo "worker-watch: worker-list failed for $run" >&2; exit 2; }

# One line per unsettled dispatch: <dispatch_id> <terminal_handle>
rows=$(printf '%s' "$list" | python3 -c '
import json, sys
try:
    workers = json.load(sys.stdin)["result"]["workers"]
except Exception:
    sys.exit(3)
for w in workers:
    p = w.get("projection") or {}
    handle = w.get("agentTerminalHandle")
    if p.get("outcome", "in_progress") != "in_progress" or not handle:
        continue
    print(w["dispatchId"], handle)
') || { echo "worker-watch: cannot parse worker-list output" >&2; exit 2; }

status=0
codex_root="${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
terminal_list=$(orca terminal list --json 2>/dev/null || true)
while read -r dispatch handle; do
  [ -n "$dispatch" ] || continue
  raw=$(orca terminal read --terminal "$handle" --screen --json 2>/dev/null) \
    || { echo "worker-watch: cannot read terminal $handle" >&2; exit 2; }
  verdict=$(printf '%s' "$raw" | python3 -c '
import json, re, sys
try:
    tail = json.load(sys.stdin)["result"]["terminal"]["tail"]
except Exception:
    sys.exit(3)
tail = [l.rstrip() for l in tail[-30:]]
# Only the providers actual stop messages, never bare words.
stop = re.compile(
    r"Individual quota reached|\bResets in \d|hit your weekly limit"
    r"|spendLimitHit: true|usage limit reached|limit will reset|Context limit reached"
    r"|Run /compact to|You.ve hit your usage limit|Switch to a different model or set a Spend Limit|Selected model is at capacity", re.I)
dialog = re.compile(r"Workspace Trust Required", re.I)
network = re.compile(r"^\s*(?:⚠\s*)?There was a network issue connecting to the server, please try again\.\s*$", re.I)
marker = re.compile(r"^\s*[⚠■✗✖!]")
# Source, diffs and shell lines are not provider notices.
code = re.compile(r"^\s*(\d+\s*[:|│]|[+\-#]|[│|])|[`=]|\b(grep|printf|echo|check|pattern|re\.compile)\b|[\x27\"]")
ui = tail[-8:]
for l in tail[-8:]:
    if dialog.search(l):
        print("BLOCKED_DIALOG", l.strip()[:160]); sys.exit(0)
for l in tail:
    if network.fullmatch(l) and (l in ui or marker.match(l)):
        print("STOPPED", l.strip()[:160]); sys.exit(0)
    if re.match(r"^\s*You.ve hit your usage limit", l) and l in ui:
        print("STOPPED", l.strip()[:160]); sys.exit(0)
    if stop.search(l) and (l in ui or marker.match(l)) and (marker.match(l) or not code.search(l)):
        print("STOPPED", l.strip()[:160]); sys.exit(0)
for l in tail[-5:]:
    m = re.search(r"ctx:\s*(\d+)%", l)
    if m and int(m.group(1)) >= 80:
        print("LOW_CONTEXT", l.strip()[:160]); sys.exit(0)
# Empty provider input prompts indicate an ended turn unless the UI is busy.
recent = [l for l in ui if l.strip()]
busy = re.compile(r"[\u2801-\u28ff]|\b(?:Running|Thinking)\b|esc to interrupt", re.I)
if recent and re.fullmatch(r"\s*[>›❯]\s*", recent[-1]) and not any(
    busy.search(l) and not code.search(l) for l in ui
):
    print("IDLE", recent[-1].strip()); sys.exit(0)
print("OK")
') || { echo "worker-watch: cannot read terminal $handle" >&2; exit 2; }
  echo "$dispatch $handle $verdict"
  case "$verdict" in OK) ;; *) status=4 ;; esac
  wt=$(printf '%s' "$terminal_list" | python3 -c 'import json,sys; d=json.load(sys.stdin); h=sys.argv[1]; print(next((t.get("worktreePath", "") for t in d["result"]["terminals"] if t.get("handle")==h), ""))' "$handle" 2>/dev/null || true)
  if [ -n "$wt" ] && [ -d "$codex_root" ]; then
    session=$(python3 - "$codex_root" "$wt" <<'PY'
import glob, json, os, sys
root, worktree = sys.argv[1:]
matches = []
for path in glob.glob(os.path.join(root, '**', '*.jsonl'), recursive=True) + glob.glob(os.path.join(root, '**', '*.jsonl.zst'), recursive=True):
    try:
        if path.endswith('.zst'):
            import subprocess
            head = subprocess.run(['zstdcat', '--', path], capture_output=True, text=True, timeout=2).stdout.splitlines()[:1]
        else:
            with open(path, errors='replace') as f: head = [f.readline()]
        meta = json.loads(head[0])
        if meta.get('type') == 'session_meta' and meta.get('payload', {}).get('cwd') == worktree:
            matches.append(path)
    except Exception:
        continue
print(max(matches, key=lambda p: os.path.getmtime(p)) if matches else '')
PY
)
    if [ -n "$session" ]; then
      calls=$(timeout 8 sh -c 'case "$1" in *.zst) zstdcat -- "$1";; *) cat -- "$1";; esac' sh "$session" 2>/dev/null | python3 -c 'import json,sys; print(sum(1 for l in sys.stdin if json.loads(l).get("type")=="event_msg" and json.loads(l).get("payload",{}).get("type")=="token_count"))' 2>/dev/null || echo 0)
      if [ "$calls" -ge 120 ] 2>/dev/null; then
        if [ "$calls" -ge 200 ]; then echo "$dispatch $handle LONG_SESSION $calls calls; end dispatch"; else echo "$dispatch $handle LONG_SESSION $calls calls"; fi
        status=4
      fi
    fi
  fi
done <<< "$rows"

exit $status
