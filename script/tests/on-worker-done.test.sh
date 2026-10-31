#!/usr/bin/env bash
# Tests for on-worker-done.sh --dry-run with a stub usage gate. bash 3.2 compatible.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home"
cat > "$tmp/gate" <<'GATE'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_DIR/gate.log"
[ "${GATE_RC:-0}" = 0 ] || exit "$GATE_RC"
echo "${GATE_OUT:---agent codex --model gpt-6.1-sol --effort medium}"
GATE
chmod +x "$tmp/gate"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/orca" <<'ORCA'
#!/usr/bin/env bash
case "$*" in
  "environment list --json")
    if [ -n "${FAKE_ORCA_ENVS:-}" ]; then printf '%s\n' "$FAKE_ORCA_ENVS"; else printf '%s\n' '{"ok":true,"result":{"environments":[]}}'; fi ;;
  *) echo "$*" >> "$FAKE_DIR/orca.log" ;;
esac
exit 0
ORCA
chmod +x "$tmp/bin/orca"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env python3
import json, os
print(json.dumps({"comments": [{"body": "Checks: PASS head=" + os.environ["QA_HEAD"] + "\nCommand: docs-check\nResult: exit 0\n"}]}))
GH
chmod +x "$tmp/bin/gh"
export FAKE_DIR="$tmp" ON_WORKER_DONE_USAGE_GATE="$tmp/gate" ORCA_CLI_COMMAND="$tmp/bin/orca" PATH="$tmp/bin:$PATH"
: > "$tmp/orca.log"
LOCAL_HOST=$(hostname -s 2>/dev/null || echo local)
head=0123456789abcdef0123456789abcdef01234567
export QA_HEAD="$head"
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
run() { "$here/on-worker-done.sh" --dry-run --repo o/n --pr 42 --head "$head" --author-family "${1:-claude}" --worktree /wt --run run_1 2>"$tmp/err"; }
run_flags() { "$here/on-worker-done.sh" --dry-run --repo o/n --pr 42 --head "$head" --author-family claude --worktree /wt --run run_1 "$@" 2>"$tmp/err"; }
capture_brief() {
  run_flags "$@" >/dev/null
  ls -t "${TMPDIR:-/tmp}"/reviewer-brief.* 2>/dev/null | head -1
}
setup_local_fleet() {
  printf '%s\n' "{\"host_caps\":{\"$LOCAL_HOST\":4},\"runs\":[]}" > "$tmp/fleet-local.json"
  cat > "$tmp/fleet-watch-local" <<FW
#!/usr/bin/env bash
[ "\$1" = "--config" ] && shift 2
[ "\$1" = "--admit" ] || exit 2
[ "\$2" = "$LOCAL_HOST" ] || exit 2
printf '%s\n' '{"admitted":true,"host":"$LOCAL_HOST","cap":4,"occupied":0,"reason":"admitted"}'
exit 0
FW
  chmod +x "$tmp/fleet-watch-local"
  export ON_WORKER_DONE_FLEET_CONFIG="$tmp/fleet-local.json" ON_WORKER_DONE_FLEET_WATCH="$tmp/fleet-watch-local"
  export FAKE_ORCA_ENVS='{"ok":true,"result":{"environments":[]}}'
}

: > "$tmp/orca.log"
( HOME="$tmp/home" unset ON_WORKER_DONE_FLEET_CONFIG; run_flags >/dev/null 2>"$tmp/err" ); rc=$?
check "fail-closed: missing fleet config refuses" "$([ "$rc" -ne 0 ] && grep -q 'fleet config missing' "$tmp/err"; echo $?)"
check "fail-closed: missing fleet config prints no worker-start" "$(! grep -q worker-start "$tmp/orca.log"; echo $?)"

ON_WORKER_DONE_FLEET_CONFIG="$tmp/does-not-exist.json" run_flags >/dev/null 2>"$tmp/err"; rc=$?
check "fail-closed: nonexistent fleet config path refuses" "$([ "$rc" -ne 0 ] && grep -q 'fleet config missing' "$tmp/err"; echo $?)"
unset ON_WORKER_DONE_FLEET_CONFIG

