#!/usr/bin/env bash
# Tests for worker-startup.sh: host-check (pull, pins, conditional bun install) and --run delegation.
# Red-green: failure modes and orca stubs before the happy path.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$here/lib/asdf-pin.sh"
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
# shellcheck source=lib/git-identity.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/git-identity.sh"
use_test_git_identity "$tmp"
export WORKER_STARTUP_STATE="$tmp/state" TEAM_AUDIT_DISPATCHES="$tmp/team-dispatches.tsv"
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
path_no_asdf=$(printf '%s\n' "${PATH//:/$'\n'}" | grep -v '/\.asdf/shims$' | paste -sd: -)
python3_real=$(PATH="$path_no_asdf" type -P python3 2>/dev/null || true)
[ -x "$python3_real" ] || python3_real="$(ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}" asdf which python3 2>/dev/null || true)"
[ -x "$python3_real" ] || { echo "missing python3" >&2; exit 1; }
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

# PATH with only stub bin + usual system dirs (no brew/local) so a real asdf is not picked up
node_match_path() { # <stub_bin_dir> : echoes PATH; links jq/git into stub if missing from system dirs
  local stub sys need origin
  stub=$1
  sys="/usr/bin:/bin"
  mkdir -p "$stub"
  for need in jq git; do
    if PATH="$sys" command -v "$need" >/dev/null 2>&1; then
      continue
    fi
    origin=$(PATH="$bin:/usr/local/bin:/opt/homebrew/bin:$PATH" command -v "$need") || {
      echo "node_match_path: missing $need" >&2
      exit 99
    }
    ln -sf "$origin" "$stub/$need"
  done
  printf '%s:%s' "$stub" "$sys"
}

# Clean repo on main: host-check fast-forwards
clean="$tmp/clean"
clean_bare="$tmp/clean.git"
make_repo "$clean" "$clean_bare"
origin_commit "$clean_bare"
bare_tip=$(git --git-dir="$clean_bare" rev-parse refs/heads/main)
clean_before=$(git -C "$clean" rev-parse HEAD)
[ "$clean_before" != "$bare_tip" ] && ok || bad "fast-forward setup: clone HEAD should differ from bare tip ($clean_before vs $bare_tip)"
cat >"$tmp/fleet.json" <<EOF
{"hosts":[],"repos":["$clean"]}
EOF
set +e
PATH="$bin:$PATH" FLEET_PULL_CONFIG="$tmp/fleet.json" bash "$script" --host-check 2>"$tmp/h1.err"
ec=$?
set -e
[ "$ec" = 0 ] && ok || bad "clean repo host-check exits 0 ($ec) $(cat "$tmp/h1.err")"
clean_head=$(git -C "$clean" rev-parse HEAD)
[ "$clean_head" = "$bare_tip" ] && ok || bad "fast-forward: HEAD $clean_head != bare origin $bare_tip"

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
mini_stub="$tmp/mini-stub-bin"
mkdir -p "$mini_stub"
cat >"$mini_stub/node" <<'EOS'
#!/bin/sh
echo v9.9.9
EOS
chmod +x "$mini_stub/node"
nm_path=$(node_match_path "$mini_stub")
PATH="$nm_path" command -v asdf >/dev/null 2>&1 && bad "nodeok PATH should not expose asdf" || ok
set +e
PATH="$nm_path" FLEET_PULL_CONFIG="$tmp/fleet-nodeok.json" bash "$script" --host-check 2>"$tmp/h4c.err"
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
wt_proof="$tmp/wt proof dir"
mkdir -p "$wt_proof"
cat >"$orca_stub" <<EOS
#!/usr/bin/env bash
# Minimal orca: worktree create + worker-start JSON (recorded from a live worker-start --json receipt).
WT_PROOF="$wt_proof"
GH_REPO_DIR="$tmp/gh-repo"
set -e
log="\${ORCA_STUB_LOG:-/dev/null}"
printf '%s\n' "\$0 \$*" >>"\$log"
printf 'orca-after-gate\n' >>"$run_order_log"
case " \$* " in
  *" repo list "*)
    printf '%s\n' "{\"ok\":true,\"result\":{\"repos\":[{\"id\":\"repo_gh\",\"path\":\"\$GH_REPO_DIR\"}]}}"
    exit 0
    ;;
  *" worktree create "*)
    printf '%s\n' "{\"ok\":true,\"result\":{\"worktree\":{\"path\":\"\$WT_PROOF\"}}}"
    exit 0
    ;;
  *" orchestration worker-start "*)
    printf '%s\n' '{"ok":true,"result":{"dispatchId":"ctx_9495d9c62de4","taskId":"task_bb8ffda3ea2e","runId":"run_4ab48cf93d6c","state":"ready","agent":"claude","model":"claude-sonnet-5-5-medium","mode":"terminal","terminal":"term_fixture4242","workspace":"repo::'"$wt_proof"'","next":"next"}}'
    exit 0
    ;;
  *" worktree set "*)
    exit 0
    ;;
esac
exit 99
EOS
chmod +x "$orca_stub"

cat >"$tmp/fleet-placement.json" <<'EOF'
{
  "local_host": "host-primary",
  "host_caps": {"host-primary": 4, "host-overflow": 4, "host-skip": 4, "host-browser": 2, "host-remote": 4},
  "host_load_ceilings": {"host-primary": 12, "host-overflow": 8, "host-skip": 12, "host-browser": 12, "host-remote": 12},
  "worker_placement": {
    "order": ["host-primary", "host-skip", "host-overflow", "host-browser", "host-remote"],
    "roles": {"host-browser": "browser"},
    "repos": {
      "host-remote": {"local-app-id": "id:remote-app-id"}
    }
  }
}
EOF
cat >"$tmp/fleet-load.sh" <<'EOS'
#!/usr/bin/env bash
printf 'host-primary cores=8 load=1.0 1.0 1.0\n'
printf 'host-overflow cores=8 load=1.0 1.0 1.0\n'
printf 'host-skip cores=8 load=1.0 1.0 unreachable\n'
EOS
chmod +x "$tmp/fleet-load.sh"
export FLEET_WATCH_CONFIG="$tmp/fleet-placement.json"
export FLEET_LOAD_SCRIPT="$tmp/fleet-load.sh"
placement_py="$here/../worker-placement.py"

