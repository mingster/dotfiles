#!/usr/bin/env bash
# Tests for worker-startup.sh: host-check (pull, pins, conditional bun install) and --run delegation.
# Red-green: failure modes and orca stubs before the happy path.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd -P)
script="$here/../worker-startup.sh"
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "worker-startup.test.sh: skip — jq not on PATH (jq-dependent cases not run)" >&2
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
unset -f python3 2>/dev/null || true
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export WORKER_STARTUP_STATE="$tmp/state"
mkdir -p "$WORKER_STARTUP_STATE"

# --- stubs: fake jq forwards to the real binary; python3 runs USAGE_GATE_CLI or real python ---
bin="$tmp/bin"
mkdir -p "$bin"
jq_bin=$(command -v jq)
cat >"$bin/jq" <<EOS
#!/usr/bin/env bash
exec "$jq_bin" "\$@"
EOS
chmod +x "$bin/jq"
python3_real=$(command -v python3)
if [ -x /usr/bin/python3 ]; then
  python3_real=/usr/bin/python3
fi
cat >"$bin/python3" <<EOS
#!/usr/bin/env bash
set -e
case "\$1" in
  *.py)
    if [ "\${2:-}" = check ]; then
      printf 'stub-gate-ran\n' >>"$tmp/run-order.log"
      printf 'usage-gate check %s\n' "\${*:3}" >>"$tmp/gate.invoked"
      printf 'gate-before-worker-start\n' >>"$tmp/run-order.log"
      exit 0
    fi
    ;;
esac
exec "$python3_real" "\$@"
EOS
chmod +x "$bin/python3"
touch "$tmp/gate-stub.py"
export USAGE_GATE_CLI="$tmp/gate-stub.py"
export PYTHON="$bin/python3"
# Log paths for the gate (ordering tests); must exist before the stub runs.
export PYTHON3_GATE_LOG="$tmp/gate.invoked" PYTHON3_RUN_ORDER_LOG="$tmp/run-order.log"
: >"$PYTHON3_GATE_LOG"
: >"$PYTHON3_RUN_ORDER_LOG"

# --- red: missing config (needs stub jq on PATH so we do not hit missing jq first) ---
set +e
out=$(PATH="$bin:$PATH" FLEET_PULL_CONFIG=/no/such.json bash "$script" --host-check 2>&1)
ec=$?
set -e
grep -q "missing config" <<<"$out" && ok || bad "missing config message"
[ "$ec" -ne 0 ] && ok || bad "missing config exits non-zero"
grep -q 'stub-gate-ran' "$tmp/run-order.log" && bad "stub gate must not run for --host-check" || ok

make_repo() { # <workdir> <bare.git> — local main with origin bare, push
  git init -q --bare "$2"
  git init -q "$1"
  git -C "$1" checkout -q -b main
  git -C "$1" remote add origin "$2"
  touch "$1/README"
  git -C "$1" add README
  git -C "$1" commit -qm init
  git -C "$1" push -q -u origin main
  git --git-dir="$2" symbolic-ref HEAD refs/heads/main
}

origin_commit() { # <bare.git> — second commit on main (clone may not check out until fetch)
  local w
  w=$(mktemp -d)
  git clone -q "$1" "$w"
  git -C "$w" fetch -q origin
  git -C "$w" checkout -q -B main origin/main
  echo more >>"$w/README"
  git -C "$w" add README
  git -C "$w" commit -qm advance
  git -C "$w" push -q origin main
  rm -rf "$w"
}

# Clean repo on main: host-check fast-forwards
clean="$tmp/clean"
clean_bare="$tmp/clean.git"
make_repo "$clean" "$clean_bare"
origin_commit "$clean_bare"
cat >"$tmp/fleet.json" <<EOF
{"hosts":[],"repos":["$clean"]}
EOF
set +e
PATH="$bin:$PATH" FLEET_PULL_CONFIG="$tmp/fleet.json" bash "$script" --host-check 2>"$tmp/h1.err"
ec=$?
set -e
[ "$ec" = 0 ] && ok || bad "clean repo host-check exits 0 ($ec) $(cat "$tmp/h1.err")"
clean_head=$(git -C "$clean" rev-parse HEAD)
origin_head=$(git -C "$clean" rev-parse origin/main)
[ "$clean_head" = "$origin_head" ] && ok || bad "fast-forward: HEAD $clean_head != origin/main $origin_head"

