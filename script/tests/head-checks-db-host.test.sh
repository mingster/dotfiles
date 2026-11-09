#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# head-checks runs a Postgres step on the head_checks_remote database host when this host has no Postgres,
# and fails (host fault) when there is no such host. Scratch HOME only; remote-heavy is a stub.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
runner=$(cd "$here/.." && pwd)/head-checks.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"

pass=0
fail=0
check() {
  if [ "$2" = ok ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi
}

repo="$tmp/repo"
mkdir -p "$repo/.agents"
git -C "$repo" init -q
printf 'createdb fixture_849\n' > "$repo/.agents/head-checks.conf"
printf 'x\n' > "$repo/code.txt"
git -C "$repo" add -A >/dev/null
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm base
base=$(git -C "$repo" rev-parse HEAD)

# A remote-heavy stand-in: records the host it was sent to and succeeds.
cat > "$tmp/remote-heavy.sh" <<'EOF'
#!/usr/bin/env bash
host=""
while [ "$1" != -- ]; do
  case "$1" in --host) host=$2; shift 2 ;; *) shift 2 ;; esac
done
shift
echo "$host" > "$REMOTE_LOG"
exec true
EOF
chmod +x "$tmp/remote-heavy.sh"

run_hc() {
  rm -f "$tmp/remote.log"
  env -u LEAD_MERGE_REMOTE_HOST HEAD_CHECKS_DB_PROBE=no-such-db-client-849 HEAD_CHECKS_WAIT_SECONDS=0 REMOTE_LOG="$tmp/remote.log" \
    HEAD_CHECKS_REMOTE_HEAVY="$tmp/remote-heavy.sh" "$@" bash "$runner" --repo "$repo" --ref HEAD --base "$base" >"$tmp/out" 2>&1
}

run_hc; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'host fault' "$tmp/out" && grep -q 'command not found' "$tmp/out"; then
  check "no Postgres and no database host fails as a host fault" ok
else
  check "no Postgres and no database host fails as a host fault" bad
fi

run_hc LEAD_MERGE_REMOTE_HOST=db-host-849 LEAD_MERGE_REMOTE_REPO_DIR=/srv/repo LEAD_MERGE_REMOTE_DIR=/srv/checks; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$tmp/remote.log" 2>/dev/null)" = db-host-849 ]; then
  check "no Postgres here sends the database step to the head_checks_remote host" ok
else
  check "no Postgres here sends the database step to the head_checks_remote host" bad
fi

printf 'true\n' > "$repo/.agents/head-checks.conf"
git -C "$repo" add -A >/dev/null
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm plain
run_hc LEAD_MERGE_REMOTE_HOST=db-host-849 LEAD_MERGE_REMOTE_REPO_DIR=/srv/repo LEAD_MERGE_REMOTE_DIR=/srv/checks; rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$tmp/remote.log" ]; then
  check "a step with no database client stays on this host" ok
else
  check "a step with no database client stays on this host" bad
fi

echo "head-checks-db-host: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
