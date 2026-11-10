#!/usr/bin/env bash
# Behavioral tests for the approval secret rules in templates/agent-team/.claude/hooks/guard-bash.py:
# a command that names the secret file or AGENT_APPROVAL_SECRET, a glob into the approval folder, and a Read of the secret file.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$ROOT/templates/agent-team/.claude/hooks/guard-bash.py"
SETTINGS="$ROOT/templates/agent-team/.claude/settings.json"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
PROJ="$TMP/proj"
mkdir -p "$HOME_DIR/.config/acme" "$PROJ/.claude/hooks"
git -C "$PROJ" init -q -b main
cat > "$PROJ/.claude/hooks/guard-config.json" <<'JSON'
{ "approval_namespace": "acme" }
JSON

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

run_hook() {
  python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[2],"cwd":sys.argv[1],"tool_input":{"command":sys.argv[3],"file_path":sys.argv[3]}}))' "$PROJ" "$1" "$2" \
    | HOME="$HOME_DIR" python3 "$HOOK"
}

decision() {
  python3 -c 'import json,sys
d=sys.stdin.read().strip()
print(json.loads(d)["hookSpecificOutput"]["permissionDecision"] if d else "allow")' <<<"$1"
}

MSG="sign the owner's sysadmin approval: an agent never reads them, with any program. Only the owner's own terminal and the server use the secret."

# check <label> <tool> <command or path> <allow|deny> [any]  (any: an older approval folder rule may deny first)
check() {
  local out dec
  out="$(run_hook "$2" "$3")"
  dec="$(decision "$out")"
  if [ "$dec" != "$4" ]; then
    bad "$1 (got $dec, want $4; out=$out)"
  elif [ "$4" = deny ] && [ "${5:-}" != any ] && ! grep -qF -- "$MSG" <<<"$out"; then
    bad "$1 (deny without the secret message: $out)"
  else
    ok "$1"
  fi
}

S="$HOME_DIR/.config/acme/approval-secret"
printf fake > "$S"
ln -s "$S" "$TMP/link"

# Deny: the secret file with any program
check "cat of the secret file is denied" Bash "cat $S" deny
check "cat with a tilde path is denied" Bash "cat ~/.config/acme/approval-secret" deny
check "cat under \$HOME is denied" Bash 'cat "$HOME/.config/acme/approval-secret"' deny
check "a namespace other than the configured one is denied" Bash "cat ~/.config/other/approval-secret" deny
check "grep of the secret file is denied" Bash "grep . $S" deny
check "head of the secret file is denied" Bash "head -c 4 $S" deny
check "cp of the secret file is denied" Bash "cp $S /tmp/x" deny
check "python reading the secret file is denied" Bash "python3 -c \"print(open('$S').read())\"" deny
check "bash -c reading the secret file is denied" Bash "bash -c 'cat $S'" deny
check "a redirect from the secret file is denied" Bash "wc -c < $S" deny
check "a command substitution reading the secret is denied" Bash "echo \"\$(cat $S)\"" deny any
check "git add of the secret file is denied" Bash "git add $S" deny
check "a split quote path is denied" Bash "cat ~/.config/acme/approval-'secret'" deny
check "a bare file name after cd is denied" Bash "cd ~/.config/acme && cat approval-secret" deny any
check "a bare file name outside the approval folder is denied" Bash "cat approval-secret" deny

# Deny: the env name
check "printenv of the env name is denied" Bash "printenv AGENT_APPROVAL_SECRET" deny
check "echoing the env variable is denied" Bash 'echo $AGENT_APPROVAL_SECRET' deny
check "an env prefix naming the variable is denied" Bash "AGENT_APPROVAL_SECRET=x python3 -c 'print(1)'" deny
check "python reading the env variable is denied" Bash "python3 -c \"import os; print(os.environ['AGENT_APPROVAL_SECRET'])\"" deny
check "export of the env variable is denied" Bash "export AGENT_APPROVAL_SECRET=abc" deny

# Deny: a glob into the approval folder
check "a star glob in the approval folder is denied" Bash "cat ~/.config/acme/*" deny
check "a prefix glob is denied" Bash "cat ~/.config/acme/approval-*" deny
check "a question mark glob is denied" Bash "cat ~/.config/acme/approval-secre?" deny
check "a bracket glob is denied" Bash "cat ~/.config/acme/approval-[s]ecret" deny
check "a glob in the namespace is denied" Bash "cat ~/.config/*/approval-secret" deny
check "ls of a glob in the approval folder is denied" Bash "ls ~/.config/acme/*.json" deny

# Allow: prose mentions and unrelated commands, like the approval file rule
check "echo of a prose mention is allowed" Bash "echo 'the AGENT_APPROVAL_SECRET env name signs approvals'" allow
check "echo of a prose path mention is allowed" Bash "echo 'the owner keeps ~/.config/other/approval-secret private'" allow
check "a commit message mention is allowed" Bash "git commit -m 'guard AGENT_APPROVAL_SECRET and approval-secret reads'" allow
check "a gh body mention is allowed" Bash "gh pr create --title t --body 'denies approval-secret and AGENT_APPROVAL_SECRET'" allow
check "ls of the approval folder without a glob is allowed" Bash "ls ~/.config/acme" allow
check "a glob outside the approval folder is allowed" Bash "ls ~/.config/other-tool/*.json" allow
check "an unrelated file in the repo is allowed" Bash "cat README.md" allow
check "a similar env name is allowed" Bash "echo \$AGENT_APPROVAL_TTL" allow
check "a file named approval-secrets.md is allowed" Bash "cat docs/approval-secrets.md" allow

# Read tool: only the secret file is denied
check "Read of the secret file is denied" Read "$S" deny
check "Read of the secret file by tilde path is denied" Read "~/.config/acme/approval-secret" deny
check "Read of the secret file in another namespace is denied" Read "$HOME_DIR/.config/other/approval-secret" deny
check "Read of a relative path reaching the secret file is denied" Read "../home/.config/acme/../acme/approval-secret" deny
check "Read of a symlink to the secret file is denied" Read "$TMP/link" deny
check "Read of a repo file is allowed" Read "$PROJ/README.md" allow
check "Read of the approval file is allowed" Read "$HOME_DIR/.config/acme/approval.json" allow
check "Read of a similarly named file is allowed" Read "$HOME_DIR/.config/acme/approval-secret-notes.md" allow
check "Read of a file under a folder of that name is allowed" Read "$PROJ/docs/approval-secret/README.md" allow

# An approval file override moves the folder; the secret stays beside it.
cat > "$PROJ/.claude/hooks/guard-config.json" <<JSON
{ "approval_file": "$TMP/owner/approval.json" }
JSON
mkdir -p "$TMP/owner"
check "override: cat of the secret beside the override file is denied" Bash "cat $TMP/owner/approval-secret" deny
check "override: a glob in the override folder is denied" Bash "cat $TMP/owner/*" deny
check "override: Read of the secret beside the override file is denied" Read "$TMP/owner/approval-secret" deny
check "override: Read of another file in the folder is allowed" Read "$TMP/owner/notes.md" allow

# The settings template runs the hook for Read as well as the edit tools.
if python3 - "$SETTINGS" <<'PY'
import json, sys
pre = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
hit = [g for g in pre if "Read" in g.get("matcher", "").split("|")
       and any("guard-bash.py" in h.get("command", "") for h in g.get("hooks", []))]
sys.exit(0 if hit else 1)
PY
then ok "settings matcher runs guard-bash.py for Read"; else bad "settings matcher does not include Read for guard-bash.py"; fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
