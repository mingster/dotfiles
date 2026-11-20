#!/usr/bin/env bash
# Repo-mapping refusals from worker-placement.py. A remote host with no mapping must not
# be reported as a missing load sample.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# Placement tests use fake hosts; only the worker count tests below read an orca fake.
export WORKER_PLACEMENT_COUNT_WORKERS=0
py=$here/../worker-placement.py
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL $*" >&2; exit 1; }

cat >"$tmp/load-primary-missing.sh" <<'EOF'
#!/usr/bin/env bash
printf 'host-remote cores=8 load=1.0 1.0 1.0\n'
printf 'host-remote-2 cores=8 load=1.0 1.0 1.0\n'
EOF
cat >"$tmp/load-local-hot.sh" <<'EOF'
#!/usr/bin/env bash
printf 'host-primary cores=8 load=20.0 1.0 1.0\n'
printf 'host-remote cores=8 load=1.0 1.0 1.0\n'
EOF
cat >"$tmp/load-all-hot.sh" <<'EOF'
#!/usr/bin/env bash
printf 'host-primary cores=8 load=20.0 1.0 1.0\n'
printf 'host-remote cores=8 load=20.0 1.0 1.0\n'
EOF
chmod +x "$tmp/load-primary-missing.sh" "$tmp/load-local-hot.sh" "$tmp/load-all-hot.sh"

cat >"$tmp/unmapped.json" <<'EOF'
{
  "local_host": "host-primary",
  "host_caps": {"host-primary": 4, "host-remote": 4, "host-remote-2": 4},
  "host_load_ceilings": {"host-primary": 12, "host-remote": 12, "host-remote-2": 12},
  "worker_placement": {"order": ["host-primary", "host-remote", "host-remote-2"], "repos": {}}
}
EOF
cat >"$tmp/mapped.json" <<'EOF'
{
  "local_host": "host-primary",
  "host_caps": {"host-primary": 4, "host-remote": 4},
  "host_load_ceilings": {"host-primary": 12, "host-remote": 12},
  "worker_placement": {
    "order": ["host-primary", "host-remote"],
    "repos": {"host-remote": {"local-app-id": "id:remote-app-id"}}
  }
}
EOF

pick() { # <config> <load script>
  FLEET_LOAD_SCRIPT="$2" FLEET_WATCH_CONFIG="$1" python3 "$py" pick --repo 'id:local-app-id'
}

out=$(pick "$tmp/unmapped.json" "$tmp/load-primary-missing.sh" 2>"$tmp/missing.err" || true)
grep -Fq 'no host has a repo mapping' <<<"$out" || fail "missing local load must name the repo mapping: $out"
grep -Fq 'no readable load' <<<"$out" && fail "missing local load must not say no readable load: $out" || true
grep -Fq 'no repo mapping' "$tmp/missing.err" || fail "stderr should name the skipped hosts: $(cat "$tmp/missing.err")"

out=$(pick "$tmp/unmapped.json" "$tmp/load-local-hot.sh" 2>/dev/null || true)
grep -Fq 'no host has a repo mapping' <<<"$out" || fail "busy local host must still name the repo mapping: $out"
grep -Fq 'host-primary=' <<<"$out" || fail "busy local host should keep its load in the refusal: $out"

out=$(pick "$tmp/mapped.json" "$tmp/load-all-hot.sh" 2>/dev/null || true)
grep -Fq 'refused host-primary=20.0 host-remote=20.0' <<<"$out" || fail "over ceiling keeps the load refusal: $out"
grep -Fq 'repo mapping' <<<"$out" && fail "over ceiling must not say repo mapping: $out" || true

# Least loaded host wins, not the first one under its ceiling.
cat >"$tmp/load-spread.sh" <<'EOS'
#!/usr/bin/env bash
printf 'host-primary cores=8 load=4.5 1.0 1.0\n'
printf 'host-remote cores=8 load=1.0 1.0 1.0\n'
printf 'host-remote-2 cores=8 load=1.0 1.0 1.0\n'
EOS
chmod +x "$tmp/load-spread.sh"
cat >"$tmp/spread.json" <<'EOS'
{
  "local_host": "host-primary",
  "host_caps": {"host-primary": 4, "host-remote": 4, "host-remote-2": 4},
  "host_load_ceilings": {"host-primary": 8, "host-remote": 8, "host-remote-2": 8},
  "worker_placement": {"order": ["host-primary", "host-remote", "host-remote-2"]}
}
EOS
out=$(FLEET_LOAD_SCRIPT="$tmp/load-spread.sh" FLEET_WATCH_CONFIG="$tmp/spread.json" python3 "$py" pick --json)
grep -Fq '"host":"host-remote"' <<<"$out" || fail "less loaded later host must win, ties keep order: $out"