spec_file="$tmp/spec.txt"
cat >"$spec_file" <<'EOS'
Refs #1

## Acceptance
- [ ] Do the task.

## Out of scope
Unrelated files.

## Verify
Run bash script/checks-local.sh.

## Finish
Run orca worktree set --worktree active --workspace-status in-review before worker_done.
1. Self-review: read code-review skill and fix findings.
2. Send worker_done.
EOS

# Bad brief: refused by brief-lint before any start
bad_spec="$tmp/bad-spec.txt"
printf 'Do the task.\n' >"$bad_spec"
: >"$tmp/orca-lint.log"
set +e
unset -f python3 2>/dev/null || true
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-lint.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  bash --noprofile --norc "$script" --run run_bad_spec --spec "$bad_spec" --title myjob --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --name n1 --repo "path:$clean" 2>"$tmp/run-lint.err"
ec_lint=$?
set -e
[ "$ec_lint" -ne 0 ] && ok || bad "bad brief --run should exit non-zero"
grep -q 'brief-lint: missing Refs' "$tmp/run-lint.err" && ok || bad "bad brief stderr should include brief-lint output ($(cat "$tmp/run-lint.err"))"
grep -q 'orchestration worker-start' "$tmp/orca-lint.log" && bad "orca should not worker-start when brief-lint fails" || ok

# 849: a "release-manager: merge" worker never starts on an overflow host
: >"$tmp/orca-merge.log"
set +e
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-merge.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  bash --noprofile --norc "$script" --run run_merge --spec "$spec_file" --title "release-manager: merge #849" --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --on host-overflow --name n_merge --repo "path:$clean" 2>"$tmp/run-merge.err"
ec_merge=$?
set -e
[ "$ec_merge" -ne 0 ] && ok || bad "merge worker --on an overflow host should exit non-zero"
grep -q 'coordinator host only' "$tmp/run-merge.err" && ok || bad "merge worker refusal should name the coordinator host ($(cat "$tmp/run-merge.err"))"
grep -q 'worker-start' "$tmp/orca-merge.log" && bad "orca should not start a merge worker on an overflow host" || ok

# Non-cursor: after host-check, worktree create + worker-start
set +e
unset -f python3 2>/dev/null || true
launch_state="$tmp/ws-launch-state"
mkdir -p "$launch_state/launches"
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  WORKER_STARTUP_STATE="$launch_state" \
  bash --noprofile --norc "$script" --run run_x --spec "$spec_file" --title myjob --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --name n1 --repo "path:$clean" 2>"$tmp/run.err"
ec=$?
set -e
[ "$ec" = 0 ] && ok || bad "run claude exits 0 ($ec) $(cat "$tmp/run.err")"
# shellcheck disable=SC1091
. "$here/../lib/pr-review-gates.sh"
export WORKER_STARTUP_STATE="$launch_state"
pair=$(pr_review_gates_worker_agent_model ctx_9495d9c62de4) || true
[ "$pair" = $'claude\tclaude-sonnet-5-5-medium' ] && ok || bad "claude --run writes dispatch launch record ($pair)"
grep -qE '^1'$'\t''[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z'$'\t''$' "$TEAM_AUDIT_DISPATCHES" && [ "$(head -1 "$TEAM_AUDIT_DISPATCHES")" = $'issue\tdispatched_at\trepo' ] \
  && ok || bad "claude --run appends issue<TAB>dispatched_at<TAB>repo to the dispatch log ($(cat "$TEAM_AUDIT_DISPATCHES" 2>&1))"

# Dispatch log scoping: owner/repo from the Refs line, and no blank row when no issue number parses
dispatch_run() { # <spec_file> [repo selector]
  set +e
  env -u BASH_ENV \
    PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-dispatch.log" \
    FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
    WORKER_STARTUP_STATE="$launch_state" \
    bash --noprofile --norc "$script" --run run_x --spec "$1" --title myjob --agent claude --model claude-sonnet-5-5-medium \
    --from term_coord --name n1 --repo "${2:-path:$clean}" >/dev/null 2>&1
  set -e
}
sed 's#^Refs \#1#Refs mingster/dotfiles\#816#' "$spec_file" >"$tmp/spec-repo.txt"
dispatch_run "$tmp/spec-repo.txt"
grep -qE '^816'$'\t''[0-9T:Z-]+'$'\t''mingster/dotfiles$' "$TEAM_AUDIT_DISPATCHES" \
  && ok || bad "Refs owner/repo#N records owner/repo in the dispatch log ($(cat "$TEAM_AUDIT_DISPATCHES" 2>&1))"
# Short Refs #N: owner/repo comes from the origin of --repo id:<id> or a bare directory path
mkdir -p "$tmp/gh-repo"
git -C "$tmp/gh-repo" init -q
git -C "$tmp/gh-repo" remote add origin git@github.com:acme/widgets.git
sed 's#^Refs \#1#Refs \#817#' "$spec_file" >"$tmp/spec-short.txt"
dispatch_run "$tmp/spec-short.txt" id:repo_gh
grep -qE '^817'$'\t''[0-9T:Z-]+'$'\t''acme/widgets$' "$TEAM_AUDIT_DISPATCHES" \
  && ok || bad "short Refs #N with --repo id:<id> resolves owner/repo ($(cat "$TEAM_AUDIT_DISPATCHES" 2>&1))"
sed 's#^Refs \#1#Refs \#818#' "$spec_file" >"$tmp/spec-short2.txt"
dispatch_run "$tmp/spec-short2.txt" "$tmp/gh-repo"
grep -qE '^818'$'\t''[0-9T:Z-]+'$'\t''acme/widgets$' "$TEAM_AUDIT_DISPATCHES" \
  && ok || bad "short Refs #N with a bare directory --repo resolves owner/repo ($(cat "$TEAM_AUDIT_DISPATCHES" 2>&1))"
# An existing zero byte log still gets the header
: >"$TEAM_AUDIT_DISPATCHES"
dispatch_run "$tmp/spec-repo.txt"
[ "$(head -1 "$TEAM_AUDIT_DISPATCHES")" = $'issue\tdispatched_at\trepo' ] \
  && ok || bad "zero byte dispatch log gets the header ($(cat "$TEAM_AUDIT_DISPATCHES" 2>&1))"