# Dirty repo: must not fail the whole host-check (skip line); treat as ok for exit
dirty="$tmp/dirty"
dirty_bare="$tmp/dirty.git"
make_repo "$dirty" "$dirty_bare"
echo x >>"$dirty/README"
cat >"$tmp/fleet-dirty.json" <<EOF
{"hosts":[],"repos":["$clean","$dirty"]}
EOF
set +e
PATH="$bin:$PATH" FLEET_PULL_CONFIG="$tmp/fleet-dirty.json" bash "$script" --host-check >"$tmp/h2.out" 2>&1
ec=$?
set -e
grep -q "skip $dirty (dirty)" "$tmp/h2.out" && ok || bad "dirty skip logged"
[ "$ec" = 0 ] && ok || bad "dirty skip still exits 0"

# Not on main: skip
side="$tmp/side"
side_bare="$tmp/side.git"
make_repo "$side" "$side_bare"
git -C "$side" checkout -q -b other
cat >"$tmp/fleet2.json" <<EOF
{"hosts":[],"repos":["$side"]}
EOF
set +e
PATH="$bin:$PATH" FLEET_PULL_CONFIG="$tmp/fleet2.json" bash "$script" --host-check >"$tmp/h3.out" 2>&1
ec=$?
set -e
grep -q "skip $side" "$tmp/h3.out" && ok || bad "non-main skip"
[ "$ec" = 0 ] && ok || bad "non-main exits 0"

# Node pin: mismatch after asdf "install" still fails (stub node keeps wrong version)
pinned="$tmp/pinned"
pinned_bare="$tmp/pinned.git"
make_repo "$pinned" "$pinned_bare"
printf 'python 3.0.0\nnodejs 9.9.9\n' >"$pinned/.tool-versions"
git -C "$pinned" add .tool-versions
git -C "$pinned" commit -qm tv
git -C "$pinned" push -q
cat >"$tmp/fleet3.json" <<EOF
{"hosts":[],"repos":["$pinned"]}
EOF
cat >"$bin/node" <<'EOS'
#!/bin/sh
echo v1.0.0
EOS
chmod +x "$bin/node"
cat >"$bin/asdf" <<'EOS'
#!/usr/bin/env bash
set -e
if [ "$1" = list ] && [ "$2" = nodejs ]; then
  echo ' * 1.0.0'
  exit 0
fi
if [ "$1" = install ] || [ "$1" = local ] || [ "$1" = set ]; then
  exit 0
fi
exit 99
EOS
chmod +x "$bin/asdf"
set +e
PATH="$bin:$PATH" FLEET_PULL_CONFIG="$tmp/fleet3.json" bash "$script" --host-check 2>"$tmp/h4.err"
ec=$?
set -e
[ "$ec" -ne 0 ] && ok || bad "node pin mismatch should exit non-zero"
grep -q 'after pin fix' "$tmp/h4.err" && ok || bad "node pin mismatch should reach version recheck (after pin fix)"

# Second mismatch: asdf ok but node still wrong after fix attempt
cat >"$bin/node" <<'EOS'
#!/bin/sh
echo v1.0.0
EOS
cat >"$bin/asdf" <<'EOS'
#!/usr/bin/env bash
set -e
if [ "$1" = list ] && [ "$2" = nodejs ]; then
  echo ' * 9.9.9'
  exit 0
fi
if [ "$1" = install ] || [ "$1" = local ] || [ "$1" = set ]; then
  exit 0
fi
exit 99
EOS
chmod +x "$bin/asdf" "$bin/node"
set +e
PATH="$bin:$PATH" FLEET_PULL_CONFIG="$tmp/fleet3.json" bash "$script" --host-check 2>"$tmp/h4b.err"
ec=$?
set -e
[ "$ec" -ne 0 ] && ok || bad "node recheck failure should exit non-zero"
grep -q 'after pin fix' "$tmp/h4b.err" && ok || bad "recheck failure should mention after pin fix"

