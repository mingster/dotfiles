#!/usr/bin/env bash
# fleet-workers.py with a fake orca that answers environment list and worker-list.
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
  "orchestration worker-list")
    if [[ " $* " == *" --environment e1 "* ]]; then
      [[ -z ${FAKE_REMOTE_FAIL:-} ]] || exit 1
      cat "$FAKE_REMOTE"
    else
      cat "$FAKE_LOCAL"
    fi ;;
esac
ORCA
chmod +x "$work/bin/orca"
cp "$root/script/fleet-workers.py" "$work/fleet-workers.py"

# worker <host> <liveness> <outcome>: one worker-list row; outcome "-" leaves it out.
rows() {
  local out='{"result":{"workers":[' sep=''
  for spec in "$@"; do
    read -r host live outcome <<< "$spec"
    out+="$sep{\"host\":\"$host\",\"liveness\":\"$live\""
    [[ $outcome == - ]] || out+=",\"outcome\":\"$outcome\""
    out+='}'
    sep=,
  done
  printf '%s]}}' "$out"
}

run() {
  PATH="$work/bin:$PATH" FAKE_ENVS="$work/envs.json" FAKE_LOCAL="$work/local.json" \
    FAKE_REMOTE="$work/remote.json" python3 "$work/fleet-workers.py"
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

printf '%s' "$no_envs" > "$work/envs.json"
rows 'local live in_progress' 'local live in_progress' > "$work/local.json"
assert_line 'live in progress dispatches' 2

rows 'local exited -' 'local exited failed' 'local unverifiable -' 'local live succeeded' > "$work/local.json"
assert_line 'finished, failed and unverifiable rows are not busy' 0

rows 'local live in_progress' 'miniu live in_progress' > "$work/local.json"
assert_line 'rows observed from other servers are not local' 1

printf '{"result":{}}' > "$work/local.json"
assert_line 'no worker list answer' '?'

printf '%s' "$one_env" > "$work/envs.json"
rows 'local live in_progress' > "$work/local.json"
rows 'local live in_progress' 'local live in_progress' 'local exited succeeded' > "$work/remote.json"
assert_line 'each environment is asked for its own list' '1 | host-a: 2'
FAKE_REMOTE_FAIL=1 assert_line 'unreachable host' '1 | host-a: ?'

printf '%s' '{"result":{"environments":[{"id":"e1","name":"203.0.113.9"}]}}' > "$work/envs.json"
assert_line 'address without an overlay' '1 | 203.0.113.9: 2'
printf '%s' '{"203.0.113.9":"host-b"}' > "$work/fleet-workers.local.json"
assert_line 'local overlay names the address' '1 | host-b: 2'

printf 'PASS: %s tests\n' "$tests"