# --- worker counts (#1231): a fake orca inventory feeds the same count fleet-watch admit uses ---
cat >"$tmp/fake-orca.sh" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  *run-list*) printf '%s\n' '{"ok":true,"result":{"runs":[{"id":"run_t"}]}}' ;;
  *task-list*) printf '%s\n' '{"ok":true,"result":{"tasks":[]}}' ;;
  *worker-list*) printf '{"ok":true,"result":{"workers":%s}}\n' "$(cat "$FAKE_WORKERS")" ;;
  *) exit 1 ;;
esac
EOS
chmod +x "$tmp/fake-orca.sh"
# workers_for host=count ... writes the fake inventory: count live workers on each host.
workers_for() {
  python3 -c '
import json, sys
rows = []
for arg in sys.argv[1:]:
    host, n = arg.split("=")
    for i in range(int(n)):
        rows.append({"dispatchId": "d_%s_%d" % (host, i), "dispatchStatus": "running", "terminalState": "active",
                     "projection": {"host": {"id": host}, "liveness": {"verdict": "live"}, "outcome": "in_progress"},
                     "resource": {"ownershipState": "owned", "releaseState": "not_requested"}})
print(json.dumps(rows))
' "$@" >"$tmp/workers.json"
}
cat >"$tmp/counted.json" <<'EOF'
{
  "local_host": "host-primary",
  "host_caps": {"host-primary": 2, "host-remote": 2, "host-remote-2": 2, "host-extra": 2},
  "host_load_ceilings": {"host-primary": 12, "host-remote": 12, "host-remote-2": 12, "host-extra": 12},
  "worker_placement": {"order": ["host-primary", "host-remote", "host-remote-2"], "recent_start_seconds": 300}
}
EOF
# host-extra is in host_caps only; leave it out of the first tests by giving it no load sample.
cat >"$tmp/load-counted.sh" <<'EOF'
#!/usr/bin/env bash
printf 'host-primary cores=8 load=0.5 0.5 0.5\n'
printf 'host-remote cores=8 load=0.5 0.5 0.5\n'
printf 'host-remote-2 cores=8 load=6.0 6.0 6.0\n'
EOF
chmod +x "$tmp/load-counted.sh"
counted_pick() { # <load script> [extra pick args...]
  local load=$1; shift
  WORKER_PLACEMENT_COUNT_WORKERS=1 ORCA_CLI_COMMAND="$tmp/fake-orca.sh" FAKE_WORKERS="$tmp/workers.json" \
    WORKER_PLACEMENT_RECENT_FILE="$tmp/recent.json" FLEET_LOAD_SCRIPT="$load" FLEET_WATCH_CONFIG="$tmp/counted.json" \
    python3 "$py" pick "$@"
}

# 1. A host at its host_caps count is skipped even when it has the lowest load.
workers_for host-remote=2
out=$(counted_pick "$tmp/load-counted.sh" 2>"$tmp/counted.err") || fail "cap skip pick failed: $out $(cat "$tmp/counted.err")"
grep -Fq 'worker-placement: host=host-remote-2 load_1m=6.0 workers=0/2' <<<"$out" || fail "full host must be skipped: $out"
workers_for host-primary=2 host-remote=2 host-remote-2=2
set +e
out=$(counted_pick "$tmp/load-counted.sh" 2>/dev/null); ec=$?
set -e
[ "$ec" = 1 ] || fail "every host at cap must refuse (ec=$ec): $out"
grep -Fq 'refused (all eligible hosts at worker cap) host-primary=2/2 host-remote=2/2 host-remote-2=2/2' <<<"$out" \
  || fail "cap refusal names each host count: $out"

# 2. Rank key is (workers/cap, load_5m per core): at equal worker share a 1 minute dip does not hide a high 5 minute load.
cat >"$tmp/load-5m.sh" <<'EOF'
#!/usr/bin/env bash
printf 'host-primary cores=8 load=9.0 9.0 9.0\n'
printf 'host-remote cores=8 load=1.0 9.0 9.0\n'
printf 'host-remote-2 cores=8 load=3.0 3.0 3.0\n'
EOF
chmod +x "$tmp/load-5m.sh"
workers_for
out=$(counted_pick "$tmp/load-5m.sh" 2>/dev/null) || fail "5m pick failed: $out"
grep -Fq 'host=host-remote-2' <<<"$out" || fail "5 minute load must count in the score: $out"
# Workers raise the score too: one of two slots used outranks a 3 of 12 load.
workers_for host-remote-2=1
cat >"$tmp/load-flat.sh" <<'EOF'
#!/usr/bin/env bash
printf 'host-primary cores=8 load=1.0 1.0 1.0\n'
printf 'host-remote cores=8 load=3.0 3.0 3.0\n'
printf 'host-remote-2 cores=8 load=1.0 1.0 1.0\n'
EOF
chmod +x "$tmp/load-flat.sh"
out=$(counted_pick "$tmp/load-flat.sh" 2>/dev/null) || fail "worker score pick failed: $out"
grep -Fq 'host=host-remote load_1m=3.0 workers=0/2' <<<"$out" || fail "worker ratio must raise the score: $out"

