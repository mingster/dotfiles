#!/usr/bin/env bash
# worker-watch.sh <run_id>
# Flags Orca workers stopped by a provider limit or network error (STOPPED), at an
# empty input prompt without busy markers (IDLE), waiting on a dialog (BLOCKED_DIALOG) or a
# tool approval prompt (BLOCKED_APPROVAL)
# near full context (LOW_CONTEXT), a long Codex worktree (LONG_SESSION, calls summed over every session of the worktree) or a gpt-6-astra worker (ASTRA_MODEL).
# Heartbeats and a live terminal do not prove progress, so read the screen.
# Exit 0 all OK, 4 any STOPPED, IDLE, BLOCKED_DIALOG, LOW_CONTEXT, LONG_SESSION or ASTRA_MODEL, 2 usage or orca error.
set -u

[ $# -eq 1 ] && [ -n "$1" ] || { echo "usage: worker-watch.sh <run_id>" >&2; exit 2; }
run="$1"

orca=${ORCA_CLI_COMMAND:-orca}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cursor=""
seen_cursors=" "
while :; do
  args=(orchestration worker-list --run "$run" --include-remote --limit 100 --json)
  [ -z "$cursor" ] || args+=(--cursor "$cursor")
  raw=$("$orca" "${args[@]}" 2>/dev/null) \
    || { echo "worker-watch: worker-list failed for $run" >&2; exit 2; }
  next_info=$(printf '%s' "$raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    with open(sys.argv[1], "a") as f:
        f.write(json.dumps(d) + "\n")
    p = d.get("result", {}).get("page") or {}
    if p.get("hasMore") and p.get("nextCursor"):
        print(p["nextCursor"])
except Exception:
    sys.exit(3)
' "$tmp/pages.jsonl") || { echo "worker-watch: cannot parse worker-list output" >&2; exit 2; }
  [ -n "$next_info" ] || break
  case "$seen_cursors" in *" $next_info "*) break ;; esac
  seen_cursors="$seen_cursors$next_info "
  cursor="$next_info"
done

# One line per unsettled dispatch: <dispatch_id>\t<terminal_handle>\t<environment>\t<disconnected>
rows=$(python3 - "$tmp/pages.jsonl" <<'PY'
import json, sys
workers = []
try:
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            data = json.loads(line)
            workers.extend(data.get("result", {}).get("workers") or [])
except Exception:
    sys.exit(3)

for w in workers:
    p = w.get("projection") or {}
    status = w.get("dispatchStatus") or (p.get("stage") or {}).get("dispatch")
    handle = w.get("agentTerminalHandle") or ((w.get("resource") or {}).get("terminalHandle"))
    if p.get("outcome", "in_progress") != "in_progress" or status in ("completed", "failed", "cancelled", "released") or not handle:
        continue
    host = p.get("host") or {}
    disc = "0"
    if host.get("connected") is False or w.get("connected") is False or p.get("connected") is False or (w.get("resource") or {}).get("connected") is False:
        disc = "1"
    if host.get("status") == "disconnected" or (p.get("liveness") or {}).get("verdict") == "disconnected":
        disc = "1"
    env = ""
    if host.get("kind") == "remote" or (host.get("id") and host.get("id") != "local") or w.get("environment") or p.get("environment"):
        env = (w.get("environment") or p.get("environment") or host.get("environment") or host.get("endpoint") or host.get("id") or (w.get("resource") or {}).get("environment") or "")
        if env == "local":
            env = ""
    print(f"{w['dispatchId']}\t{handle}\t{env}\t{disc}")
PY
) || { echo "worker-watch: cannot parse worker-list output" >&2; exit 2; }

status=0
codex_root="${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
terminal_list=$("$orca" terminal list --json 2>/dev/null || true)
while IFS=$'\t' read -r dispatch handle env disc; do
  [ -n "$dispatch" ] || continue
  if [ "$disc" = "1" ]; then
    verdict="UNKNOWN_COVERAGE"
  else
    eargs=()
    [ -z "$env" ] || eargs=(--environment "$env")
    if ! raw=$("$orca" terminal read ${eargs[@]+"${eargs[@]}"} --terminal "$handle" --screen --json 2>/dev/null); then
      if [ -n "$env" ]; then
        verdict="UNKNOWN_COVERAGE"
      else
        echo "worker-watch: cannot read terminal $handle" >&2; exit 2
      fi
    else
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
approval = re.compile(r"Do you want to (?:proceed|make this edit|create)\?|Would you like to run the following command\?|Yes, proceed \(y\)", re.I)
network = re.compile(r"^\s*(?:⚠\s*)?There was a network issue connecting to the server, please try again\.\s*$", re.I)
marker = re.compile(r"^\s*[⚠■✗✖!]")
# Source, diffs and shell lines are not provider notices.
code = re.compile(r"^\s*(\d+\s*[:|│]|[+\-#]|[│|])|[`=]|\b(grep|printf|echo|check|pattern|re\.compile)\b|[\x27\"]")
ui = tail[-8:]
for l in tail[-8:]:
    if dialog.search(l):
        print("BLOCKED_DIALOG", l.strip()[:160]); sys.exit(0)
for l in tail[-8:]:
    if approval.search(l) and not code.search(l):
        print("BLOCKED_APPROVAL", l.strip()[:160]); sys.exit(0)
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
    fi
  fi
  echo "$dispatch $handle $verdict"
  case "$verdict" in OK) ;; *) status=4 ;; esac
  wt=$(printf '%s' "$terminal_list" | python3 -c 'import json,sys; d=json.load(sys.stdin); h=sys.argv[1]; print(next((t.get("worktreePath", "") for t in d["result"]["terminals"] if t.get("handle")==h), ""))' "$handle" 2>/dev/null || true)
  if [ -n "$wt" ] && [ -d "$codex_root" ]; then
    # Count calls over every Codex session of this worktree: a restart must not reset the count (2026-10-22: 10 restarts, 620 calls, no flag).
    read -r calls astra <<< "$(python3 - "$codex_root" "$wt" <<'PY'
