#!/usr/bin/env bash
# #1940: a PR body with no Builder line gets the builder agent and model from the dispatch that owns the PR branch;
# with no matching dispatch the pair stays unknown (fleet-watch then skips the verifier, as before).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export FLEET_WATCH_LOG_PATH="$tmp/fleet-watch.log"
mkdir -p "$tmp/launches"
printf '{"dispatchId":"ctx_b1","agent":"antigravity","model":"gemini-4-argon"}\n' >"$tmp/launches/ctx_b1.json"
out=$(WORKER_STARTUP_STATE="$tmp" python3 - "$here/../fleet-watch.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('fw', sys.argv[1])
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)
nobody = {'number': 7, 'headRefName': 'feat/x', 'body': 'No builder line.'}
with_line = {'number': 7, 'headRefName': 'feat/x', 'body': 'x\nBuilder: agent=claude model=claude-sonnet-5-5\n'}
by_branch = [{'dispatchId': 'ctx_b1', 'branch': 'feat/x'}]
by_number = [{'dispatchId': 'ctx_b1', 'githubPullRequestNumber': 7}]
projected = [{'dispatchId': 'ctx_none', 'branch': 'feat/x', 'projection': {'provider': {'id': 'grok', 'model': 'grok-4.7-high'}}}]
other = [{'dispatchId': 'ctx_b1', 'branch': 'other', 'githubPullRequestNumber': 99}]
checks = {
    'body line wins': fw.builder_pair(with_line, by_branch) == ('claude', 'claude-sonnet-5-5'),
    'dispatch by branch': fw.builder_pair(nobody, by_branch) == ('antigravity', 'gemini-4-argon'),
    'dispatch by pr number': fw.builder_pair(nobody, by_number) == ('antigravity', 'gemini-4-argon'),
    'dispatch projection': fw.builder_pair(nobody, projected) == ('grok', 'grok-4.7-high'),
    'no matching dispatch stays unknown': fw.builder_pair(nobody, other) is None,
    'no workers stays unknown': fw.builder_pair(nobody, []) is None,
    'body parse alone ignores dispatches': fw.builder_pair_from_body(nobody) is None,
}
state = {}
for _ in range(fw.UNKNOWN_BUILDER_REFUSALS):
    fw.unknown_builder_refused(state, 'o/r', 7, 'h1')
parked = fw.unknown_builder_parked(state, 'o/r', 7, 'h1')
fw.unknown_builder_clear(state, 'o/r', 7)
checks['park holds until cleared'] = parked
checks['clear lifts the park'] = not fw.unknown_builder_parked(state, 'o/r', 7, 'h1')
for name, good in checks.items():
    print(('ok: ' if good else 'FAIL: ') + name)
PY
)
echo "$out"
! grep -q '^FAIL' <<<"$out" && [ -n "$out" ]