printf '%s\n' '{not json' > "$tmp/fleet-bad.json"
ON_WORKER_DONE_FLEET_CONFIG="$tmp/fleet-bad.json" run_flags >/dev/null 2>"$tmp/err"; rc=$?
check "fail-closed: invalid fleet config refuses" "$([ "$rc" -ne 0 ]; echo $?)"
unset ON_WORKER_DONE_FLEET_CONFIG

setup_local_fleet
cat > "$tmp/fleet-watch-local" <<'FW'
#!/usr/bin/env bash
[ "$1" = "--config" ] && shift 2
[ "$1" = "--admit" ] || exit 2
printf '%s\n' '{"admitted":true,"host":"bad","cap":2,"occupied":0}'
exit 1
FW
chmod +x "$tmp/fleet-watch-local"
run_flags >/dev/null 2>"$tmp/err"; rc=$?
check "fail-closed: admit helper nonzero refuses" "$([ "$rc" -ne 0 ]; echo $?)"
check "fail-closed: admit helper nonzero skips worker-start" "$(! grep -q worker-start "$tmp/orca.log"; echo $?)"

setup_local_fleet
cat > "$tmp/fleet-watch-local" <<'FW'
#!/usr/bin/env bash
[ "$1" = "--config" ] && shift 2
[ "$1" = "--admit" ] || exit 2
echo 'not-json'
exit 0
FW
chmod +x "$tmp/fleet-watch-local"
run_flags >/dev/null 2>"$tmp/err"; rc=$?
check "fail-closed: malformed admit receipt refuses" "$([ "$rc" -ne 0 ]; echo $?)"

setup_local_fleet
printf '%s\n' '{"host_caps":{"remote-only":2},"runs":[]}' > "$tmp/fleet-remote.json"
cat > "$tmp/fleet-watch-remote" <<'FW'
#!/usr/bin/env bash
[ "$1" = "--config" ] && shift 2
[ "$1" = "--admit" ] || exit 2
printf '%s\n' '{"admitted":true,"host":"remote-only","cap":2,"occupied":0,"reason":"admitted"}'
exit 0
FW
chmod +x "$tmp/fleet-watch-remote"
export ON_WORKER_DONE_FLEET_CONFIG="$tmp/fleet-remote.json" ON_WORKER_DONE_FLEET_WATCH="$tmp/fleet-watch-remote"
export FAKE_ORCA_ENVS='{"ok":true,"result":{"environments":[]}}'
run_flags >/dev/null 2>"$tmp/err"; rc=$?
check "fail-closed: admitted host without saved Orca environment refuses" "$([ "$rc" -ne 0 ] && grep -q 'no saved Orca environment' "$tmp/err"; echo $?)"

setup_local_fleet

out=$(run); rc=$?
check "gate ok: exit 0" "$rc"
check "gate ok: cross-family agent flags" "$(echo "$out" | grep -q -- '--agent codex'; echo $?)"
check "gate ok: no fallback note" "$(! grep -q 'cross-family unavailable' "$tmp/err"; echo $?)"
check "reviewer task title for pane color" "$(echo "$out" | grep -q -- '--task-title "reviewer - PR 42"'; echo $?)"
check "gate asked to avoid the author family" "$(grep -q -- 'pick --role reviewer --avoid-family claude' "$tmp/gate.log"; echo $?)"

out=$(GATE_RC=3 run); rc=$?
check "gate blocked: exit nonzero" "$([ "$rc" -ne 0 ]; echo $?)"
check "gate blocked: no worker-start line" "$(! echo "$out" | grep -q 'worker-start'; echo $?)"
check "gate blocked: prints cross-family unavailable" "$(grep -q 'cross-family unavailable' "$tmp/err"; echo $?)"

GATE_RC=4 run >/dev/null 2>"$tmp/err"; rc=$?
check "gate error: exit nonzero" "$([ "$rc" -ne 0 ]; echo $?)"
check "gate error: no opus fallback" "$(! grep -q 'opus' "$tmp/err"; echo $?)"

