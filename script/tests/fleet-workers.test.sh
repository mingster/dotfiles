#!/usr/bin/env bash
# fleet-workers.py with a fake orca, fake ssh and fake count-agents.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tests=0

mkdir "$work/bin"
cat > "$work/bin/orca" <<'ORCA'
#!/usr/bin/env bash
case "$1 $2" in
  "environment list") cat "$FAKE_ENVS" ;;
  "terminal list") cat "$FAKE_TERMS" ;;
esac
ORCA
cat > "$work/bin/ssh" <<'SSH'
#!/usr/bin/env bash
cat > /dev/null
[[ -z ${FAKE_SSH_FAIL:-} ]] || exit 255
printf '%b' "$FAKE_SSH_OUT"
SSH
chmod +x "$work/bin/orca" "$work/bin/ssh"

printf '#!/usr/bin/env bash\necho "$FAKE_LOCAL_COUNT"\n' > "$work/count.sh"

terms() {
  local out='{"result":{"terminals":[' sep=''
  for name in "$@"; do
    out+="$sep{\"worktreePath\":\"/home/u/orca/workspaces/proj/$name\"}"
    sep=,
  done
  printf '%s]}}' "$out"
}

run() {
  PATH="$work/bin:$PATH" COUNT_AGENTS="$work/count.sh" FAKE_ENVS="$work/envs.json" \
    FAKE_TERMS="$work/terms.json" python3 "$root/script/fleet-workers.py"
}

assert_line() {
  local label=$1 expected=$2 actual
  actual=$(run | sed 's/^[^:]*: //')
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s: expected "%s", got "%s"\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
  tests=$((tests + 1))
}

no_envs='{"result":{"environments":[]}}'
one_env='{"result":{"environments":[{"id":"e1","name":"host-a"}]}}'
export FAKE_LOCAL_COUNT=5

printf '%s' "$no_envs" > "$work/envs.json"
terms lead-x elon-y lead-x worker-z > "$work/terms.json"
assert_line 'agent sessions minus live coordinator worktrees' 3

terms lead-x elon-y lead-z > "$work/terms.json"
FAKE_LOCAL_COUNT=1 assert_line 'never below zero' 0

printf '%s' "$one_env" > "$work/envs.json"
terms > "$work/terms.json"
FAKE_SSH_FAIL=1 assert_line 'unreachable host' '5 | host-a: ?'
FAKE_SSH_OUT='Welcome\n3 updates\n7\n' assert_line 'login banner number before the count' '5 | host-a: 7'
FAKE_SSH_OUT='7\n' assert_line 'bare count' '5 | host-a: 7'

printf 'PASS: %s tests\n' "$tests"
