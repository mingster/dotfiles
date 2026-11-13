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
printf '%s\n' "$@" > "$REMOTE_LOG.argv"
exec true
EOF
chmod +x "$tmp/remote-heavy.sh"

run_hc() {
  rm -f "$tmp/remote.log"
  env -u LEAD_MERGE_REMOTE_HOST HEAD_CHECKS_DB_PROBE=no-such-db-client-849 HEAD_CHECKS_WAIT_SECONDS=0 REMOTE_LOG="$tmp/remote.log" \
    HEAD_CHECKS_REMOTE_HEAVY="$tmp/remote-heavy.sh" "$@" bash "$runner" --repo "$repo" --ref HEAD --base "$base" >"$tmp/out" 2>&1
}

run_hc; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'host fault' "$tmp/out" && grep -q 'no reachable local Postgres' "$tmp/out"; then
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

# A step marked "# db" whose createdb is inside a script still counts as a database step.
mkdir -p "$repo/bin"
printf '#!/usr/bin/env bash\ncreatedb fixture_849\n' > "$repo/bin/head-checks-db.sh"
printf 'bash bin/head-checks-db.sh # db\n' > "$repo/.agents/head-checks.conf"
git -C "$repo" add -A >/dev/null
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm marked
run_hc; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'host fault' "$tmp/out" && [ ! -f "$tmp/remote.log" ]; then
  check "a marked script step with no database host fails as a host fault" ok
else
  check "a marked script step with no database host fails as a host fault" bad
fi
run_hc LEAD_MERGE_REMOTE_HOST=db-host-849 LEAD_MERGE_REMOTE_REPO_DIR=/srv/repo LEAD_MERGE_REMOTE_DIR=/srv/checks; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$tmp/remote.log" 2>/dev/null)" = db-host-849 ]; then
  check "a marked script step goes to the database host when the probe is missing" ok
else
  check "a marked script step goes to the database host when the probe is missing" bad
fi

# createdb is on every host, so it says nothing about a server: only an answering pg_isready runs the step here.
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/createdb"
printf '#!/bin/sh\nexit 2\n' > "$tmp/bin/pg_isready"
chmod +x "$tmp/bin/createdb" "$tmp/bin/pg_isready"
printf 'createdb fixture_849\n' > "$repo/.agents/head-checks.conf"
git -C "$repo" add -A >/dev/null
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm createdb-only
run_hc HEAD_CHECKS_DB_PROBE= PATH="$tmp/bin:$PATH"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'host fault' "$tmp/out" && [ ! -f "$tmp/remote.log" ]; then
  check "createdb present but no server is a host fault without a database host" ok
else
  check "createdb present but no server is a host fault without a database host" bad
fi
run_hc HEAD_CHECKS_DB_PROBE= PATH="$tmp/bin:$PATH" LEAD_MERGE_REMOTE_HOST=db-host-849 LEAD_MERGE_REMOTE_REPO_DIR=/srv/repo LEAD_MERGE_REMOTE_DIR=/srv/checks; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$tmp/remote.log" 2>/dev/null)" = db-host-849 ]; then
  check "createdb present but no server routes to the database host" ok
else
  check "createdb present but no server routes to the database host" bad
fi
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/pg_isready"
run_hc HEAD_CHECKS_DB_PROBE= PATH="$tmp/bin:$PATH" LEAD_MERGE_REMOTE_HOST=db-host-849 LEAD_MERGE_REMOTE_REPO_DIR=/srv/repo LEAD_MERGE_REMOTE_DIR=/srv/checks; rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$tmp/remote.log" ]; then
  check "a reachable local server runs the database step here" ok
else
  check "a reachable local server runs the database step here" bad
fi

# The remote command keeps the caller's step variables but never this host's PATH or HOME.
run_hc LEAD_MERGE_REMOTE_HOST=db-host-849 LEAD_MERGE_REMOTE_REPO_DIR=/srv/repo LEAD_MERGE_REMOTE_DIR=/srv/checks LANG=en_US.UTF-8 DOTFILES_DIR=/caller/dotfiles; rc=$?
argv="$tmp/remote.log.argv"
if [ "$rc" -eq 0 ] && grep -qx 'LANG=en_US.UTF-8' "$argv" && grep -qx 'DOTFILES_DIR=/caller/dotfiles' "$argv" \
  && grep -q '^HEAD_CHECK_SHA=' "$argv" && grep -q '^HEAD_CHECK_BASE=' "$argv" && grep -q '^HEAD_CHECKS_TSC_BUILD_INFO=' "$argv" \
  && ! grep -q '^PATH=' "$argv" && ! grep -q '^HOME=' "$argv" && ! grep -qx -- '-i' "$argv"; then
  check "the remote step keeps the step variables and drops this host's PATH and HOME" ok
else
  check "the remote step keeps the step variables and drops this host's PATH and HOME" bad
fi

echo "head-checks-db-host: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
