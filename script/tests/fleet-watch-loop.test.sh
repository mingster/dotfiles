#!/usr/bin/env bash
# fleet-watch-loop.sh: one pass per loop turn, pid file, a second copy exits, --status and --stop.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'kill "$(cat "$tmp/dir/loop.pid" 2>/dev/null)" 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" = ok ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

cat >"$tmp/fake-python" <<'PY'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
PY
chmod +x "$tmp/fake-python"
export PYTHON="$tmp/fake-python" FAKE_LOG="$tmp/calls.log" FLEET_WATCH_LOOP_DIR="$tmp/dir"
export FLEET_WATCH_CONFIG=/c.json FLEET_WATCH_STATE=/s.json FLEET_WATCH_INTERVAL=1

FLEET_WATCH_LOOP_ONCE=1 bash "$here/fleet-watch-loop.sh"
grep -q -- "fleet-watch.py --config /c.json --state /s.json" "$tmp/calls.log" && r=ok || r=bad
check "one pass runs fleet-watch with the config and state" "$r"
[ ! -e "$tmp/dir/loop.pid" ] && r=ok || r=bad
check "pid file is removed when the loop ends" "$r"

bash "$here/fleet-watch-loop.sh" >/dev/null 2>&1 &
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$tmp/dir/loop.pid" ] && break; sleep 0.3; done
bash "$here/fleet-watch-loop.sh" --status >/dev/null && r=ok || r=bad
check "--status reports the running loop" "$r"
out=$(bash "$here/fleet-watch-loop.sh" 2>&1); code=$?
[ "$code" = 0 ] && [[ "$out" == *"already running"* ]] && r=ok || r=bad
check "a second copy exits 0 and says it is running" "$r"
sleep 2.5
[ "$(wc -l <"$tmp/calls.log")" -ge 3 ] && r=ok || r=bad
check "the loop repeats on the interval" "$r"
bash "$here/fleet-watch-loop.sh" --stop >/dev/null
sleep 0.5
bash "$here/fleet-watch-loop.sh" --status >/dev/null && r=bad || r=ok
check "--stop ends the loop" "$r"

env -u FLEET_WATCH_CONFIG bash "$here/fleet-watch-loop.sh" >/dev/null 2>&1; [ "$?" = 2 ] && r=ok || r=bad
check "missing config is refused" "$r"
exit "$fail"
