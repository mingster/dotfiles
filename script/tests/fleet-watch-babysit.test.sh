#!/usr/bin/env bash
# Babysit dispatch: one verifier or one fixer per head, with fake gh and worker-startup.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
# shellcheck source=lib/asdf-pin.sh
. "$root/script/tests/lib/asdf-pin.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export PATH="$tmp/bin:$PATH"
export USAGE_GATE_CLI="$tmp/bin/usage-gate.py"
export BABYSIT_GH_DIR="$tmp/gh"
export BABYSIT_STARTS="$tmp/starts"
export BABYSIT_LINT="$root/script/brief-lint.sh"
export WORKER_STARTUP_STATE="$tmp/startup-state"
mkdir -p "$tmp/bin" "$BABYSIT_GH_DIR/owner" "$WORKER_STARTUP_STATE/launches"
: > "$BABYSIT_STARTS"

cat > "$tmp/bin/gh" <<'EOF'
#!/bin/bash
repo=""
listed=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  if [ "${args[$i]}" = "--repo" ]; then
    i=$((i + 1))
    repo=${args[$i]}
  elif [ "${args[$i]}" = "--state" ]; then
    i=$((i + 1))
    listed=${args[$i]}
  fi
  i=$((i + 1))
done
if [ "$listed" != "open" ]; then
  echo "gh pr list must request open PRs (got ${listed:-unset})" >&2
  exit 1
fi
file="${BABYSIT_GH_DIR}/${repo}.json"
if [ ! -f "$file" ]; then
  echo "gh fixture missing for ${repo}" >&2
  exit 1
fi
cat "$file"
EOF
chmod +x "$tmp/bin/gh"

cat > "$tmp/bin/usage-gate.py" <<'EOF'
#!/usr/bin/env python3
import json
import sys

args = sys.argv[1:]
role = ""
if "--role" in args:
    role = args[args.index("--role") + 1]
if role == "qa-sdet":
    print(json.dumps({
        "selected": {"provider": "cursor", "model": "grok-4.7-xhigh", "eligible": True},
        "candidates": [
            {"provider": "cursor", "model": "grok-4.7-xhigh", "eligible": True},
            {"provider": "claude", "model": "opus", "eligible": True},
        ],
    }))
    raise SystemExit(0)
if role == "fullstack-dev":
    print(json.dumps({
        "selected": {"provider": "cursor", "model": "composer-2.5", "eligible": True},
        "candidates": [
            {"provider": "cursor", "model": "composer-2.5", "eligible": True},
        ],
    }))
    raise SystemExit(0)
print("no pick", file=sys.stderr)
raise SystemExit(4)
EOF
chmod +x "$tmp/bin/usage-gate.py"

cat > "$tmp/worker-startup.sh" <<'EOF'
#!/bin/bash
spec=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--spec" ]; then
    spec=$arg
  fi
  prev=$arg
done
if [ -z "$spec" ] || ! bash "$BABYSIT_LINT" "$spec" >/dev/null 2>&1; then
  echo "lint-fail $*" >> "$BABYSIT_STARTS"
  exit 1
fi
printf '%s\n' "$*" >> "$BABYSIT_STARTS"
exit 0
EOF
chmod +x "$tmp/worker-startup.sh"