# Node matches pin: no asdf on PATH should still succeed
nodeok="$tmp/nodeok"
nodeok_bare="$tmp/nodeok.git"
make_repo "$nodeok" "$nodeok_bare"
printf 'nodejs 9.9.9\n' >"$nodeok/.tool-versions"
git -C "$nodeok" add .tool-versions
git -C "$nodeok" commit -qm tv
git -C "$nodeok" push -q
cat >"$tmp/fleet-nodeok.json" <<EOF
{"hosts":[],"repos":["$nodeok"]}
EOF
mini_bin="$tmp/mini-bin"
mkdir -p "$mini_bin"
ln -sf "$jq_bin" "$mini_bin/jq"
cat >"$mini_bin/node" <<'EOS'
#!/bin/sh
echo v9.9.9
EOS
chmod +x "$mini_bin/node"
set +e
PATH="$mini_bin:$PATH" FLEET_PULL_CONFIG="$tmp/fleet-nodeok.json" bash "$script" --host-check 2>"$tmp/h4c.err"
ec=$?
set -e
[ "$ec" = 0 ] && ok || bad "node matches pin without asdf should exit 0 ($ec)"

# Fix node stub so pin matches (with asdf on PATH for later bun tests)
cat >"$bin/node" <<'EOS'
#!/bin/sh
echo v9.9.9
EOS
cat >"$bin/asdf" <<'EOS'
#!/usr/bin/env bash
set -e
if [ "$1" = list ] && [ "$2" = nodejs ]; then
  echo ' * 9.9.9'
  exit 0
fi
if [ "$1" = install ] || [ "$1" = local ] || [ "$1" = set ]; then
  exit 0
fi
exit 99
EOS
chmod +x "$bin/asdf" "$bin/node"
set +e
PATH="$bin:$PATH" FLEET_PULL_CONFIG="$tmp/fleet3.json" bash "$script" --host-check 2>"$tmp/h5.err"
ec=$?
set -e
[ "$ec" = 0 ] && ok || bad "node pin satisfied exits 0 ($ec)"

# Bun pin + lockfile: install runs once, skipped second time with same hash
bunrepo="$tmp/bunrepo"
bun_bare="$tmp/bunrepo.git"
make_repo "$bunrepo" "$bun_bare"
printf '{"packageManager":"bun@1.0.0"}\n' >"$bunrepo/package.json"
printf 'lock-bytes\n' >"$bunrepo/bun.lock"
git -C "$bunrepo" add package.json bun.lock
git -C "$bunrepo" commit -qm pkg
git -C "$bunrepo" push -q
cat >"$tmp/fleet4.json" <<EOF
{"hosts":[],"repos":["$bunrepo"]}
EOF
cat >"$bin/bun" <<'EOS'
#!/usr/bin/env bash
if [ "$1" = --version ] || [ "$1" = -v ]; then echo 1.0.0; exit 0; fi
echo "install $(pwd) $*" >>"${BUN_LOG:?}"
exit 0
EOS
chmod +x "$bin/bun"
export BUN_LOG="$tmp/bun.log"
: >"$BUN_LOG"
cat >"$bin/node" <<'EOS'
#!/bin/sh
echo v9.9.9
EOS
cat >"$bin/asdf" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$bin/asdf" "$bin/node"
mkdir -p "$tmp/home-bun"
set +e
PATH="$bin:$PATH" FLEET_PULL_CONFIG="$tmp/fleet4.json" HOME="$tmp/home-bun" bash "$script" --host-check 2>"$tmp/h6.err"
ec=$?
set -e
[ "$ec" = 0 ] && ok || bad "bun host-check exits 0"
grep -q "install" "$BUN_LOG" && ok || bad "bun install ran"
lines1=$(wc -l <"$BUN_LOG" | tr -d ' ')
set +e
PATH="$bin:$PATH" FLEET_PULL_CONFIG="$tmp/fleet4.json" HOME="$tmp/home-bun" bash "$script" --host-check 2>>"$tmp/h6.err"
ec=$?
set -e
[ "$ec" = 0 ] && ok || bad "second host-check exits 0"
lines2=$(wc -l <"$BUN_LOG" | tr -d ' ')
[ "$lines1" = "$lines2" ] && ok || bad "bun install skipped when lock unchanged ($lines1 vs $lines2)"
unset BUN_LOG

