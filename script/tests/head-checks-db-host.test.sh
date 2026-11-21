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
  && grep -q '^HEAD_CHECK_SHA=' "$argv" && grep -q '^HEAD_CHECK_BASE=' "$argv" && grep -q '^HEAD_CHECKS_TSC_CACHE_DIR=' "$argv" \
  && ! grep -q '^PATH=' "$argv" && ! grep -q '^HOME=' "$argv" && ! grep -qx -- '-i' "$argv"; then
  check "the remote step keeps the step variables and drops this host's PATH and HOME" ok
else
  check "the remote step keeps the step variables and drops this host's PATH and HOME" bad
fi

# A remote step that only hit load errors (no failing test) is a host fault, not a verdict on the code.
cat > "$tmp/remote-heavy-load.sh" <<'EOF2'
#!/usr/bin/env bash
printf 'bun test v1.3.0\n\nerror: Cannot find module .prisma/client/default\n\n 0 pass\n 0 fail\n 3 errors\n'
exit 1
EOF2
chmod +x "$tmp/remote-heavy-load.sh"
printf 'bun test # db\n' > "$repo/.agents/head-checks.conf"
git -C "$repo" add -A >/dev/null
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm load-errors
run_hc LEAD_MERGE_REMOTE_HOST=db-host-849 LEAD_MERGE_REMOTE_REPO_DIR=/srv/repo LEAD_MERGE_REMOTE_DIR=/srv/checks HEAD_CHECKS_REMOTE_HEAVY="$tmp/remote-heavy-load.sh"; rc=$?
if [ "$rc" -ne 0 ] && grep -q '^Result: host fault; .*load errors' "$tmp/out" && ! grep -q '^Result: exit 1' "$tmp/out"; then
  check "load errors with no failing test on the database host is a host fault" ok
else
  check "load errors with no failing test on the database host is a host fault" bad
fi
cat > "$tmp/remote-heavy-fail.sh" <<'EOF2'
#!/usr/bin/env bash
printf 'bun test v1.3.0\n\n 4 pass\n 2 fail\n 1 error\n'
exit 1
EOF2
chmod +x "$tmp/remote-heavy-fail.sh"
run_hc LEAD_MERGE_REMOTE_HOST=db-host-849 LEAD_MERGE_REMOTE_REPO_DIR=/srv/repo LEAD_MERGE_REMOTE_DIR=/srv/checks HEAD_CHECKS_REMOTE_HEAVY="$tmp/remote-heavy-fail.sh"; rc=$?
if [ "$rc" -ne 0 ] && grep -q '^Result: exit 1' "$tmp/out" && ! grep -q 'host fault' "$tmp/out"; then
  check "load errors next to failing tests stays a FAIL" ok
else
  check "load errors next to failing tests stays a FAIL" bad
fi

# A database step that executed 0 tests is a host fault (INFRA, no rework), even with a nonzero exit and no failing test.
cat > "$tmp/remote-heavy-zero.sh" <<'EOF2'
#!/usr/bin/env bash
printf 'bun test v1.3.0\n\n 0 pass\n 0 fail\n'
exit 1
EOF2
chmod +x "$tmp/remote-heavy-zero.sh"
run_hc LEAD_MERGE_REMOTE_HOST=db-host-849 LEAD_MERGE_REMOTE_REPO_DIR=/srv/repo LEAD_MERGE_REMOTE_DIR=/srv/checks HEAD_CHECKS_REMOTE_HEAVY="$tmp/remote-heavy-zero.sh"; rc=$?
if [ "$rc" -ne 0 ] && grep -q '^Checks: INFRA' "$tmp/out" && grep -q '^Result: host fault' "$tmp/out" && ! grep -q '^Result: exit 1' "$tmp/out"; then
  check "a database step with 0 tests executed is a host fault" ok
else
  check "a database step with 0 tests executed is a host fault" bad
fi

# Two runs at once share one remote checkout: the second waits for the first, and each reports its own result.
cat > "$tmp/remote-heavy-slow.sh" <<'EOF2'
#!/usr/bin/env bash
echo "start $$" >> "$SLOW_LOG"
sleep 2
echo "end $$" >> "$SLOW_LOG"
exec true
EOF2
chmod +x "$tmp/remote-heavy-slow.sh"
printf 'bash -c true # db\n' > "$repo/.agents/head-checks.conf"
git -C "$repo" add -A >/dev/null
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm concurrent
rm -f "$tmp/slow.log"
conc_env=(env -u LEAD_MERGE_REMOTE_HOST HEAD_CHECKS_DB_PROBE=no-such-db-client-849 HEAD_CHECKS_WAIT_SECONDS=30 SLOW_LOG="$tmp/slow.log"
  LEAD_MERGE_REMOTE_HOST=db-host-849 LEAD_MERGE_REMOTE_REPO_DIR=/srv/repo LEAD_MERGE_REMOTE_DIR=/srv/checks HEAD_CHECKS_REMOTE_HEAVY="$tmp/remote-heavy-slow.sh")
