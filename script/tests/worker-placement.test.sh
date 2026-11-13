#!/usr/bin/env bash
# Repo-mapping refusals from worker-placement.py. A remote host with no mapping must not
# be reported as a missing load sample.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
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

echo "worker-placement.test.sh passed"
