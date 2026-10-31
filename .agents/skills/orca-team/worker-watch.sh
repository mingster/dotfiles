#!/usr/bin/env bash
# worker-watch.sh <run_id>
# Flags Orca workers stopped by a provider limit or network error (STOPPED), at an
# empty input prompt without busy markers (IDLE), waiting on a dialog (BLOCKED_DIALOG) or a
# tool approval prompt (BLOCKED_APPROVAL)
# or near full context (LOW_CONTEXT).
# Heartbeats and a live terminal do not prove progress, so read the screen.
# Exit 0 all OK, 4 any STOPPED, IDLE, BLOCKED_DIALOG or LOW_CONTEXT, 2 usage or orca error.
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
done <<< "$rows"

exit $status