"${conc_env[@]}" bash "$runner" --repo "$repo" --ref HEAD --base "$base" >"$tmp/out1" 2>&1 & pid1=$!
sleep 0.5
"${conc_env[@]}" bash "$runner" --repo "$repo" --ref HEAD --base "$base" >"$tmp/out2" 2>&1 & pid2=$!
wait "$pid1"; rc1=$?; wait "$pid2"; rc2=$?
order=$(awk '{print $1}' "$tmp/slow.log" 2>/dev/null | paste -sd, -)
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$order" = start,end,start,end ] \
  && grep -q '^Checks: PASS' "$tmp/out1" && grep -q '^Checks: PASS' "$tmp/out2"; then
  check "two concurrent runs use the remote checkout one after the other and each passes" ok
else
  check "two concurrent runs use the remote checkout one after the other and each passes" bad
fi

# The database host's heavy-gate refusing admission within the wait cap is INFRA, naming the gate reason; the cap is passed on.
cat > "$tmp/remote-heavy-cap.sh" <<'EOF2'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REMOTE_LOG.argv"
echo 'heavy-gate: wait cap of 600s reached, not admitted: load 22.51 exceeds 5' >&2
exit 75
EOF2
chmod +x "$tmp/remote-heavy-cap.sh"
run_hc LEAD_MERGE_REMOTE_HOST=db-host-849 LEAD_MERGE_REMOTE_REPO_DIR=/srv/repo LEAD_MERGE_REMOTE_DIR=/srv/checks HEAD_CHECKS_REMOTE_HEAVY="$tmp/remote-heavy-cap.sh"; rc=$?
if [ "$rc" -ne 0 ] && grep -q '^Checks: INFRA' "$tmp/out" && grep -q '^Result: host busy; .*load 22.51 exceeds 5' "$tmp/out" \
  && grep -qx 'Remote wait: 600s' "$tmp/out" && ! grep -q '^Checks: FAIL' "$tmp/out" \
  && grep -qx -- '--max-wait' "$tmp/remote.log.argv" && grep -qx 600 "$tmp/remote.log.argv"; then
  check "a database step the gate never admitted is INFRA with the gate reason" ok
else
  check "a database step the gate never admitted is INFRA with the gate reason" bad
fi

# The receipt carries the wait seconds of an admitted remote step.
cat > "$tmp/remote-heavy-waited.sh" <<'EOF2'
#!/usr/bin/env bash
echo 'heavy-gate: waited 42s for admission' >&2
exit 0
EOF2
chmod +x "$tmp/remote-heavy-waited.sh"
run_hc LEAD_MERGE_REMOTE_HOST=db-host-849 LEAD_MERGE_REMOTE_REPO_DIR=/srv/repo LEAD_MERGE_REMOTE_DIR=/srv/checks HEAD_CHECKS_REMOTE_HEAVY="$tmp/remote-heavy-waited.sh"; rc=$?
if [ "$rc" -eq 0 ] && grep -qx 'Remote wait: 42s' "$tmp/out"; then
  check "the receipt logs the remote wait seconds" ok
else
  check "the receipt logs the remote wait seconds" bad
fi

# When the wait runs out the run reports host busy (INFRA), not FAIL, and the holder is untouched.
mkdir -p "$HOME/orca/workspaces/repo"
held="$HOME/orca/workspaces/repo/"
sleep 300 & holder=$!
key=$(printf '%s_%s' db-host-849 /srv/checks | tr -c 'A-Za-z0-9._\n' '_')
mkdir -p "${held}_db-$key.lock"; echo "$holder" > "${held}_db-$key.lock/pid"
"${conc_env[@]}" HEAD_CHECKS_DB_WAIT_SECONDS=1 bash "$runner" --repo "$repo" --ref HEAD --base "$base" >"$tmp/out3" 2>&1; rc3=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
if [ "$rc3" -ne 0 ] && grep -q '^Checks: INFRA' "$tmp/out3" && grep -q '^Result: host busy' "$tmp/out3" && ! grep -q '^Checks: FAIL' "$tmp/out3"; then
  check "a busy remote checkout reports host busy, not FAIL" ok
else
  check "a busy remote checkout reports host busy, not FAIL" bad
fi

echo "head-checks-db-host: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
