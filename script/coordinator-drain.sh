#!/usr/bin/env bash
# The coordinator's inbox check, minus messages it does not need to be woken for.
#   coordinator-drain.sh <args for `orca orchestration check`>   e.g. --run RUN --wait
# Prints the same JSON as the check, without:
#   - "Worker stopped without reporting" for a lead terminal (from the fleet-watch config). Leads hold their dispatch open
#     by design. Each one is counted per lead (a line with the lead's handle appended to COORDINATOR_DRAIN_STATE), and
#     fleet-watch reports the counts in its digest. A worker's stop always passes.
#   - worker_done for a dispatch whose <dispatch>.relayed marker says sent (worker-done-relay.sh sweep already routed it).
# Every other worker_done for a dispatch with an owner record and no .released marker is also saved as
# <dispatch>.done.json (before it is printed), because the check marks it read and the sweep only peeks at unread
# messages. The sweep reads that store, so the waiter reading first loses nothing.
# The check marks what it returns as read, so dropped messages are gone from the inbox. Dropped ones are counted on stderr.
# Env: FLEET_WATCH_CONFIG (default ~/.config/fleet-watch/config.json), WORKER_DONE_OWNER_DIR (default ~/.claude/state/dispatch-owners),
#      COORDINATOR_DRAIN_STATE (dropped lead stops, one handle per line, default ~/.claude/state/coordinator-drain.log).
set -uo pipefail
orca=${ORCA_CLI_COMMAND:-orca}
args=("$@")
case " $* " in *" --json "*) ;; *) args+=(--json) ;; esac

# shellcheck disable=SC2086
$orca orchestration check "${args[@]}" | python3 -c '
import json, os, re, sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
    box = data["result"] if isinstance(data.get("result"), dict) else data
    messages = box["messages"]
except (ValueError, KeyError, TypeError, AttributeError):
    sys.stdout.write(raw)
    sys.exit(0)
config = os.environ.get("FLEET_WATCH_CONFIG") or os.path.expanduser("~/.config/fleet-watch/config.json")
try:
    leads = {lead["terminal"] for lead in json.load(open(config)).get("leads", [])}
except (OSError, ValueError, KeyError, TypeError):
    leads = set()
state_path = os.environ.get("COORDINATOR_DRAIN_STATE") or os.path.expanduser("~/.claude/state/coordinator-drain.log")
owners = os.environ.get("WORKER_DONE_OWNER_DIR") or os.path.expanduser("~/.claude/state/dispatch-owners")

def payload(message):
    value = message.get("payload")
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            return {}
    return value if isinstance(value, dict) else {}

def relayed_already(dispatch):
    try:
        return open(os.path.join(owners, dispatch + ".relayed")).read().strip() not in ("sending", "resending")
    except OSError:
        return False

def save(dispatch, message):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", dispatch):
        return
    try:
        if not open(os.path.join(owners, dispatch)).readline().strip() or os.path.exists(os.path.join(owners, dispatch + ".released")):
            return
        path = os.path.join(owners, dispatch + ".done.json")
        if not os.path.exists(path):
            temporary = "%s.%d.tmp" % (path, os.getpid())
            json.dump(message, open(temporary, "w"))
            os.replace(temporary, path)
    except OSError as error:
        print("coordinator-drain: cannot save worker_done for %s: %s" % (dispatch, error), file=sys.stderr)

kept, lead_stops, relayed, dropped_leads = [], 0, 0, []
for message in messages:
    body = payload(message)
    lead = body.get("handle") or message.get("from_handle") or message.get("from")
    if message.get("subject") == "Worker stopped without reporting" and lead in leads:
        lead_stops += 1
        dropped_leads.append(lead)
    elif message.get("type") == "worker_done" and body.get("dispatchId") and relayed_already(str(body["dispatchId"])):
        relayed += 1
    else:
        if message.get("type") == "worker_done" and body.get("dispatchId"):
            save(str(body["dispatchId"]), message)
        kept.append(message)
box["messages"] = kept
print(json.dumps(data))
if dropped_leads:
    try:
        os.makedirs(os.path.dirname(state_path), exist_ok=True)
        with open(state_path, "a") as stream:
            stream.write("".join(lead + "\n" for lead in dropped_leads))
    except OSError as error:
        print("coordinator-drain: cannot save %s: %s" % (state_path, error), file=sys.stderr)
if lead_stops or relayed:
    print("coordinator-drain: dropped %d (lead stops %d, relayed worker_done %d)" % (lead_stops + relayed, lead_stops, relayed), file=sys.stderr)
'
exit "${PIPESTATUS[0]}"