rows_before=$(wc -l <"$TEAM_AUDIT_DISPATCHES")
# brief-lint accepts a multi-slash ref the dispatch parser does not read: no issue number, so no row
sed 's#^Refs \#1#Refs a/b/c\#5#' "$spec_file" >"$tmp/spec-noref.txt"
dispatch_run "$tmp/spec-noref.txt"
[ "$(wc -l <"$TEAM_AUDIT_DISPATCHES")" = "$rows_before" ] && ! grep -qE '^'$'\t' "$TEAM_AUDIT_DISPATCHES" \
  && ok || bad "brief without a parsable Refs ...#N appends no row ($(cat "$TEAM_AUDIT_DISPATCHES" 2>&1))"
grep -Fq "path:$wt_proof" "$tmp/orca.log" && ok || bad "worktree path with space passed to orchestration ($wt_proof)"
grep -q 'orchestration worker-start' "$tmp/orca.log" && ok || bad "orca log has worker-start"
grep -Fq "worktree set --worktree path:$wt_proof --workspace-status in-progress" "$tmp/orca.log" && ok || bad "new worktree set in-progress on the board ($(cat "$tmp/orca.log"))"
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

# Automation PATH is ~/.local/bin plus system dirs, with no asdf shims. The start
# command must still run the pinned node from ~/.asdf/shims.
shim_home="$tmp/home-shim"
shim_bin="$shim_home/.asdf/shims"
mkdir -p "$shim_bin" "$shim_home/.local/bin"
shim_log="$tmp/node-shim.log"
: >"$shim_log"
cat >"$shim_bin/node" <<EOS
#!/bin/sh
printf 'node\n' >>"$shim_log"
echo v22.2.2
EOS
chmod +x "$shim_bin/node"
auto_path=$(node_match_path "$shim_home/.local/bin")
case ":$auto_path:" in
  *":$shim_bin:"*) bad "automation-style PATH must not already contain the asdf shims" ;;
  *) ok ;;
esac
shimrepo="$tmp/shimrepo"
shimrepo_bare="$tmp/shimrepo.git"
make_repo "$shimrepo" "$shimrepo_bare"
printf 'nodejs 22.2.2\n' >"$shimrepo/.tool-versions"
git -C "$shimrepo" add .tool-versions
git -C "$shimrepo" commit -qm pin
git -C "$shimrepo" push -q
cat >"$tmp/fleet-shim.json" <<EOF
{"hosts":[],"repos":["$shimrepo"]}
EOF
: >"$tmp/orca-shim.log"
set +e
env -u BASH_ENV -u ASDF_DATA_DIR -u AGENT_STATE_DIR -u REMOTE_REPO \
  HOME="$shim_home" PATH="$auto_path" \
  ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-shim.log" \
  FLEET_PULL_CONFIG="$tmp/fleet-shim.json" \
  FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" \
  FLEET_LOAD_SCRIPT="$tmp/fleet-load.sh" \
  PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  WORKER_STARTUP_STATE="$launch_state" \
  bash --noprofile --norc "$script" --run run_shim --spec "$spec_file" \
  --title myjob --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --name nshim --repo "path:$shimrepo" 2>"$tmp/run-shim.err"
ec_shim=$?
set -e
[ "$ec_shim" = 0 ] && ok || bad "minimal PATH start finds pinned node ($ec_shim) $(cat "$tmp/run-shim.err")"
grep -qx node "$shim_log" && ok || bad "pinned node shim was invoked ($(cat "$shim_log" 2>/dev/null))"
grep -q 'orchestration worker-start' "$tmp/orca-shim.log" && ok || bad "start reached worker-start under minimal PATH"

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
mkdir -p "$helper_dir/lib"
cp "$script" "$helper_dir/worker-startup.sh"
cp "$here/../lib/pr-review-gates.sh" "$helper_dir/lib/pr-review-gates.sh"
cp "$here/../lib/automation-path.sh" "$helper_dir/lib/automation-path.sh"
cp "$here/../lib/board-status.sh" "$helper_dir/lib/board-status.sh"
[ ! -f "$here/../brief-lint.sh" ] || cp "$here/../brief-lint.sh" "$helper_dir/brief-lint.sh"
cp "$here/../worker-placement.py" "$helper_dir/worker-placement.py"
chmod +x "$helper_dir/worker-startup.sh" "$helper_dir/worker-placement.py"
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

# --- AGENT_STATE_DIR config resolution + state dir fast-forward in host-check ---
state_repo="$tmp/agent-state"
state_bare="$tmp/agent-state.git"
make_repo "$state_repo" "$state_bare"
app_from_state="$tmp/app-from-state"
app_from_state_bare="$tmp/app-from-state.git"
make_repo "$app_from_state" "$app_from_state_bare"
cat >"$state_repo/fleet-pull.json" <<EOF
{"hosts":[],"repos":["$app_from_state"]}
EOF
git -C "$state_repo" add fleet-pull.json
git -C "$state_repo" commit -qm state-cfg
git -C "$state_repo" push -q origin main
origin_commit "$state_bare"
origin_commit "$app_from_state_bare"
state_tip=$(git --git-dir="$state_bare" rev-parse refs/heads/main)
app_state_tip=$(git --git-dir="$app_from_state_bare" rev-parse refs/heads/main)
set +e
env -u FLEET_PULL_CONFIG PATH="$bin:$PATH" AGENT_STATE_DIR="$state_repo" bash "$script" --host-check 2>"$tmp/h-state.err"
ec=$?
set -e
[ "$ec" = 0 ] && ok || bad "host-check with AGENT_STATE_DIR/fleet-pull.json exits 0 ($ec) $(cat "$tmp/h-state.err")"
[ "$(git -C "$state_repo" rev-parse HEAD)" = "$state_tip" ] && ok || bad "host-check fast-forwards AGENT_STATE_DIR"
[ "$(git -C "$app_from_state" rev-parse HEAD)" = "$app_state_tip" ] && ok || bad "host-check fast-forwards repo from AGENT_STATE_DIR config"

# --- Remote start (--on): pulls dotfiles, app checkout and state dir on target host, and refuses on failure ---
rem_home="$tmp/rem-home"
mkdir -p "$rem_home"
rem_dotfiles="$rem_home/dotfiles"
rem_dotfiles_bare="$tmp/rem-dotfiles.git"
make_repo "$rem_dotfiles" "$rem_dotfiles_bare"
mkdir -p "$rem_dotfiles/script"
cp "$script" "$rem_dotfiles/script/worker-startup.sh"
chmod +x "$rem_dotfiles/script/worker-startup.sh"
git -C "$rem_dotfiles" add script/worker-startup.sh
git -C "$rem_dotfiles" commit -qm add-startup
git -C "$rem_dotfiles" push -q origin main

