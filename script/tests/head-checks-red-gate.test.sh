#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# #1745 and #1746: head-checks runs the project db preflight before the database step, files or updates one deduped
# "red gate: <tool>" issue on an infra failure, and tells other PRs "blocked by red gate #<n>" while it is open.
# Scratch HOME; gh is a file backed stub.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
runner=$(cd "$here/.." && pwd)/head-checks.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME" "$tmp/bin"

pass=0
fail=0
check() {
  if [ "$2" = ok ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi
}

# gh stub: issues live in $STUB/issues.json, every create and comment is logged, `pr view` serves the PR fixture.
export STUB="$tmp/stub"
mkdir -p "$STUB"
cat > "$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
case "$1 $2" in
  'issue list') cat "$STUB/issues.json" ;;
  'issue create')
    title="" ; prev=""
    for a in "$@"; do [ "$prev" = --title ] && title=$a; prev=$a; done
    printf '%s\n' "$*" >> "$STUB/created"
    n=$(( $(jq length "$STUB/issues.json") + 77 ))
    jq --argjson n "$n" --arg t "$title" '. + [{number:$n,title:$t}]' "$STUB/issues.json" > "$STUB/issues.tmp" && mv "$STUB/issues.tmp" "$STUB/issues.json"
    echo "https://github.com/example/fixture/issues/$n" ;;
  'issue comment') printf '%s\n' "$*" >> "$STUB/commented" ;;
  'pr view')
    case "$*" in
      *headRefOid*) printf '{"headRefOid":"%s","baseRefOid":"%s","headRefName":"topic"}\n' "$(cat "$STUB/head")" "$(cat "$STUB/base")" ;;
      *) cat "$STUB/pr-body" ;;
    esac ;;
  'pr comment') : ;;
  *) exit 1 ;;
esac
EOS
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" RED_GATE_GH="$tmp/bin/gh"

repo="$tmp/repo"
mkdir -p "$repo/.agents" "$repo/bin"
git -C "$repo" init -q -b main
git -C "$repo" remote add origin https://github.com/example/fixture.git
git init -q --bare -b main "$tmp/origin.git"
git -C "$repo" config url."$tmp/origin.git".insteadOf https://github.com/example/fixture.git
printf 'x\n' > "$repo/code.txt"
commit_conf() { # <conf text>
  printf '%s\n' "$1" > "$repo/.agents/head-checks.conf"
  git -C "$repo" add -A >/dev/null
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm conf
}
commit_conf 'true'
base=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" push -q origin main

reset_stub() { echo '[]' > "$STUB/issues.json"; rm -f "$STUB/created" "$STUB/commented"; }
run_hc() { # [VAR=value ...]
  env HEAD_CHECKS_DB_PROBE=true HEAD_CHECKS_WAIT_SECONDS=0 "$@" bash "$runner" --repo "$repo" --ref HEAD --base "$base" >"$tmp/out" 2>&1
}

# 1. A failing preflight stops the database step, says whose fault it is, and files one P1 issue.
printf '#!/usr/bin/env bash\necho ran >> "$HOME/db-step-ran"\n' > "$repo/bin/db-step.sh"
printf '#!/usr/bin/env bash\necho "shard behind main: 3 pending migrations" >&2\nexit 3\n' > "$repo/bin/preflight.sh"
commit_conf '# db-preflight: bash bin/preflight.sh
bash bin/db-step.sh # db'
reset_stub; rm -f "$HOME/db-step-ran"
run_hc; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'infra: shared database behind main, not this PR' "$tmp/out" \
  && grep -q '3 pending migrations' "$tmp/out" && grep -q 'red gate #77' "$tmp/out" && [ ! -f "$HOME/db-step-ran" ]; then
  check "a failing preflight stops the database step with the infra message" ok
else check "a failing preflight stops the database step with the infra message" bad; fi
if [ "$(grep -c '^issue create' "$STUB/created")" -eq 1 ] && grep -q -- '--title red gate: shared-db' "$STUB/created" \
  && grep -q -- '--label P1' "$STUB/created" && grep -q -- '--label ready-for-agent' "$STUB/created"; then
  check "the failure files one P1 red gate: shared-db issue" ok
else check "the failure files one P1 red gate: shared-db issue" bad; fi
grep -q '^Checks: INFRA' "$tmp/out" && check "the receipt verdict is INFRA, not FAIL" ok || check "the receipt verdict is INFRA, not FAIL" bad

# 2. While that issue is open, the next PR is told it is blocked and the preflight is not retried.
rm -f "$STUB/created"
run_hc; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'blocked by red gate #77' "$tmp/out" && [ ! -f "$STUB/created" ] && [ ! -f "$HOME/db-step-ran" ]; then
  check "an open red gate blocks the next run with blocked by red gate #n" ok
else check "an open red gate blocks the next run with blocked by red gate #n" bad; fi

# 3. A new failure with the issue already open comments instead of filing a second one (dedupe).
# A PR that fixes the gate runs past the block and its preflight failure comments on the open issue.
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m topic
git -C "$repo" push -q origin HEAD:refs/heads/topic
head=$(git -C "$repo" rev-parse HEAD); printf '%s' "$head" > "$STUB/head"; printf '%s' "$base" > "$STUB/base"
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/preflight.sh"
git -C "$repo" add -A >/dev/null; git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm "fix preflight"
git -C "$repo" push -q -f origin HEAD:refs/heads/topic
head=$(git -C "$repo" rev-parse HEAD); printf '%s' "$head" > "$STUB/head"
printf 'Fixes red gate: #77\n' > "$STUB/pr-body"
rm -f "$STUB/created" "$STUB/commented"
env HEAD_CHECKS_DB_PROBE=true HEAD_CHECKS_WAIT_SECONDS=0 HEAD_CHECKS_PR_HEAD_WAIT_SECONDS=2 bash "$runner" --repo "$repo" --pr 5 >"$tmp/out" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$HOME/db-step-ran" ] && ! grep -q 'blocked by red gate' "$tmp/out"; then
  check "a PR that says Fixes red gate: #n is not blocked by that gate" ok
