#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# Behavioural regression for mingster/projb#563: drives the REAL guard hook (.claude/hooks/guard-bash.py)
# with PreToolUse JSON on stdin. The hook only reads the command text and never runs it, so nothing
# executes. HOME is a temp dir, so no real approval file or ledger is read or written; a sentinel file
# in the command proves the denied command did no further mutation. Run: bash script/tests/release-guard-hook.test.sh [<project root>]
set -u
# Arg 1: a project root whose .claude/hooks/guard-bash.py carries the project guard (projb, proja).
# The generic template hook has no owner-approve or production seam (known gap, see below), so with no
# argument this SKIPs the denial cases and only runs the controls.
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/templates/agent-team}"
HOOK="$ROOT/.claude/hooks/guard-bash.py"
[ -f "$HOOK" ] || { echo "FAIL no hook at $HOOK"; exit 1; }
GATED=0; grep -q "owner-approve" "$HOOK" && GATED=1
PROMOTE="${PROMOTE_CMD:-projb_op/bin/deploy-stage.sh production web2}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SENT="$TMP/sentinel"; fail=0; n=0
run_hook() { # prints the hook stdout for a command string
  python3 -I -c 'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$TMP" "$1" \
    | HOME="$TMP" python3 -I "$HOOK"
}
decision() { python3 -I -c 'import json,sys
d=sys.stdin.read().strip()
print(json.loads(d)["hookSpecificOutput"]["permissionDecision"] if d else "allow")' <<<"$1"; }
check() { # check <name> <command> <expected deny|allow> [needle in reason]
  if [ "$3" = deny ] && [ "$GATED" = 0 ]; then echo "SKIP $1 (hook has no owner-approve guard)"; return; fi
  n=$((n+1)); local out rc dec
  out="$(run_hook "$2")"; rc=$?; dec="$(decision "$out")"
  if [ "$rc" -ne 0 ] || [ "$dec" != "$3" ]; then echo "FAIL $1 (exit $rc, got $dec, want $3)"; fail=1; return; fi
  if [ -n "${4:-}" ] && ! grep -qF -- "$4" <<<"$out"; then echo "FAIL $1 (reason lacks: $4)"; fail=1; return; fi
  echo "ok   $1"
}
SHA=0123456789abcdef0123456789abcdef01234567
APPROVER="bin/owner-approve.sh"
check "approver status denied" "bash $APPROVER status" deny "an agent never runs it"
check "approver --help denied" "bash $APPROVER --help" deny
check "approver wrapped in sh -c denied" "sh -c 'bash $APPROVER status'" deny
check "approver after a mutation: denied, no sentinel" "touch $SENT && bash $APPROVER status" deny
check "variable-\$S production run denied" "$PROMOTE "'$S' deny "literal"
check "variable-\$S after assignment denied" 'S=abc; '"$PROMOTE "'$S' deny "literal"
check "variable-\$S with mutation first denied" "touch $SENT; $PROMOTE "'$S' deny "literal"
check "literal sha without owner approval denied (fail closed)" "$PROMOTE $SHA" deny
check "control: reading the script is allowed" "grep -n status $APPROVER" allow
check "control: git status is allowed" "git status" allow
n=$((n+1)); if [ -e "$SENT" ]; then echo "FAIL sentinel exists: a denied command ran"; fail=1; else echo "ok   sentinel absent: nothing ran after denial"; fi
n=$((n+1)); if [ -e "$TMP/.config" ]; then echo "FAIL hook wrote under temp HOME"; fail=1; else echo "ok   no approval file or ledger created"; fi
echo "$n checks"; exit $fail
