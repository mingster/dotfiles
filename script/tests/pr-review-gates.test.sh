#!/usr/bin/env bash
# Unit tests for script/lib/pr-review-gates.sh (Elon review of #765).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/asdf-pin.sh
. "$here/tests/lib/asdf-pin.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# shellcheck disable=SC1091
. "$here/lib/pr-review-gates.sh"
export WORKER_STARTUP_STATE="$tmp/launch-state"
mkdir -p "$WORKER_STARTUP_STATE/launches"

pass=0 fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
refuse() { printf '%s' "$1" >&2; return 1; }

cat >"$tmp/fake-orca" <<'EOS'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "orchestration worker-show" ]; then
  id=""
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --dispatch) id=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  wt="/tmp/wt-x"
  printf '{"ok":true,"result":{"dispatchId":"%s","taskId":"task_x","runId":"run_x","state":"ready","stage":"working","liveness":"live","terminal":"term_x","terminalState":"active","workspace":"repo::%s"}}\n' "$id" "$wt"
  exit 0
fi
if [ "${1:-} ${2:-}" = "orchestration worker-list" ]; then
  echo '{"ok":true,"result":{"workers":[{"dispatchId":"ctx_builder","agent":"cursor","workspace":"repo::/tmp/wt-x"}],"nextCursor":null}}'
  exit 0
fi
exit 1
EOS
chmod +x "$tmp/fake-orca"
export ORCA_CLI_COMMAND="$tmp/fake-orca"

# 1. Self-review sha carries across verdict_carry hook.
carry_ok() { [ "$1" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ] && [ "$2" = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]; }
body=$'## Self-review\naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
if pr_review_gate_self_review "$body" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb refuse carry_ok; then
  ok "self-review carries when carry hook accepts"
else
  bad "self-review carry hook"
fi
if pr_review_gate_self_review "$body" cccccccccccccccccccccccccccccccccccccccc refuse carry_ok; then
  bad "self-review without carry should refuse"
else
  ok "self-review refuses stale sha without carry"
fi

# 2. Missing builder agent/model refuses (no Builder: line bypass).
pr_review_gates_resolve_builder_dispatch ctx_builder feat-x refuse
if PRG_BUILDER_DISPATCH=ctx_builder && ! pr_review_gate_same_agent_model ctx_verify ctx_builder refuse; then
  ok "same agent/model refuses without PR Builder line when launches missing"
else
  bad "same agent/model fail-open without builder identity"
fi

# 3. Real worker-show shape: agent/model from launch record, same model refused.
pr_review_gates_launch_record_worktree /tmp/wt-x cursor composer-2.5
pr_review_gates_launch_record_dispatch ctx_builder cursor composer-2.5 /tmp/wt-x
pr_review_gates_launch_record_dispatch ctx_same cursor composer-2.5 /tmp/wt-y
pair=$(pr_review_gates_worker_agent_model ctx_builder) || true
if [ "$pair" = $'cursor\tcomposer-2.5' ] && ! pr_review_gate_same_agent_model ctx_same ctx_builder refuse; then
  ok "real worker-show shape uses launch record and refuses same model"
else
  bad "launch record agent/model ($pair)"
fi

# 4. Cursor PR: coordinator verifier with builder author.
printf '{"coordinator_ids":["term_coord"]}\n' >"$here/lead-merge.local.json"
PRG_COORD_LOADED=0
pr_review_gates_launch_record_dispatch ctx_cursor_builder cursor composer-2.5
if pr_review_gate_coordinator_verdict term_coord ctx_cursor_builder ctx_cursor_builder refuse; then
  ok "cursor PR accepts coordinator verifier and builder author"
else
  bad "cursor coordinator verdict"
fi
if pr_review_gate_coordinator_verdict term_coord unknown ctx_cursor_builder refuse; then
  bad "cursor PR with author=unknown must refuse"
else
  ok "cursor PR refuses author=unknown"
fi
rm -f "$here/lead-merge.local.json"

# 5. Verifier cannot be the builder dispatch.
if pr_review_gate_verifier_known ctx_builder ctx_builder "" refuse; then
  bad "verifier_known must not accept builder as verifier"
else
  ok "verifier_known refuses builder as verifier"
fi

echo "passed $pass failed $fail"
[ "$fail" -eq 0 ]
