#!/usr/bin/env bash
# #1201: the contradicted verifier rule and the refused small title rule stay out of the team templates.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
if git -C "$root" grep -nE 'never in PR comments|fullstack-dev-small - ' -- templates/agent-team/ >/dev/null; then
  echo "FAIL: a removed rule is back in templates/agent-team/"; fail=1
else echo "ok: contradicted and refused rules are absent"; fi
if grep -q 'post-verdict.sh' "$root/templates/agent-team/.claude/model-routing.md"; then echo "ok: the verifier rule names post-verdict.sh"
else echo "FAIL: verifier rule lacks post-verdict.sh"; fail=1; fi
if grep -q 'fleet-pull.sh' "$root/templates/agent-team/docs/agents/coordinator-operations.md"; then
  echo "FAIL: coordinator-operations.md still tells the coordinator to run fleet-pull.sh"; fail=1
else echo "ok: no per-wake fleet-pull.sh"; fi
exit "$fail"