GATE_RC=3 GATE_OUT= run 2>"$tmp/err" >/dev/null; rc=$?
check "live path blocked: exit nonzero" "$([ "$rc" -ne 0 ]; echo $?)"
check "live path blocked: no orca worker-start" "$(! grep -q worker-start "$tmp/orca.log"; echo $?)"

run cursor >/dev/null
check "cursor author avoids gpt" "$(grep -q -- '--avoid-family gpt' "$tmp/gate.log"; echo $?)"
run codex >/dev/null
check "codex author avoids gpt" "$(grep -q -- '--avoid-family gpt' "$tmp/gate.log"; echo $?)"

"$here/on-worker-done.sh" --dry-run --repo o/n --pr 42 >/dev/null 2>&1
check "missing args exit nonzero" "$([ $? -ne 0 ]; echo $?)"
"$here/on-worker-done.sh" --dry-run --repo o/n --pr x --head "$head" --author-family claude --worktree /wt --run r >/dev/null 2>&1
check "bad pr exits nonzero" "$([ $? -ne 0 ]; echo $?)"
"$here/on-worker-done.sh" --dry-run --repo o/n --pr 1 --head "$head" --author-family gpt --worktree /wt --run r >/dev/null 2>&1
check "bad family exits nonzero" "$([ $? -ne 0 ]; echo $?)"

# Shared family across providers: Antigravity Claude vs Claude reviewer
rc=0
GATE_OUT="--agent claude --model claude-3-5-sonnet" \
  "$here/on-worker-done.sh" --dry-run --repo o/n --pr 42 --head "$head" --author-provider antigravity --author-model claude-3-5-sonnet --worktree /wt --run run_1 >/dev/null 2>"$tmp/err" || rc=$?
check "shared claude family across antigravity and claude rejected" "$([ "$rc" -ne 0 ] && grep -q 'cross-family unavailable' "$tmp/err"; echo $?)"

# Shared family across providers: Antigravity GPT vs Codex reviewer
rc=0
GATE_OUT="--agent codex --model gpt-6.1-sol" \
  "$here/on-worker-done.sh" --dry-run --repo o/n --pr 42 --head "$head" --author-provider antigravity --author-model gpt-4o --worktree /wt --run run_1 >/dev/null 2>"$tmp/err" || rc=$?
check "shared gpt family across antigravity and codex rejected" "$([ "$rc" -ne 0 ] && grep -q 'cross-family unavailable' "$tmp/err"; echo $?)"

# Unknown author model blocks independence acceptance
rc=0
GATE_OUT="--agent codex --model gpt-6.1-sol" \
  "$here/on-worker-done.sh" --dry-run --repo o/n --pr 42 --head "$head" --author-provider antigravity --author-model unknown-model-x --worktree /wt --run run_1 >/dev/null 2>"$tmp/err" || rc=$?
check "unknown author model blocks independence acceptance" "$([ "$rc" -ne 0 ] && grep -q 'cross-family unavailable' "$tmp/err"; echo $?)"

# Unknown verifier model blocks independence acceptance
rc=0
GATE_OUT="--agent codex --model mystery-model-v9" \
  "$here/on-worker-done.sh" --dry-run --repo o/n --pr 42 --head "$head" --author-provider antigravity --author-model gemini-3.8-flash --worktree /wt --run run_1 >/dev/null 2>"$tmp/err" || rc=$?
check "unknown verifier model blocks independence acceptance" "$([ "$rc" -ne 0 ] && grep -q 'cross-family unavailable' "$tmp/err"; echo $?)"