else check "a PR that says Fixes red gate: #n is not blocked by that gate" bad; fi
rm -f "$HOME/db-step-ran"; printf 'No fix here\n' > "$STUB/pr-body"
env HEAD_CHECKS_DB_PROBE=true HEAD_CHECKS_WAIT_SECONDS=0 HEAD_CHECKS_PR_HEAD_WAIT_SECONDS=2 bash "$runner" --repo "$repo" --pr 5 >"$tmp/out" 2>&1; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'blocked by red gate #77' "$tmp/out" && [ ! -f "$HOME/db-step-ran" ]; then
  check "a PR without the Fixes line is blocked" ok
else check "a PR without the Fixes line is blocked" bad; fi

# 3b. Filing twice for one tool comments on the open issue and never opens a second one.
reset_stub
# shellcheck disable=SC1091
. "$(cd "$here/.." && pwd)/lib/red-gate.sh"
first=$(red_gate_file example/fixture shared-db "first failure postgres://user:secret@host/db")
second=$(red_gate_file example/fixture shared-db "second failure")
if [ "$first" = 77 ] && [ "$second" = 77 ] && [ "$(grep -c '^issue create' "$STUB/created")" -eq 1 ] \
  && grep -q '^issue comment 77' "$STUB/commented" && ! grep -q 'secret' "$STUB/created"; then
  check "a second failure updates the open issue and the database URL is scrubbed" ok
else check "a second failure updates the open issue and the database URL is scrubbed" bad; fi

# 3c. A fixer PR still runs the preflight: while it is still broken the PR fails and the open issue gets the comment.
printf '#!/usr/bin/env bash\nexit 5\n' > "$repo/bin/preflight.sh"
git -C "$repo" add -A >/dev/null; git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm "still broken"
git -C "$repo" push -q -f origin HEAD:refs/heads/topic
printf '%s' "$(git -C "$repo" rev-parse HEAD)" > "$STUB/head"
printf 'Fixes red gate: #77\n' > "$STUB/pr-body"
rm -f "$STUB/created" "$STUB/commented"
env HEAD_CHECKS_DB_PROBE=true HEAD_CHECKS_WAIT_SECONDS=0 HEAD_CHECKS_PR_HEAD_WAIT_SECONDS=2 bash "$runner" --repo "$repo" --pr 5 >"$tmp/out" 2>&1; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'infra: shared database behind main' "$tmp/out" && [ ! -f "$STUB/created" ] && grep -q '^issue comment 77' "$STUB/commented"; then
  check "a fixer PR still runs the preflight and a failure updates the open issue" ok
else check "a fixer PR still runs the preflight and a failure updates the open issue" bad; fi

# 4. A passing preflight lets the database step run, and no issue is filed.
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/preflight.sh"
commit_conf '# db-preflight: bash bin/preflight.sh
bash bin/db-step.sh # db'
reset_stub; rm -f "$HOME/db-step-ran"
run_hc; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$HOME/db-step-ran" ] && [ ! -f "$STUB/created" ]; then
  check "a passing preflight runs the database step and files nothing" ok
else check "a passing preflight runs the database step and files nothing" bad; fi

# 5. No preflight line, no change: the database step just runs.
commit_conf 'bash bin/db-step.sh # db'
reset_stub; rm -f "$HOME/db-step-ran"
run_hc; rc=$?
[ "$rc" -eq 0 ] && [ -f "$HOME/db-step-ran" ] && check "no db-preflight line leaves the database step alone" ok || check "no db-preflight line leaves the database step alone" bad

# 6. A gate tool that exits with a usage error files red gate: <tool>; a plain test failure does not.
printf '#!/usr/bin/env bash\necho "usage: run-scoped-tests.py FILES" >&2\nexit 2\n' > "$repo/bin/run-scoped-tests.sh"
commit_conf 'bash bin/run-scoped-tests.sh'
reset_stub
run_hc; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'infra: gate tool run-scoped-tests failed with exit 2' "$tmp/out" && grep -q 'red gate #77' "$tmp/out" \
  && grep -q -- '--title red gate: run-scoped-tests' "$STUB/created" && grep -q '^Checks: INFRA' "$tmp/out"; then
  check "a gate tool usage error files red gate: <tool>" ok
else check "a gate tool usage error files red gate: <tool>" bad; fi
rm -f "$STUB/created"
run_hc; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'blocked by red gate #77 (run-scoped-tests)' "$tmp/out" && [ ! -f "$STUB/created" ]; then
  check "the next run is blocked by the open gate and files nothing" ok
else check "the next run is blocked by the open gate and files nothing" bad; fi
printf '#!/usr/bin/env bash\necho "1 failed" >&2\nexit 1\n' > "$repo/bin/run-scoped-tests.sh"
commit_conf 'bash bin/run-scoped-tests.sh'
reset_stub
run_hc; rc=$?
if [ "$rc" -ne 0 ] && [ ! -f "$STUB/created" ] && grep -q '^Checks: FAIL' "$tmp/out"; then
  check "a plain test failure from a gate tool is a FAIL and files nothing" ok
else check "a plain test failure from a gate tool is a FAIL and files nothing" bad; fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