# 2b. A burst of recorded starts spreads: each start counts as a worker before its load shows.
rm -f "$tmp/recent.json"
workers_for
seq_hosts=
for _ in 1 2 3 4 5; do
  out=$(counted_pick "$tmp/load-flat.sh" --record --json 2>/dev/null) || fail "burst pick failed: $out"
  seq_hosts="$seq_hosts $(python3 -c 'import json,sys; print(json.load(sys.stdin)["host"])' <<<"$out")"
done
first_four=$(tr ' ' '\n' <<<"${seq_hosts% *}" | sed '/^$/d' | sort | uniq -c | tr -s ' ')
[ "$first_four" = " 2 host-remote
 2 host-remote-2" ] && [ "${seq_hosts##* }" = host-primary ] \
  || fail "burst must spread and fill remotes before the coordinator host:$seq_hosts"
grep -c '"host"' "$tmp/recent.json" >/dev/null || fail "recent starts file not written"
# A pick without --record leaves the recent file alone.
before=$(cat "$tmp/recent.json")
counted_pick "$tmp/load-flat.sh" >/dev/null 2>&1 || true
[ "$(cat "$tmp/recent.json")" = "$before" ] || fail "pick without --record must not record"
# A start older than recent_start_seconds no longer counts.
old=$(( $(date +%s) - 900 ))
printf '{"starts":[{"host":"host-remote-2","at":%s,"workers":2}]}\n' "$old" >"$tmp/recent.json"
out=$(counted_pick "$tmp/load-flat.sh" --record 2>/dev/null) || fail "expired recent pick failed: $out"
grep -Fq 'host=host-remote-2 load_1m=1.0 workers=0/2' <<<"$out" || fail "expired start must not count: $out"

# 3. Every host_caps host is eligible (order only breaks ties); the coordinator host goes last.
cat >"$tmp/load-extra.sh" <<'EOF'
#!/usr/bin/env bash
printf 'host-primary cores=8 load=0.5 0.5 0.5\n'
printf 'host-remote cores=8 load=4.0 4.0 4.0\n'
printf 'host-remote-2 cores=8 load=4.0 4.0 4.0\n'
printf 'host-extra cores=8 load=1.0 1.0 1.0\n'
EOF
chmod +x "$tmp/load-extra.sh"
rm -f "$tmp/recent.json"
workers_for
out=$(counted_pick "$tmp/load-extra.sh" 2>/dev/null) || fail "extra host pick failed: $out"
grep -Fq 'host=host-extra' <<<"$out" || fail "a host_caps host missing from order must be eligible: $out"
grep -Fq 'host=host-primary' <<<"$out" && fail "coordinator host must go last while another host has room: $out"
workers_for host-remote=2 host-remote-2=2 host-extra=2
out=$(counted_pick "$tmp/load-extra.sh" 2>/dev/null) || fail "coordinator fallback pick failed: $out"
grep -Fq 'host=host-primary load_1m=0.5 workers=0/2' <<<"$out" || fail "coordinator host takes the start when the rest are full: $out"

# 4. An unreadable inventory warns and places on load alone.
out=$(WORKER_PLACEMENT_COUNT_WORKERS=1 ORCA_CLI_COMMAND=false WORKER_PLACEMENT_RECENT_FILE="$tmp/recent.json" \
  FLEET_LOAD_SCRIPT="$tmp/load-counted.sh" FLEET_WATCH_CONFIG="$tmp/counted.json" \
  python3 "$py" pick 2>"$tmp/noinv.err") || fail "no inventory pick failed: $out"
grep -Fq 'worker count unavailable' "$tmp/noinv.err" || fail "no inventory must warn: $(cat "$tmp/noinv.err")"
grep -Fq 'host=host-remote load_1m=0.5' <<<"$out" || fail "no inventory places on load: $out"

# 5. Spread under load ratio (trial #1232): a quiet host must not take every back to back start
# while other hosts with free slots sit at a high load ratio.
cat >"$tmp/spread-trial.json" <<'EOF2'
{
  "local_host": "host-primary",
  "host_caps": {"host-primary": 4, "host-small": 4, "host-a": 4, "host-b": 4},
  "host_load_ceilings": {"host-primary": 12, "host-small": 4, "host-a": 8, "host-b": 8},
  "worker_placement": {"order": ["host-primary", "host-small", "host-a", "host-b"], "recent_start_seconds": 300}
}
EOF2
cat >"$tmp/load-trial.sh" <<'EOF2'
#!/usr/bin/env bash
printf 'host-primary cores=8 load=1.0 1.0 1.0\n'
printf 'host-small cores=4 load=0.5 0.5 0.5\n'
printf 'host-a cores=8 load=6.0 6.0 6.0\n'
printf 'host-b cores=8 load=6.0 6.0 6.0\n'
EOF2
chmod +x "$tmp/load-trial.sh"
trial_picks() { # [ORCA_CLI_COMMAND override]: four recorded picks, prints the hosts
  local cli=${1:-$tmp/fake-orca.sh} hosts= out h
  rm -f "$tmp/recent.json"
  for _ in 1 2 3 4; do
    out=$(WORKER_PLACEMENT_COUNT_WORKERS=1 ORCA_CLI_COMMAND="$cli" FAKE_WORKERS="$tmp/workers.json" \
      WORKER_PLACEMENT_RECENT_FILE="$tmp/recent.json" FLEET_LOAD_SCRIPT="$tmp/load-trial.sh" \
      FLEET_WATCH_CONFIG="$tmp/spread-trial.json" python3 "$py" pick --record --json 2>>"$tmp/trial.err") \
      || fail "trial pick failed: $out"
    h=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["host"])' <<<"$out")
    hosts="$hosts $h"
  done
  echo "$hosts"
}
distinct() { tr ' ' '\n' <<<"$1" | sed '/^$/d' | sort -u | wc -l | tr -d ' '; }
workers_for
: >"$tmp/trial.err"
picked=$(trial_picks)
[ "$(distinct "$picked")" -ge 3 ] || fail "four starts must reach at least 3 hosts (inventory ok):$picked"
grep -Fq 'host-primary' <<<"$picked" && fail "coordinator host must not be picked while others have room:$picked"
picked=$(trial_picks false)
[ "$(distinct "$picked")" -ge 3 ] || fail "four starts must reach at least 3 hosts (inventory failed):$picked"
grep -Fq 'worker count unavailable' "$tmp/trial.err" || fail "failed inventory must warn: $(cat "$tmp/trial.err")"

# 6. Burst guard (#1235): back to back starts at equal load must not pile builders on a small host.
# A 4 core host takes at most cores / cores_per_worker (2) = 2 workers even though host_caps says 4,
# and free memory minus the memory the recent starts will take gates it too.
cat >"$tmp/burst.json" <<'EOF2'
{
  "local_host": "host-primary",
  "host_caps": {"host-primary": 4, "host-small": 4, "host-big": 4},
  "host_load_ceilings": {"host-primary": 12, "host-small": 12, "host-big": 12},
  "worker_placement": {"order": ["host-primary", "host-small", "host-big"], "recent_start_seconds": 300}
}
EOF2
cat >"$tmp/load-burst.sh" <<'EOF2'
#!/usr/bin/env bash
printf 'host-primary cores=8 load=1.0 1.0 1.0 memfree=24\n'
printf 'host-small cores=4 load=1.0 1.0 1.0 memfree=12\n'
printf 'host-big cores=8 load=1.0 1.0 1.0 memfree=24\n'
EOF2
chmod +x "$tmp/load-burst.sh"
burst_picks() { # <load script> <count>: recorded picks, prints each host on its own line
  local load=$1 n=$2 out
  rm -f "$tmp/recent.json"
  workers_for
  for _ in $(seq "$n"); do
    out=$(WORKER_PLACEMENT_COUNT_WORKERS=1 ORCA_CLI_COMMAND="$tmp/fake-orca.sh" FAKE_WORKERS="$tmp/workers.json" \
      WORKER_PLACEMENT_RECENT_FILE="$tmp/recent.json" FLEET_LOAD_SCRIPT="$load" \
      FLEET_WATCH_CONFIG="$tmp/burst.json" python3 "$py" pick --record --json 2>/dev/null) || break
    python3 -c 'import json,sys; print(json.load(sys.stdin)["host"])' <<<"$out"
  done
}
small=$(burst_picks "$tmp/load-burst.sh" 8 | grep -c '^host-small$' || true)
[ "$small" -le 2 ] || fail "8 burst picks put $small workers on the 4 core host (scaled cap 2)"
# Memory gate: 5 GB free with 4 GB per worker leaves room for one start, not two.
cat >"$tmp/load-lowmem.sh" <<'EOF2'
#!/usr/bin/env bash
printf 'host-primary cores=8 load=1.0 1.0 1.0 memfree=24\n'
printf 'host-small cores=16 load=1.0 1.0 1.0 memfree=5\n'
printf 'host-big cores=8 load=1.0 1.0 1.0 memfree=24\n'
EOF2
chmod +x "$tmp/load-lowmem.sh"
small=$(burst_picks "$tmp/load-lowmem.sh" 8 | grep -c '^host-small$' || true)
[ "$small" -le 1 ] || fail "8 burst picks put $small workers on a host with 5 GB free (budget 4 GB each)"

# 1273: a stub config with no runs reads only the active Run, seats name retained workers, a failed start unrecords.
mkdir -p "$tmp/home/.config/fleet-watch"
cp "$tmp/counted.json" "$tmp/home/.config/fleet-watch/config.json"
printf '{"runs":[{"id":"run_active","terminal":"term_a"}]}\n' >"$tmp/coordinator.json"
cat >"$tmp/fake-orca-runs.sh" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  *run-list*) printf '%s\n' '{"ok":true,"result":{"runs":[{"id":"run_old"},{"id":"run_active"}]}}' ;;
  *task-list*) printf '%s\n' '{"ok":true,"result":{"tasks":[]}}' ;;
  *"worker-list --run run_old"*) printf '{"ok":true,"result":{"workers":%s}}\n' "$(cat "$FAKE_WORKERS")" ;;
  *"worker-list --run run_active"*) cat "$FAKE_ACTIVE" ;;
  *) exit 1 ;;