import glob, json, os, subprocess, sys
root, worktree = sys.argv[1:]
calls, astra = 0, 0
for path in glob.glob(os.path.join(root, '**', '*.jsonl'), recursive=True) + glob.glob(os.path.join(root, '**', '*.jsonl.zst'), recursive=True):
    try:
        if path.endswith('.zst'):
            lines = subprocess.run(['zstdcat', '--', path], capture_output=True, text=True, timeout=8).stdout.splitlines()
        else:
            with open(path, errors='replace') as f: lines = f.read().splitlines()
        meta = json.loads(lines[0])
        if meta.get('type') != 'session_meta' or meta.get('payload', {}).get('cwd') != worktree:
            continue
        for l in lines:
            e = json.loads(l)
            if e.get('type') == 'event_msg' and e.get('payload', {}).get('type') == 'token_count':
                calls += 1
            elif e.get('type') == 'turn_context' and str(e.get('payload', {}).get('model', '')).startswith('gpt-6-astra'):
                astra = 1
    except Exception:
        continue
print(calls, astra)
PY
)"
    if [ "${astra:-0}" = 1 ]; then
      echo "$dispatch $handle ASTRA_MODEL needs the owner's yes for this use; end dispatch unless OWNER_ASTRA_YES was recorded"
      status=4
    fi
    if [ "${calls:-0}" -ge 120 ] 2>/dev/null; then
      if [ "$calls" -ge 200 ]; then echo "$dispatch $handle LONG_SESSION $calls calls; end dispatch"; else echo "$dispatch $handle LONG_SESSION $calls calls"; fi
      status=4
    fi
  fi
done <<< "$rows"

exit $status