python3 - "$tmp/config.json" "$tmp/worker-startup.sh" <<'PY'
import json
import sys
cfg = {
    "issue_scan": {
        "enabled": False,
        "pr_repos": ["owner/app", "owner/lib"],
        "repo_roots": {"owner/app": "/tmp/app", "owner/lib": "/tmp/lib"},
        "run": "run_test",
        "from_terminal": "term_test",
        "startup": sys.argv[2],
    },
    "pr_watch": {"repos": ["owner/app", "owner/lib"]},
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(cfg, fh)
PY

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok  $*"; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

starts() {
  wc -l < "$BABYSIT_STARTS" | tr -d ' '
}

run_pass() {
  # run_pass <state> <mode> [workers-json]
  local state=$1 mode=$2 workers=${3:-} out=$4
  local -a args
  args=(python3 "$root/script/fleet-watch.py" --config "$tmp/config.json" --state "$state")
  if [ "$mode" = dry ]; then
    args+=(--babysit-dry-run)
  else
    args+=(--babysit-only)
  fi
  if [ -n "$workers" ]; then
    args+=(--workers-json "$workers")
  fi
  if "${args[@]}" >"$out" 2>"$out.err"; then
    return 0
  fi
  echo "fleet-watch exited $? (see $out.err)" >&2
  cat "$out.err" >&2 || true
  return 1
}

empty_repos() {
  echo '[]' > "$BABYSIT_GH_DIR/owner/app.json"
  echo '[]' > "$BABYSIT_GH_DIR/owner/lib.json"
}

green() {
  local n=$1 head=$2 repo=${3:-owner/app}
  python3 - "$BABYSIT_GH_DIR/$repo.json" "$n" "$head" <<'PY'
import json, sys
path, number, head = sys.argv[1:]
row = {
    "number": int(number),
    "state": "OPEN",
    "isDraft": False,
    "headRefOid": head,
    "headRefName": "feature/pr-%s" % number,
    "body": "Why\n\nBuilder: agent=cursor model=grok-4.7-xhigh\n",
    "files": [{"path": "script/fleet-watch.py"}],
    "comments": [],
    "statusCheckRollup": [
        {"name": "script-tests", "status": "COMPLETED", "conclusion": "SUCCESS"},
        {"name": "shellcheck", "status": "COMPLETED", "conclusion": "SUCCESS"},
        {"name": "review", "status": None, "conclusion": None},
    ],
}
try:
    rows = json.load(open(path, encoding="utf-8"))
except FileNotFoundError:
    rows = []
rows.append(row)
json.dump(rows, open(path, "w", encoding="utf-8"))
PY
}

HEAD_A=$(python3 -c 'print("a"*40)')
HEAD_B=$(python3 -c 'print("b"*40)')
HEAD_C=$(python3 -c 'print("c"*40)')
HEAD_D=$(python3 -c 'print("d"*40)')
HEAD_E=$(python3 -c 'print("e"*40)')

# --- green, no Verdict: one verifier; the pick that matches the builder is refused ---
empty_repos
: > "$BABYSIT_STARTS"
green 1 "$HEAD_A"
state=$tmp/state-green.json
echo '{}' > "$state"
if run_pass "$state" only "" "$tmp/green1.out"; then
  ok "green pass exits 0"
else
  bad "green pass exits 0"
fi
if [ "$(starts)" = 1 ]; then ok "green starts one verifier"; else bad "green starts one verifier (got $(starts))"; fi
if grep -q -- '--agent claude' "$BABYSIT_STARTS" && grep -q -- '--model opus' "$BABYSIT_STARTS"; then
  ok "verifier route is the non-builder pick"
else
  bad "verifier route is the non-builder pick ($(cat "$BABYSIT_STARTS"))"
fi
if grep -q -- '--model grok-4.7-xhigh' "$BABYSIT_STARTS"; then
  bad "verifier must refuse the builder agent and model"
else
  ok "verifier refuses the builder agent and model"
fi
if grep -q 'action=verifier agent=claude model=opus' "$tmp/green1.out"; then
  ok "green line names the verifier"
else
  bad "green line names the verifier ($(cat "$tmp/green1.out"))"
fi
spec=$(python3 -c 'import shlex,sys
try:
    p=shlex.split(open(sys.argv[1], encoding="utf-8").readline())
    print(p[p.index("--spec")+1])
except (IndexError, ValueError, OSError):
    print("")' "$BABYSIT_STARTS" || true)
if [ -n "$spec" ] && grep -q 'Refs owner/app#1' "$spec" && grep -q 'qa-sdet' "$spec" && grep -q 'checks-local.sh' "$spec"; then
  ok "verifier brief has refs, role and checks"
else
  bad "verifier brief has refs, role and checks"
fi
if [ -n "$spec" ] && grep -q 'fullstack-dev' "$spec"; then
  bad "verifier brief must not be a builder brief"
else
  ok "verifier brief is not a builder brief"
fi
if run_pass "$state" only "" "$tmp/green2.out"; then
  ok "second pass exits 0"
else
  bad "second pass exits 0"
fi
if [ "$(starts)" = 1 ]; then ok "second pass starts nothing"; else bad "second pass starts nothing (got $(starts))"; fi
if grep -q 'action=skip already' "$tmp/green2.out"; then
  ok "second pass reports already dispatched"
else
  bad "second pass reports already dispatched ($(cat "$tmp/green2.out"))"
fi
python3 - "$BABYSIT_GH_DIR/owner/app.json" "$HEAD_E" <<'PY'
import json, sys
path, head = sys.argv[1:]
rows = json.load(open(path, encoding="utf-8"))
rows[0]["headRefOid"] = head
json.dump(rows, open(path, "w", encoding="utf-8"))
PY
if run_pass "$state" only "" "$tmp/green3.out"; then
  ok "new head pass exits 0"
else
  bad "new head pass exits 0"
fi
if [ "$(starts)" = 2 ]; then ok "new head re-arms one verifier"; else bad "new head re-arms one verifier (got $(starts))"; fi

# dry-run lists the verifier and does not start or record it
empty_repos
: > "$BABYSIT_STARTS"
green 1 "$HEAD_A"
dry_state=$tmp/state-dry.json
rm -f "$dry_state"
if run_pass "$dry_state" dry "" "$tmp/dry.out"; then
  ok "dry-run exits 0"
else
  bad "dry-run exits 0"
fi
if [ "$(starts)" = 0 ] && [ ! -f "$dry_state" ]; then
  ok "dry-run starts nothing and writes no state"
else
  bad "dry-run starts nothing and writes no state (starts $(starts) state $(test -f "$dry_state" && echo yes || echo no))"
fi
if grep -q 'action=verifier' "$tmp/dry.out"; then
  ok "dry-run lists the verifier"
else
  bad "dry-run lists the verifier ($(cat "$tmp/dry.out"))"
fi

# --- a Verdict that also names agent and model still counts for this head ---
empty_repos
: > "$BABYSIT_STARTS"
python3 - "$BABYSIT_GH_DIR/owner/app.json" "$HEAD_A" <<'PY'
import json, sys
path, head = sys.argv[1:]
json.dump([{
    "number": 8,
    "state": "OPEN",
    "isDraft": False,
    "headRefOid": head,
    "headRefName": "feature/pr-8",
    "body": "Why\n\nBuilder: agent=cursor model=grok-4.7-xhigh\n",
    "files": [{"path": "script/fleet-watch.py"}],
    "comments": [{
        "body": "Verdict: PASS head=%s verifier=ctx_v author=ctx_a agent=claude model=opus\n" % head,
    }],
    "statusCheckRollup": [
        {"name": "head-checks", "status": "COMPLETED", "conclusion": "SUCCESS"},
    ],
}], open(path, "w", encoding="utf-8"))
PY
echo '{}' > "$tmp/state-verdict.json"
if run_pass "$tmp/state-verdict.json" only "" "$tmp/verdict.out"; then
  ok "verdict suffix pass exits 0"
else
  bad "verdict suffix pass exits 0"
fi
if [ "$(starts)" = 0 ] && grep -q 'action=skip has-verdict' "$tmp/verdict.out"; then
  ok "Verdict with agent and model suppresses a verifier"
else
  bad "Verdict with agent and model suppresses a verifier ($(cat "$tmp/verdict.out"))"
fi

# --- failing head-checks stay on the existing fixer group; this pass does not start one ---
empty_repos
: > "$BABYSIT_STARTS"
python3 - "$BABYSIT_GH_DIR/owner/app.json" "$HEAD_B" <<'PY'
import json, sys
path, head = sys.argv[1:]
json.dump([{
    "number": 2,
    "state": "OPEN",
    "isDraft": False,
    "headRefOid": head,
    "headRefName": "feature/pr-2",
    "body": "Why\n\nBuilder: agent=cursor model=grok-4.7-xhigh\n",
    "files": [{"path": "script/fleet-watch.py"}],
    "comments": [],
    "statusCheckRollup": [
        {"name": "head-checks", "status": "COMPLETED", "conclusion": "FAILURE"},
    ],
}], open(path, "w", encoding="utf-8"))
PY
echo '{}' > "$tmp/state-fail.json"
if run_pass "$tmp/state-fail.json" only "" "$tmp/fail.out"; then
  ok "fail pass exits 0"
else
  bad "fail pass exits 0"
fi
if [ "$(starts)" = 0 ] && ! grep -q 'action=fixer' "$tmp/fail.out"; then
  ok "failing checks do not start a babysit fixer"
else
  bad "failing checks do not start a babysit fixer ($(cat "$tmp/fail.out"))"
fi

# --- owner-only path reports and does not dispatch, even when checks failed ---
empty_repos
: > "$BABYSIT_STARTS"
python3 - "$BABYSIT_GH_DIR/owner/app.json" "$HEAD_C" <<'PY'
import json, sys
path, head = sys.argv[1:]
json.dump([{
    "number": 3,
    "state": "OPEN",
    "isDraft": False,
    "headRefOid": head,
    "headRefName": "feature/pr-3",
    "body": "Why\n\nBuilder: agent=cursor model=grok-4.7-xhigh\n",
    "files": [{"path": ".claude/hooks/guard.sh"}],
    "comments": [],
    "statusCheckRollup": [
        {"name": "head-checks", "status": "COMPLETED", "conclusion": "FAILURE"},
    ],
}], open(path, "w", encoding="utf-8"))
PY
echo '{}' > "$tmp/state-owner.json"
if run_pass "$tmp/state-owner.json" only "" "$tmp/owner.out"; then
  ok "owner pass exits 0"
else
  bad "owner pass exits 0"
fi
if [ "$(starts)" = 0 ]; then ok "owner-only path does not dispatch"; else bad "owner-only path does not dispatch (got $(starts))"; fi
if grep -q 'action=report' "$tmp/owner.out" && grep -q '.claude/hooks/guard.sh' "$tmp/owner.out"; then
  ok "owner-only path reports"
else
  bad "owner-only path reports ($(cat "$tmp/owner.out"))"
fi

# --- draft is skipped ---
empty_repos
: > "$BABYSIT_STARTS"
python3 - "$BABYSIT_GH_DIR/owner/app.json" "$HEAD_D" <<'PY'
import json, sys
path, head = sys.argv[1:]
json.dump([{
    "number": 4,
    "state": "OPEN",
    "isDraft": True,
    "headRefOid": head,
    "headRefName": "feature/pr-4",
    "body": "Why\n\nBuilder: agent=cursor model=grok-4.7-xhigh\n",
    "files": [{"path": "script/fleet-watch.py"}],
    "comments": [],
    "statusCheckRollup": [
        {"name": "head-checks", "status": "COMPLETED", "conclusion": "SUCCESS"},
    ],
}], open(path, "w", encoding="utf-8"))
PY
echo '{}' > "$tmp/state-draft.json"
if run_pass "$tmp/state-draft.json" only "" "$tmp/draft.out"; then
  ok "draft pass exits 0"
else
  bad "draft pass exits 0"
fi
if [ "$(starts)" = 0 ]; then ok "draft does not dispatch"; else bad "draft does not dispatch (got $(starts))"; fi
if grep -q 'action=skip draft' "$tmp/draft.out"; then
  ok "draft is skipped"
else
  bad "draft is skipped ($(cat "$tmp/draft.out"))"
fi

# --- builder comes from the dispatch record when the body has no Builder line ---
empty_repos
: > "$BABYSIT_STARTS"
python3 - "$BABYSIT_GH_DIR/owner/app.json" "$HEAD_A" "$tmp/workers.json" "$WORKER_STARTUP_STATE/launches/ctx_builder.json" <<'PY'
import json, sys
prs, head, workers, launch = sys.argv[1:]
json.dump([{
    "number": 5,
    "state": "OPEN",
    "isDraft": False,
    "headRefOid": head,
    "headRefName": "feature/pr-5",
    "body": "No builder line here.\n",
    "files": [{"path": "script/fleet-watch.py"}],
    "comments": [],
    "statusCheckRollup": [
        {"name": "head-checks", "status": "COMPLETED", "conclusion": "SUCCESS"},
    ],
}], open(prs, "w", encoding="utf-8"))
json.dump([{
    "githubPullRequestNumber": 5,
    "dispatchId": "ctx_builder",
}], open(workers, "w", encoding="utf-8"))
json.dump({"dispatchId": "ctx_builder", "agent": "cursor", "model": "grok-4.7-xhigh"}, open(launch, "w"))
PY
echo '{}' > "$tmp/state-record.json"
if run_pass "$tmp/state-record.json" only "$tmp/workers.json" "$tmp/record.out"; then
  ok "dispatch-record pass exits 0"
else
  bad "dispatch-record pass exits 0"
fi
if [ "$(starts)" = 1 ] && grep -q -- '--model opus' "$BABYSIT_STARTS" && ! grep -q -- '--model grok-4.7-xhigh' "$BABYSIT_STARTS"; then
  ok "dispatch record refuses the builder pair"
else
  bad "dispatch record refuses the builder pair ($(cat "$BABYSIT_STARTS"))"
fi

# --- default cap is 2 dispatches per pass, across both watched repos ---
empty_repos
: > "$BABYSIT_STARTS"
H10=$(python3 -c 'print("1"*40)')
H11=$(python3 -c 'print("2"*40)')
H12=$(python3 -c 'print("3"*40)')
green 10 "$H10" owner/app
green 11 "$H11" owner/app
green 12 "$H12" owner/lib
echo '{}' > "$tmp/state-cap.json"
if run_pass "$tmp/state-cap.json" only "" "$tmp/cap1.out"; then
  ok "cap pass exits 0"
else
  bad "cap pass exits 0"
fi
if [ "$(starts)" = 2 ]; then ok "cap allows two dispatches"; else bad "cap allows two dispatches (got $(starts))"; fi
if grep -q 'owner/lib#12' "$tmp/cap1.out" && grep -q 'action=skip cap' "$tmp/cap1.out"; then
  ok "third PR waits for the next pass"
else
  bad "third PR waits for the next pass ($(cat "$tmp/cap1.out"))"
fi
if run_pass "$tmp/state-cap.json" only "" "$tmp/cap2.out"; then
  ok "cap second pass exits 0"
else
  bad "cap second pass exits 0"
fi
if [ "$(starts)" = 3 ] && grep -q 'owner/lib#12' "$BABYSIT_STARTS"; then
  ok "next pass dispatches the capped PR"
else
  bad "next pass dispatches the capped PR (starts $(starts))"
fi

# --- a stub config with no runs adopts the coordinator file and refreshes issue_scan ---
real_py=$(asdf which python3 2>/dev/null || command -v python3)
stub_home=$tmp/stub-home
mkdir -p "$stub_home/.config/fleet-watch" "$stub_home/.claude/state"
printf '%s\n' '{"local_host":"h","host_caps":{"h":1}}' > "$stub_home/.config/fleet-watch/config.json"
python3 - "$stub_home/.claude/state/fleet-watch-elon.json" "$HEAD_A" <<'PY'
import json, sys
path, head = sys.argv[1:]
json.dump({
    "runs": [{"id": "run_live", "terminal": "term_live", "waiter_pattern": "check"}],
    "issue_scan": {
        "enabled": False,
        "run": "run_stale",
        "from_terminal": "term_stale",
        "agent": "cursor",
        "model": "old-model",
        "pr_repos": ["owner/app"],
        "repo_roots": {"owner/app": "/tmp/app"},
    },
}, open(path, "w", encoding="utf-8"))
PY
empty_repos
green 1 "$HEAD_A" owner/app
: > "$BABYSIT_STARTS"
echo '{}' > "$tmp/state-adopt.json"
if HOME="$stub_home" "$real_py" "$root/script/fleet-watch.py" \
  --config "$stub_home/.config/fleet-watch/config.json" \
  --state "$tmp/state-adopt.json" --babysit-dry-run >"$tmp/adopt.out" 2>"$tmp/adopt.err"; then
  ok "stub config dry-run exits 0"
else
  bad "stub config dry-run exits 0"
fi
if grep -q 'using coordinator config' "$tmp/adopt.err" && grep -q 'action=verifier' "$tmp/adopt.out"; then
  ok "stub config adopts the coordinator file"
else
  bad "stub config adopts the coordinator file ($(cat "$tmp/adopt.err") $(cat "$tmp/adopt.out"))"
fi
if (cd "$root" && HOME="$stub_home" "$real_py" - <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location("fw", "script/fleet-watch.py")
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)
cfg = {
    "runs": [{"id": "run_live", "terminal": "term_live", "waiter_pattern": "check"}],
    "issue_scan": {
        "enabled": True,
        "run": "run_stale",
        "from_terminal": "term_stale",
        "role": "fullstack-dev",
        "agent": "cursor",
        "model": "old-model",
    },
}
fw.apply_active_run(cfg, pick=lambda role: {
    "selected": {"provider": "cursor", "model": "fresh-model", "eligible": True},
})
assert cfg["issue_scan"]["run"] == "run_live", cfg["issue_scan"]
assert cfg["issue_scan"]["from_terminal"] == "term_live", cfg["issue_scan"]
assert cfg["issue_scan"]["model"] == "fresh-model", cfg["issue_scan"]
PY
); then
  ok "active run refreshes issue_scan run, terminal and model"
else
  bad "active run refreshes issue_scan run, terminal and model"
fi

# --- a pass with no coordinator Run keeps queued notices and exits 0 ---
# The recorded concise run-list has runs and no coordinator terminal. Pagination stops on this copy.
recorded_list=$(ls "$root"/script/tests/fixtures/fleet-watch/orca-*/run-list.json | tail -1)
cat > "$tmp/bin/orca-no-run" <<EOF
#!/bin/bash
'$real_py' - '$recorded_list' <<'PY'
import json, sys
raw = json.load(open(sys.argv[1], encoding='utf-8'))
body = json.loads(raw['stdout'])
body['result']['nextCursor'] = None
json.dump(body, sys.stdout)
PY
EOF
chmod +x "$tmp/bin/orca-no-run"
python3 - "$tmp/state-noruns.json" <<'PY'
import json, sys
json.dump({
    "notice_queue": {"term_old": [{"text": "queued notice", "urgent": False, "passes": 0}]},
}, open(sys.argv[1], "w", encoding="utf-8"))
PY
printf '%s\n' '{"runs":[{"id":"run_stale","terminal":"term_stale","waiter_pattern":"old"}],"local_host":"h"}' > "$tmp/noruns.json"
noruns_log=$tmp/noruns.log
rm -f "$noruns_log"
noruns_rc=0
ORCA_CLI_COMMAND="$tmp/bin/orca-no-run" HOME="$stub_home" FLEET_WATCH_LOG_PATH="$noruns_log" \
  "$real_py" "$root/script/fleet-watch.py" \
  --config "$tmp/noruns.json" --state "$tmp/state-noruns.json" >"$tmp/noruns.out" 2>"$tmp/noruns.err" || noruns_rc=$?
if [ "$noruns_rc" -eq 0 ] \
  && grep -q "no coordinator run" "$tmp/noruns.err" \
  && grep -q "no coordinator run" "$noruns_log" \
  && grep -q "queued notice" "$tmp/state-noruns.json"; then
  ok "no coordinator run keeps the queue and exits 0"
else
  bad "no coordinator run keeps the queue and exits 0 (rc=$noruns_rc stderr=$(cat "$tmp/noruns.err") log=$(cat "$noruns_log" 2>/dev/null || true) state=$(cat "$tmp/state-noruns.json" 2>/dev/null || true))"
fi

echo "babysit-dispatch: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