run >/dev/null
brief=$(ls -t "${TMPDIR:-/tmp}"/reviewer-brief.* | head -1)
re='^Verdict: PASS\|PASS\+NOTES\|FAIL head=[0-9a-f]{40} verifier=<your dispatch id> author=unknown$'
check "brief has the verdict line template with the head" "$(grep -E "$re" "$brief" | grep -q "head=$head"; echo $?)"
check "brief records author and verifier families separately from provider" "$(grep -q 'Author: provider=' "$brief" && grep -q 'family=' "$brief" && grep -q 'Verifier: provider=' "$brief"; echo $?)"
check "default brief asks for full review against spec and standards" "$(grep -q "repo's standards" "$brief" && grep -q "PR's spec" "$brief"; echo $?)"
check "default brief runs tests through heavy-gate" "$(grep -q 'heavy-gate.sh' "$brief"; echo $?)"
check "default brief reads Checks receipt last and treats pending as not pass" "$(grep -q 'Checks receipt' "$brief" && grep -q 'pending' "$brief"; echo $?)"
check "default brief is not resolution-only" "$(! grep -q 'git show --remerge-diff' "$brief"; echo $?)"
rm -f "$brief"

brief=$(capture_brief --resolution)
check "resolution brief names git show --remerge-diff" "$(grep -q 'git show --remerge-diff' "$brief"; echo $?)"
check "resolution brief skips full spec and standards review" "$(! grep -q "Check the diff against the PR's spec and the repo's standards" "$brief"; echo $?)"
check "resolution brief still uses heavy-gate and pending Checks rule" "$(grep -q 'heavy-gate.sh' "$brief" && grep -q 'Checks receipt' "$brief"; echo $?)"
rm -f "$brief"

cat > "$tmp/fleet-config.json" <<'JSON'
{"host_caps":{"fleet-a":2,"fleet-b":2},"runs":[]}
JSON
cat > "$tmp/fleet-watch" <<'FW'
#!/usr/bin/env bash
[ "$1" = "--config" ] && shift 2
[ "$1" = "--admit" ] || exit 2
host=$2
case "$host" in
  fleet-a) printf '%s\n' '{"admitted":false,"host":"fleet-a","cap":2,"occupied":2,"reason":"host cap exceeded: fleet-a 2/2"}'; exit 1 ;;
  fleet-b) printf '%s\n' '{"admitted":true,"host":"fleet-b","cap":2,"occupied":1,"reason":"admitted"}'; exit 0 ;;
  *) exit 2 ;;
esac
FW
chmod +x "$tmp/fleet-watch"
export ON_WORKER_DONE_FLEET_CONFIG="$tmp/fleet-config.json" ON_WORKER_DONE_FLEET_WATCH="$tmp/fleet-watch"
export FAKE_ORCA_ENVS='{"ok":true,"result":{"environments":[{"id":"env-fleet-b","name":"fleet-b"}]}}'
out=$(run_flags 2>"$tmp/err"); rc=$?
check "host pick under cap: exit 0" "$rc"
check "host pick maps --on to saved Orca environment id" "$(echo "$out" | grep -q -- '--on env-fleet-b'; echo $?)"
unset ON_WORKER_DONE_FLEET_CONFIG ON_WORKER_DONE_FLEET_WATCH FAKE_ORCA_ENVS

setup_local_fleet
export ON_WORKER_DONE_FLEET_CONFIG="$tmp/fleet-config.json" ON_WORKER_DONE_FLEET_WATCH="$tmp/fleet-watch"
cat > "$tmp/fleet-watch" <<'FW'
#!/usr/bin/env bash
[ "$1" = "--config" ] && shift 2
[ "$1" = "--admit" ] || exit 2
printf '%s\n' '{"admitted":false,"host":"'"$2"'","cap":2,"occupied":2,"reason":"host cap exceeded: '"$2"' 2/2"}'
exit 1
FW
chmod +x "$tmp/fleet-watch"
run_flags >/dev/null 2>"$tmp/err"; rc=$?
check "every host at cap: exit nonzero" "$([ "$rc" -ne 0 ]; echo $?)"
check "every host at cap: names counts in stderr" "$(grep -q 'host cap exceeded' "$tmp/err" && grep -q '2/2' "$tmp/err"; echo $?)"
check "every host at cap: no worker-start" "$(! grep -q worker-start "$tmp/orca.log"; echo $?)"
unset ON_WORKER_DONE_FLEET_CONFIG ON_WORKER_DONE_FLEET_WATCH

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