# Root + web lockfiles: separate state per lock; install only in dirs whose lock changed
dual="$tmp/dual"
dual_bare="$tmp/dual.git"
make_repo "$dual" "$dual_bare"
mkdir -p "$dual/web"
printf '{"packageManager":"bun@1.0.0"}\n' >"$dual/package.json"
printf '{"packageManager":"bun@1.0.0"}\n' >"$dual/web/package.json"
printf 'lock-root\n' >"$dual/bun.lock"
printf 'lock-web\n' >"$dual/web/bun.lock"
git -C "$dual" add package.json web/package.json bun.lock web/bun.lock
git -C "$dual" commit -qm dual
git -C "$dual" push -q
cat >"$tmp/fleet-dual.json" <<EOF
{"hosts":[],"repos":["$dual"]}
EOF
export BUN_LOG="$tmp/bun-dual.log"
: >"$BUN_LOG"
set +e
PATH="$bin:$PATH" FLEET_PULL_CONFIG="$tmp/fleet-dual.json" HOME="$tmp/home-bun" bash "$script" --host-check 2>"$tmp/h7.err"
ec=$?
set -e
[ "$ec" = 0 ] && ok || bad "dual-lock host-check exits 0"
dual_lines1=$(wc -l <"$BUN_LOG" | tr -d ' ')
[ "$dual_lines1" = 2 ] && ok || bad "dual lock first run: want 2 bun install lines ($dual_lines1)"
set +e
PATH="$bin:$PATH" FLEET_PULL_CONFIG="$tmp/fleet-dual.json" HOME="$tmp/home-bun" bash "$script" --host-check 2>>"$tmp/h7.err"
ec=$?
set -e
[ "$ec" = 0 ] && ok || bad "dual lock second run exits 0"
dual_lines2=$(wc -l <"$BUN_LOG" | tr -d ' ')
[ "$dual_lines1" = "$dual_lines2" ] && ok || bad "dual lock unchanged skips install"
printf '\n' >>"$dual/web/bun.lock"
git -C "$dual" add web/bun.lock
git -C "$dual" commit -qm web-lock
git -C "$dual" push -q
set +e
PATH="$bin:$PATH" FLEET_PULL_CONFIG="$tmp/fleet-dual.json" HOME="$tmp/home-bun" bash "$script" --host-check 2>>"$tmp/h7.err"
ec=$?
set -e
[ "$ec" = 0 ] && ok || bad "dual lock web-only change exits 0"
dual_lines3=$(wc -l <"$BUN_LOG" | tr -d ' ')
[ "$dual_lines3" -eq $((dual_lines2 + 1)) ] && ok || bad "web lock change should add one install ($dual_lines2 -> $dual_lines3)"
last_install=$(tail -1 "$BUN_LOG")
grep -q "$dual/web" <<<"$last_install" && ok || bad "last bun install should run in web ($last_install)"
unset BUN_LOG

# --- orca stub + --run: records worker-start; delegates start-cursor-worker path ---
gate_invoked="$PYTHON3_GATE_LOG"
run_order_log="$PYTHON3_RUN_ORDER_LOG"
: >"$gate_invoked"
: >"$run_order_log"
orca_stub="$tmp/orca"
# Minimal PATH for --run (PYTHON + USAGE_GATE_CLI exercise the gate stub).
run_path="$bin:/usr/bin:/bin"
# Isolate bun from the real home: otherwise ~/.bun/bin can satisfy an extreme pin and skip the failing curl.
badbun_home="$tmp/home-badbun-run"
mkdir -p "$badbun_home"
wt_proof="$root/wt-proof"
cat >"$orca_stub" <<EOS
#!/usr/bin/env bash
# Minimal orca: worktree create + worker-start JSON (recorded from a live worker-start --json receipt).
WT_PROOF="$wt_proof"
set -e
log="\${ORCA_STUB_LOG:-/dev/null}"
printf '%s\n' "\$0 \$*" >>"\$log"
printf 'orca-after-gate\n' >>"$run_order_log"
case " \$* " in
  *" worktree create "*)
    printf '%s\n' "{\"ok\":true,\"result\":{\"worktree\":{\"path\":\"\$WT_PROOF\"}}}"
    exit 0
    ;;
  *" orchestration worker-start "*)
    printf '%s\n' '{"ok":true,"result":{"dispatchId":"ctx_9495d9c62de4","taskId":"task_bb8ffda3ea2e","runId":"run_4ab48cf93d6c","state":"ready","agent":"claude","model":"claude-sonnet-5-5-medium","mode":"terminal","terminal":"term_fixture4242","workspace":"repo::'"$wt_proof"'","next":"next"}}'
    exit 0
    ;;