rem_state="$rem_home/agent-state"
rem_state_bare="$tmp/rem-state.git"
make_repo "$rem_state" "$rem_state_bare"
rem_app="$tmp/rem-app"
rem_app_bare="$tmp/rem-app.git"
make_repo "$rem_app" "$rem_app_bare"
cat >"$rem_state/fleet-pull.json" <<EOF
{"hosts":[],"repos":["$rem_dotfiles","$rem_app"]}
EOF
git -C "$rem_state" add fleet-pull.json
git -C "$rem_state" commit -qm rem-cfg
git -C "$rem_state" push -q origin main

origin_commit "$rem_dotfiles_bare"
origin_commit "$rem_state_bare"
origin_commit "$rem_app_bare"
rem_dotfiles_tip=$(git --git-dir="$rem_dotfiles_bare" rev-parse refs/heads/main)
rem_state_tip=$(git --git-dir="$rem_state_bare" rev-parse refs/heads/main)
rem_app_tip=$(git --git-dir="$rem_app_bare" rev-parse refs/heads/main)

cat >"$bin/claude" <<'EOS'
#!/bin/sh
exit 0
EOS
chmod +x "$bin/claude"

orca_remote_stub="$tmp/orca-remote"
cat >"$orca_remote_stub" <<EOS
#!/usr/bin/env bash
set -e
log="\${ORCA_STUB_LOG:-/dev/null}"
printf '%s\n' "\$0 \$*" >>"\$log"
case " \$* " in
  *" worktree create "*)
    printf '%s\n' "{\"ok\":true,\"result\":{\"worktree\":{\"path\":\"$wt_proof\"}}}"
    exit 0
    ;;
  *" terminal create "*)
    cmd=""
    while [ \$# -gt 0 ]; do
      if [ "\$1" = "--command" ]; then cmd=\$2; break; fi
      shift
    done
    set +e
    HOME="$rem_home" AGENT_STATE_DIR="$rem_state" FLEET_PULL_CONFIG="" PATH="$bin:/usr/bin:/bin" bash -c "\$cmd" >"$tmp/rem-term.out" 2>&1
    rc=\$?
    set -e
    printf '%s' "\$rc" >"$tmp/rem-term.rc"
    printf '%s\n' '{"ok":true,"result":{"terminal":{"handle":"term_rem_1"}}}'
    exit 0
    ;;
  *" terminal wait "*)
    rc=\$(cat "$tmp/rem-term.rc")
    printf '%s\n' "{\"ok\":true,\"result\":{\"wait\":{\"satisfied\":true,\"status\":\"exited\",\"exitCode\":\$rc}}}"
    exit 0
    ;;
  *" terminal close "*)
    printf '%s\n' '{"ok":true,"result":{}}'
    exit 0
    ;;
  *" orchestration worker-start "*)
    printf '%s\n' '{"ok":true,"result":{"dispatchId":"ctx_rem","state":"ready"}}'
    exit 0
    ;;
esac
exit 99
EOS
chmod +x "$orca_remote_stub"

# Dirty remote app checkout -> remote start must refuse before worker-start
echo dirty_change >>"$rem_app/README"
: >"$tmp/orca-rem-fail.log"
set +e
unset -f python3 2>/dev/null || true
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_remote_stub" ORCA_STUB_LOG="$tmp/orca-rem-fail.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  bash --noprofile --norc "$script" --run run_rem_dirty --spec "$spec_file" --title remjob --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --on rem-env --name n_rem --repo "path:$rem_app" 2>"$tmp/rem-dirty.err"
ec_rem_dirty=$?
set -e
[ "$ec_rem_dirty" -ne 0 ] && ok || bad "remote start with dirty target app checkout should exit non-zero"
grep -q 'orchestration worker-start' "$tmp/orca-rem-fail.log" && bad "remote start should not worker-start when target host check fails" || ok

# Clean remote checkouts -> remote start pulls dotfiles, state dir, and app checkout on target host and starts worker
git -C "$rem_app" checkout -q -- README
: >"$tmp/orca-rem-ok.log"
set +e
unset -f python3 2>/dev/null || true
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_remote_stub" ORCA_STUB_LOG="$tmp/orca-rem-ok.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  bash --noprofile --norc "$script" --run run_rem_ok --spec "$spec_file" --title remjob --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --on rem-env --name n_rem --repo "path:$rem_app" 2>"$tmp/rem-ok.err"
ec_rem_ok=$?
set -e
[ "$ec_rem_ok" = 0 ] && ok || bad "remote start with clean target checkouts exits 0 ($ec_rem_ok) $(cat "$tmp/rem-ok.err") $(cat "$tmp/rem-term.out" 2>/dev/null)"
[ "$(git -C "$rem_dotfiles" rev-parse HEAD)" = "$rem_dotfiles_tip" ] && ok || bad "remote dotfiles fast-forwarded"
[ "$(git -C "$rem_state" rev-parse HEAD)" = "$rem_state_tip" ] && ok || bad "remote state dir fast-forwarded"
[ "$(git -C "$rem_app" rev-parse HEAD)" = "$rem_app_tip" ] && ok || bad "remote app checkout fast-forwarded"
grep -q 'orchestration worker-start' "$tmp/orca-rem-ok.log" && ok || bad "remote start dispatches after target host check"

# --- Stall restart mode (--task + --retry-of + --worktree) ---
: >"$tmp/orca-retry.log"
set +e
unset -f python3 2>/dev/null || true
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-retry.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  bash --noprofile --norc "$script" --run run_retry --task task_123 --retry-of disp_old --worktree "wt::/p" \
  --agent claude --from term_coord 2>"$tmp/retry.err"
ec_retry=$?
set -e
[ "$ec_retry" = 0 ] && ok || bad "stall restart via worker-startup exits 0 ($ec_retry) $(cat "$tmp/retry.err")"
grep -q 'orchestration worker-start.*--task task_123.*--retry-of disp_old' "$tmp/orca-retry.log" && ok || bad "stall restart forwards --task and --retry-of to worker-start"

