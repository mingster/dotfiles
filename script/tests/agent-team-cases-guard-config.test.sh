#!/usr/bin/env bash
# Host deploy sets and guard-config.json extension handling.
# Part of the agent-team.sh tests, split from agent-team.test.sh so the parts run in parallel (#1325).
# shellcheck source=script/tests/lib/asdf-pin.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# shellcheck source=script/tests/lib/agent-team-cases.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/agent-team-cases.sh"

# ── 10. An empty host deploy set is empty, and a union of command name sets is
# extra read only commands merged with the shared defaults, never a replacement.
union="$tmp/name-union"
mkdir -p "$union/.claude/hooks"
git -C "$union" init -q
git -C "$union" config user.name "Test"
git -C "$union" config user.email "test@example.invalid"
cat > "$union/.claude/hooks/guard-bash.py" <<'PY'
GREPS = {"grep", "rg"}
HOST_DEPLOY_COMMANDS = set()
REMOTE_READ_ONLY = {"echo", "ls", "["} | GREPS
PY
printf 'gate.example.invalid\n' > "$union/.claude/hooks/production-hosts.txt"
printf '# Agents\n' > "$union/AGENTS.md"
git -C "$union" add -A
git -C "$union" commit -qm "fixture"
union_out=$(bash "$SCRIPT" project "$union" --project-name fixture 2>&1) || true
union_home="$tmp/union-home"
mkdir -p "$union_home"
if python3 - "$union" "$real_dotfiles/templates/agent-team/.claude/hooks/guard-bash.py" "$union_home" <<'PY'
import json, os, subprocess, sys
root, hook, home = sys.argv[1:]
cfg = json.load(open(os.path.join(root, ".claude/hooks/guard-config.json")))
assert "host_deploy_commands" not in cfg, cfg
assert "remote_read_only" not in cfg, cfg
assert set(cfg.get("remote_read_only_commands") or []) == {"echo", "ls", "[", "grep", "rg"}, cfg

def decide(command):
    payload = json.dumps({"tool_name": "Bash", "cwd": root, "tool_input": {"command": command}})
    out = subprocess.run([sys.executable, hook], input=payload, text=True, capture_output=True,
                         cwd=root, env={**os.environ, "HOME": home})
    if out.returncode != 0:
        raise SystemExit(out.stderr or out.stdout)
    text = out.stdout.strip()
    if not text:
        return "allow"
    return json.loads(text)["hookSpecificOutput"]["permissionDecision"]

host = "root@gate.example.invalid"
assert decide(f"ssh {host} uptime") == "allow", "shared default was replaced"
assert decide(f"ssh {host} 'echo hi'") == "allow", "extra command was dropped"
assert decide(f"ssh {host} 'ls /tmp'") == "allow", "extra command lost its arguments"
assert decide(f"ssh {host} 'rm /tmp/x'") == "deny", "unlisted command was allowed"
PY
then
  check "empty host deploy set and command name union merge with shared defaults" ok
else
  echo "$union_out" >&2
  check "empty host deploy set and command name union merge with shared defaults" bad
fi

# Project guard-config.json is an extension file. Sync keeps project keys and entries,
# adds template defaults that are missing, and a second run leaves the file unchanged.
guard_tpl="$real_dotfiles/templates/agent-team/.claude/hooks/guard-config.json"
keep="$tmp/keep-guard"
mkdir -p "$keep/.claude/hooks"
git -C "$keep" init -q
git -C "$keep" config user.email t@example.invalid
git -C "$keep" config user.name t
cat > "$keep/.claude/hooks/guard-config.json" <<'JSON'
{
  "host_deploy_commands": {
    "root@slot.example": ["echo kept", "echo project-slot"],
    "root@other.example": ["echo other-slot"]
  },
  "remote_read_only": ["uptime", "project-allow"],
  "worktree_env_allow": [".env.local"],
  "project_only": ["stay"]
}
JSON
cat > "$keep/.claude/hooks/guard-bash.py" <<'PY'
HOST_DEPLOY_COMMANDS = {"root@slot.example": ["echo kept"]}
REMOTE_READ_ONLY = ["uptime"]
PY
printf '# Agents\n' > "$keep/AGENTS.md"
git -C "$keep" add -A
git -C "$keep" commit -qm init
keep_out=$(bash "$SCRIPT" project "$keep" --project-name fixture 2>&1)
keep_rc=$?
if [ "$keep_rc" -eq 0 ] && python3 - "$keep" "$guard_tpl" <<'PY'
import json, sys
root, tpl_path = sys.argv[1:]
cfg = json.load(open(root + "/.claude/hooks/guard-config.json"))
tpl = json.load(open(tpl_path))
cmds = cfg["host_deploy_commands"]["root@slot.example"]
assert "echo project-slot" in cmds and "echo kept" in cmds, cmds
assert cfg["host_deploy_commands"]["root@other.example"] == ["echo other-slot"]
assert "project-allow" in cfg["remote_read_only"] and "uptime" in cfg["remote_read_only"]
assert cfg["project_only"] == ["stay"]
assert ".env.local" in cfg["worktree_env_allow"]
for key, value in tpl.items():
    assert key in cfg, key
    if isinstance(value, list):
        for item in value:
            assert item in cfg[key], (key, item)
    elif isinstance(value, dict):
        for child, child_val in value.items():
            assert child in cfg[key], (key, child)
            if isinstance(child_val, list):
                for piece in child_val:
                    assert piece in cfg[key][child], (key, child, piece)
            else:
                assert cfg[key][child] == child_val
    else:
        assert cfg[key] == value