esac
exit 99
EOS
chmod +x "$orca_stub"

spec_file="$tmp/spec.txt"
printf 'Do the task.\n' >"$spec_file"

# Non-cursor: after host-check, worktree create + worker-start
set +e
unset -f python3 2>/dev/null || true
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  bash --noprofile --norc "$script" --run run_x --spec "$spec_file" --title myjob --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --name n1 --repo "path:$clean" 2>"$tmp/run.err"
ec=$?
set -e
[ "$ec" = 0 ] && ok || bad "run claude exits 0 ($ec) $(cat "$tmp/run.err")"
grep -q 'orchestration worker-start' "$tmp/orca.log" && ok || bad "orca log has worker-start"
grep -Fq 'usage-gate check' "$gate_invoked" && ok || bad "usage gate check recorded"
grep -q 'stub-gate-ran' "$run_order_log" && ok || bad "stub gate ran (logged)"
grep 'stub-gate-ran' "$run_order_log" | head -1 >"$tmp/order.stub"
grep 'orca-after-gate' "$run_order_log" | head -1 >"$tmp/order.orca"
[ -s "$tmp/order.stub" ] && [ -s "$tmp/order.orca" ] && ok || bad "stub gate and orca order markers present"
if ! awk '/stub-gate-ran/{s=NR} /orca-after-gate/{o=NR} END{exit !(s>0 && o>0 && s<o)}' "$run_order_log"; then
  bad "stub usage gate must run before orca worker-start path"
else
  ok
fi

# --run with unfixable bun pin: host-check fails, no worker-start
badbun="$tmp/badbun"
badbun_bare="$tmp/badbun.git"
make_repo "$badbun" "$badbun_bare"
printf '{"packageManager":"bun@9.9.9"}\n' >"$badbun/package.json"
git -C "$badbun" add package.json
git -C "$badbun" commit -qm pin
git -C "$badbun" push -q
cat >"$tmp/fleet-badbun.json" <<EOF
{"hosts":[],"repos":["$badbun"]}
EOF
cat >"$bin/curl" <<'EOS'
#!/bin/sh
exit 1
EOS
chmod +x "$bin/curl"
: >"$tmp/orca-bad.log"
set +e
unset -f python3 2>/dev/null || true
env -u BASH_ENV \
  HOME="$badbun_home" PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-bad.log" \
  FLEET_PULL_CONFIG="$tmp/fleet-badbun.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" CURL="$bin/curl" \
  bash --noprofile --norc "$script" --run run_bad --spec "$spec_file" --title bad --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --name n1 --repo "path:$badbun" 2>"$tmp/run-bad.err"
ec_bad=$?
set -e
[ "$ec_bad" -ne 0 ] && ok || bad "unfixable bun pin --run should exit non-zero"
grep -q 'orchestration worker-start' "$tmp/orca-bad.log" && bad "orca should not worker-start when bun pin fails" || ok

# Cursor: copy script next to stub start-cursor-worker so exec hits the stub
helper_dir="$tmp/helpers"
mkdir -p "$helper_dir"
cp "$script" "$helper_dir/worker-startup.sh"
chmod +x "$helper_dir/worker-startup.sh"
cat >"$helper_dir/start-cursor-worker.sh" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp/cursor.args"
exit 0
EOS
chmod +x "$helper_dir/start-cursor-worker.sh"
set +e
unset -f python3 2>/dev/null || true
env -u BASH_ENV \
  PATH="$helper_dir:$run_path" ORCA_CLI_COMMAND="$orca_stub" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  bash --noprofile --norc "$helper_dir/worker-startup.sh" --run run_y --spec "$spec_file" --title cjob --agent cursor --model composer-2.5 \
  --from term_coord --worktree-path /abs/wt 2>"$tmp/cursor.err"
ec=$?
set -e
[ "$ec" = 0 ] && ok || bad "cursor run exits 0 ($ec)"
grep -q -- '--run run_y' "$tmp/cursor.args" && grep -q composer-2.5 "$tmp/cursor.args" && ok || bad "cursor helper args"

echo "worker-startup: $pass passed, $fail failed"
[ "$fail" = 0 ]