esac
EOS
chmod +x "$tmp/fake-orca-runs.sh"
workers_for host-primary=2
printf '%s\n' '{"ok":true,"result":{"workers":[{"dispatchId":"d_kept","dispatchStatus":"completed","workerState":"succeeded","terminalState":"retained","projection":{"host":{"id":"host-remote"}},"resource":{"ownershipState":"owned","releaseState":"retained"}}]}}' >"$tmp/active.json"
py3=$(asdf which python3 2>/dev/null || command -v python3)
seat_env() {
  HOME="$tmp/home" FLEET_WATCH_COORDINATOR_CONFIG="$tmp/coordinator.json" WORKER_PLACEMENT_COUNT_WORKERS=1 \
    ORCA_CLI_COMMAND="$tmp/fake-orca-runs.sh" FAKE_WORKERS="$tmp/workers.json" FAKE_ACTIVE="$tmp/active.json" \
    WORKER_PLACEMENT_RECENT_FILE="$tmp/recent-1273.json" FLEET_LOAD_SCRIPT="$tmp/load-counted.sh" \
    FLEET_WATCH_CONFIG="$tmp/home/.config/fleet-watch/config.json" "$@"
}
out=$(seat_env "$py3" "$py" pick 2>"$tmp/sp.err") || fail "scoped pick failed: $out $(cat "$tmp/sp.err")"
grep -Fq "host-remote-2" <<<"$out" || fail "scoped pick should still place: $out"
out=$(seat_env "$py3" "$py" seats 2>"$tmp/seats.err") || fail "seats failed: $(cat "$tmp/seats.err")"
grep -Fq 'host-primary: 0/2 live=0 retained=0 retained_workers=none' <<<"$out" || fail "seats must count the active Run only: $out"
grep -Fq 'host-remote: 1/2 live=0 retained=1 retained_workers=d_kept(' <<<"$out" || fail "seats must name the retained worker: $out"
out=$(seat_env "$py3" "$py" seats --json 2>/dev/null) || fail "seats --json failed"
[ "$(jq -r '.["host-remote"].retained_workers[0].dispatchId' <<<"$out")" = d_kept ] || fail "seats --json names the retained worker: $out"
rm -f "$tmp/recent-1273.json"
seat_env "$py3" "$py" pick --record >/dev/null 2>&1 || fail "recorded pick failed"
[ "$(jq -r '.starts | length' "$tmp/recent-1273.json")" = 1 ] || fail "pick --record should record a start"
seat_env "$py3" "$py" unrecord --host "$(jq -r ".starts[0].host" "$tmp/recent-1273.json")"
[ "$(jq -r '.starts | length' "$tmp/recent-1273.json")" = 0 ] || fail "unrecord should drop the failed start's claim"

echo "worker-placement.test.sh passed"
