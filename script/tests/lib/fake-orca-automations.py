import json
import os
import sys
import time
import uuid
from pathlib import Path

store = Path(os.environ["FAKE_ORCA_STORE"])


def load():
    if store.exists():
        return json.loads(store.read_text())
    return {"automations": [], "runs": []}


def save(data):
    store.parent.mkdir(parents=True, exist_ok=True)
    store.write_text(json.dumps(data, indent=2))


def ok(payload):
    print(json.dumps({"ok": True, "result": payload}))
    return 0


def fail(msg):
    print(json.dumps({"ok": False, "error": {"message": msg}}))
    return 1


def parse_flags(argv):
    flags = {}
    rest = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--"):
            key = a[2:].replace("-", "_")
            if i + 1 < len(argv) and not argv[i + 1].startswith("--"):
                flags[key] = argv[i + 1]
                i += 2
                continue
            flags[key] = True
            i += 1
        else:
            rest.append(a)
            i += 1
    return flags, rest


def find_by_name(data, name):
    for a in data["automations"]:
        if a.get("name") == name:
            return a
    return None


def find_by_id(data, aid):
    for a in data["automations"]:
        if a.get("id") == aid:
            return a
    return None


def automation_payload(flags, name=None):
    aid = flags.get("id") or str(uuid.uuid4())
    precheck = flags.get("precheck")
    timeout = int(flags.get("precheck_timeout") or 60)
    enabled = "disabled" not in flags
    trigger = flags.get("trigger") or "*/5 * * * *"
    row = {
        "id": aid,
        "name": name or flags.get("name"),
        "prompt": flags.get("prompt") or "Script only job, the precheck always stops it.",
        "precheck": {"command": precheck, "timeoutSeconds": timeout} if precheck else None,
        "agentId": flags.get("provider") or "claude",
        "rrule": trigger,
        "enabled": enabled,
        "setupDecision": flags.get("setup") or "skip",
        "repo": flags.get("repo"),
        "timezone": flags.get("timezone"),
    }
    return row


def cmd_automations(argv):
    if not argv:
        return fail("missing subcommand")
    sub = argv[0]
    flags, rest = parse_flags(argv[1:])
    data = load()
    if sub == "list":
        return ok({"automations": data["automations"]})
    if sub == "show":
        aid = flags.get("id") or (rest[0] if rest else None)
        if not aid:
            name = rest[0] if rest else None
            row = find_by_name(data, name) if name else None
        else:
            row = find_by_id(data, aid)
        if not row:
            return fail("Automation not found.")
        return ok({"automation": row})
    if sub == "create":
        row = automation_payload(flags)
        if find_by_name(data, row["name"]):
            return fail("name taken")
        data["automations"].append(row)
        save(data)
        return ok({"automation": row})
    if sub == "edit":
        aid = flags.get("id") or (rest[0] if rest else None)
        row = find_by_id(data, aid)
        if not row:
            return fail("Automation not found.")
        if "trigger" in flags:
            row["rrule"] = flags["trigger"]
        if "precheck" in flags:
            row["precheck"] = {
                "command": flags["precheck"],
                "timeoutSeconds": int(
                    flags.get("precheck_timeout")
                    or row.get("precheck", {}).get("timeoutSeconds")
                    or 60
                ),
            }
        elif "precheck_timeout" in flags and row.get("precheck"):
            row["precheck"]["timeoutSeconds"] = int(flags["precheck_timeout"])
        if "disabled" in flags:
            row["enabled"] = False
        if "enabled" in flags:
            row["enabled"] = True
        if "timezone" in flags:
            row["timezone"] = flags["timezone"]
        save(data)
        return ok({"automation": row})
    if sub == "remove":
        aid = flags.get("id") or (rest[0] if rest else None)
        before = len(data["automations"])
        data["automations"] = [a for a in data["automations"] if a.get("id") != aid]
        if len(data["automations"]) == before:
            return fail("Automation not found.")
        save(data)
        return ok({"removed": aid})
    if sub == "run":
        aid = flags.get("id") or (rest[0] if rest else None)
        row = find_by_id(data, aid)
        if not row:
            return fail("Automation not found.")
        run = {
            "id": str(uuid.uuid4()),
            "automationId": aid,
            "status": "skipped_precheck",
            "startedAt": int(time.time() * 1000),
        }
        data["runs"].append(run)
        save(data)
        return ok({"run": run})
    if sub == "runs":
        aid = flags.get("id")
        runs = [r for r in data["runs"] if not aid or r.get("automationId") == aid]
        return ok({"runs": runs})
    return fail("unsupported automations subcommand")


def main():
    argv = sys.argv[1:]
    if not argv:
        return fail("no command")
    if argv[0] != "automations":
        return fail("unsupported command")
    return cmd_automations(argv[1:])


if __name__ == "__main__":
    raise SystemExit(main())
