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
  [ -n "${PRG_FAKE_WORKERS:-}" ] && { cat "$PRG_FAKE_WORKERS"; exit 0; }
  echo '{"ok":true,"result":{"workers":[{"dispatchId":"ctx_slug_builder","agent":"claude","workspace":"repo::'"$tmp"'/dot-760"}],"nextCursor":null}}'
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
printf '{"coordinator_ids":["term_coord"]}\n' >"$here/ship.local.json"
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
rm -f "$here/ship.local.json"

# 5. Verifier cannot be the builder dispatch.
if pr_review_gate_verifier_known ctx_builder ctx_builder "" refuse; then
  bad "verifier_known must not accept builder as verifier"
else
  ok "verifier_known refuses builder as verifier"
fi

# 6. author=unknown: head branch user/slug matches worktree basename (dot-760).
slug_wt="$tmp/dot-760"
mkdir -p "$slug_wt"
git -C "$slug_wt" init -q
git -C "$slug_wt" checkout -q -b mingster/dot-760 2>/dev/null || git -C "$slug_wt" switch -q -c mingster/dot-760
if pr_review_gates_resolve_builder_dispatch unknown mingster/dot-760 refuse \
  && [ "${PRG_BUILDER_DISPATCH:-}" = ctx_slug_builder ]; then
  ok "unknown author resolves builder via worktree slug branch"
else
  bad "slug branch resolve (${PRG_BUILDER_DISPATCH:-missing})"
fi

# 7. Coordinator-authored Verdict: not refused as non-builder; skips cross-model gate.
printf '{"coordinator_ids":["term_elon"]}\n' >"$here/ship.local.json"
PRG_COORD_LOADED=0
if pr_review_gates_resolve_builder_dispatch term_elon feat-x refuse \
  && [ -z "${PRG_BUILDER_DISPATCH:-}" ]; then
  ok "coordinator author is not a builder dispatch refusal"
else
  bad "coordinator author resolve"
fi
pr_review_gates_launch_record_dispatch ctx_reviewer claude opus-test
if pr_review_gate_same_agent_model ctx_reviewer "" refuse; then
  ok "coordinator-built PR skips cross-model gate without builder"
else
  bad "coordinator-built cross-model skip"
fi
if pr_review_gate_coordinator_verdict ctx_reviewer term_elon "" refuse; then
  ok "coordinator-built PR skips cursor coordinator verdict rule"
else
  bad "coordinator-built coordinator_verdict skip"
fi
rm -f "$here/ship.local.json"

# 8. Missing launch record: refusal names worker-startup.sh.
pr_review_gates_resolve_builder_dispatch ctx_builder feat-x refuse
if ! pr_review_gate_same_agent_model ctx_no_record ctx_builder refuse 2>"$tmp/refuse.err"; then
  grep -Fq 'start the reviewer with script/worker-startup.sh, which writes the launch record' "$tmp/refuse.err" \
    && ok "missing launch record refusal cites worker-startup.sh" \
    || bad "refusal hint ($(cat "$tmp/refuse.err"))"
else
  bad "missing launch record should refuse"
fi

# 9. worker-startup path: orchestration_worker_start writes dispatch launch record.
startup_stub="$tmp/orca-startup"
cat >"$startup_stub" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" | grep -q orchestration && printf '{"ok":true,"result":{"dispatchId":"ctx_from_startup","agent":"claude","model":"claude-sonnet-5-5-medium"}}'
exit 0
EOS
chmod +x "$startup_stub"
ORCA_CLI_COMMAND="$startup_stub" \
  pr_review_gates_orchestration_worker_start claude claude-sonnet-5-5-medium /tmp/wt-from-startup -- \
  --run run_stub --spec brief --agent claude --model claude-sonnet-5-5-medium --from term_x
pair=$(pr_review_gates_worker_agent_model ctx_from_startup) || true
if [ "$pair" = $'claude\tclaude-sonnet-5-5-medium' ]; then
  ok "worker-startup launch record resolves agent/model"
else
  bad "startup launch record ($pair)"
fi

# 10. author=unknown: checked-out branch in the PR's repo beats a same-named worktree in another repo (#771).
other_wt="$tmp/other/dot-771"
right_wt="$tmp/right/wt-abc"
mkdir -p "$other_wt" "$right_wt"
git -C "$other_wt" init -q
git -C "$other_wt" remote add origin git@github.com:someone/elsewhere.git
git -C "$right_wt" init -q
git -C "$right_wt" remote add origin https://github.com/Mingster/Dotfiles.git
git -C "$right_wt" checkout -q -b mingster/dot-771 2>/dev/null || git -C "$right_wt" switch -q -c mingster/dot-771
jq -n --arg o "repo::$other_wt" --arg r "repo::$right_wt" \
  '{ok:true,result:{workers:[{dispatchId:"ctx_other_repo",workspace:$o},{dispatchId:"ctx_right_repo",workspace:$r}],nextCursor:null}}' \
  >"$tmp/workers-771.json"
if PRG_FAKE_WORKERS="$tmp/workers-771.json" pr_review_gates_resolve_builder_dispatch unknown mingster/dot-771 refuse mingster/dotfiles \
  && [ "${PRG_BUILDER_DISPATCH:-}" = ctx_right_repo ]; then
  ok "unknown author prefers checked-out branch in the PR repo"
else
  bad "checked-out branch in PR repo (${PRG_BUILDER_DISPATCH:-missing})"
fi
git -C "$right_wt" checkout -q -b other-branch
if PRG_FAKE_WORKERS="$tmp/workers-771.json" pr_review_gates_resolve_builder_dispatch unknown mingster/dot-771 refuse mingster/dotfiles 2>/dev/null; then
  bad "name match in another repo must not resolve (${PRG_BUILDER_DISPATCH:-})"
else
  ok "unknown author ignores a same-named worktree in another repo"
fi

echo "passed $pass failed $fail"
[ "$fail" -eq 0 ]
