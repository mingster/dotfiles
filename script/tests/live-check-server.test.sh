#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# Unit tests for script/live-check-server.sh.
set -euo pipefail

here=$(cd "$(dirname "$0")/../.." && pwd)
SUT="$here/script/live-check-server.sh"
tmp=$(mktemp -d)

cleanup() {
  if [ -d "$tmp/state" ]; then
    bash "$SUT" --state-dir "$tmp/state" stop >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok - $1"; }
bad() { fail=$((fail + 1)); echo "not ok - $1" >&2; }

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
url="http://127.0.0.1:${port}"
state_dir="$tmp/state"
start_count_file="$tmp/start-count"
echo 0 > "$start_count_file"

# Set up bare origin repo and local shared checkout
origin_repo="$tmp/origin.git"
checkout_dir="$tmp/checkout"
git init -q --bare "$origin_repo"
git init -q "$checkout_dir"
git -C "$checkout_dir" config user.email "test@example.com"
git -C "$checkout_dir" config user.name "Test"
git -C "$checkout_dir" checkout -q -b main
echo "v1" > "$checkout_dir/index.txt"
git -C "$checkout_dir" add index.txt
git -C "$checkout_dir" commit -qm "initial main"
git -C "$checkout_dir" remote add origin "$origin_repo"
git -C "$checkout_dir" push -q -u origin main
sha1=$(git -C "$checkout_dir" rev-parse HEAD)

start_cmd="cnt=\$(cat '$start_count_file'); echo \$((cnt + 1)) > '$start_count_file'; exec python3 -m http.server '$port' --bind 127.0.0.1"

# 1. Starts server once when down, runs verifier command, and releases lock while keeping server up
out1=$(bash "$SUT" \
  --host local \
  --dir "$checkout_dir" \
  --port "$port" \
  --url "$url" \
  --state-dir "$state_dir" \
  --start-cmd "$start_cmd" \
  --ready-seconds 15 \
  -- bash -c 'printf "url=%s sha=%s pid=%s\n" "$LIVE_CHECK_URL" "$LIVE_CHECK_SHA" "$LIVE_CHECK_PID"' 2>"$tmp/err1")

if [[ "$out1" == *"url=${url} sha=${sha1}"* ]] \
  && grep -q "started server" "$tmp/err1" \
  && [ "$(cat "$start_count_file")" -eq 1 ] \
  && [ ! -d "$state_dir/lock" ] \
  && bash "$SUT" --dir "$checkout_dir" --state-dir "$state_dir" --port "$port" --url "$url" status >/dev/null; then
  ok "starts shared server on main, runs verifier command, releases lock, keeps server up"
else
  bad "starts shared server on main (out=$out1 err=$(cat "$tmp/err1"))"
fi
pid1=$(cat "$state_dir/server.pid")

# 2. Second verifier run reuses running server on same main SHA without restarting
out2=$(bash "$SUT" \
  --host local \
  --dir "$checkout_dir" \
  --port "$port" \
  --url "$url" \
  --state-dir "$state_dir" \
  --start-cmd "$start_cmd" \
  --ready-seconds 15 \
  -- bash -c 'printf "pid=%s sha=%s\n" "$LIVE_CHECK_PID" "$LIVE_CHECK_SHA"' 2>"$tmp/err2")

if [[ "$out2" == "pid=${pid1} sha=${sha1}" ]] \
  && grep -q "reusing server" "$tmp/err2" \
  && [ "$(cat "$start_count_file")" -eq 1 ]; then
  ok "reuses running server when origin/main SHA matches"
else
  bad "reuses running server (out=$out2 err=$(cat "$tmp/err2") count=$(cat "$start_count_file"))"
fi

# 3. Advancing origin/main restarts the server on the new main SHA
work_clone="$tmp/work-clone"
git clone -q -b main "$origin_repo" "$work_clone"
git -C "$work_clone" config user.email "test@example.com"
git -C "$work_clone" config user.name "Test"
echo "v2" > "$work_clone/index.txt"
git -C "$work_clone" commit -am "advance main" -q
git -C "$work_clone" push -q origin main
sha2=$(git -C "$work_clone" rev-parse HEAD)

out3=$(bash "$SUT" \
  --host local \
  --dir "$checkout_dir" \
  --port "$port" \
  --url "$url" \
  --state-dir "$state_dir" \
  --start-cmd "$start_cmd" \
  --ready-seconds 15 \
  -- bash -c 'printf "sha=%s body=%s\n" "$LIVE_CHECK_SHA" "$(curl -fsS "$LIVE_CHECK_URL/index.txt")"' 2>"$tmp/err3")

if [[ "$out3" == "sha=${sha2} body=v2" ]] \
  && [ "$(cat "$start_count_file")" -eq 2 ]; then
  ok "restarts server on latest origin/main when main advances"
else
  bad "restarts server when origin/main advances (out=$out3 err=$(cat "$tmp/err3"))"
fi

# 4. Reclaims stale lock from dead PID
mkdir -p "$state_dir/lock"
echo 999999 > "$state_dir/lock/pid"
if bash "$SUT" \
  --host local \
  --dir "$checkout_dir" \
  --port "$port" \
  --url "$url" \
  --state-dir "$state_dir" \
  --start-cmd "$start_cmd" \
  -- true 2>/dev/null; then
  ok "reclaims stale lock from dead PID"
else
  bad "reclaims stale lock from dead PID"
fi

# 5. Waits when lock is held by a live process, then proceeds once released
sleep 30 &
holder_pid=$!
mkdir -p "$state_dir/lock"
echo "$holder_pid" > "$state_dir/lock/pid"
(
  sleep 2
  rm -rf "$state_dir/lock"
) &
releaser_pid=$!

if bash "$SUT" \
  --host local \
  --dir "$checkout_dir" \
  --port "$port" \
  --url "$url" \
  --state-dir "$state_dir" \
  --start-cmd "$start_cmd" \
  --wait-seconds 6 \
  --poll-seconds 1 \
  -- true 2>"$tmp/err5"; then
  ok "waits on live lock holder and proceeds after release"
else
  bad "waits on live lock holder (err=$(cat "$tmp/err5"))"
fi
wait "$releaser_pid" 2>/dev/null || true

# 6. Exits 75 naming the 30m wait limit when lock remains held past --wait-seconds
mkdir -p "$state_dir/lock"
echo "$holder_pid" > "$state_dir/lock/pid"
set +e
bash "$SUT" \
  --host local \
  --dir "$checkout_dir" \
  --port "$port" \
  --url "$url" \
  --state-dir "$state_dir" \
  --start-cmd "$start_cmd" \
  --wait-seconds 2 \
  --poll-seconds 1 \
  -- true 2>"$tmp/err6"
rc6=$?
set -e
rm -rf "$state_dir/lock"
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true

if [ "$rc6" -eq 75 ] \
  && grep -q "30m wait limit" "$tmp/err6" \
  && bash "$SUT" --dir "$checkout_dir" --state-dir "$state_dir" --port "$port" --url "$url" status >/dev/null; then
  ok "exits 75 naming 30m wait limit on lock timeout without stopping running server"
else
  bad "lock timeout exit code or message (rc=$rc6 err=$(cat "$tmp/err6"))"
fi

# 7. Reads per-host config via apply-local-overlay.py (ship.local.json overlay) and supports acquire/release
local_cfg="$tmp/ship.local.json"
cat > "$local_cfg" <<EOF
{
  "live_check_server": {
    "example-org/sample-web": {
      "host": "local",
      "dir": "$checkout_dir",
      "port": $port,
      "url": "$url",
      "start_cmd": "$start_cmd",
      "state_dir": "$state_dir",
      "wait_seconds": 1800
    }
  }
}
EOF

acq_out=$(bash "$SUT" --config "$local_cfg" --repo "example-org/sample-web" acquire 2>"$tmp/err7")
tok7=$(printf '%s\n' "$acq_out" | sed -n 's/^LIVE_CHECK_TOKEN=//p')
if [[ "$acq_out" == *"LIVE_CHECK_URL=${url}"* ]] \
  && [ -n "$tok7" ] \
  && [ -d "$state_dir/lock" ] \
  && bash "$SUT" --config "$local_cfg" --repo "example-org/sample-web" --token "$tok7" release \
  && [ ! -d "$state_dir/lock" ]; then
  ok "reads config from ship.local.json overlay and supports acquire/release"
else
  bad "ship.local.json overlay acquire/release (out=$acq_out err=$(cat "$tmp/err7"))"
fi

# 8. Remote host delegation via ssh
mkdir -p "$tmp/bin"
cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'SSH_HOST=%s SSH_CMD=%s\n' "$1" "$2"
EOF
chmod +x "$tmp/bin/ssh"

ssh_out=$(PATH="$tmp/bin:$PATH" bash "$SUT" \
  --host "remote-box" \
  --repo "example-org/sample-web" \
  -- status)
if [[ "$ssh_out" == *"SSH_HOST=remote-box"* ]] && [[ "$ssh_out" == *"--host local"* ]]; then
  ok "delegates to remote live-check host over ssh when host is non-local"
else
  bad "remote ssh delegation (out=$ssh_out)"
fi

# 9. acquire keeps the lock after the calling shell exits (no PPID ownership)
sh -c "bash '$SUT' --host local --dir '$checkout_dir' --port '$port' --url '$url' --state-dir '$state_dir' --start-cmd '$start_cmd' acquire >'$tmp/acq9' 2>/dev/null"
tok9=$(sed -n 's/^LIVE_CHECK_TOKEN=//p' "$tmp/acq9")
set +e
bash "$SUT" --host local --dir "$checkout_dir" --port "$port" --url "$url" --state-dir "$state_dir" \
  --start-cmd "$start_cmd" --wait-seconds 2 --poll-seconds 1 -- true 2>"$tmp/err9"
rc9=$?
set -e
if [ -n "$tok9" ] && [ "$rc9" -eq 75 ] && [ -d "$state_dir/lock" ]; then
  ok "acquire keeps the lock after the caller's shell exits"
else
  bad "acquire lock lost after caller exit (tok=$tok9 rc=$rc9 err=$(cat "$tmp/err9"))"
fi

# 10. release refuses to delete a lock it does not own
set +e
bash "$SUT" --state-dir "$state_dir" release 2>/dev/null
rc10a=$?
bash "$SUT" --state-dir "$state_dir" --token wrong-token release 2>/dev/null
rc10b=$?
set -e
still=0
[ -d "$state_dir/lock" ] && still=1
bash "$SUT" --state-dir "$state_dir" --token "$tok9" release 2>/dev/null
if [ "$rc10a" -ne 0 ] && [ "$rc10b" -ne 0 ] && [ "$still" -eq 1 ] && [ ! -d "$state_dir/lock" ]; then
  ok "release refuses a lock it does not own and frees it for the owner"
else
  bad "release ownership (rc=$rc10a/$rc10b still=$still)"
fi

# 11. Remote host resolves its own state dir, not the caller's local TMPDIR
ssh_out11=$(TMPDIR="$tmp/caller-tmp" PATH="$tmp/bin:$PATH" bash "$SUT" \
  --host "remote-box" \
  --repo "example-org/sample-web" \
  status)
if [[ "$ssh_out11" == *"SSH_HOST=remote-box"* ]] \
  && [[ "$ssh_out11" != *"caller-tmp"* ]] \
  && [[ "$ssh_out11" != *"--state-dir"* ]]; then
  ok "remote host does not receive the caller's local state dir"
else
  bad "remote state dir leaked (out=$ssh_out11)"
fi

# 12. No checkout for this host (no --dir, no env, empty ship.local.json): status exits 3 and names the missing key
empty_cfg="$tmp/empty-ship.local.json"
echo '{}' > "$empty_cfg"
set +e
env -u LIVE_CHECK_DIR bash "$SUT" --config "$empty_cfg" --repo "example-org/sample-web" \
  --state-dir "$tmp/state12" status >"$tmp/out12" 2>"$tmp/err12"
rc12=$?
set -e
if [ "$rc12" -eq 3 ] && grep -q 'live_check_server\.example-org/sample-web\.dir' "$tmp/err12"; then
  ok "missing checkout config exits 3 and names live_check_server.<repo>.dir"
else
  bad "missing checkout config (rc=$rc12 err=$(cat "$tmp/err12"))"
fi

bash "$SUT" --state-dir "$state_dir" stop >/dev/null 2>&1 || true

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