# --- worker placement (fake load source + worker-placement.py) ---
cat >"$tmp/load-overflow.sh" <<'EOS'
#!/usr/bin/env bash
printf 'host-primary cores=8 load=15.0 15.0 15.0\n'
printf 'host-overflow cores=8 load=2.0 2.0 2.0\n'
printf 'host-skip cores=8 load=1.0 unreachable\n'
EOS
chmod +x "$tmp/load-overflow.sh"
cat >"$tmp/load-all-over.sh" <<'EOS'
#!/usr/bin/env bash
printf 'host-primary cores=8 load=15.0 15.0 15.0\n'
printf 'host-overflow cores=8 load=9.0 9.0 9.0\n'
EOS
chmod +x "$tmp/load-all-over.sh"
set +e
out_overflow=$(FLEET_LOAD_SCRIPT="$tmp/load-overflow.sh" FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" \
  "$python3_real" "$placement_py" pick --spec "$spec_file" 2>"$tmp/placement1.err")
ec_overflow=$?
set -e
[ "$ec_overflow" = 0 ] && ok || bad "placement picks overflow when primary over limit ($ec_overflow)"
grep -q 'host=host-overflow load_1m=2.0' <<<"$out_overflow" && ok || bad "overflow placement line ($out_overflow)"

set +e
out_refuse=$(FLEET_LOAD_SCRIPT="$tmp/load-all-over.sh" FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" \
  "$python3_real" "$placement_py" pick --spec "$spec_file" 2>"$tmp/placement2.err")
ec_refuse=$?
set -e
[ "$ec_refuse" -ne 0 ] && ok || bad "placement refuses when every host is over ($ec_refuse)"
grep -q 'refused host-overflow=9.0 host-primary=15.0' <<<"$out_refuse" && ok || bad "refuse lists loads ($out_refuse)"

set +e
out_skip=$(FLEET_LOAD_SCRIPT="$tmp/fleet-load.sh" FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" \
  "$python3_real" "$placement_py" pick --spec "$spec_file" 2>"$tmp/placement3.err")
ec_skip=$?
set -e
[ "$ec_skip" = 0 ] && ok || bad "placement skips unreadable host ($ec_skip)"
grep -q 'host=host-primary' <<<"$out_skip" && ok || bad "skipped unreadable host, chose primary ($out_skip)"

set +e
out_pickonly=$(FLEET_LOAD_SCRIPT="$tmp/fleet-load.sh" FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" \
  bash "$script" --pick-host-only --spec "$spec_file" 2>"$tmp/pickonly.err")
ec_pickonly=$?
set -e
[ "$ec_pickonly" = 0 ] && ok || bad "--pick-host-only exits 0 ($ec_pickonly)"
grep -q 'worker-placement: host=host-primary' <<<"$out_pickonly" && ok || bad "pick-host-only output ($out_pickonly)"

# Explicit --on: remote start still uses the given environment (placement not applied)
: >"$tmp/orca-explicit-on.log"
set +e
unset -f python3 2>/dev/null || true
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_remote_stub" ORCA_STUB_LOG="$tmp/orca-explicit-on.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" FLEET_LOAD_SCRIPT="$tmp/load-all-over.sh" \
  bash --noprofile --norc "$script" --run run_explicit_on --spec "$spec_file" --title remjob --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --on rem-env --name n_rem --repo "path:$rem_app" 2>"$tmp/explicit-on.err"
ec_explicit=$?
set -e
[ "$ec_explicit" = 0 ] && ok || bad "explicit --on run exits 0 despite all-over load sensor ($ec_explicit)"
grep -q 'worker-placement:' "$tmp/explicit-on.err" && bad "explicit --on must not run placement" || ok

# Local host: 0.75 load per core (9 on 12) is over — overflow wins under ceiling
cat >"$tmp/load-local-percore.sh" <<'EOS'
#!/usr/bin/env bash
printf 'host-primary cores=12 load=9.0 9.0 9.0\n'
printf 'host-overflow cores=8 load=2.0 2.0 2.0\n'
EOS
chmod +x "$tmp/load-local-percore.sh"
set +e
out_percore=$(FLEET_LOAD_SCRIPT="$tmp/load-local-percore.sh" FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" \
  "$python3_real" "$placement_py" pick --spec "$spec_file" 2>"$tmp/placement-percore.err")
ec_percore=$?
set -e
[ "$ec_percore" = 0 ] && ok || bad "local 0.75 per core picks overflow ($ec_percore)"
grep -q 'host=host-overflow load_1m=2.0' <<<"$out_percore" && ok || bad "per-core overflow line ($out_percore)"

# Browser routing: prose "secrets" stays code; explicit Host role: browser uses browser host
secrets_spec="$tmp/secrets-spec.txt"
printf 'Never record secrets in the brief.\nDo code work.\n' >"$secrets_spec"
set +e
out_secrets=$(FLEET_LOAD_SCRIPT="$tmp/fleet-load.sh" FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" \
  "$python3_real" "$placement_py" pick --spec "$secrets_spec" 2>"$tmp/placement-secrets.err")
ec_secrets=$?
set -e
[ "$ec_secrets" = 0 ] && ok || bad "secrets prose stays code ($ec_secrets)"
grep -q 'host=host-primary' <<<"$out_secrets" && ok || bad "code host for secrets prose ($out_secrets)"
browser_spec="$tmp/browser-spec.txt"
printf 'Host role: browser\n\nOpen staging and check UI.\n' >"$browser_spec"
cat >"$tmp/load-browser.sh" <<'EOS'
#!/usr/bin/env bash
printf 'host-primary cores=8 load=1.0 1.0 1.0\n'
printf 'host-browser cores=8 load=1.0 1.0 1.0\n'
EOS
chmod +x "$tmp/load-browser.sh"
set +e
out_browser=$(FLEET_LOAD_SCRIPT="$tmp/load-browser.sh" FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" \
  "$python3_real" "$placement_py" pick --spec "$browser_spec" 2>"$tmp/placement-browser.err")
ec_browser=$?
set -e
[ "$ec_browser" = 0 ] && ok || bad "browser role line picks browser host ($ec_browser)"
grep -q 'host=host-browser' <<<"$out_browser" && ok || bad "browser host placement ($out_browser)"

# Remote repo map: translated id on worktree create for auto-picked remote host
cat >"$tmp/load-remote-map.sh" <<'EOS'
#!/usr/bin/env bash
printf 'host-primary cores=8 load=15.0 15.0 15.0\n'
printf 'host-remote cores=8 load=1.0 1.0 1.0\n'
EOS
chmod +x "$tmp/load-remote-map.sh"
set +e
out_map_json=$(FLEET_LOAD_SCRIPT="$tmp/load-remote-map.sh" FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" \
  "$python3_real" "$placement_py" pick --spec "$spec_file" --repo "id:local-app-id" --json 2>"$tmp/repo-map-pick.err")
ec_map_json=$?
set -e
[ "$ec_map_json" = 0 ] && ok || bad "repo map pick exits 0 ($ec_map_json)"
grep -q '"repo":"id:remote-app-id"' <<<"$out_map_json" && ok || bad "pick JSON includes mapped repo ($out_map_json)"
: >"$tmp/orca-repo-map.log"
set +e
unset -f python3 2>/dev/null || true
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_remote_stub" ORCA_STUB_LOG="$tmp/orca-repo-map.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" FLEET_LOAD_SCRIPT="$tmp/load-remote-map.sh" \
  bash --noprofile --norc "$script" --run run_repo_map --spec "$spec_file" --title mapjob --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --name n_map --repo "id:local-app-id" 2>"$tmp/repo-map.err"
ec_repo_map=$?
set -e
[ "$ec_repo_map" = 0 ] && ok || bad "remote repo map run exits 0 ($ec_repo_map) $(cat "$tmp/repo-map.err")"
grep -q 'worktree create' "$tmp/orca-repo-map.log" && ok || bad "repo map worktree create logged"
grep -q 'id:remote-app-id' "$tmp/orca-repo-map.log" && ok || bad "worktree create uses mapped remote repo id ($(cat "$tmp/orca-repo-map.log"))"

# Missing fleet config: skip placement and start locally; malformed config still refuses
no_cfg_path="$tmp/no-fleet-placement.json"
set +e
out_no_cfg=$(FLEET_WATCH_CONFIG="$no_cfg_path" \
  bash "$script" --pick-host-only --spec "$spec_file" 2>"$tmp/placement-nocfg.err")
ec_no_cfg=$?
set -e
[ "$ec_no_cfg" = 0 ] && ok || bad "--pick-host-only without fleet config exits 0 ($ec_no_cfg)"
grep -q 'worker-placement: skipped (no fleet config)' "$tmp/placement-nocfg.err" && ok || bad "missing config skip line ($(cat "$tmp/placement-nocfg.err"))"
printf '{not-json' >"$tmp/fleet-broken.json"
set +e
out_broken=$(FLEET_WATCH_CONFIG="$tmp/fleet-broken.json" bash "$script" --pick-host-only --spec "$spec_file" 2>"$tmp/placement-broken.err")
ec_broken=$?
set -e
[ "$ec_broken" -ne 0 ] && ok || bad "malformed fleet config refuses ($ec_broken)"
: >"$tmp/orca-nocfg.log"
set +e
unset -f python3 2>/dev/null || true
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-nocfg.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  FLEET_WATCH_CONFIG="$no_cfg_path" \
  bash --noprofile --norc "$script" --run run_nocfg --spec "$spec_file" --title nocfg --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --name n_nc --repo "path:$clean" 2>"$tmp/run-nocfg.err"
ec_run_nocfg=$?
set -e
[ "$ec_run_nocfg" = 0 ] && ok || bad "--run without fleet config starts locally ($ec_run_nocfg)"
grep -q 'worker-placement: skipped (no fleet config)' "$tmp/run-nocfg.err" && ok || bad "run skip placement stderr ($(cat "$tmp/run-nocfg.err"))"
grep -q 'orchestration worker-start' "$tmp/orca-nocfg.log" && ok || bad "local worker-start without fleet config"

# Follow-up 1: --worktree-path stays local, placement is not applied
: >"$tmp/orca-wtpath.log"
set +e
unset -f python3 2>/dev/null || true
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-wtpath.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" FLEET_LOAD_SCRIPT="$tmp/load-remote-map.sh" \
  bash --noprofile --norc "$script" --run run_wtpath --spec "$spec_file" --title wtjob --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --worktree-path "$clean" --repo "id:local-app-id" 2>"$tmp/wtpath.err"
ec_wtpath=$?
set -e
[ "$ec_wtpath" = 0 ] && ok || bad "--worktree-path run exits 0 ($ec_wtpath) $(cat "$tmp/wtpath.err")"
grep -q 'worker-placement:' "$tmp/wtpath.err" && bad "--worktree-path must not run placement" || ok

# #759 case: --worktree-path with no --repo also skips placement
: >"$tmp/orca-wtpath-norepo.log"
set +e
unset -f python3 2>/dev/null || true
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-wtpath-norepo.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" FLEET_LOAD_SCRIPT="$tmp/load-all-over.sh" \
  bash --noprofile --norc "$script" --run run_wtpath2 --spec "$spec_file" --title wtjob2 --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --worktree-path "$clean" 2>"$tmp/wtpath-norepo.err"
ec_wtpath2=$?
set -e
[ "$ec_wtpath2" = 0 ] && ok || bad "--worktree-path without --repo exits 0 ($ec_wtpath2) $(cat "$tmp/wtpath-norepo.err")"
grep -q 'worker-placement:' "$tmp/wtpath-norepo.err" && bad "--worktree-path without --repo must not run placement" || ok

# Load sensor failure and timeout: refusal line, exit 4, not a generic failure
cat >"$tmp/load-fail.sh" <<'EOS'
#!/usr/bin/env bash
exit 7
EOS
cat >"$tmp/load-hang.sh" <<'EOS'
#!/usr/bin/env bash
sleep 30
EOS
chmod +x "$tmp/load-fail.sh" "$tmp/load-hang.sh"
for sensor_case in fail hang; do
  set +e
  WORKER_PLACEMENT_TIMEOUT=1 FLEET_LOAD_SCRIPT="$tmp/load-$sensor_case.sh" FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" \
    bash "$script" --pick-host-only --spec "$spec_file" >"$tmp/sensor-$sensor_case.out" 2>"$tmp/sensor-$sensor_case.err"
  ec_sensor=$?
  set -e
  [ "$ec_sensor" = 4 ] && ok || bad "load sensor $sensor_case exits 4 ($ec_sensor)"
  grep -q '^worker-placement: refused (load sensor' "$tmp/sensor-$sensor_case.err" && ok || bad "load sensor $sensor_case refusal line ($(cat "$tmp/sensor-$sensor_case.err"))"
done

# Follow-up 2: cursor agent passes the usage gate before the helper is exec'd
: >"$PYTHON3_RUN_ORDER_LOG"
rm -f "$tmp/cursor.args"
set +e
env -u BASH_ENV \
  PATH="$helper_dir:$run_path" ORCA_CLI_COMMAND="$orca_stub" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  bash --noprofile --norc "$helper_dir/worker-startup.sh" --run run_gate --spec "$spec_file" --title cgate --agent cursor --model composer-2.5 \
  --from term_coord --worktree-path /abs/wt 2>"$tmp/cursor-gate.err"
set -e
grep -q 'stub-gate-ran' "$PYTHON3_RUN_ORDER_LOG" && ok || bad "cursor run must pass the usage gate before exec"
cat >"$tmp/deny-python3" <<EOS
#!/usr/bin/env bash
case "\$1" in *.py) [ "\${2:-}" = check ] && exit 1 ;; esac
exec "$PYTHON" "\$@"
EOS
chmod +x "$tmp/deny-python3"
rm -f "$tmp/cursor.args"
set +e
env -u BASH_ENV \
  PATH="$helper_dir:$run_path" ORCA_CLI_COMMAND="$orca_stub" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$tmp/deny-python3" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  bash --noprofile --norc "$helper_dir/worker-startup.sh" --run run_gate2 --spec "$spec_file" --title cgate2 --agent cursor --model composer-2.5 \
  --from term_coord --worktree-path /abs/wt 2>"$tmp/cursor-deny.err"
ec_cdeny=$?
set -e
[ "$ec_cdeny" = 3 ] && ok || bad "cursor run refused by the usage gate exits 3 ($ec_cdeny)"
[ -e "$tmp/cursor.args" ] && bad "cursor helper must not run when the gate refuses" || ok

# Follow-up 3: every host skipped for a missing repo mapping says so
cat >"$tmp/fleet-nomap.json" <<'EOF'
{
  "local_host": "host-primary",
  "host_caps": {"host-primary": 4, "host-remote": 4},
  "host_load_ceilings": {"host-primary": 12, "host-remote": 12},
  "worker_placement": {"order": ["host-remote"], "repos": {}}
}
EOF
set +e
out_nomap=$(FLEET_LOAD_SCRIPT="$tmp/load-remote-map.sh" FLEET_WATCH_CONFIG="$tmp/fleet-nomap.json" \
  "$python3_real" "$placement_py" pick --spec "$spec_file" --repo "id:local-app-id" 2>/dev/null)
ec_nomap=$?
set -e
[ "$ec_nomap" -ne 0 ] && ok || bad "unmapped repo on every host refuses ($ec_nomap)"
grep -q 'no host has a repo mapping' <<<"$out_nomap" && ok || bad "unmapped refusal names the repo mapping ($out_nomap)"
grep -q 'no readable load' <<<"$out_nomap" && bad "unmapped refusal must not say no readable load" || ok

# Builder route: fullstack-dev and light refuse Claude while pick allows Cursor.
cat >"$tmp/pick-stub.py" <<'EOS'
#!/usr/bin/env python3
import os, sys
mode = os.environ.get("PICK_STUB_MODE", "cursor")
role = sys.argv[sys.argv.index("--role") + 1] if "--role" in sys.argv else ""
with open(os.environ["PICK_STUB_LOG"], "a") as handle:
    handle.write(role + "\n")
if mode == "cursor":
    print("--agent cursor --model grok-4.7-xhigh")
    raise SystemExit(0)
if mode == "sonnet":
    print("--agent claude --model sonnet --effort medium")
    raise SystemExit(0)
if mode == "haiku":
    print("--agent claude --model haiku")
    raise SystemExit(0)
raise SystemExit(4)
EOS
route_state="$tmp/route-state"
mkdir -p "$route_state"
route_run() { # <title> <agent> <model> [extra args...]
  : >"$tmp/pick-stub.log"
  : >"$tmp/orca-route.log"
  set +e
  env -u BASH_ENV \
    PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-route.log" \
    FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
    USAGE_GATE_PICK="$tmp/pick-stub.py" USAGE_GATE_PRESETS="$root/.orca/presets.json" \
    PICK_STUB_MODE="${PICK_STUB_MODE:-cursor}" PICK_STUB_LOG="$tmp/pick-stub.log" \
    WORKER_STARTUP_STATE="$route_state" \
    bash --noprofile --norc "$script" --run run_route --spec "$spec_file" --title "$1" --agent "$2" --model "$3" \
    --from term_coord --name nroute --repo "path:$clean" "${@:4}" \
    >"$tmp/route.out" 2>"$tmp/route.err"
  route_ec=$?
  set -e
}
PICK_STUB_MODE=cursor route_run "fullstack-dev - feature" claude claude-sonnet-5-5-medium
[ "$route_ec" -ne 0 ] && ok || bad "fullstack-dev on claude should be refused while Cursor is allowed (ec=$route_ec)"
grep -Fq -- '--agent cursor --model grok-4.7-xhigh' "$tmp/route.err" && ok || bad "refusal should print the pick ($(cat "$tmp/route.err"))"
grep -q 'worker-start' "$tmp/orca-route.log" && bad "refused builder must not reach worker-start" || ok
PICK_STUB_MODE=cursor route_run "fullstack-dev-small - chore" claude claude-haiku
[ "$route_ec" -ne 0 ] && ok || bad "light unit on claude should be refused while Cursor is allowed (ec=$route_ec)"
grep -Fq -- '--agent cursor --model grok-4.7-xhigh' "$tmp/route.err" && ok || bad "light refusal should print the pick ($(cat "$tmp/route.err"))"
rm -f "$route_state/route-override.log"
PICK_STUB_MODE=cursor route_run "fullstack-dev - feature" claude claude-sonnet-5-5-medium --route-override "cursor desktop trust is stuck"
[ "$route_ec" = 0 ] && ok || bad "route override should let claude through (ec=$route_ec) $(cat "$tmp/route.err")"
grep -Fq 'cursor desktop trust is stuck' "$route_state/route-override.log" && ok || bad "route override should log the reason ($(cat "$route_state/route-override.log" 2>/dev/null))"
grep -q 'worker-start' "$tmp/orca-route.log" && ok || bad "route override should still start the worker"
PICK_STUB_MODE=sonnet route_run "fullstack-dev - feature" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "claude is allowed when pick says Cursor is blocked (ec=$route_ec) $(cat "$tmp/route.err")"
grep -q 'refused' "$tmp/route.err" && bad "cursor-blocked pick must not refuse claude" || ok
: >"$tmp/pick-stub.log"
PICK_STUB_MODE=cursor route_run "elon - think" claude claude-opus
[ "$route_ec" = 0 ] && ok || bad "strong role on claude must not hit the builder gate (ec=$route_ec) $(cat "$tmp/route.err")"
grep -q '^elon$' "$tmp/pick-stub.log" && bad "strong role must not be asked to yield to Cursor" || ok

# Orca registers the physical checkout. A symlink selector must be rewritten before worktree create.
link_real="$tmp/link-real"
mkdir -p "$link_real"
git -C "$link_real" init -q
ln -s "$link_real" "$tmp/link-repo"
link_physical=$(cd "$tmp/link-repo" && pwd -P)
cat >"$tmp/orca-link" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${ORCA_STUB_LOG:?}"
case " $* " in
  *" worktree create "*)
    printf '%s\n' '{"ok":true,"result":{"worktree":{"path":"/tmp/wt-link"}}}'
    exit 0 ;;
  *" orchestration worker-start "*)
    printf '%s\n' '{"ok":true,"result":{"dispatchId":"ctx_link","taskId":"task_link","runId":"run_x","state":"ready","agent":"claude","model":"sonnet"}}'
    exit 0 ;;
esac
exit 99
EOS
chmod +x "$tmp/orca-link"
set +e
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$tmp/orca-link" ORCA_STUB_LOG="$tmp/orca-link.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  WORKER_STARTUP_STATE="$tmp/link-state" \
  bash --noprofile --norc "$script" --run run_x --spec "$spec_file" --title myjob --agent claude --model sonnet \
  --from term_coord --name nlink --repo "path:$tmp/link-repo" >"$tmp/link.out" 2>"$tmp/link.err"
ec_link=$?
set -e
[ "$ec_link" = 0 ] && ok || bad "symlink repo run exits 0 ($ec_link) $(cat "$tmp/link.err")"
grep -F "path:$link_physical" "$tmp/orca-link.log" >/dev/null && ok || bad "worktree create uses the physical repo ($link_physical) $(cat "$tmp/orca-link.log")"
grep -F "path:$tmp/link-repo" "$tmp/orca-link.log" >/dev/null && bad "worktree create kept the symlink repo" || ok

# Antigravity sign-in screen: the start check fails, and startup returns that on stderr.
# A normal Antigravity screen still exits 0.
cat >"$tmp/orca-agy" <<'EOS'
#!/usr/bin/env bash
set -e
log="${ORCA_STUB_LOG:-/dev/null}"
printf '%s\n' "$*" >>"$log"
case "$*" in
  *"worktree create"*)
    printf '%s\n' "{\"ok\":true,\"result\":{\"worktree\":{\"path\":\"${AGY_WT:?}\"}}}"
    ;;
  *"orchestration worker-start"*)
    printf '%s\n' '{"ok":true,"result":{"dispatchId":"ctx_agy","taskId":"task_agy","runId":"run_agy","state":"ready","agent":"antigravity","model":"gemini-4-argon-medium","terminal":"term_agy"}}'
    ;;
  *"orchestration worker-show"*)
    printf '%s\n' '{"ok":true,"result":{"dispatchId":"ctx_agy","state":"ready","liveness":"live","terminal":"term_agy"}}'
    ;;
  *"terminal read"*)
    python3 -c '
import json, os
tail = open(os.environ["AGY_SCREEN"]).read().splitlines()
print(json.dumps({"ok": True, "result": {"terminal": {"tail": tail}}}))
'
    ;;
  *)
    printf 'unexpected orca: %s\n' "$*" >&2
    exit 99
    ;;
