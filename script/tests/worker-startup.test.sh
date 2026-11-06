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

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export WORKER_STARTUP_STATE="$tmp/state"
mkdir -p "$WORKER_STARTUP_STATE"

# --- red: missing jq / missing config ---
set +e
out=$(FLEET_PULL_CONFIG=/no/such.json bash "$script" --host-check 2>&1)
ec=$?
set -e
grep -q "missing config" <<<"$out" && ok || bad "missing config message"
[ "$ec" -ne 0 ] && ok || bad "missing config exits non-zero"

# --- stubs: fake jq forwards to the real binary ---
bin="$tmp/bin"
mkdir -p "$bin"
jq_bin=$(command -v jq)
cat >"$bin/jq" <<EOS
#!/usr/bin/env bash
exec "$jq_bin" "\$@"
EOS
chmod +x "$bin/jq"

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
if [ "$1" = install ] || [ "$1" = local ]; then
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

# Fix node stub so pin matches
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
if [ "$1" = install ] || [ "$1" = local ]; then
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
echo install "$@" >>"${BUN_LOG:?}"
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

# --- orca stub + --run: records worker-start; delegates start-cursor-worker path ---
cat >"$tmp/gate.py" <<'EOS'
import sys
sys.exit(0)
EOS
export USAGE_GATE_CLI="$tmp/gate.py"
orca_stub="$tmp/orca"
wt_proof="$root/wt-proof"
cat >"$orca_stub" <<EOS
#!/usr/bin/env bash
# Minimal orca: worktree create + worker-start JSON (recorded from a live worker-start --json receipt).
WT_PROOF="$wt_proof"
set -e
log="\${ORCA_STUB_LOG:-/dev/null}"
printf '%s\n' "\$0 \$*" >>"\$log"
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
PATH="$bin:$PATH" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" \
  bash "$script" --run run_x --spec "$spec_file" --title myjob --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --name n1 --repo "path:$clean" 2>"$tmp/run.err"
ec=$?
set -e
[ "$ec" = 0 ] && ok || bad "run claude exits 0 ($ec) $(cat "$tmp/run.err")"
grep -q 'orchestration worker-start' "$tmp/orca.log" && ok || bad "orca log has worker-start"

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
PATH="$helper_dir:$bin:$PATH" ORCA_CLI_COMMAND="$orca_stub" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" \
  bash "$helper_dir/worker-startup.sh" --run run_y --spec "$spec_file" --title cjob --agent cursor --model composer-2.5 \
  --from term_coord --worktree-path /abs/wt 2>"$tmp/cursor.err"
ec=$?
set -e
[ "$ec" = 0 ] && ok || bad "cursor run exits 0 ($ec)"
grep -q -- '--run run_y' "$tmp/cursor.args" && grep -q composer-2.5 "$tmp/cursor.args" && ok || bad "cursor helper args"

echo "worker-startup: $pass passed, $fail failed"
[ "$fail" = 0 ]