PY
then
  check "sync keeps project guard-config entries and adds missing template defaults" ok
else
  echo "$keep_out" >&2
  check "sync keeps project guard-config entries and adds missing template defaults" bad
fi
keep_first=$(cat "$keep/.claude/hooks/guard-config.json")
keep_again=$(bash "$SCRIPT" sync "$keep" --project-name fixture 2>&1)
keep_second=$(cat "$keep/.claude/hooks/guard-config.json")
if [ -z "$keep_again" ] && [ "$keep_first" = "$keep_second" ] \
  && python3 - "$keep/.claude/hooks/guard-config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
assert "echo project-slot" in cfg["host_deploy_commands"]["root@slot.example"]
PY
then
  check "second sync leaves guard-config.json unchanged" ok
else
  echo "$keep_again" >&2
  check "second sync leaves guard-config.json unchanged" bad
fi

missing="$tmp/missing-guard"
mkdir -p "$missing"
git -C "$missing" init -q
git -C "$missing" config user.email t@example.invalid
git -C "$missing" config user.name t
printf '# Agents\n' > "$missing/AGENTS.md"
git -C "$missing" add -A
git -C "$missing" commit -qm init
if bash "$SCRIPT" project "$missing" --project-name fixture >/dev/null 2>&1 \
  && cmp -s "$missing/.claude/hooks/guard-config.json" "$guard_tpl"; then
  missing_first=$(cat "$missing/.claude/hooks/guard-config.json")
  missing_again=$(bash "$SCRIPT" sync "$missing" --project-name fixture 2>&1)
  missing_second=$(cat "$missing/.claude/hooks/guard-config.json")
  if [ -z "$missing_again" ] && [ "$missing_first" = "$missing_second" ]; then
    check "project with no guard-config.json gets the template copy" ok
  else
    echo "$missing_again" >&2
    check "project with no guard-config.json gets the template copy" bad
  fi
else
  check "project with no guard-config.json gets the template copy" bad
fi

assert_bad_guard_config() {
  local label=$1 body=$2 needle=$3
  local repo="$tmp/bad-guard-$label"
  local before="$tmp/bad-guard-$label.before"
  local out rc=0
  mkdir -p "$repo/.claude/hooks"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.invalid
  git -C "$repo" config user.name t
  printf '%s' "$body" > "$repo/.claude/hooks/guard-config.json"
  cp "$repo/.claude/hooks/guard-config.json" "$before"
  printf '# Agents\n' > "$repo/AGENTS.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm init
  out=$(bash "$SCRIPT" project "$repo" --project-name fixture 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] \
    && cmp -s "$before" "$repo/.claude/hooks/guard-config.json" \
    && printf '%s\n' "$out" | grep -F ".claude/hooks/guard-config.json" >/dev/null \
    && printf '%s\n' "$out" | grep -F "$needle" >/dev/null; then
    check "$label" ok
  else
    printf '%s\n' "$out" >&2
    echo "rc=$rc" >&2
    check "$label" bad
  fi
}
assert_bad_guard_config \
  "invalid guard-config.json is left unchanged and sync fails" \
  '{ "worktree_env_allow": [".env.local",, }' \
  "not valid JSON"
assert_bad_guard_config \
  "array guard-config.json is left unchanged and sync fails" \
  '["x"]' \
  "JSON object"
assert_bad_guard_config \
  "string guard-config.json is left unchanged and sync fails" \
  '"plain"' \
  "JSON object"


agent_team_cases_done