esac
EOS
chmod +x "$tmp/orca-agy"
printf '%s\n' 'You are currently not signed in. Select login method' >"$tmp/agy-login.txt"
printf '%s\n' 'Working on the assigned task' 'Running the checks' '>' >"$tmp/agy-ok.txt"
agy_run() { # <screen file> <stderr>
  : >"$tmp/orca-agy.log"
  set +e
  unset -f python3 2>/dev/null || true
  env -u BASH_ENV \
    PATH="$run_path" ORCA_CLI_COMMAND="$tmp/orca-agy" ORCA_STUB_LOG="$tmp/orca-agy.log" \
    FLEET_PULL_CONFIG="$tmp/fleet.json" FLEET_WATCH_CONFIG="$tmp/no-agy-fleet.json" \
    PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
    AGY_WT="$wt_proof" AGY_SCREEN="$1" \
    bash --noprofile --norc "$script" --run run_agy --spec "$spec_file" --title myjob \
    --agent antigravity --model gemini-4-argon-medium \
    --from term_coord --name nagy --repo "path:$clean" >"$tmp/agy.out" 2>"$2"
  agy_ec=$?
  set -e
}
agy_run "$tmp/agy-login.txt" "$tmp/agy-login.err"
[ "$agy_ec" -ne 0 ] && ok || bad "antigravity sign-in screen should exit non-zero ($agy_ec)"
grep -q 'sign-in step' "$tmp/agy-login.err" && ok || bad "antigravity sign-in stderr should name the sign-in step ($(cat "$tmp/agy-login.err"))"
grep -q 'orchestration worker-start' "$tmp/orca-agy.log" && ok || bad "sign-in failure is reported after the worker starts"
agy_run "$tmp/agy-ok.txt" "$tmp/agy-ok.err"
[ "$agy_ec" = 0 ] && ok || bad "normal antigravity screen should exit 0 ($agy_ec) $(cat "$tmp/agy-ok.err")"
grep -q 'sign-in step' "$tmp/agy-ok.err" && bad "normal antigravity screen must not report sign-in" || ok

echo "worker-startup: $pass passed, $fail failed"
[ "$fail" = 0 ]
