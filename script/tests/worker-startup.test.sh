#!/usr/bin/env bash
# Tests for worker-startup.sh: host-check (pull, pins, conditional bun install) and --run delegation.
# Red-green: failure modes and orca stubs before the happy path.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# Placement tests use fake hosts; only the worker count tests below read an orca fake.
export WORKER_PLACEMENT_COUNT_WORKERS=0
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
# Starts here are fake and never counted as live workers; an unusable recent file keeps them from filling host caps.
export WORKER_PLACEMENT_RECENT_FILE="$tmp/no-such-dir/placement-recent.json"
mkdir -p "$tmp" && : >"$tmp/no-such-dir"
trap 'rm -rf "$tmp"' EXIT
export FLEET_WATCH_LOG_PATH="$tmp/fleet-watch-test.log"
unset -f python3 2>/dev/null || true
# shellcheck source=lib/git-identity.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/git-identity.sh"
use_test_git_identity "$tmp"
export USAGE_GATE_PRESETS="${USAGE_GATE_PRESETS:-$root/.orca/presets.json}"
export WORKER_STARTUP_STATE="$tmp/state" TEAM_AUDIT_DISPATCHES="$tmp/team-dispatches.tsv"
export WORKER_STARTUP_READINESS_WAIT=0
export GROK_HOME="$tmp/grok-home"
# The label gate and the dotfiles first check call gh; they run only in the tests that stub it.
export DOTFILES_REPO=off
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
    { printf '%s\n' "{\"id\":\"repo_gh\",\"path\":\"\$GH_REPO_DIR\"}"; for d in "$tmp"/*/; do printf '{"id":"repo_fx_%s","path":"%s"}\n' "\$(basename "\$d")" "\${d%/}"; done; } | jq -cs '{ok:true,result:{repos:.}}'
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
  *" terminal list "*)
    # The worker, a plain shell and a setup shell in this worktree, plus one terminal in another worktree.
    printf '%s\n' '{"ok":true,"result":{"terminals":[{"handle":"term_fixture4242","worktreePath":"'"\$WT_PROOF"'"},{"handle":"term_extra_shell","worktreePath":"'"\$WT_PROOF"'"},{"handle":"term_extra_setup","worktreePath":"'"\$WT_PROOF"'"},{"handle":"term_other_wt","worktreePath":"/elsewhere/other"}]}}'
    exit 0
    ;;
  *" terminal close "*)
    printf '%s\n' '{"ok":true,"result":{}}'
    exit 0
    ;;
  *" orchestration task-list "*|*" orchestration worker-list "*)
    printf '%s\n' '{"ok":true,"result":{"tasks":[],"workers":[]}}'
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
  bash --noprofile --norc "$script" --run run_bad_spec --spec "$bad_spec" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --name n1 --repo "path:$clean" 2>"$tmp/run-lint.err"
ec_lint=$?
set -e
[ "$ec_lint" -ne 0 ] && ok || bad "bad brief --run should exit non-zero"
grep -q 'brief-lint: missing Acceptance' "$tmp/run-lint.err" && ok || bad "bad brief stderr should include brief-lint output ($(cat "$tmp/run-lint.err"))"
grep -q 'brief-lint: missing Refs' "$tmp/run-lint.err" && bad "the title #1 supplies the Refs line, so lint must not report it missing" || ok
grep -q 'orchestration worker-start' "$tmp/orca-lint.log" && bad "orca should not worker-start when brief-lint fails" || ok

# 1328: a passing lint still shows its owner path warning on stderr
warn_spec="$tmp/warn-spec.txt"
{ cat "$spec_file"; printf '\n## Allowed files\n- .claude/settings.json\n'; } >"$warn_spec"
: >"$tmp/orca-warn.log"
set +e
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-warn.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  bash --noprofile --norc "$script" --run run_warn --spec "$warn_spec" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --name n1 --repo "path:$clean" 2>"$tmp/run-warn.err"
set -e
grep -q 'brief-lint: warning: Allowed files names owner gated path .claude/settings.json' "$tmp/run-warn.err" && ok || bad "passing lint should print the owner path warning ($(cat "$tmp/run-warn.err"))"
grep -q 'orchestration worker-start' "$tmp/orca-warn.log" && ok || bad "a warning must not stop the start ($(cat "$tmp/run-warn.err"))"

# 968: a brief with no Finish starts, and the spec the worker gets carries the fixed Finish block
nofin_spec="$tmp/nofin-spec.txt"
cat >"$nofin_spec" <<'EOS'
Refs #968
Role: fullstack-dev.

## Acceptance
- [ ] Do the task.

## Out of scope
Unrelated files.

## Verify
Run bash script/checks-local.sh.
EOS
ws968_run() { # <log> <run id> <spec> -> exit code in ec_968, stderr in $tmp/run-968.err
  : >"$1"
  set +e
  env -u BASH_ENV \
    PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$1" \
    FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
    bash --noprofile --norc "$script" --run "$2" --spec "$3" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
    --from term_coord --name n1 --repo "path:$clean" 2>"$tmp/run-968.err"
  ec_968=$?
  set -e
}
ws968_run "$tmp/orca-nofin.log" run_nofin "$nofin_spec"
[ "$ec_968" = 0 ] && ok || bad "brief with no Finish should start ($ec_968) $(cat "$tmp/run-968.err")"
grep -q 'orchestration worker-start' "$tmp/orca-nofin.log" && ok || bad "no-Finish brief should reach worker-start"
grep -q '## Finish' "$tmp/orca-nofin.log" && ok || bad "worker spec should carry a ## Finish block"
grep -q 'workspace-status in-review' "$tmp/orca-nofin.log" && ok || bad "worker spec Finish should set in-review when there is a PR"
grep -q 'workspace-status completed' "$tmp/orca-nofin.log" && ok || bad "worker spec Finish should set completed when there is no PR"
grep -q 'no pull request' "$tmp/orca-nofin.log" && ok || bad "worker spec Finish should name the no-PR case"
grep -q 'to run run_nofin' "$tmp/orca-nofin.log" && bad "worker spec Finish must not name the home run for worker_done (#1220)" || ok
grep -q 'without a `--run` flag' "$tmp/orca-nofin.log" && ok || bad "worker spec Finish should tell workers to send worker_done without --run (#1220)"
grep -q 'Builder: agent=claude model=claude-sonnet-5-5-medium' "$tmp/orca-nofin.log" && ok || bad "builder spec Finish should write the exact Builder agent and model line"
grep -q 'Builder: agent=<agent>' "$tmp/orca-nofin.log" && bad "builder spec Finish must not leave <agent> placeholder" || ok
grep -q '40 hex' "$tmp/orca-nofin.log" && bad "builder spec Finish should not demand a Self-review head sha" || ok
grep -q 'gh pr checks' "$tmp/orca-nofin.log" && ok || bad "builder spec Finish should wait for green checks"
grep -q 'pr-review.sh <pr> <head sha>' "$tmp/orca-nofin.log" && ok || bad "builder spec Finish should tell the builder to run pr-review.sh itself (#1675)"
grep -q 'PR body sections' "$tmp/orca-nofin.log" && grep -q 'check-pr-body.sh' "$tmp/orca-nofin.log" && ok || bad "builder spec Finish should list the PR body sections (#1676)"
grep -q '^## Finish' "$nofin_spec" && bad "the original brief file should be untouched" || ok

# 1201: a brief with no Refs line gets "Refs #<issue>" from the title, in a copy. A written Refs form is left alone.
norefs_spec="$tmp/norefs-spec.txt"
sed '/^Refs #968$/d' "$nofin_spec" >"$norefs_spec"
ws968_run "$tmp/orca-norefs.log" run_norefs "$norefs_spec"
[ "$ec_968" = 0 ] && ok || bad "a brief with no Refs should start from the title ($ec_968) $(cat "$tmp/run-968.err")"
grep -q '^Refs #1$' "$tmp/orca-norefs.log" && ok || bad "worker spec should carry Refs #1 from the title"
grep -q 'Refs' "$norefs_spec" && bad "the original brief file should be untouched by the Refs injection" || ok
for form in 'Refs: #7' 'Closes #7' 'Refs a/b#7'; do
  sed "s|^Refs #968\$|$form|" "$nofin_spec" >"$tmp/refsform.txt"
  ws968_run "$tmp/orca-refsform.log" run_refsform "$tmp/refsform.txt"
  [ "$ec_968" = 0 ] && ! grep -q '^Refs #1$' "$tmp/orca-refsform.log" && ok || bad "'$form' is a Refs line, so none is injected ($ec_968) $(cat "$tmp/run-968.err")"
done

# 968: a brief with its own Finish is not given a second one, and a builder with its own Finish still gets the exact Builder line
ownfin_builder="$tmp/ownfin-builder.txt"
cat >"$ownfin_builder" <<'EOS'
Refs #968
Role: fullstack-dev.

## Acceptance
- [ ] Do the task.

## Out of scope
Unrelated files.

## Verify
Run bash script/checks-local.sh.

## Finish
Self-review, open the PR, then send worker_done.
EOS
ws968_run "$tmp/orca-ownfin.log" run_ownfin "$ownfin_builder"
[ "$(grep -o '## Finish' "$tmp/orca-ownfin.log" | wc -l | tr -d ' ')" = 1 ] && ok || bad "a brief with its own Finish should keep exactly one"
grep -q 'Builder: agent=claude model=claude-sonnet-5-5-medium' "$tmp/orca-ownfin.log" && ok || bad "a builder brief with its own Finish should still carry the exact Builder line"

# 968: a brief with no Acceptance is still refused
noacc_spec="$tmp/noacc-spec.txt"
sed '/^## Acceptance/,/^$/d' "$nofin_spec" >"$noacc_spec"
ws968_run "$tmp/orca-noacc.log" run_noacc "$noacc_spec"
[ "$ec_968" -ne 0 ] && grep -q 'brief-lint: missing Acceptance' "$tmp/run-968.err" && ok || bad "no Acceptance should be refused ($ec_968) $(cat "$tmp/run-968.err")"
grep -q 'orchestration worker-start' "$tmp/orca-noacc.log" && bad "no-Acceptance brief must not start" || ok

# 849: a "release-manager: merge" worker never starts on an overflow host
: >"$tmp/orca-merge.log"
merge_spec_saved=$(cat "$spec_file")
printf '# release-manager merge #849\n\n%s\n' "$merge_spec_saved" >"$spec_file"
set +e
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-merge.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  bash --noprofile --norc "$script" --run run_merge --spec "$spec_file" --title "#849|release-manager" --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --on host-overflow --name n_merge --repo "path:$clean" 2>"$tmp/run-merge.err"
ec_merge=$?
set -e
[ "$ec_merge" -ne 0 ] && ok || bad "merge worker --on an overflow host should exit non-zero"
grep -q 'coordinator host only' "$tmp/run-merge.err" && ok || bad "merge worker refusal should name the coordinator host ($(cat "$tmp/run-merge.err"))"
grep -q 'worker-start' "$tmp/orca-merge.log" && bad "orca should not start a merge worker on an overflow host" || ok
printf '%s\n' "$merge_spec_saved" >"$spec_file"

# Owner rule 2026-11-18: --title must be "#<issue>|<role>"
for bad_title in myjob "qa-sdet - verify #5" "#12" "#12|QA" "12|qa-sdet" "#12|qa-sdet extra" "#12|qa-sdet|"; do
  : >"$tmp/orca-title.log"
  set +e
  env -u BASH_ENV \
    PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-title.log" \
    FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
    bash --noprofile --norc "$script" --run run_title --spec "$spec_file" --title "$bad_title" --agent claude --model claude-sonnet-5-5-medium \
    --from term_coord --name n_title --repo "path:$clean" 2>"$tmp/title.err"
  ec_title=$?
  set -e
  [ "$ec_title" = 2 ] && ok || bad "title '$bad_title' should exit 2 ($ec_title)"
  grep -q "#<issue>|<role>" "$tmp/title.err" && ok || bad "title '$bad_title' refusal should show the expected form ($(cat "$tmp/title.err"))"
  [ ! -s "$tmp/orca-title.log" ] && ok || bad "title '$bad_title' must not reach orca"
done
# 1324: a refused title prints the corrected one when the brief heading names the issue.
hint_spec="$tmp/hint-spec.md"
printf '# Build #1324: worker-startup refusals\nRole: fullstack-dev\n' >"$hint_spec"
set +e
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-title.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  bash --noprofile --norc "$script" --run run_title --spec "$hint_spec" --title "myjob" --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --name n_title --repo "path:$clean" 2>"$tmp/title.err"
set -e
grep -q "did you mean '#1324|fullstack-dev'?" "$tmp/title.err" && ok || bad "refused title should print the corrected title ($(cat "$tmp/title.err"))"
: >"$tmp/orca-title.log"
set +e
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-title.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  bash --noprofile --norc "$script" --run run_title --spec "$spec_file" --title "#123|qa-sdet" --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --name n_title --repo "path:$clean" 2>"$tmp/title.err"
ec_title=$?
set -e
[ "$ec_title" = 0 ] && ok || bad "title '#123|qa-sdet' should start ($ec_title) $(cat "$tmp/title.err")"
grep -q -- "--task-title #123|qa-sdet" "$tmp/orca-title.log" && ok || bad "worker-start should carry the task title"
grep -q -- "terminal rename --terminal term_fixture4242 --title #123|qa-sdet" "$tmp/orca-title.log" && ok || bad "terminal should be renamed to the title ($(cat "$tmp/orca-title.log"))"
grep -q -- "terminal set-pane-title --terminal term_fixture4242 --title #123|qa-sdet" "$tmp/orca-title.log" && ok || bad "pane title should be set"
grep -E "terminal (rename|set-pane-title)" "$tmp/orca-title.log" | grep -q -- '--environment' && bad "a local worker title must not pass --environment" || ok
# #1653: after the start only the worker terminal stays in its new worktree; other worktrees are untouched.
grep -q -- "terminal close --terminal term_extra_shell" "$tmp/orca-title.log" && ok || bad "extra shell terminal should be closed ($(cat "$tmp/orca-title.log"))"
grep -q -- "terminal close --terminal term_extra_setup" "$tmp/orca-title.log" && ok || bad "extra setup terminal should be closed"
grep -q -- "terminal close --terminal term_fixture4242" "$tmp/orca-title.log" && bad "the worker terminal must stay open" || ok
grep -q -- "terminal close --terminal term_other_wt" "$tmp/orca-title.log" && bad "a terminal in another worktree must stay open" || ok
grep "terminal close" "$tmp/orca-title.log" | grep -q -- '--environment' && bad "a local close must not pass --environment" || ok
# Optional suffix: "#<issue>|<role>|free text" starts, and the role is read from the second field.
: >"$tmp/orca-title.log"
set +e
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-title.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  bash --noprofile --norc "$script" --run run_title --spec "$spec_file" --title "#123|qa-sdet|another try" --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --name n_title --repo "path:$clean" 2>"$tmp/title.err"
ec_title=$?
set -e
[ "$ec_title" = 0 ] && ok || bad "suffix title should start ($ec_title) $(cat "$tmp/title.err")"
grep -q -- "--task-title #123|qa-sdet|another try" "$tmp/orca-title.log" && ok || bad "suffix title should reach worker-start"

# Non-cursor: after host-check, worktree create + worker-start
set +e
unset -f python3 2>/dev/null || true
launch_state="$tmp/ws-launch-state"
mkdir -p "$launch_state/launches"
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  WORKER_STARTUP_STATE="$launch_state" \
  bash --noprofile --norc "$script" --run run_x --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --name n1 --repo "path:$clean" 2>"$tmp/run.err"
ec=$?
set -e
[ "$ec" = 0 ] && ok || bad "run claude exits 0 ($ec) $(cat "$tmp/run.err")"
# shellcheck disable=SC1091
. "$here/../lib/pr-review-gates.sh"
export WORKER_STARTUP_STATE="$launch_state"
pair=$(pr_review_gates_worker_agent_model ctx_9495d9c62de4) || true
[ "$pair" = $'claude\tclaude-sonnet-5-5-medium' ] && ok || bad "claude --run writes dispatch launch record ($pair)"
grep -qE '^1'$'\t''[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z'$'\t\t''fullstack-dev$' "$TEAM_AUDIT_DISPATCHES" && [ "$(head -1 "$TEAM_AUDIT_DISPATCHES")" = $'issue\tdispatched_at\trepo\trole' ] \
  && ok || bad "claude --run appends issue<TAB>dispatched_at<TAB>repo<TAB>role to the dispatch log ($(cat "$TEAM_AUDIT_DISPATCHES" 2>&1))"

# Dispatch log scoping: owner/repo from the Refs line, and no blank row when no issue number parses
dispatch_run() { # <spec_file> [repo selector]
  set +e
  env -u BASH_ENV \
    PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-dispatch.log" \
    FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
    WORKER_STARTUP_STATE="$launch_state" \
    bash --noprofile --norc "$script" --run run_x --spec "$1" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
    --from term_coord --name n1 --repo "${2:-path:$clean}" >/dev/null 2>&1
  set -e
}
sed 's#^Refs \#1#Refs mingster/dotfiles\#816#' "$spec_file" >"$tmp/spec-repo.txt"
dispatch_run "$tmp/spec-repo.txt"
grep -qE '^816'$'\t''[0-9T:Z-]+'$'\t''mingster/dotfiles'$'\t''fullstack-dev$' "$TEAM_AUDIT_DISPATCHES" \
  && ok || bad "Refs owner/repo#N records owner/repo in the dispatch log ($(cat "$TEAM_AUDIT_DISPATCHES" 2>&1))"
# 1411: a placed start binds its recent-start claim to the dispatch it created, before the readiness wait:
# the first worker-show read already finds the claim tied to the dispatch, so the live worker is not counted twice.
cat >"$tmp/orca-bind-order" <<EOS
#!/usr/bin/env bash
case " \$* " in *" orchestration worker-show "*) cp "$tmp/bind-recent.json" "$tmp/bind-at-show.json" 2>/dev/null ;; esac
exec "$orca_stub" "\$@"
EOS
chmod +x "$tmp/orca-bind-order"
rm -f "$tmp/bind-recent.json" "$tmp/bind-at-show.json"
WORKER_PLACEMENT_RECENT_FILE="$tmp/bind-recent.json" orca_stub="$tmp/orca-bind-order" dispatch_run "$tmp/spec-repo.txt"
[ "$(jq -r '.starts[-1].dispatch // empty' "$tmp/bind-recent.json" 2>/dev/null)" = ctx_9495d9c62de4 ] \
  && ok || bad "placed start binds its claim to the new dispatch ($(cat "$tmp/bind-recent.json" 2>&1))"
[ "$(jq -r '.starts[-1].dispatch // empty' "$tmp/bind-at-show.json" 2>/dev/null)" = ctx_9495d9c62de4 ] \
  && ok || bad "the claim is bound before the readiness wait ($(cat "$tmp/bind-at-show.json" 2>&1))"
# Short Refs #N: owner/repo comes from the origin of --repo id:<id> or a bare directory path
mkdir -p "$tmp/gh-repo"
git -C "$tmp/gh-repo" init -q
git -C "$tmp/gh-repo" remote add origin git@github.com:acme/widgets.git
sed 's#^Refs \#1#Refs \#817#' "$spec_file" >"$tmp/spec-short.txt"
dispatch_run "$tmp/spec-short.txt" id:repo_gh
grep -qE '^817'$'\t''[0-9T:Z-]+'$'\t''acme/widgets'$'\t''fullstack-dev$' "$TEAM_AUDIT_DISPATCHES" \
  && ok || bad "short Refs #N with --repo id:<id> resolves owner/repo ($(cat "$TEAM_AUDIT_DISPATCHES" 2>&1))"
sed 's#^Refs \#1#Refs \#818#' "$spec_file" >"$tmp/spec-short2.txt"
dispatch_run "$tmp/spec-short2.txt" "$tmp/gh-repo"
grep -qE '^818'$'\t''[0-9T:Z-]+'$'\t''acme/widgets'$'\t''fullstack-dev$' "$TEAM_AUDIT_DISPATCHES" \
  && ok || bad "short Refs #N with a bare directory --repo resolves owner/repo ($(cat "$TEAM_AUDIT_DISPATCHES" 2>&1))"
# An existing zero byte log still gets the header
: >"$TEAM_AUDIT_DISPATCHES"
dispatch_run "$tmp/spec-repo.txt"
[ "$(head -1 "$TEAM_AUDIT_DISPATCHES")" = $'issue\tdispatched_at\trepo\trole' ] \
  && ok || bad "zero byte dispatch log gets the header ($(cat "$TEAM_AUDIT_DISPATCHES" 2>&1))"
# 1839: an older 3 column log keeps its header and rows; a new start appends a 4 column row after them.
printf 'issue\tdispatched_at\trepo\n815\t2026-11-01T00:00:00Z\tmingster/dotfiles\n' >"$TEAM_AUDIT_DISPATCHES"
dispatch_run "$tmp/spec-repo.txt"
[ "$(head -2 "$TEAM_AUDIT_DISPATCHES")" = $'issue\tdispatched_at\trepo\n815\t2026-11-01T00:00:00Z\tmingster/dotfiles' ] \
  && grep -qE '^816'$'\t''[0-9T:Z-]+'$'\t''mingster/dotfiles'$'\t''fullstack-dev$' "$TEAM_AUDIT_DISPATCHES" \
  && ok || bad "1839: a 3 column log keeps its rows and gets a 4 column row ($(cat "$TEAM_AUDIT_DISPATCHES" 2>&1))"
: >"$TEAM_AUDIT_DISPATCHES"
dispatch_run "$tmp/spec-repo.txt"
rows_before=$(wc -l <"$TEAM_AUDIT_DISPATCHES")
# brief-lint accepts a multi-slash ref the dispatch parser does not read: no issue number, so no row
sed 's#^Refs \#1#Refs a/b/c\#5#' "$spec_file" >"$tmp/spec-noref.txt"
dispatch_run "$tmp/spec-noref.txt"
[ "$(wc -l <"$TEAM_AUDIT_DISPATCHES")" = "$rows_before" ] && ! grep -qE '^'$'\t' "$TEAM_AUDIT_DISPATCHES" \
  && ok || bad "brief without a parsable Refs ...#N appends no row ($(cat "$TEAM_AUDIT_DISPATCHES" 2>&1))"
grep -Fq "path:$wt_proof" "$tmp/orca.log" && ok || bad "worktree path with space passed to orchestration ($wt_proof)"
grep -q 'orchestration worker-start' "$tmp/orca.log" && ok || bad "orca log has worker-start"
grep -Fq "worktree set --worktree path:$wt_proof --workspace-status in-progress" "$tmp/orca.log" && ok || bad "new worktree set in-progress on the board ($(cat "$tmp/orca.log"))"
grep -Fq "worktree set --worktree path:$wt_proof --display-name #1|fullstack-dev" "$tmp/orca.log" && ok || bad "card display name is the --title value ($(cat "$tmp/orca.log"))"
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
  --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
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
  bash --noprofile --norc "$script" --run run_bad --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --name n1 --repo "path:$badbun" 2>"$tmp/run-bad.err"
ec_bad=$?
set -e
[ "$ec_bad" -ne 0 ] && ok || bad "unfixable bun pin --run should exit non-zero"
grep -q 'orchestration worker-start' "$tmp/orca-bad.log" && bad "orca should not worker-start when bun pin fails" || ok

# Cursor: copy script next to stub start-cursor-worker so exec hits the stub
helper_dir="$tmp/helpers"
mkdir -p "$helper_dir/lib"
cp "$script" "$helper_dir/worker-startup.sh"
cp "$here/../worker-preamble.py" "$helper_dir/worker-preamble.py"
cp "$here/../lib/pr-review-gates.sh" "$helper_dir/lib/pr-review-gates.sh"
cp "$here/../lib/automation-path.sh" "$helper_dir/lib/automation-path.sh"
cp "$here/../lib/app-path.sh" "$helper_dir/lib/app-path.sh"
cp "$here/../lib/board-status.sh" "$helper_dir/lib/board-status.sh"
cp "$here/../lib/worker-role.sh" "$helper_dir/lib/worker-role.sh"
cp "$here/../lib/dotfiles-fresh.sh" "$helper_dir/lib/dotfiles-fresh.sh"
[ ! -f "$here/../brief-lint.sh" ] || cp "$here/../brief-lint.sh" "$helper_dir/brief-lint.sh"
cp "$here/../worker-placement.py" "$helper_dir/worker-placement.py"
cp "$here/../grok-trust.sh" "$helper_dir/grok-trust.sh"
cp "$here/../usage-gate.py" "$helper_dir/usage-gate.py"
chmod +x "$helper_dir/worker-startup.sh" "$helper_dir/worker-placement.py"
cat >"$helper_dir/start-cursor-worker.sh" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp/cursor.args"
prev=; for a in "\$@"; do [ "\$prev" != --spec ] || cp "\$a" "$tmp/cursor.spec"; prev=\$a; done
exit 0
EOS
chmod +x "$helper_dir/start-cursor-worker.sh"
set +e
unset -f python3 2>/dev/null || true
env -u BASH_ENV \
  PATH="$helper_dir:$run_path" ORCA_CLI_COMMAND="$orca_stub" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  bash --noprofile --norc "$helper_dir/worker-startup.sh" --run run_y --spec "$spec_file" --title "#1|release-manager" --agent cursor --model composer-2.5 \
  --from term_coord --worktree-path /abs/wt 2>"$tmp/cursor.err"
ec=$?
set -e
[ "$ec" = 0 ] && ok || bad "cursor run exits 0 ($ec)"
grep -q -- '--run run_y' "$tmp/cursor.args" && grep -q composer-2.5 "$tmp/cursor.args" && ok || bad "cursor helper args"

# Cursor receives the same Finish block: a PR stays in review, and no PR goes to Done.
rm -f "$tmp/cursor.args"
set +e
env -u BASH_ENV \
  PATH="$helper_dir:$run_path" ORCA_CLI_COMMAND="$orca_stub" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  bash --noprofile --norc "$helper_dir/worker-startup.sh" --run run_cursor_fin --spec "$nofin_spec" --title "#1|release-manager" --agent cursor --model composer-2.5 \
  --from term_coord --worktree-path /abs/wt 2>"$tmp/cursor-fin.err"
ec_cfin=$?
set -e
[ "$ec_cfin" = 0 ] && ok || bad "cursor no-Finish brief exits 0 ($ec_cfin) $(cat "$tmp/cursor-fin.err")"
cursor_spec="$tmp/cursor.spec"
grep -q 'workspace-status in-review' "$cursor_spec" && ok || bad "cursor Finish should set in-review when there is a PR ($(cat "$cursor_spec" 2>/dev/null))"
grep -q 'Read these files before any work' "$cursor_spec" && ok || bad "cursor spec should carry the role preamble"
grep -q 'workspace-status completed' "$cursor_spec" && ok || bad "cursor Finish should set completed when there is no PR"
grep -q 'no pull request' "$cursor_spec" && ok || bad "cursor Finish should name the no-PR case"

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
cp "$here/../worker-preamble.py" "$rem_dotfiles/script/worker-preamble.py"
chmod +x "$rem_dotfiles/script/worker-startup.sh"
git -C "$rem_dotfiles" add script/worker-startup.sh script/worker-preamble.py
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
  *" repo list "*)
    for d in "$tmp"/*/; do printf '{"id":"repo_fx_%s","path":"%s"}\n' "\$(basename "\$d")" "\${d%/}"; done | jq -cs '{ok:true,result:{repos:.}}'
    exit 0
    ;;
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
    printf '%s\n' '{"ok":true,"result":{"dispatchId":"ctx_rem","state":"ready","terminal":"term_rem_worker"}}'
    exit 0
    ;;
  *" terminal rename "*|*" terminal set-pane-title "*)
    printf '%s\n' '{"ok":true,"result":{}}'
    exit 0
    ;;
  *" terminal list "*)
    printf '%s\n' '{"ok":true,"result":{"terminals":[{"handle":"term_rem_worker","worktreePath":"$wt_proof"},{"handle":"term_rem_extra","worktreePath":"$wt_proof"},{"handle":"term_rem_other","worktreePath":"/elsewhere/other"}]}}'
    exit 0
    ;;
  *" orchestration task-list "*|*" orchestration worker-list "*)
    printf '%s\n' '{"ok":true,"result":{"tasks":[],"workers":[]}}'
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
  bash --noprofile --norc "$script" --run run_rem_dirty --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
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
  bash --noprofile --norc "$script" --run run_rem_ok --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
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
grep -q 'host=host-overflow' <<<"$out_skip" && ok || bad "skipped unreadable host, coordinator host last, chose overflow ($out_skip)"

set +e
out_pickonly=$(FLEET_LOAD_SCRIPT="$tmp/fleet-load.sh" FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" \
  bash "$script" --pick-host-only --spec "$spec_file" 2>"$tmp/pickonly.err")
ec_pickonly=$?
set -e
[ "$ec_pickonly" = 0 ] && ok || bad "--pick-host-only exits 0 ($ec_pickonly)"
grep -q 'worker-placement: host=host-overflow' <<<"$out_pickonly" && ok || bad "pick-host-only output ($out_pickonly)"

# Explicit --on: remote start still uses the given environment (placement not applied)
: >"$tmp/orca-explicit-on.log"
set +e
unset -f python3 2>/dev/null || true
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_remote_stub" ORCA_STUB_LOG="$tmp/orca-explicit-on.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" FLEET_LOAD_SCRIPT="$tmp/load-all-over.sh" \
  bash --noprofile --norc "$script" --run run_explicit_on --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
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
grep -q 'host=host-overflow' <<<"$out_secrets" && ok || bad "code host for secrets prose ($out_secrets)"
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
  bash --noprofile --norc "$script" --run run_repo_map --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --name n_map --repo "id:local-app-id" 2>"$tmp/repo-map.err"
ec_repo_map=$?
set -e
[ "$ec_repo_map" = 0 ] && ok || bad "remote repo map run exits 0 ($ec_repo_map) $(cat "$tmp/repo-map.err")"
grep -q 'worktree create' "$tmp/orca-repo-map.log" && ok || bad "repo map worktree create logged"
grep -q 'id:remote-app-id' "$tmp/orca-repo-map.log" && ok || bad "worktree create uses mapped remote repo id ($(cat "$tmp/orca-repo-map.log"))"

# Explicit --on (#1230): a local repo id maps through worker_placement.repos; a remote id passes as given.
for on_case in local-app-id remote-app-id; do
  : >"$tmp/orca-on-$on_case.log"
  set +e
  unset -f python3 2>/dev/null || true
  env -u BASH_ENV \
    PATH="$run_path" ORCA_CLI_COMMAND="$orca_remote_stub" ORCA_STUB_LOG="$tmp/orca-on-$on_case.log" \
    FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
    FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" FLEET_LOAD_SCRIPT="$tmp/load-remote-map.sh" \
    bash --noprofile --norc "$script" --run "run_on_$on_case" --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
    --from term_coord --on host-remote --name "n_on_$on_case" --repo "id:$on_case" 2>"$tmp/on-$on_case.err"
  ec_on=$?
  set -e
  [ "$ec_on" = 0 ] && ok || bad "--on host-remote --repo id:$on_case exits 0 ($ec_on) $(cat "$tmp/on-$on_case.err")"
  grep 'worktree create' "$tmp/orca-on-$on_case.log" | grep -q -- '--repo id:remote-app-id' && ok \
    || bad "--on with id:$on_case creates the worktree from id:remote-app-id ($(grep 'worktree create' "$tmp/orca-on-$on_case.log"))"
done

# Remote worker titles: terminal rename and set-pane-title must carry --environment <host> (the local orca cannot see a remote handle).
for t in rename set-pane-title; do
  grep "terminal $t" "$tmp/orca-on-remote-app-id.log" | grep -q -- '--environment host-remote' && ok \
    || bad "remote worker: terminal $t must pass --environment host-remote ($(grep "terminal $t" "$tmp/orca-on-remote-app-id.log"))"
done

# #1653: the remote start closes the extra terminal on that host, keeps the worker and other worktrees.
grep -q -- "terminal close --terminal term_rem_extra --environment host-remote" "$tmp/orca-on-remote-app-id.log" && ok \
  || bad "remote extra terminal should be closed with --environment host-remote ($(grep 'terminal close' "$tmp/orca-on-remote-app-id.log"))"
grep "terminal close" "$tmp/orca-on-remote-app-id.log" | grep -q -e term_rem_worker -e term_rem_other && bad "remote close must keep the worker and other worktrees" || ok

# Brief lint with --on (#1233): lint_dir comes from the local --repo, so checks-local is required only for repos that have it.
sed 's#Run bash script/checks-local.sh\.#Run npm test.#' "$spec_file" >"$tmp/spec-no-checks.txt"
mkdir -p "$tmp/lint-nochecks" "$tmp/lint-haschecks/script"
: >"$tmp/lint-haschecks/script/checks-local.sh"
for lint_case in nochecks:0 haschecks:1; do
  lc_name=${lint_case%%:*}
  lc_want=${lint_case##*:}
  : >"$tmp/orca-lint-on-$lc_name.log"
  set +e
  unset -f python3 2>/dev/null || true
  env -u BASH_ENV \
    PATH="$run_path" ORCA_CLI_COMMAND="$orca_remote_stub" ORCA_STUB_LOG="$tmp/orca-lint-on-$lc_name.log" \
    FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
    FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" FLEET_LOAD_SCRIPT="$tmp/load-remote-map.sh" \
    bash --noprofile --norc "$script" --run "run_lint_on_$lc_name" --spec "$tmp/spec-no-checks.txt" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
    --from term_coord --on host-remote --name "n_lint_$lc_name" --repo "id:repo_fx_lint-$lc_name" 2>"$tmp/lint-on-$lc_name.err"
  lc_ec=$?
  set -e
  if [ "$lc_want" = 0 ]; then
    [ "$lc_ec" = 0 ] && ok || bad "--on remote with a repo lacking checks-local passes lint ($lc_ec) $(cat "$tmp/lint-on-$lc_name.err")"
  else
    [ "$lc_ec" -ne 0 ] && grep -q 'checks-local' "$tmp/lint-on-$lc_name.err" && ok \
      || bad "--on remote with a repo having checks-local still requires it ($lc_ec) $(cat "$tmp/lint-on-$lc_name.err")"
  fi
done

# --repo path:<dir> resolves to its Orca repo id before placement, so it places like id:.
mkdir -p "$tmp/pathapp"
sed 's/"local-app-id"/"repo_fx_pathapp"/' "$tmp/fleet-placement.json" >"$tmp/fleet-placement-path.json"
for case_dir in pathapp:0 pathunknown:1; do
  cd_name=${case_dir%%:*}
  : >"$tmp/orca-path-$cd_name.log"
  set +e
  env -u BASH_ENV \
    PATH="$run_path" ORCA_CLI_COMMAND="$orca_remote_stub" ORCA_STUB_LOG="$tmp/orca-path-$cd_name.log" \
    FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
    FLEET_WATCH_CONFIG="$tmp/fleet-placement-path.json" FLEET_LOAD_SCRIPT="$tmp/load-remote-map.sh" \
    bash --noprofile --norc "$script" --run "run_$cd_name" --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
    --from term_coord --name "n_$cd_name" --repo "path:$tmp/$cd_name" >"$tmp/path-$cd_name.out" 2>"$tmp/path-$cd_name.err"
  ec_path=$?
  set -e
  if [ "$cd_name" = pathapp ]; then
    [ "$ec_path" = 0 ] && ok || bad "path: repo run exits 0 ($ec_path) $(cat "$tmp/path-$cd_name.err")"
    grep -q 'worker-placement: host=host-remote' "$tmp/path-$cd_name.out" && ok || bad "path: repo is placed on the remote host ($(cat "$tmp/path-$cd_name.out"))"
    grep -q 'id:remote-app-id' "$tmp/orca-path-$cd_name.log" && ok || bad "path: repo uses the mapped remote repo id ($(cat "$tmp/orca-path-$cd_name.log"))"
  else
    [ "$ec_path" != 0 ] && ok || bad "unknown path: repo must be refused"
    grep -q 'refused: no Orca repo id for path:' "$tmp/path-$cd_name.err" && ok || bad "unknown path: names the refusal ($(cat "$tmp/path-$cd_name.err"))"
  fi
done

# Cursor on a placed remote host must receive that host's repo selector, not the caller's.
rm -f "$tmp/cursor.args"
set +e
env -u BASH_ENV \
  PATH="$helper_dir:$run_path" ORCA_CLI_COMMAND="$orca_stub" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" FLEET_LOAD_SCRIPT="$tmp/load-remote-map.sh" \
  bash --noprofile --norc "$helper_dir/worker-startup.sh" --run run_cursor_map --spec "$spec_file" --title "#1|release-manager" --agent cursor --model composer-2.5 \
  --from term_coord --name n_cmap --repo "id:local-app-id" 2>"$tmp/cursor-map.err"
ec_cmap=$?
set -e
[ "$ec_cmap" = 0 ] && ok || bad "cursor placed remote run exits 0 ($ec_cmap) $(cat "$tmp/cursor-map.err")"
grep -q -- '--on host-remote' "$tmp/cursor.args" && ok || bad "cursor helper receives the placed host ($(cat "$tmp/cursor.args" 2>/dev/null))"
grep -q -- '--repo id:remote-app-id' "$tmp/cursor.args" && ok || bad "cursor helper receives the placed repo ($(cat "$tmp/cursor.args" 2>/dev/null))"
grep -q 'id:local-app-id' "$tmp/cursor.args" && bad "cursor helper must not keep the local repo id ($(cat "$tmp/cursor.args"))" || ok

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
  bash --noprofile --norc "$script" --run run_nocfg --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
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
  bash --noprofile --norc "$script" --run run_wtpath --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
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
  bash --noprofile --norc "$script" --run run_wtpath2 --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
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
  bash --noprofile --norc "$helper_dir/worker-startup.sh" --run run_gate --spec "$spec_file" --title "#1|release-manager" --agent cursor --model composer-2.5 \
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
  bash --noprofile --norc "$helper_dir/worker-startup.sh" --run run_gate2 --spec "$spec_file" --title "#1|release-manager" --agent cursor --model composer-2.5 \
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

# Every remote host skipped for no mapping, while the local host has no readable load.
cat >"$tmp/fleet-remote-unmapped.json" <<'EOF'
{
  "local_host": "host-primary",
  "host_caps": {"host-primary": 4, "host-remote": 4, "host-remote-2": 4},
  "host_load_ceilings": {"host-primary": 12, "host-remote": 12, "host-remote-2": 12},
  "worker_placement": {"order": ["host-primary", "host-remote", "host-remote-2"], "repos": {}}
}
EOF
cat >"$tmp/load-primary-missing.sh" <<'EOS'
#!/usr/bin/env bash
printf 'host-remote cores=8 load=1.0 1.0 1.0\n'
printf 'host-remote-2 cores=8 load=1.0 1.0 1.0\n'
EOS
chmod +x "$tmp/load-primary-missing.sh"
set +e
out_remote_nomap=$(FLEET_LOAD_SCRIPT="$tmp/load-primary-missing.sh" FLEET_WATCH_CONFIG="$tmp/fleet-remote-unmapped.json" \
  "$python3_real" "$placement_py" pick --spec "$spec_file" --repo "id:local-app-id" 2>/dev/null)
ec_remote_nomap=$?
set -e
[ "$ec_remote_nomap" -ne 0 ] && ok || bad "every remote unmapped refuses ($ec_remote_nomap)"
grep -q 'no host has a repo mapping' <<<"$out_remote_nomap" && ok || bad "every remote unmapped names the repo mapping ($out_remote_nomap)"
grep -q 'no readable load' <<<"$out_remote_nomap" && bad "every remote unmapped must not say no readable load" || ok

# The shell refusal line, the one --run prints, says the same thing.
set +e
out_shell_nomap=$(FLEET_LOAD_SCRIPT="$tmp/load-primary-missing.sh" FLEET_WATCH_CONFIG="$tmp/fleet-remote-unmapped.json" \
  bash "$script" --pick-host-only --spec "$spec_file" --repo "id:local-app-id" 2>"$tmp/nomap-shell.err")
ec_shell_nomap=$?
set -e
[ "$ec_shell_nomap" = 4 ] && ok || bad "shell unmapped refusal exits 4 ($ec_shell_nomap) $(cat "$tmp/nomap-shell.err")"
grep -q 'no host has a repo mapping' "$tmp/nomap-shell.err" && ok || bad "shell refusal names the repo mapping ($(cat "$tmp/nomap-shell.err"))"
grep -q 'no readable load' "$tmp/nomap-shell.err" && bad "shell refusal must not say no readable load" || ok

# Builder route: fullstack-dev and light refuse antigravity, grok and cursor while pick allows Claude.
cat >"$tmp/pick-stub.py" <<'EOS'
#!/usr/bin/env python3
import os, sys
mode = os.environ.get("PICK_STUB_MODE", "cursor")
role = sys.argv[sys.argv.index("--role") + 1] if "--role" in sys.argv else ""
tier = sys.argv[sys.argv.index("--tier") + 1] if "--tier" in sys.argv else ""
with open(os.environ["PICK_STUB_LOG"], "a") as handle:
    handle.write(role + (" " + tier if tier else "") + "\n")
if tier == "strong":
    strong = os.environ.get("PICK_STUB_STRONG", "opus")
    if strong == "opus":
        print("--agent claude --model opus --effort high")
    elif strong == "argon":
        print("--agent antigravity --model gemini-4-argon-high")
    raise SystemExit(0 if strong in ("opus", "argon") else 3)
if mode == "cursor":
    print("--agent cursor --model grok-4.7-high")
    raise SystemExit(0)
if mode == "grok":
    print("--agent grok --model grok-4.7")
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
PICK_STUB_MODE=sonnet route_run "#5|fullstack-dev" cursor grok-4.7-high
[ "$route_ec" -ne 0 ] && ok || bad "fullstack-dev on cursor should be refused while claude is allowed (ec=$route_ec)"
grep -Fq -- '--agent claude --model sonnet' "$tmp/route.err" && ok || bad "refusal should print the pick ($(cat "$tmp/route.err"))"
grep -q 'worker-start' "$tmp/orca-route.log" && bad "refused builder must not reach worker-start" || ok
PICK_STUB_MODE=haiku route_run "#5|fullstack-dev-small" antigravity gemini-3.8-flash
[ "$route_ec" -ne 0 ] && ok || bad "light unit on antigravity should be refused while claude is allowed (ec=$route_ec)"
grep -Fq -- '--agent claude --model haiku' "$tmp/route.err" && ok || bad "light refusal should print the pick ($(cat "$tmp/route.err"))"
PICK_STUB_MODE=sonnet route_run "#5|fullstack-dev" grok grok-4.7
[ "$route_ec" -ne 0 ] && ok || bad "fullstack-dev on grok should be refused while claude is allowed (ec=$route_ec)"
rm -f "$route_state/route-override.log"
PICK_STUB_MODE=sonnet route_run "#5|fullstack-dev" cursor grok-4.7-high --route-override "claude is rate limited"
[ "$route_ec" = 0 ] && ok || bad "route override should let cursor through (ec=$route_ec) $(cat "$route_state/../route.err" 2>/dev/null)$(cat "$tmp/route.err")"
grep -Fq 'claude is rate limited' "$route_state/route-override.log" && ok || bad "route override should log the reason ($(cat "$route_state/route-override.log" 2>/dev/null))"
grep -q 'worker-start' "$tmp/orca-route.log" && ok || bad "route override should still start the worker"
PICK_STUB_MODE=cursor route_run "#5|fullstack-dev" cursor grok-4.7-high
[ "$route_ec" = 0 ] && ok || bad "cursor is allowed when pick says claude is blocked (ec=$route_ec) $(cat "$tmp/route.err")"
grep -q 'refused' "$tmp/route.err" && bad "claude-blocked pick must not refuse cursor" || ok
PICK_STUB_MODE=sonnet route_run "#5|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "claude builder is never refused by the builder gate (ec=$route_ec) $(cat "$tmp/route.err")"
: >"$tmp/pick-stub.log"
PICK_STUB_MODE=sonnet route_run "#5|elon" antigravity gemini-4-argon-medium
[ "$route_ec" = 0 ] && ok || bad "strong role must not hit the builder gate (ec=$route_ec) $(cat "$tmp/route.err")"
grep -q '^elon$' "$tmp/pick-stub.log" && bad "strong role must not be asked to yield to claude" || ok

# Grok (#1097): grok starts locally and --on only for hosts the fleet config lists in grok_hosts.
PICK_STUB_MODE=grok route_run "#5|fullstack-dev" grok grok-4.7
[ "$route_ec" = 0 ] && ok || bad "local grok start exits 0 (ec=$route_ec) $(cat "$tmp/route.err")"
grep -Fq -- '--agent grok --model grok-4.7' "$tmp/orca-route.log" && ok || bad "local grok start should reach worker-start ($(cat "$tmp/orca-route.log"))"
grep -Fq "[folders.\"$(cd "$wt_proof" && pwd -P)\"]" "$GROK_HOME/trusted_folders.toml" && ok || bad "local grok start should trust the worktree (#1312) ($(cat "$GROK_HOME/trusted_folders.toml" 2>&1))"
: >"$tmp/grok-bad-home"
: >"$tmp/orca-route.log"
GROK_HOME="$tmp/grok-bad-home/x" PICK_STUB_MODE=grok route_run "#5|fullstack-dev" grok grok-4.7
[ "$route_ec" -ne 0 ] && ok || bad "grok start must fail when the worktree cannot be trusted (ec=$route_ec)"
grep -q 'worker-start' "$tmp/orca-route.log" && bad "untrusted grok start must not reach worker-start" || ok
cat >"$helper_dir/start-remote-worker.sh" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp/grok-remote.args"
printf '%s\n' '{"ok":true,"result":{"dispatchId":"ctx_grok","state":"ready"}}'
exit 0
EOS
chmod +x "$helper_dir/start-remote-worker.sh"
cat >"$tmp/fleet-grok.json" <<EOF
{"hosts": ["grok-box", "plain-box"], "grok_hosts": ["grok-box"], "repos": ["$clean"]}
EOF
cat >"$tmp/fleet-nogrok.json" <<EOF
{"hosts": ["grok-box", "plain-box"], "repos": ["$clean"]}
EOF
grok_on() { # <fleet config> <environment>
  rm -f "$tmp/grok-remote.args"
  set +e
  env -u BASH_ENV \
    PATH="$helper_dir:$run_path" ORCA_CLI_COMMAND="$orca_stub" \
    FLEET_PULL_CONFIG="$1" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
    bash --noprofile --norc "$helper_dir/worker-startup.sh" --run run_grok --spec "$spec_file" --title "#1|release-manager" --agent grok --model grok-4.7 \
    --from term_coord --on "$2" --worktree-path /abs/wt >"$tmp/grok-on.out" 2>"$tmp/grok-on.err"
  grok_ec=$?
  set -e
}
grok_on "$tmp/fleet-grok.json" grok-box
[ "$grok_ec" = 0 ] && ok || bad "grok --on a host with the CLI exits 0 ($grok_ec) $(cat "$tmp/grok-on.err")"
grep -Fq -- '--agent grok --model grok-4.7' "$tmp/grok-remote.args" 2>/dev/null && grep -Fq -- '--on grok-box' "$tmp/grok-remote.args" && ok || bad "grok --on should reach the remote start ($(cat "$tmp/grok-remote.args" 2>/dev/null))"
grok_on "$tmp/fleet-grok.json" plain-box
[ "$grok_ec" -ne 0 ] && ok || bad "grok --on a host listed without the CLI should be refused"
grep -q 'no grok CLI' "$tmp/grok-on.err" && ok || bad "grok refusal should name the missing CLI ($(cat "$tmp/grok-on.err"))"
[ -e "$tmp/grok-remote.args" ] && bad "refused grok start must not reach the remote start" || ok
grok_on "$tmp/fleet-nogrok.json" grok-box
[ "$grok_ec" -ne 0 ] && ok || bad "grok --on with no grok_hosts config should be refused"

# A builder brief for a backlog line that a merged PR already carries is refused before worker-start.
ghbin="$tmp/ghbin"
mkdir -p "$ghbin"
cat >"$ghbin/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_LOG"
printf '[{"number":8111,"title":"release notes titles (#7298 L103)"},{"number":9,"title":"other (#7298 L1030)"}]\n' \
  | jq -r "${@: -1}"
EOS
chmod +x "$ghbin/gh"
spec_saved=$(cat "$spec_file")
printf 'Refs acme/app#7298\n\n# fullstack-dev - #7298 L103: titles\n\n%s\n' "$spec_saved" >"$spec_file"
run_path_saved=$run_path
run_path="$ghbin:$run_path"
export GH_STUB_LOG="$tmp/gh-stub.log"
: >"$GH_STUB_LOG"
PICK_STUB_MODE=sonnet route_run "#7298|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" -ne 0 ] && ok || bad "merged backlog line should be refused (ec=$route_ec)"
grep -q 'L103 already merged in PR #8111' "$tmp/route.err" && ok || bad "refusal should name the merged PR ($(cat "$tmp/route.err"))"
grep -q -- '-R acme/app' "$GH_STUB_LOG" && ok || bad "lookup should use the Refs repo ($(cat "$GH_STUB_LOG"))"
grep -q 'worker-start' "$tmp/orca-route.log" && bad "refused builder must not reach worker-start" || ok
printf 'Refs acme/app#7298\n\n# fullstack-dev - #7298 L10: titles\n\n%s\n' "$spec_saved" >"$spec_file"
PICK_STUB_MODE=sonnet route_run "#7298|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "L10 is not L103 or L1030 (ec=$route_ec) $(cat "$tmp/route.err")"
: >"$GH_STUB_LOG"
printf 'Refs acme/app#7298\n\n# qa-sdet - verify #7298 L103\n\n%s\n' "$spec_saved" >"$spec_file"
PICK_STUB_MODE=sonnet route_run "#7298|qa-sdet" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "a verifier for a merged line is not refused (ec=$route_ec) $(cat "$tmp/route.err")"
grep -q '^pr list' "$GH_STUB_LOG" && bad "non-builder must not look up merged PRs" || ok

# A builder brief whose Refs issue a merged PR already closed is refused unless --allow-delivered REASON (#1158).
cat >"$ghbin/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_LOG"
[ "${GH_STUB_FAIL:-}" != 1 ] || exit 1
printf '[{"number":8280,"body":"Part one.\\nCloses #7880"},{"number":8288,"body":"Fixes acme/app#7880"},{"number":8349,"body":"Refs #7880 only"},{"number":9,"body":"Closes #78801"}]\n' \
  | jq -r "${@: -1}"
EOS
printf 'Refs acme/app#7880\n\n# fullstack-dev - issue 7880\n\n%s\n' "$spec_saved" >"$spec_file"
: >"$GH_STUB_LOG"
PICK_STUB_MODE=sonnet route_run "#7880|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" -ne 0 ] && ok || bad "an issue closed by merged PRs should be refused (ec=$route_ec)"
grep -q 'already delivered by merged PR #8280, #8288;' "$tmp/route.err" && ok || bad "refusal should name only the closing PRs, not a Refs only PR (#1811) ($(cat "$tmp/route.err"))"
grep -q '#9\b' "$tmp/route.err" && bad "a longer number must not count" || ok
grep -q 'worker-start' "$tmp/orca-route.log" && bad "refused delivered issue must not reach worker-start" || ok
PICK_STUB_MODE=sonnet route_run "#7880|fullstack-dev" claude claude-sonnet-5-5-medium --allow-delivered "follow-up slice"
[ "$route_ec" = 0 ] && ok || bad "--allow-delivered should start anyway (ec=$route_ec) $(cat "$tmp/route.err")"
grep -q 'allow-delivered.*follow-up slice' "$tmp/route.err" && ok || bad "the override reason should be logged ($(cat "$tmp/route.err"))"
GH_STUB_FAIL=1 PICK_STUB_MODE=sonnet route_run "#7880|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "a failed gh call must not block the start (ec=$route_ec) $(cat "$tmp/route.err")"
# A child slice whose brief quotes its delivered parent first is checked as the child, the "#<n>|" title (#1811).
printf 'Refs acme/app#7880\n\n## Problem\n\nA child slice of the parent.\n\n%s\n' "$spec_saved" >"$spec_file"
: >"$GH_STUB_LOG"
PICK_STUB_MODE=sonnet route_run "#10099|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "a child slice must not be refused for its delivered parent (ec=$route_ec) $(cat "$tmp/route.err")"
grep -q -- '--search 10099 in:body' "$GH_STUB_LOG" && ok || bad "the delivered check should search the title issue ($(cat "$GH_STUB_LOG"))"
grep -q -- '-R acme/app' "$GH_STUB_LOG" && ok || bad "the child keeps the repo of the parent Refs line ($(cat "$GH_STUB_LOG"))"
grep -q 'issue view 10099 ' "$GH_STUB_LOG" && ok || bad "the claim should read the child issue ($(cat "$GH_STUB_LOG"))"
grep -Eq '(issue (view|edit)|in:body).*\b7880\b|7880 in:body' "$GH_STUB_LOG" && bad "the parent must not be checked or claimed ($(cat "$GH_STUB_LOG"))" || ok
# A builder start whose Allowed files overlap other work is refused unless --allow-overlap REASON (#1678).
overlap_cli="$tmp/overlap-cli.sh"
printf '#!/usr/bin/env bash\necho "overlap: script/a.sh is also in open PR #5" >&2\nexit 1\n' >"$overlap_cli"
printf 'Refs acme/app#7880\n\n# fullstack-dev - issue 7880\n\n%s\n' "$spec_saved" >"$spec_file"
ISSUE_OVERLAP_CLI="$overlap_cli" PICK_STUB_MODE=sonnet route_run "#7880|fullstack-dev" claude claude-sonnet-5-5-medium --allow-delivered "slice"
[ "$route_ec" -ne 0 ] && ok || bad "an overlapping builder start should be refused (ec=$route_ec)"
grep -q 'overlap: script/a.sh' "$tmp/route.err" && grep -q 'allow-overlap REASON' "$tmp/route.err" && ok || bad "refusal should print the overlap and the override ($(cat "$tmp/route.err"))"
ISSUE_OVERLAP_CLI="$overlap_cli" PICK_STUB_MODE=sonnet route_run "#7880|fullstack-dev" claude claude-sonnet-5-5-medium --allow-delivered "slice" --allow-overlap "same file, rebased"
[ "$route_ec" = 0 ] && ok || bad "--allow-overlap should start anyway (ec=$route_ec) $(cat "$tmp/route.err")"
grep -q 'allow-overlap.*same file, rebased' "$tmp/route.err" && ok || bad "the overlap reason should be logged ($(cat "$tmp/route.err"))"
# The overlap check also runs when the brief has no Refs line and the title names the issue.
printf '# fullstack-dev - issue 7880\n\n%s\n' "$spec_saved" >"$spec_file"
ISSUE_OVERLAP_CLI="$overlap_cli" PICK_STUB_MODE=sonnet route_run "#7880|fullstack-dev" claude claude-sonnet-5-5-medium --allow-delivered "slice"
[ "$route_ec" -ne 0 ] && grep -q 'overlap: script/a.sh' "$tmp/route.err" && ok || bad "a brief with no Refs line should still be checked from the title (ec=$route_ec)"
# #2025: a tier 0 PR with Review PASS at its head ships with no verifier, so a hand-started verifier is refused.
tier0_gh_saved=$(cat "$ghbin/gh"); tier0_spec_saved=$(cat "$spec_file")
cat >"$ghbin/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_LOG"
[ "$1 $2" = "pr view" ] && cat "$TIER0_PR_JSON"
exit 0
EOS
export TIER0_PR_JSON="$tmp/tier0-pr.json"
tier0_head=1111111111111111111111111111111111111111
tier0_pr() { # <state> <path> <reviewed head> [lines]
  jq -n --arg s "$1" --arg p "$2" --arg h "$tier0_head" --arg r "$3" --argjson n "${4:-52}" \
    '{state:$s, headRefOid:$h, files:[{path:$p, additions:$n, deletions:0}], comments:[{body:("Review: PASS head=" + $r + " model=none")}]}' >"$TIER0_PR_JSON"
}
printf 'Refs acme/app#7950\n\n# qa-sdet - verify PR 7951\n\n%s\n' "$spec_saved" >"$spec_file"
tier0_pr OPEN docs/guide.md "$tier0_head"
: >"$GH_STUB_LOG"
FLEET_WATCH= PICK_STUB_MODE=sonnet route_run "#7951|qa-sdet" claude claude-sonnet-5-5-medium
[ "$route_ec" = 2 ] && ok || bad "2025: a verifier for a tier 0 PR with Review PASS at head is refused (ec=$route_ec) $(cat "$tmp/route.err")"
grep -q 'PR #7951 is tier 0.*--allow-overlap REASON' "$tmp/route.err" && ok || bad "2025: refusal names the PR, tier 0 and the override ($(cat "$tmp/route.err"))"
grep -q 'worker-start' "$tmp/orca-route.log" && bad "2025: refused verifier must not reach worker-start" || ok
grep -q '^pr view 7951 -R acme/app ' "$GH_STUB_LOG" && ok || bad "2025: the PR is read from the Refs repo ($(cat "$GH_STUB_LOG"))"
FLEET_WATCH= PICK_STUB_MODE=sonnet route_run "#7951|qa-sdet" claude claude-sonnet-5-5-medium --allow-overlap "owner wants a second look"
[ "$route_ec" = 0 ] && ok || bad "2025: --allow-overlap starts the verifier (ec=$route_ec) $(cat "$tmp/route.err")"
grep -q 'allow-overlap.*tier 0.*owner wants a second look' "$tmp/route.err" && ok || bad "2025: the override reason is logged ($(cat "$tmp/route.err"))"
FLEET_WATCH=1 PICK_STUB_MODE=sonnet route_run "#7951|qa-sdet" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "2025: fleet-watch still starts a verifier after a failed auto-ship (ec=$route_ec) $(cat "$tmp/route.err")"
for tier0_case in "OPEN script/a.sh $tier0_head" "OPEN docs/guide.md 2222222222222222222222222222222222222222" \
  "MERGED docs/guide.md $tier0_head" "OPEN docs/guide.md $tier0_head 200"; do
  # shellcheck disable=SC2086
  tier0_pr $tier0_case
  FLEET_WATCH= PICK_STUB_MODE=sonnet route_run "#7951|qa-sdet" claude claude-sonnet-5-5-medium
  [ "$route_ec" = 0 ] && ok || bad "2025: verifier should start for $tier0_case (ec=$route_ec) $(cat "$tmp/route.err")"
done
# An edited or hidden Verdict must not mask an earlier FAIL at the same head: ship.sh ignores it, so a verifier may start.
for tier0_mask in includesCreatedEdit isMinimized; do
  jq -n --arg h "$tier0_head" --arg k "$tier0_mask" \
    '{state:"OPEN", headRefOid:$h, files:[{path:"docs/guide.md", additions:52, deletions:0}],
      comments:[{createdAt:"2026-01-01T00:00:01Z", body:("Review: PASS head=" + $h + " model=none")},
                {createdAt:"2026-01-01T00:00:02Z", body:("Verdict: FAIL head=" + $h)},
                {createdAt:"2026-01-01T00:00:03Z", body:("Verdict: PASS head=" + $h), ($k):true}]}' >"$TIER0_PR_JSON"
  FLEET_WATCH= PICK_STUB_MODE=sonnet route_run "#7951|qa-sdet" claude claude-sonnet-5-5-medium
  [ "$route_ec" = 0 ] && ok || bad "2025: a $tier0_mask Verdict PASS must not mask an earlier Verdict FAIL (ec=$route_ec) $(cat "$tmp/route.err")"
done
printf '%s\n' "$tier0_gh_saved" >"$ghbin/gh"; printf '%s\n' "$tier0_spec_saved" >"$spec_file"
# fleet-watch issue scan default title "builder - #<n>" is a builder too.
printf 'Refs acme/app#7880\n\n# builder - #7880\n\n%s\n' "$spec_saved" >"$spec_file"
PICK_STUB_MODE=sonnet route_run "#7880|builder" claude claude-sonnet-5-5-medium
[ "$route_ec" -ne 0 ] && ok || bad "the scan default builder title should be refused (ec=$route_ec)"
printf 'Refs acme/app#7881\n\n# fullstack-dev - issue 7881\n\n%s\n' "$spec_saved" >"$spec_file"
PICK_STUB_MODE=sonnet route_run "#7881|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "an issue no merged PR closed should start (ec=$route_ec) $(cat "$tmp/route.err")"

# A builder start claims its issue before the worker starts (#1192, #1216, #1692). A verify or rework start leaves it.
cat >"$ghbin/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_LOG"
case "$1 $2" in
  "pr list") printf '[]\n' | jq -r "${@: -1}" ;;
esac
EOS
printf 'Refs acme/app#7900\n\n# fullstack-dev - issue 7900\n\n%s\n' "$spec_saved" >"$spec_file"
: >"$GH_STUB_LOG"
PICK_STUB_MODE=sonnet route_run "#7900|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "builder start for a ready issue should succeed (ec=$route_ec) $(cat "$tmp/route.err")"
grep -Fxq -- 'issue edit 7900 -R acme/app --remove-label ready-for-agent --add-label status:進行中 --remove-label needs-triage' "$GH_STUB_LOG" && ok || bad "started builder should drop ready-for-agent and set status:進行中 ($(cat "$GH_STUB_LOG"))"
: >"$GH_STUB_LOG"
PICK_STUB_MODE=sonnet route_run "#7900|qa-sdet" claude claude-sonnet-5-5-medium
grep -q '^issue edit' "$GH_STUB_LOG" && bad "a qa-sdet start must not edit issue labels (#1271)" || ok

# #1692: the claim lands before worker-start; a failed start puts back the labels it changed; an unreadable label set is not claimed.
prior_spec=$(cat "$spec_file")
cat >"$ghbin/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_LOG"
case "$1 $2" in
  "issue view") [ -z "${GH_VIEW_FAIL:-}" ] || exit 1; printf '%s\n' "${GH_LABELS:-}" ;;
  "pr list") printf '[]\n' | jq -r "${@: -1}" ;;
esac
exit 0
EOS
chmod +x "$ghbin/gh"
printf 'Refs acme/app#7901\n\n# fullstack-dev - issue 7901\n\n%s\n' "$spec_saved" >"$spec_file"
export GH_LABELS=$'ready-for-agent\nP2'
: >"$tmp/orca-route.log"
saved_gh_log=$GH_STUB_LOG
export GH_STUB_LOG="$tmp/orca-route.log"
PICK_STUB_MODE=sonnet route_run "#7901|fullstack-dev" claude claude-sonnet-5-5-medium
export GH_STUB_LOG=$saved_gh_log
[ "$route_ec" = 0 ] && ok || bad "claim order: a builder start should succeed (ec=$route_ec) $(cat "$tmp/route.err")"
claim_line=$(grep -n '^issue edit 7901 -R acme/app --remove-label ready-for-agent --add-label status:進行中' "$tmp/orca-route.log" | head -1 | cut -d: -f1)
start_line=$(grep -n 'orchestration worker-start' "$tmp/orca-route.log" | head -1 | cut -d: -f1)
[ -n "$claim_line" ] && [ -n "$start_line" ] && [ "$claim_line" -lt "$start_line" ] && ok || bad "the claim must land before worker-start (claim=$claim_line start=$start_line)"

# A failed worker-start restores ready-for-agent and takes status:進行中 back off.
cat >"$tmp/orca-fail" <<EOS
#!/usr/bin/env bash
case " \$* " in *" orchestration worker-start "*) echo "worker-start refused" >&2; exit 1 ;; esac
exec "$tmp/orca" "\$@"
EOS
chmod +x "$tmp/orca-fail"
: >"$GH_STUB_LOG"
orca_stub="$tmp/orca-fail" PICK_STUB_MODE=sonnet route_run "#7901|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" -ne 0 ] && ok || bad "a refused worker-start must fail the start"
grep -Fxq -- 'issue edit 7901 -R acme/app --add-label ready-for-agent --remove-label status:進行中' "$GH_STUB_LOG" && ok || bad "a failed start must restore ready-for-agent and drop status:進行中 ($(cat "$GH_STUB_LOG"))"

# A label set that cannot be read is not claimed: no edit, and the start goes on.
export GH_VIEW_FAIL=1
: >"$GH_STUB_LOG"
PICK_STUB_MODE=sonnet route_run "#7901|fullstack-dev" claude claude-sonnet-5-5-medium
unset GH_VIEW_FAIL GH_LABELS
grep -q '^issue edit' "$GH_STUB_LOG" && bad "an unreadable label set must not be claimed ($(cat "$GH_STUB_LOG"))" || ok
[ "$route_ec" = 0 ] && ok || bad "an unreadable label set must not block the start (ec=$route_ec)"
printf '%s\n' "$prior_spec" >"$spec_file"

# A complex builder start (#1396): fullstack-dev-strong, or a Refs issue labelled size:L, takes the Strong pick.
cat >"$ghbin/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_LOG"
[ "${GH_STUB_FAIL:-}" != 1 ] || exit 1
case "$1 $2" in
  "pr list") printf '[]\n' | jq -r "${@: -1}" ;;
  "issue view") printf '{"labels":[{"name":"P2"},{"name":"%s"}]}\n' "${GH_STUB_SIZE:-size:S}" | jq -r "${@: -1}" ;;
esac
EOS
PICK_STUB_MODE=sonnet route_run "#7900|fullstack-dev-strong" claude sonnet
[ "$route_ec" -ne 0 ] && ok || bad "fullstack-dev-strong on sonnet should be refused while opus is allowed (ec=$route_ec)"
grep -Fq -- '--agent claude --model opus --effort high' "$tmp/route.err" && ok || bad "strong refusal should print the Strong pick ($(cat "$tmp/route.err"))"
grep -Fxq 'fullstack-dev-strong strong' "$tmp/pick-stub.log" && ok || bad "strong start should pick with --tier strong ($(cat "$tmp/pick-stub.log"))"
grep -q 'worker-start' "$tmp/orca-route.log" && bad "refused strong start must not reach worker-start" || ok
PICK_STUB_MODE=sonnet route_run "#7900|fullstack-dev-strong" claude opus
[ "$route_ec" = 0 ] && ok || bad "fullstack-dev-strong on opus should start (ec=$route_ec) $(cat "$tmp/route.err")"
PICK_STUB_MODE=sonnet PICK_STUB_STRONG=argon route_run "#7900|fullstack-dev-strong" antigravity gemini-4-argon-medium
[ "$route_ec" -ne 0 ] && ok || bad "strong start on argon medium should be refused while argon high is allowed (ec=$route_ec)"
PICK_STUB_MODE=sonnet PICK_STUB_STRONG=argon route_run "#7900|fullstack-dev-strong" antigravity gemini-4-argon-high
[ "$route_ec" = 0 ] && ok || bad "strong start on argon high should start (ec=$route_ec) $(cat "$tmp/route.err")"
PICK_STUB_MODE=sonnet PICK_STUB_STRONG=none route_run "#7900|fullstack-dev-strong" claude sonnet
[ "$route_ec" = 0 ] && ok || bad "with no Strong model available a sonnet start is not refused (ec=$route_ec) $(cat "$tmp/route.err")"
rm -f "$route_state/route-override.log"
PICK_STUB_MODE=sonnet route_run "#7900|fullstack-dev-strong" claude sonnet --route-override "opus is slow today"
[ "$route_ec" = 0 ] && ok || bad "route override lets a strong start run on sonnet (ec=$route_ec) $(cat "$tmp/route.err")"
grep -Fq 'opus is slow today' "$route_state/route-override.log" && ok || bad "strong route override should log the reason"
GH_STUB_SIZE=size:L PICK_STUB_MODE=sonnet route_run "#7900|fullstack-dev" claude sonnet
[ "$route_ec" -ne 0 ] && ok || bad "a size:L issue on sonnet should be refused while opus is allowed (ec=$route_ec)"
grep -Fq 'issue view 7900 -R acme/app' "$GH_STUB_LOG" && ok || bad "size check should read the Refs issue ($(cat "$GH_STUB_LOG"))"
GH_STUB_SIZE=size:L PICK_STUB_MODE=sonnet route_run "#7900|fullstack-dev" claude claude-opus-5-5-high
[ "$route_ec" = 0 ] && ok || bad "a size:L issue on an opus model id should start (ec=$route_ec) $(cat "$tmp/route.err")"
GH_STUB_SIZE=size:L PICK_STUB_MODE=sonnet route_run "#7900|fullstack-dev-small" claude haiku
[ "$route_ec" -ne 0 ] && ok || bad "a size:L issue on a Light start should be refused (ec=$route_ec)"
PICK_STUB_MODE=sonnet route_run "#7900|fullstack-dev" claude sonnet
[ "$route_ec" = 0 ] && ok || bad "a simple issue keeps sonnet (ec=$route_ec) $(cat "$tmp/route.err")"
grep -q ' strong$' "$tmp/pick-stub.log" && bad "a simple issue must not ask for the Strong pick" || ok
GH_STUB_FAIL=1 PICK_STUB_MODE=sonnet route_run "#7900|fullstack-dev" claude sonnet
[ "$route_ec" = 0 ] && ok || bad "a failed size lookup must not block the start (ec=$route_ec) $(cat "$tmp/route.err")"

# A handoff line has no --from: the coordinator's own handle is the sender (#1192).
: >"$tmp/orca-route.log"
set +e
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-route.log" ORCA_TERMINAL_HANDLE=term_coordinator_env \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  USAGE_GATE_PICK="$tmp/pick-stub.py" USAGE_GATE_PRESETS="$root/.orca/presets.json" \
  PICK_STUB_MODE=sonnet PICK_STUB_LOG="$tmp/pick-stub.log" WORKER_STARTUP_STATE="$route_state" \
  bash --noprofile --norc "$script" --run run_route --spec "$spec_file" --title "#7900|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
  --name nroute --repo "path:$clean" >"$tmp/route.out" 2>"$tmp/route.err"
route_ec=$?
set -e
[ "$route_ec" = 0 ] && ok || bad "a start without --from should use ORCA_TERMINAL_HANDLE (ec=$route_ec) $(cat "$tmp/route.err")"
grep -Fq -- '--from term_coordinator_env' "$tmp/orca-route.log" && ok || bad "worker-start should carry the env handle ($(cat "$tmp/orca-route.log"))"
run_path=$run_path_saved
printf '%s\n' "$spec_saved" >"$spec_file"

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
  *" orchestration task-list "*|*" orchestration worker-list "*) printf '%s\n' '{"ok":true,"result":{"tasks":[],"workers":[]}}'; exit 0 ;;
esac
exit 99
EOS
chmod +x "$tmp/orca-link"
set +e
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$tmp/orca-link" ORCA_STUB_LOG="$tmp/orca-link.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  WORKER_STARTUP_STATE="$tmp/link-state" \
  bash --noprofile --norc "$script" --run run_x --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model sonnet \
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
  *"orchestration worker-stop"*)
    printf '%s\n' '{"ok":true,"result":{"stopped":true}}'
    ;;
  *"orchestration task-list"*|*"orchestration worker-list"*)
    printf '%s\n' '{"ok":true,"result":{"tasks":[],"workers":[]}}'
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
    AGY_WT="$wt_proof" AGY_SCREEN="$1" WORKER_STARTUP_AGY_WAIT=0 AGY_UNAVAILABLE_STATE="$tmp/agy-unavailable.json" \
    bash --noprofile --norc "$script" --run run_agy --spec "$spec_file" --title "#1|fullstack-dev" \
    --agent antigravity --model gemini-4-argon-medium \
    --from term_coord --name nagy --repo "path:$clean" >"$tmp/agy.out" 2>"$2"
  agy_ec=$?
  set -e
}
# 1240: the sign-in screen stops the dispatch and restarts the same brief on claude; a working screen starts once.
agy_run "$tmp/agy-login.txt" "$tmp/agy-login.err"
[ "$agy_ec" = 0 ] && ok || bad "antigravity sign-in screen falls back and exits 0 ($agy_ec) $(cat "$tmp/agy-login.err")"
grep -q '^agy-signin: host=.* fell back to claude$' "$tmp/agy.out" && ok || bad "fallback line missing ($(cat "$tmp/agy.out"))"
grep -q 'orchestration worker-stop --dispatch ctx_agy' "$tmp/orca-agy.log" && ok || bad "sign-in worker is stopped ($(cat "$tmp/orca-agy.log"))"
[ "$(grep -c 'orchestration worker-start' "$tmp/orca-agy.log")" = 2 ] && ok || bad "sign-in start is repeated once ($(cat "$tmp/orca-agy.log"))"
grep -q -- '--agent antigravity --model' "$tmp/orca-agy.log" && grep -q -- '--agent claude --model sonnet' "$tmp/orca-agy.log" && ok || bad "restart is on claude sonnet after an antigravity start"
# 1966: the sign-in screen marks the host first, so the next pick skips it.
FLEET_WATCH_CONFIG="$tmp/no-agy-fleet.json" AGY_UNAVAILABLE_STATE="$tmp/agy-unavailable.json" "$PYTHON" "$here/../agy-signin.py" unavailable "$(hostname -s)" && ok || bad "1966: the sign-in screen marks the host"
rm -f "$tmp/agy-unavailable.json"
agy_run "$tmp/agy-ok.txt" "$tmp/agy-ok.err"
[ "$agy_ec" = 0 ] && ok || bad "normal antigravity screen should exit 0 ($agy_ec) $(cat "$tmp/agy-ok.err")"
grep -q 'agy-signin' "$tmp/agy.out" && bad "normal antigravity screen must not fall back" || ok
[ "$(grep -c 'orchestration worker-start' "$tmp/orca-agy.log")" = 1 ] && ok || bad "normal antigravity screen starts once"
grep -q 'worker-stop' "$tmp/orca-agy.log" && bad "normal antigravity screen must not stop the worker" || ok
# A host already marked agy-unavailable starts on claude without the first antigravity start.
agy_unavailable_run() {
  : >"$tmp/orca-agy.log"
  host_label=$(hostname -s | tr '[:upper:]' '[:lower:]')
  FLEET_WATCH_CONFIG="$tmp/no-agy-fleet.json" AGY_UNAVAILABLE_STATE="$tmp/agy-unavailable.json" "$PYTHON" "$here/../agy-signin.py" mark "$host_label" >/dev/null
  agy_run "$tmp/agy-ok.txt" "$tmp/agy-unavailable.err"
}
agy_unavailable_run
[ "$agy_ec" = 0 ] && ok || bad "unavailable host start exits 0 ($agy_ec) $(cat "$tmp/agy-unavailable.err")"
grep -q 'is agy-unavailable, using claude' "$tmp/agy.out" && ok || bad "unavailable host line missing ($(cat "$tmp/agy.out"))"
[ "$(grep -c 'orchestration worker-start' "$tmp/orca-agy.log")" = 1 ] && ok || bad "unavailable host starts once"
grep -q -- '--agent claude --model sonnet' "$tmp/orca-agy.log" && ! grep -q -- '--agent antigravity' "$tmp/orca-agy.log" && ok || bad "unavailable host starts on claude only"

# 1832: WORKER_STARTUP_AGY_SIGNIN=exit. A signed out antigravity start marks the host, stops and releases the dispatch,
# puts the labels back, removes the worktree it made and exits 10; its last stderr line names the host and notify|known.
agyx_gh="$tmp/agyx-gh"
mkdir -p "$agyx_gh"
cat >"$agyx_gh/gh" <<'EOS'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$ORCA_STUB_LOG"
case "$1 $2" in
  "issue view") printf '%s\n' "${GH_LABELS:-}" ;;
  "pr list") printf '[]\n' | jq -r "${@: -1}" ;;
esac
exit 0
EOS
chmod +x "$agyx_gh/gh"
cat >"$tmp/orca-agyx" <<'EOS'
#!/usr/bin/env bash
log="${ORCA_STUB_LOG:-/dev/null}"
printf '%s\n' "$*" >>"$log"
case "$*" in
  *"worktree create"*) printf '%s\n' "{\"ok\":true,\"result\":{\"worktree\":{\"path\":\"${AGY_WT:?}\"}}}" ;;
  *"worktree rm"*) printf '%s\n' '{"ok":true}' ;;
  *"orchestration worker-start"*) printf '%s\n' '{"ok":true,"result":{"dispatchId":"ctx_agy","taskId":"task_agy","runId":"run_agy","state":"ready","agent":"antigravity","terminal":"term_agy"}}' ;;
  *"orchestration worker-stop"*) printf '%s\n' '{"ok":true,"result":{"stopped":true}}' ;;
  *"orchestration worker-release --dispatch ctx_agy --environment"*)
    [ -z "${AGY_REMOTE_RELEASE_FAIL:-}" ] || { echo "remote release refused" >&2; exit 1; }
    printf '%s\n' '{"ok":true}' ;;
  *"orchestration worker-release"*) printf '%s\n' '{"ok":true}' ;;
  *"orchestration task-list"*|*"orchestration worker-list"*) printf '%s\n' '{"ok":true,"result":{"tasks":[],"workers":[]}}' ;;
  *"terminal read"*)
    python3 -c '
import json, os
print(json.dumps({"ok": True, "result": {"terminal": {"tail": open(os.environ["AGY_SCREEN"]).read().splitlines()}}}))' ;;
  *) printf 'unexpected orca: %s\n' "$*" >&2; exit 99 ;;
esac
EOS
chmod +x "$tmp/orca-agyx"
cp "$here/../agy-signin.py" "$helper_dir/agy-signin.py"
cp "$here/../check-issue-overlap.sh" "$helper_dir/check-issue-overlap.sh"
agyx_spec="$tmp/agyx-spec.txt"
printf 'Refs acme/app#7950\n\n# fullstack-dev - issue 7950\n\n%s\n' "$(cat "$spec_file")" >"$agyx_spec"
agyx_local() { # <title> [state file] (env WORKER_STARTUP_AGY_SIGNIN=exit unless AGY_X_NOENV)
  : >"$tmp/orca-agyx.log"
  set +e
  unset -f python3 2>/dev/null || true
  env -u BASH_ENV ${AGY_X_NOENV:-WORKER_STARTUP_AGY_SIGNIN=exit} \
    PATH="$agyx_gh:$run_path" ORCA_CLI_COMMAND="$tmp/orca-agyx" ORCA_STUB_LOG="$tmp/orca-agyx.log" \
    FLEET_PULL_CONFIG="$tmp/fleet.json" FLEET_WATCH_CONFIG="$tmp/no-agy-fleet.json" \
    PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" GH_LABELS="${GH_LABELS:-}" \
    AGY_WT="$wt_proof" AGY_SCREEN="$tmp/agy-login.txt" WORKER_STARTUP_AGY_WAIT=0 \
    AGY_UNAVAILABLE_STATE="${2:-$tmp/agyx-state.json}" \
    bash --noprofile --norc "$script" --run run_agy --spec "$agyx_spec" --title "$1" \
    --agent antigravity --model gemini-4-argon-medium \
    --from term_coord --name nagyx --repo "path:$clean" >"$tmp/agyx.out" 2>"$tmp/agyx.err"
  agyx_ec=$?
  set -e
}
host_label=$(hostname -s | tr '[:upper:]' '[:lower:]')
rm -f "$tmp/agyx-state.json"
export GH_LABELS=$'ready-for-agent\nP2'
agyx_local "#7950|fullstack-dev"
[ "$agyx_ec" = 10 ] && ok || bad "1832: a signed out issue start exits 10 ($agyx_ec) $(cat "$tmp/agyx.err")"
[ "$(tail -n 1 "$tmp/agyx.err")" = "agy-signin: host=$host_label notify" ] && ok || bad "1832: last stderr line is the notify line ($(tail -n 2 "$tmp/agyx.err"))"
FLEET_WATCH_CONFIG="$tmp/no-agy-fleet.json" AGY_UNAVAILABLE_STATE="$tmp/agyx-state.json" "$PYTHON" "$here/../agy-signin.py" unavailable "$host_label" && ok || bad "1832: the host is marked"
grep -q 'orchestration worker-stop --dispatch ctx_agy' "$tmp/orca-agyx.log" && ok || bad "1832: the dispatch is stopped"
grep -q 'orchestration worker-release --dispatch ctx_agy' "$tmp/orca-agyx.log" && ok || bad "1832: the dispatch is released"
grep 'worker-stop\|worker-release' "$tmp/orca-agyx.log" | grep -q -- '--environment' && bad "1832: a local start passes no --environment" || ok
grep -q 'worktree rm' "$tmp/orca-agyx.log" && ok || bad "1832: the worktree this start created is removed ($(cat "$tmp/orca-agyx.log"))"
grep -Fq 'issue edit 7950 -R acme/app --add-label ready-for-agent --remove-label status:進行中' "$tmp/orca-agyx.log" && ok || bad "1832: the labels are put back ($(grep 'gh ' "$tmp/orca-agyx.log"))"
[ "$(grep -c 'orchestration worker-start' "$tmp/orca-agyx.log")" = 1 ] && ok || bad "1832: no second start in process"
# The next start sees the mark and starts on claude; the pre-marked host does not print notify.
agyx_local "#7950|fullstack-dev"
[ "$agyx_ec" = 0 ] && ok || bad "1832: the next start on a marked host exits 0 ($agyx_ec) $(cat "$tmp/agyx.err")"
grep -q -- '--agent claude --model sonnet' "$tmp/orca-agyx.log" && ! grep -q -- '--agent antigravity' "$tmp/orca-agyx.log" && ok || bad "1832: the next start is claude only"
# A host notified less than 6 hours ago but whose mark ran out prints known.
rm -f "$tmp/agyx-state2.json"
FLEET_WATCH_CONFIG="$tmp/no-agy-fleet.json" AGY_UNAVAILABLE_STATE="$tmp/agyx-state2.json" "$PYTHON" "$here/../agy-signin.py" mark "$host_label" >/dev/null
"$PYTHON" -c "
import json,sys
p=sys.argv[1]; d=json.load(open(p));
for r in d.values(): r['until']=0
json.dump(d,open(p,'w'))" "$tmp/agyx-state2.json"
agyx_local "#7950|fullstack-dev" "$tmp/agyx-state2.json"
[ "$agyx_ec" = 10 ] && ok || bad "1832: a host whose mark ran out exits 10 again ($agyx_ec)"
[ "$(tail -n 1 "$tmp/agyx.err")" = "agy-signin: host=$host_label known" ] && ok || bad "1832: a recently notified host prints known ($(tail -n 2 "$tmp/agyx.err"))"
# qa-sdet and a start whose claim failed: exit 10, no label edited.
rm -f "$tmp/agyx-state.json"
printf 'Refs acme/app#7951\n\n# qa-sdet - verify\n\n%s\n' "$(cat "$spec_file")" >"$agyx_spec"
agyx_local "#7951|qa-sdet"
[ "$agyx_ec" = 10 ] && ok || bad "1832: a qa-sdet issue start exits 10 too ($agyx_ec)"
grep -q 'issue edit' "$tmp/orca-agyx.log" && bad "1832: a qa-sdet start edits no label" || ok
rm -f "$tmp/agyx-state.json"
printf 'Refs acme/app#7952\n\n# fullstack-dev - issue 7952\n\n%s\n' "$(cat "$spec_file")" >"$agyx_spec"
cp "$agyx_gh/gh" "$agyx_gh/gh.real"
cat >"$agyx_gh/gh" <<'EOS'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$ORCA_STUB_LOG"
[ "$1 $2" != "issue view" ] || exit 1
exit 0
EOS
agyx_local "#7952|fullstack-dev"
[ "$agyx_ec" = 10 ] && ok || bad "1832: an unclaimed builder start exits 10 ($agyx_ec)"
grep -q 'issue edit' "$tmp/orca-agyx.log" && bad "1832: an unclaimed start edits no label" || ok
mv "$agyx_gh/gh.real" "$agyx_gh/gh"
# Without the variable (a verifier, fixer, rework or hand start) the in process fallback is unchanged.
rm -f "$tmp/agyx-state.json"
AGY_X_NOENV=A=B agyx_local "#7952|fullstack-dev"
[ "$agyx_ec" = 0 ] && ok || bad "1832: without the variable the sign-in start falls back in process ($agyx_ec)"
grep -q 'worker-release' "$tmp/orca-agyx.log" && bad "1832: without the variable nothing is released" || ok
# Remote: the remote release fails, the coordinator release still runs, the start exits 10 and a reused worktree is kept.
cat >"$helper_dir/start-remote-worker.sh" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp/agyx-remote.args"
printf '%s\n' '{"ok":true,"result":{"dispatchId":"ctx_agy","taskId":"task_agy","runId":"run_agy","state":"ready","agent":"antigravity","terminal":"term_agy"}}'
EOS
chmod +x "$helper_dir/start-remote-worker.sh"
cat >"$tmp/fleet-agyx.json" <<EOF
{"hosts": ["agy-box"], "repos": ["$clean"]}
EOF
agyx_remote() {
  : >"$tmp/orca-agyx.log"; rm -f "$tmp/agyx-state.json" "$tmp/agyx-remote.args"
  set +e
  env -u BASH_ENV WORKER_STARTUP_AGY_SIGNIN=exit PATH="$agyx_gh:$run_path" ORCA_CLI_COMMAND="$tmp/orca-agyx" ORCA_STUB_LOG="$tmp/orca-agyx.log" \
    FLEET_PULL_CONFIG="$tmp/fleet-agyx.json" FLEET_WATCH_CONFIG="$tmp/no-agy-fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
    AGY_WT="$wt_proof" AGY_SCREEN="$tmp/agy-login.txt" WORKER_STARTUP_AGY_WAIT=0 AGY_UNAVAILABLE_STATE="$tmp/agyx-state.json" \
    AGY_REMOTE_RELEASE_FAIL="${AGY_REMOTE_RELEASE_FAIL:-}" GH_LABELS="$GH_LABELS" \
    bash --noprofile --norc "$helper_dir/worker-startup.sh" --run run_agy --spec "$agyx_spec" --title "#7952|fullstack-dev" --agent antigravity \
    --model gemini-4-argon-medium --from term_coord --on agy-box --worktree-path /abs/wt >"$tmp/agyx.out" 2>"$tmp/agyx.err"
  agyx_ec=$?
  set -e
}
AGY_REMOTE_RELEASE_FAIL=1 agyx_remote
[ "$agyx_ec" = 10 ] && ok || bad "1832: a failed remote release still exits 10 ($agyx_ec) $(cat "$tmp/agyx.err")"
grep -q 'worker-release --dispatch ctx_agy --environment agy-box' "$tmp/orca-agyx.log" && ok || bad "1832: the remote release runs with --environment"
grep -q 'worker-release --dispatch ctx_agy$' "$tmp/orca-agyx.log" && ok || bad "1832: the coordinator release still runs ($(grep release "$tmp/orca-agyx.log"))"
grep -q 'worker-stop --dispatch ctx_agy --environment agy-box' "$tmp/orca-agyx.log" && ok || bad "1832: the remote stop carries --environment"
[ "$(tail -n 1 "$tmp/agyx.err")" = "agy-signin: host=agy-box notify" ] && ok || bad "1832: remote last line names the remote host ($(tail -n 2 "$tmp/agyx.err"))"
grep -q 'worktree rm' "$tmp/orca-agyx.log" && bad "1832: a reused worktree (--worktree-path) is not removed" || ok
# The mark fails: no exit 10, the dispatch is still stopped and the start falls back to claude in process.
cp "$helper_dir/agy-signin.py" "$tmp/agy-signin.real.py"
cat >"$helper_dir/agy-signin.py" <<'EOS'
#!/usr/bin/env python3
import sys
if sys.argv[1:2] == ['mark']:
    raise SystemExit(1)
raise SystemExit(0 if sys.argv[1:2] in (['match'], ['usable']) else 1)
EOS
agyx_remote
[ "$agyx_ec" = 0 ] && ok || bad "1832: a failed mark does not exit 10 ($agyx_ec) $(cat "$tmp/agyx.err")"
grep -q 'could not mark' "$tmp/agyx.err" && ok || bad "1832: a failed mark is logged"
grep -q 'worker-stop --dispatch ctx_agy' "$tmp/orca-agyx.log" && ok || bad "1832: a failed mark still stops the antigravity dispatch"
grep -q -- '--agent claude' "$tmp/agyx-remote.args" && ok || bad "1832: a failed mark falls back to claude ($(cat "$tmp/agyx-remote.args"))"
cp "$tmp/agy-signin.real.py" "$helper_dir/agy-signin.py"
unset GH_LABELS

# 1966: one swap rule. A verifier on antigravity never swaps to claude; a builder does.
agyv_spec="$tmp/agyv-spec.txt"
agyv_run() { # <title> <screen file> (env AGYV_PREMARK=1 marks agy-box first)
  : >"$tmp/orca-agyx.log"; rm -f "$tmp/agyv-state.json" "$tmp/agyx-remote.args"
  [ -z "${AGYV_PREMARK:-}" ] || FLEET_WATCH_CONFIG="$tmp/no-agy-fleet.json" AGY_UNAVAILABLE_STATE="$tmp/agyv-state.json" \
    "$PYTHON" "$here/../agy-signin.py" mark agy-box >/dev/null
  set +e
  env -u BASH_ENV PATH="$agyx_gh:$run_path" ORCA_CLI_COMMAND="$tmp/orca-agyx" ORCA_STUB_LOG="$tmp/orca-agyx.log" \
    FLEET_PULL_CONFIG="$tmp/fleet-agyx.json" FLEET_WATCH_CONFIG="$tmp/no-agy-fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
    AGY_WT="$wt_proof" AGY_SCREEN="$2" WORKER_STARTUP_AGY_WAIT=0 AGY_UNAVAILABLE_STATE="$tmp/agyv-state.json" GH_LABELS= \
    bash --noprofile --norc "$helper_dir/worker-startup.sh" --run run_agy --spec "$agyv_spec" --title "$1" --agent antigravity \
    --model gemini-4-argon-medium --from term_coord --on agy-box --worktree-path /abs/wt >"$tmp/agyv.out" 2>"$tmp/agyv.err"
  agyv_ec=$?
  set -e
}
printf 'Refs acme/app#7953\nType: verify\n\n# qa-sdet - verify PR 7953\n\nPost the Verdict with script/post-verdict.sh.\n\n%s\n' "$(cat "$spec_file")" >"$agyv_spec"
AGYV_PREMARK=1 agyv_run "#7953|qa-sdet" "$tmp/agy-ok.txt"
[ "$agyv_ec" = 4 ] && ok || bad "1966: a verifier on a marked host exits 4 ($agyv_ec) $(cat "$tmp/agyv.err")"
[ ! -s "$tmp/agyx-remote.args" ] && ! grep -q 'worker-start' "$tmp/orca-agyx.log" && ok || bad "1966: a verifier on a marked host starts nothing"
grep -q 'using claude' "$tmp/agyv.out" && bad "1966: a verifier never prints the using claude line" || ok
printf 'Refs acme/app#7954\n\n# fullstack-dev - issue 7954\n\n%s\n' "$(cat "$spec_file")" >"$agyv_spec"
AGYV_PREMARK=1 agyv_run "#7954|fullstack-dev" "$tmp/agy-ok.txt"
[ "$agyv_ec" = 0 ] && ok || bad "1966: a builder on a marked host exits 0 ($agyv_ec) $(cat "$tmp/agyv.err")"
grep -q 'agy-signin: host=agy-box is agy-unavailable, using claude' "$tmp/agyv.out" && ok || bad "1966: builder using claude line ($(cat "$tmp/agyv.out"))"
grep -q -- '--agent claude --model sonnet' "$tmp/agyx-remote.args" && ! grep -q -- '--agent antigravity' "$tmp/agyx-remote.args" && ok || bad "1966: builder starts claude/sonnet only ($(cat "$tmp/agyx-remote.args"))"
# A verifier start whose start screen is the sign-in screen: marked, stopped and released, exit 4, no claude start.
printf 'Refs acme/app#7955\n\n# qa-sdet - verify PR 7955\n\n%s\n' "$(cat "$spec_file")" >"$agyv_spec"
agyv_run "#7955|qa-sdet" "$tmp/agy-login.txt"
[ "$agyv_ec" = 4 ] && ok || bad "1966: a signed out verifier start exits 4 ($agyv_ec) $(cat "$tmp/agyv.err")"
FLEET_WATCH_CONFIG="$tmp/no-agy-fleet.json" AGY_UNAVAILABLE_STATE="$tmp/agyv-state.json" "$PYTHON" "$here/../agy-signin.py" unavailable agy-box && ok || bad "1966: the verifier sign-in screen marks the host"
grep -q 'worker-stop --dispatch ctx_agy --environment agy-box' "$tmp/orca-agyx.log" && ok || bad "1966: the verifier dispatch is stopped"
grep -q 'worker-release --dispatch ctx_agy --environment agy-box' "$tmp/orca-agyx.log" && grep -q 'worker-release --dispatch ctx_agy$' "$tmp/orca-agyx.log" && ok || bad "1966: the verifier dispatch is released on the host and here"
[ "$(grep -c -- '--agent' "$tmp/agyx-remote.args")" = 1 ] && ! grep -q -- '--agent claude' "$tmp/agyx-remote.args" && ok || bad "1966: no claude start follows ($(cat "$tmp/agyx-remote.args"))"
cat >"$helper_dir/agy-signin.py" <<'EOS'
#!/usr/bin/env python3
import sys
if sys.argv[1:2] == ['mark']:
    raise SystemExit(1)
raise SystemExit(0 if sys.argv[1:2] in (['match'], ['usable']) else 1)
EOS
agyv_run "#7955|qa-sdet" "$tmp/agy-login.txt"
[ "$agyv_ec" = 4 ] && ok || bad "1966: a verifier whose mark failed still exits 4 ($agyv_ec) $(cat "$tmp/agyv.err")"
grep -q 'could not mark agy-box' "$tmp/agyv.err" && ok || bad "1966: the failed mark is logged"
! grep -q -- '--agent claude' "$tmp/agyx-remote.args" && ok || bad "1966: a failed mark still starts no claude"
cp "$tmp/agy-signin.real.py" "$helper_dir/agy-signin.py"

# 1221: a worker that vanishes at startup is started once more; a healthy or non-startup failure is not retried.
cat >"$tmp/orca-retry" <<'EOS'
#!/usr/bin/env bash
set -e
printf '%s\n' "$*" >>"$RETRY_LOG"
case "$*" in
  *"worktree create"*)
    printf '%s\n' "{\"ok\":true,\"result\":{\"worktree\":{\"path\":\"${AGY_WT:?}\"}}}"
    ;;
  *"orchestration worker-start"*)
    n=$(grep -c 'orchestration worker-start' "$RETRY_LOG")
    if [ "$RETRY_MODE" = exit_first ] && [ "$n" = 1 ]; then
      echo 'terminal_exited at agent_readiness' >&2
      exit 1
    fi
    printf '{"ok":true,"result":{"dispatchId":"ctx_r%s","taskId":"task_r","runId":"run_r","state":"ready","terminal":"term_r"}}\n' "$n"
    ;;
  *"orchestration worker-show"*)
    if [ "$RETRY_MODE" = ready_then_vanish ] && [[ "$*" == *ctx_r1* ]]; then
      c=$(grep -c 'orchestration worker-show' "$RETRY_LOG")
      if [ "$c" -lt 2 ]; then
        echo '{"ok":true,"result":{"dispatchId":"ctx_r1","state":"ready","stage":"agent_readiness"}}'
      else
        echo '{"ok":true,"result":{"dispatchId":"ctx_r1","state":"failed","stage":"agent_readiness","lastError":"timeout"}}'
      fi
    elif [ "$RETRY_MODE" = vanish_first ] && [[ "$*" == *ctx_r1* ]]; then
      echo '{"ok":true,"result":{"dispatchId":"ctx_r1","state":"failed","stage":{"detail":"agent_readiness"},"lastError":"terminal_exited"}}'
    elif [ "$RETRY_MODE" = other_failure ]; then
      echo '{"ok":true,"result":{"dispatchId":"ctx_r1","state":"failed","lastError":"budget exhausted"}}'
    else
      echo '{"ok":true,"result":{"state":"ready","liveness":"live","terminal":"term_r"}}'
    fi
    ;;
  *"orchestration worker-release"*) echo '{"ok":true,"result":{}}' ;;
  *"orchestration task-list"*|*"orchestration worker-list"*) echo '{"ok":true,"result":{"tasks":[],"workers":[]}}' ;;
  *"terminal read"*) echo '{"ok":true,"result":{"terminal":{"tail":[]}}}' ;;
  *) printf 'unexpected orca: %s\n' "$*" >&2; exit 99 ;;
esac
EOS
chmod +x "$tmp/orca-retry"
retry_run() { # <mode>
  : >"$tmp/orca-retry.log"
  set +e
  unset -f python3 2>/dev/null || true
  env -u BASH_ENV \
    PATH="$run_path" ORCA_CLI_COMMAND="$tmp/orca-retry" RETRY_LOG="$tmp/orca-retry.log" RETRY_MODE="$1" \
    FLEET_PULL_CONFIG="$tmp/fleet.json" FLEET_WATCH_CONFIG="$tmp/no-agy-fleet.json" WORKER_STARTUP_READINESS_WAIT=2 \
    PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" AGY_WT="$wt_proof" \
    bash --noprofile --norc "$script" --run run_r --spec "$spec_file" --title "#1|fullstack-dev" \
    --agent claude --model claude-sonnet-5-5-medium \
    --from term_coord --name nretry --repo "path:$clean" >"$tmp/retry.out" 2>"$tmp/retry.err"
  retry_ec=$?
  set -e
  retry_starts=$(grep -c 'orchestration worker-start' "$tmp/orca-retry.log" || true)
}
retry_run vanish_first
[ "$retry_ec" = 0 ] && [ "$retry_starts" = 2 ] && ok || bad "dispatch that failed at startup is started once more (ec=$retry_ec starts=$retry_starts) $(cat "$tmp/retry.err")"
grep -q 'orchestration worker-release --dispatch ctx_r1' "$tmp/orca-retry.log" && ok || bad "failed startup dispatch is released before the retry"
grep 'orchestration worker-start' "$tmp/orca-retry.log" | sed -n 2p | grep -q -- '--task task_r --retry-of ctx_r1' && ok || bad "startup retry reuses the task (--task task_r --retry-of ctx_r1)"
grep 'orchestration worker-start' "$tmp/orca-retry.log" | sed -n 2p | grep -q -- '--task-title' && bad "startup retry must not create a second task" || ok
retry_run ready_then_vanish
[ "$retry_ec" = 0 ] && [ "$retry_starts" = 2 ] && ok || bad "ready then agent_readiness timeout is retried once (ec=$retry_ec starts=$retry_starts) $(cat "$tmp/retry.err")"
retry_run exit_first
[ "$retry_ec" = 0 ] && [ "$retry_starts" = 2 ] && ok || bad "worker-start exiting with terminal_exited is retried once (ec=$retry_ec starts=$retry_starts)"
retry_run healthy
[ "$retry_ec" = 0 ] && [ "$retry_starts" = 1 ] && ok || bad "healthy start is not retried (ec=$retry_ec starts=$retry_starts)"
retry_run other_failure
[ "$retry_starts" = 1 ] && ok || bad "failure that is not a startup exit is not retried (starts=$retry_starts)"

# 1270: a remote start that reports ready and then fails at startup is released and retried once on the same task.
cat >"$tmp/orca-remote-retry" <<EOS
#!/usr/bin/env bash
case " \$* " in
  *" orchestration worker-start "*)
    printf '%s\n' "\$(printf '%s ' "\$@" | tr '\n' ' ')" >>"$tmp/remote-retry.log"
    n=\$(grep -c . "$tmp/remote-retry.log")
    printf '{"ok":true,"result":{"dispatchId":"ctx_rr%s","taskId":"task_rr","state":"ready","terminal":"term_rr"}}\n' "\$n"
    ;;
  *" orchestration worker-show "*)
    if [[ "\$*" == *ctx_rr1* ]]; then
      echo '{"ok":true,"result":{"state":"failed","stage":"agent_readiness","lastError":"agent_not_in_foreground"}}'
    else
      echo '{"ok":true,"result":{"state":"running","terminal":"term_rr"}}'
    fi
    ;;
  *" orchestration worker-release "*)
    printf '%s\n' "\$*" >>"$tmp/remote-release.log"
    echo '{"ok":true,"result":{}}'
    ;;
  *) exec "$orca_remote_stub" "\$@" ;;
esac
EOS
chmod +x "$tmp/orca-remote-retry"
: >"$tmp/remote-retry.log"; : >"$tmp/remote-release.log"
set +e
unset -f python3 2>/dev/null || true
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$tmp/orca-remote-retry" ORCA_STUB_LOG="$tmp/orca-rem-retry.log" WORKER_STARTUP_READINESS_WAIT=2 \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  bash --noprofile --norc "$script" --run run_rem_retry --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --on rem-env --name n_rem --repo "path:$rem_app" >"$tmp/rem-retry.out" 2>"$tmp/rem-retry.err"
ec_rem_retry=$?
set -e
[ "$ec_rem_retry" = 0 ] && ok || bad "remote startup retry exits 0 ($ec_rem_retry) $(cat "$tmp/rem-retry.err")"
[ "$(grep -c . "$tmp/remote-retry.log")" = 2 ] && ok || bad "remote startup failure starts twice ($(cat "$tmp/remote-retry.log"))"
grep -q -- '--dispatch ctx_rr1 --environment rem-env' "$tmp/remote-release.log" && ok || bad "failed remote dispatch is released on its environment ($(cat "$tmp/remote-release.log"))"
sed -n 2p "$tmp/remote-retry.log" | grep -q -- '--task task_rr --retry-of ctx_rr1' && ok || bad "remote retry reuses the task ($(sed -n 2p "$tmp/remote-retry.log"))"
sed -n 2p "$tmp/remote-retry.log" | grep -q -- '--task-title' && bad "remote retry must not create a second task" || ok

# 1019: --on this host starts locally. --on another host still passes --environment.
cat >"$bin/hostname" <<'EOS'
#!/bin/sh
if [ "${1:-}" = "-s" ]; then
  printf '%s\n' thishost
else
  printf '%s\n' thishost.local
fi
EOS
chmod +x "$bin/hostname"
: >"$tmp/orca-own-host.log"
set +e
unset -f python3 2>/dev/null || true
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-own-host.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" FLEET_LOAD_SCRIPT="$tmp/load-all-over.sh" \
  bash --noprofile --norc "$script" --run run_own_host --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --on thishost --force-host chrome-dev --name n_own --repo "path:$clean" 2>"$tmp/own-host.err"
ec_own=$?
set -e
[ "$ec_own" = 0 ] && ok || bad "own-host --on exits 0 ($ec_own) $(cat "$tmp/own-host.err")"
grep -q 'worktree create' "$tmp/orca-own-host.log" && ok || bad "own-host start creates a worktree ($(cat "$tmp/orca-own-host.log"))"
grep -q 'orchestration worker-start' "$tmp/orca-own-host.log" && ok || bad "own-host start reaches worker-start"
grep -q -- '--environment' "$tmp/orca-own-host.log" && bad "own-host start must not pass --environment ($(cat "$tmp/orca-own-host.log"))" || ok
grep -q 'worker-placement:' "$tmp/own-host.err" && bad "own-host --on must not run placement" || ok
: >"$tmp/orca-own-host-case.log"
set +e
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-own-host-case.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" FLEET_LOAD_SCRIPT="$tmp/load-all-over.sh" \
  bash --noprofile --norc "$script" --run run_own_host --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --on THISHOST --force-host host-file --name n_own_case --repo "path:$clean" 2>"$tmp/own-host-case.err"
ec_case=$?
set -e
[ "$ec_case" = 0 ] && ok || bad "own-host --on THISHOST exits 0 ($ec_case) $(cat "$tmp/own-host-case.err")"
grep -q -- '--environment' "$tmp/orca-own-host-case.log" && bad "own-host THISHOST must not pass --environment ($(cat "$tmp/orca-own-host-case.log"))" || ok
grep -q -- '--environment rem-env' "$tmp/orca-rem-ok.log" && ok || bad "remote --on still passes --environment ($(cat "$tmp/orca-rem-ok.log"))"
# Forced --on: load check, --force-host, coordinator host gate, live worker spread
cat >"$tmp/load-forced-hot.sh" <<'EOS'
#!/usr/bin/env bash
printf 'host-primary cores=8 load=1.0 1.0 1.0\n'
printf 'host-overflow cores=8 load=9.0 9.0 9.0\n'
EOS
cat >"$tmp/load-forced-ok.sh" <<'EOS'
#!/usr/bin/env bash
printf 'host-primary cores=8 load=1.0 1.0 1.0\n'
printf 'host-overflow cores=8 load=2.0 2.0 2.0\n'
EOS
chmod +x "$tmp/load-forced-hot.sh" "$tmp/load-forced-ok.sh"
forced_start() { # <load script> <--on host> [extra args...] -> sets forced_ec, stderr in $tmp/forced.err
  local load=$1 on=$2; shift 2
  set +e
  env -u BASH_ENV \
    PATH="$run_path" ORCA_CLI_COMMAND="$orca_remote_stub" ORCA_STUB_LOG="$tmp/orca-forced.log" \
    FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
    FLEET_WATCH_CONFIG="${forced_cfg:-$tmp/fleet-placement.json}" FLEET_LOAD_SCRIPT="$load" \
    bash --noprofile --norc "$script" --run run_forced --spec "$spec_file" --title "${forced_title:-#1|fullstack-dev}" --agent claude --model claude-sonnet-5-5-medium \
    --from term_coord --on "$on" --name n_forced --repo "path:$rem_app" "$@" 2>"$tmp/forced.err"
  forced_ec=$?
  set -e
}
: >"$tmp/orca-forced.log"
forced_start "$tmp/load-forced-hot.sh" host-overflow
[ "$forced_ec" = 4 ] && ok || bad "forced --on over the limit exits 4 ($forced_ec) $(cat "$tmp/forced.err")"
grep -q 'host-primary' "$tmp/forced.err" && ok || bad "refusal names the alternative host ($(cat "$tmp/forced.err"))"
grep -q 'orchestration worker-start' "$tmp/orca-forced.log" && bad "refused forced start must not reach worker-start" || ok
forced_start "$tmp/load-forced-ok.sh" host-overflow
[ "$forced_ec" = 0 ] && ok || bad "forced --on under the limit passes ($forced_ec) $(cat "$tmp/forced.err")"
forced_start "$tmp/load-forced-hot.sh" host-overflow --force-host "owner asked for this host"
[ "$forced_ec" = 0 ] && ok || bad "--force-host passes over the limit ($forced_ec) $(cat "$tmp/forced.err")"
grep -q 'force-host: owner asked for this host' "$tmp/forced.err" && ok || bad "--force-host logs the reason ($(cat "$tmp/forced.err"))"

# #1756: a release-manager or qa-sdet --on a host outside browser_hosts exits 4 naming browser_hosts; --force-host overrides.
jq '. + {browser_hosts: ["host-primary"]}' "$tmp/fleet-placement.json" >"$tmp/fleet-placement-browser.json"
for bh_title in '#1|release-manager' '#1|qa-sdet'; do
  : >"$tmp/orca-forced.log"
  forced_title=$bh_title forced_cfg="$tmp/fleet-placement-browser.json" forced_start "$tmp/load-forced-ok.sh" host-overflow
  [ "$forced_ec" = 4 ] && ok || bad "$bh_title --on a non-browser host exits 4 ($forced_ec) $(cat "$tmp/forced.err")"
  grep -q 'browser_hosts' "$tmp/forced.err" && ok || bad "$bh_title refusal names browser_hosts ($(cat "$tmp/forced.err"))"
  grep -q 'orchestration worker-start' "$tmp/orca-forced.log" && bad "$bh_title refused start must not reach worker-start" || ok
  forced_title=$bh_title forced_cfg="$tmp/fleet-placement-browser.json" forced_start "$tmp/load-forced-ok.sh" host-overflow --force-host "browser installed by hand"
  [ "$forced_ec" = 0 ] && ok || bad "$bh_title --force-host overrides browser_hosts ($forced_ec) $(cat "$tmp/forced.err")"
  # No browser_hosts key: unchanged.
  forced_title=$bh_title forced_start "$tmp/load-forced-ok.sh" host-overflow
  [ "$forced_ec" = 0 ] && ok || bad "$bh_title with no browser_hosts key is unchanged ($forced_ec) $(cat "$tmp/forced.err")"
done
# A role with no browser gate is not held to browser_hosts.
forced_title='#1|fullstack-dev' forced_cfg="$tmp/fleet-placement-browser.json" forced_start "$tmp/load-forced-ok.sh" host-overflow
[ "$forced_ec" = 0 ] && ok || bad "fullstack-dev is not held to browser_hosts ($forced_ec) $(cat "$tmp/forced.err")"

forced_start "$tmp/load-forced-ok.sh" thishost
[ "$forced_ec" = 4 ] && ok || bad "coordinator host without a reason exits 4 even under load limit ($forced_ec)"
grep -q 'chrome-dev, line-desktop, host-file' "$tmp/forced.err" && ok || bad "coordinator refusal lists the allowed reasons ($(cat "$tmp/forced.err"))"
forced_start "$tmp/load-forced-ok.sh" thishost --force-host because
[ "$forced_ec" = 4 ] && ok || bad "coordinator host with a bad reason exits 4 ($forced_ec)"
forced_start "$tmp/load-forced-ok.sh" thishost --force-host line-desktop
[ "$forced_ec" = 0 ] && ok || bad "coordinator host with an allowed reason passes ($forced_ec) $(cat "$tmp/forced.err")"
grep -q 'worker-startup: live workers' "$tmp/forced.err" && ok || bad "start prints the live worker spread ($(cat "$tmp/forced.err"))"

# No --on: still goes through placement
: >"$tmp/orca-noon.log"
set +e
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-noon.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  FLEET_WATCH_CONFIG="$tmp/fleet-placement.json" FLEET_LOAD_SCRIPT="$tmp/load-forced-ok.sh" \
  bash --noprofile --norc "$script" --run run_noon --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --name n_noon --repo "path:$clean" >"$tmp/noon.out" 2>"$tmp/noon.err"
set -e
grep -q 'worker-placement: host=' "$tmp/noon.err" "$tmp/noon.out" && ok || bad "no --on goes through placement ($(cat "$tmp/noon.err"))"

# --force-host REASON picks the mapped host without --on
cat >"$tmp/fleet-reasons.json" <<'EOS'
{
  "local_host": "host-primary",
  "host_caps": {"host-primary": 4, "host-overflow": 4},
  "host_load_ceilings": {"host-primary": 12, "host-overflow": 8},
  "worker_placement": {
    "order": ["host-primary", "host-overflow"],
    "reasons": {"chrome-dev": "host-overflow", "line-desktop": "host-overflow", "host-file": "host-overflow"}
  }
}
EOS
: >"$tmp/orca-reason.log"
set +e
env -u BASH_ENV \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_remote_stub" ORCA_STUB_LOG="$tmp/orca-reason.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  FLEET_WATCH_CONFIG="$tmp/fleet-reasons.json" FLEET_LOAD_SCRIPT="$tmp/load-forced-ok.sh" \
  bash --noprofile --norc "$script" --run run_reason --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --force-host chrome-dev --name n_reason --repo "path:$rem_app" 2>"$tmp/reason.err"
ec_reason=$?
set -e
[ "$ec_reason" = 0 ] && ok || bad "--force-host chrome-dev without --on exits 0 ($ec_reason) $(cat "$tmp/reason.err")"
grep -q 'reason chrome-dev -> host=host-overflow' "$tmp/reason.err" && ok || bad "reason names the mapped host ($(cat "$tmp/reason.err"))"
grep -q 'worker-placement: host=' "$tmp/reason.err" && bad "reason start must not run placement" || ok

# A failed worker-start removes the worktree this run created, and only that one (#1184).
orca_fail_stub="$tmp/orca-fail-stub"
sed 's#^  \*" orchestration worker-start "\*)#  *" worktree rm "*) exit 0 ;;\n  *" orchestration worker-start "*) exit 7 ;;\n  *" orchestration worker-start-unused "*)#' "$orca_stub" >"$orca_fail_stub"
chmod +x "$orca_fail_stub"
fail_start() { # <log> [extra args...]
  local log=$1; shift
  : >"$log"
  set +e
  env -u BASH_ENV \
    PATH="$run_path" ORCA_CLI_COMMAND="$orca_fail_stub" ORCA_STUB_LOG="$log" \
    FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
    WORKER_STARTUP_STATE="$launch_state" \
    bash --noprofile --norc "$script" --run run_x --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
    --from term_coord "$@" >/dev/null 2>&1
  fail_ec=$?
  set -e
}
fail_start "$tmp/orca-fail.log" --name n1 --repo "path:$clean"
[ "$fail_ec" = 7 ] && ok || bad "failed worker-start keeps its exit code ($fail_ec)"
grep -Fq "worktree rm --worktree path:$wt_proof --force" "$tmp/orca-fail.log" && ok || bad "failed start removes the worktree it created ($(cat "$tmp/orca-fail.log"))"
fail_start "$tmp/orca-fail-given.log" --worktree-path "$wt_proof"
[ "$fail_ec" = 7 ] && ok || bad "failed start on a given worktree keeps its exit code ($fail_ec)"
grep -Fq 'worktree rm' "$tmp/orca-fail-given.log" && bad "failed start removed a worktree it did not create" || ok

# A qa-sdet start for a PR that already has a live verifier warns on stderr and still starts (#1222).
orca_live_stub="$tmp/orca-live"
cat >"$orca_live_stub" <<EOS
#!/usr/bin/env bash
case " \$* " in
  *" orchestration worker-list "*)
    printf '%s\\n' "\$*" >>"$tmp/live-list.log"
    echo '{"ok":true,"result":{"workers":[{"dispatchId":"ctx_live1","taskId":"task_v1","liveness":"live","terminalState":"active"},{"dispatchId":"ctx_live2","taskId":"task_b1","liveness":"live","terminalState":"active"},{"dispatchId":"ctx_rem1","taskId":"task_r1","dispatchStatus":"dispatched","workerState":"ready","terminalState":null},{"dispatchId":"ctx_done1","taskId":"task_d1","dispatchStatus":"completed","workerState":"succeeded","terminalState":null}]}}'
    exit 0 ;;
  *" orchestration task-list "*)
    echo '{"ok":true,"result":{"tasks":[{"id":"task_v1","title":"#9|qa-sdet|verify PR 77","spec":"Role: qa-sdet. Verify this open PR at head abc1234def the way a user would."},{"id":"task_b1","title":"#78|fullstack-dev"},{"id":"task_r1","title":"#1262|qa-sdet|verify 1263"},{"id":"task_d1","title":"#1300|qa-sdet|verify 1301"}]}}'
    exit 0 ;;
esac
exec "$orca_stub" "\$@"
EOS
chmod +x "$orca_live_stub"
live_verifier_run() { # <title> [extra args...]
  : >"$tmp/orca-live.log"
  set +e
  env -u BASH_ENV \
    PATH="$run_path" ORCA_CLI_COMMAND="$orca_live_stub" ORCA_STUB_LOG="$tmp/orca-live.log" \
    FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
    USAGE_GATE_PICK="$tmp/pick-stub.py" USAGE_GATE_PRESETS="$root/.orca/presets.json" \
    PICK_STUB_MODE=sonnet PICK_STUB_LOG="$tmp/pick-stub.log" WORKER_STARTUP_STATE="$route_state" \
    bash --noprofile --norc "$script" --run run_route --spec "${LIVE_SPEC:-$spec_file}" --title "$1" --agent claude --model claude-sonnet-5-5-medium \
    --from term_coord --repo "path:$clean" "${@:2}" >"$tmp/live.out" 2>"$tmp/live.err"
  live_ec=$?
  set -e
}
# #1839 (owner Q4 A) replaces #1222's warn-and-go for the same issue: a second live qa-sdet on #9 is refused with exit 2.
live_verifier_run "#9|qa-sdet|verify PR 77" --name verify-77
[ "$live_ec" = 2 ] && ok || bad "1839: a second live qa-sdet on the same issue exits 2 (ec=$live_ec) $(cat "$tmp/live.err")"
grep -Fq 'refused: #9 already has live qa-sdet worker ctx_live1' "$tmp/live.err" && ok || bad "1839: refusal names the live dispatch ($(cat "$tmp/live.err"))"
grep -q 'worker-start' "$tmp/orca-live.log" && bad "1839: a refused duplicate must not reach worker-start" || ok
# A verifier under another issue for the same PR still only warns (#1222).
live_verifier_run "#99|qa-sdet|verify PR 77" --name verify-77
[ "$live_ec" = 0 ] && ok || bad "a duplicate verifier start still goes on (ec=$live_ec) $(cat "$tmp/live.err")"
grep -Fq 'worker-startup: warning: live verifier ctx_live1 (#9|qa-sdet|verify PR 77) is already running for PR #77' "$tmp/live.err" && ok || bad "duplicate verifier should warn naming the live dispatch ($(cat "$tmp/live.err"))"
grep -q 'ctx_live2' "$tmp/live.err" && bad "a live builder must not be named" || ok
grep -q 'worker-start' "$tmp/orca-live.log" && ok || bad "the duplicate verifier should still reach worker-start"
# 1960: a second verifier for the same PR and head is refused (exit 2); another head starts; --allow-overlap overrides.
printf 'Refs acme/app#77\n\nVerify this open PR at head abc1234def5678 the way a user would.\n\n%s\n' "$(cat "$spec_file")" >"$tmp/verify-same-head.md"
printf 'Refs acme/app#77\n\nVerify this open PR at head 0f0f0f0f the way a user would.\n\n%s\n' "$(cat "$spec_file")" >"$tmp/verify-new-head.md"
LIVE_SPEC="$tmp/verify-same-head.md" live_verifier_run "#99|qa-sdet|verify PR 77" --name verify-77
[ "$live_ec" = 2 ] && ok || bad "1960: a second verifier for the same PR and head exits 2 (ec=$live_ec) $(cat "$tmp/live.err")"
grep -Fq 'refused: live verifier ctx_live1 (#9|qa-sdet|verify PR 77) already holds PR #77 at head abc1234' "$tmp/live.err" && ok || bad "1960: the refusal names the live verifier and head ($(cat "$tmp/live.err"))"
grep -q 'worker-start' "$tmp/orca-live.log" && bad "1960: a refused verifier must not reach worker-start" || ok
LIVE_SPEC="$tmp/verify-new-head.md" live_verifier_run "#99|qa-sdet|verify PR 77" --name verify-77
[ "$live_ec" = 0 ] && grep -q 'worker-start' "$tmp/orca-live.log" && ok || bad "1960: a verifier for a new head starts (ec=$live_ec) $(cat "$tmp/live.err")"
LIVE_SPEC="$tmp/verify-same-head.md" live_verifier_run "#99|qa-sdet|verify PR 77" --name verify-77 --allow-overlap "owner asked"
[ "$live_ec" = 0 ] && grep -Fq 'allow-overlap: live verifier ctx_live1' "$tmp/live.err" && ok || bad "1960: --allow-overlap starts a second verifier and says so (ec=$live_ec) $(cat "$tmp/live.err")"
live_verifier_run "#99|qa-sdet|standing" --name verify-78
grep -q 'warning: live verifier' "$tmp/live.err" && bad "a verifier for another PR must not warn ($(cat "$tmp/live.err"))" || ok
live_verifier_run "#79|fullstack-dev" --name verify-77
grep -q 'warning: live verifier' "$tmp/live.err" && bad "a builder start must not warn" || ok

# 1271: a remote live verifier (terminalState null) titled with a bare "verify <pr>" warns, a finished one does not.
: >"$tmp/live-list.log"
live_verifier_run "#1264|qa-sdet|verify 1263" --name verify-1263
grep -Fq 'worker-startup: warning: live verifier ctx_rem1 (#1262|qa-sdet|verify 1263) is already running for PR #1263' "$tmp/live.err" && ok || bad "remote live verifier with a bare verify title should warn ($(cat "$tmp/live.err"))"
grep -- '--run' "$tmp/live-list.log" | grep -q -- '--terminal-state'  && bad "warn_live_verifier must not filter by --terminal-state" || ok
live_verifier_run "#1300|qa-sdet|verify 1301" --name verify-1301
grep -q 'ctx_done1' "$tmp/live.err" && bad "a completed verifier must not warn" || ok
live_verifier_run "#1263|qa-sdet"
grep -Fq 'ctx_rem1' "$tmp/live.err" && ok || bad "a verifier titled by its PR number only should warn ($(cat "$tmp/live.err"))"

# 1271: a verifier start never removes ready-for-agent from the issue it refs.
cat >"$bin/gh" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp/gh.log"
EOS
chmod +x "$bin/gh"
: >"$tmp/gh.log"
live_verifier_run "#99|qa-sdet|verify PR 77" --name verify-77
grep -q 'issue edit' "$tmp/gh.log" && bad "qa-sdet start must not edit issue labels ($(cat "$tmp/gh.log"))" || ok
rm -f "$bin/gh"

# Hand dispatch obeys the start order: a builder for another repo is refused while a ready dotfiles issue waits (#1286).
run_path="$ghbin:$run_path_saved"
cat >"$ghbin/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_LOG"
[ "${GH_STUB_FAIL:-}" != 1 ] || exit 1
view_default='{"labels":[],"title":"feat: x"}'
case "$1 $2" in
  "issue list") printf '%s\n' "$GH_STUB_ISSUES" ;;
  "issue view") [ "${GH_STUB_VIEW_FAIL:-}" != 1 ] || exit 1
    case "$*" in *"--json state"*) printf '%s\n' "${GH_STUB_BLOCKER_STATE:-CLOSED}" ;; *) printf '%s\n' "${GH_STUB_VIEW:-$view_default}" ;; esac ;;
  "pr list") printf '[]\n' | jq -r "${@: -1}" ;;
esac
EOS
ready_issue='[{"number":5,"labels":[{"name":"ready-for-agent"},{"name":"P2"}]}]'
printf 'Refs acme/app#7950\n\n# fullstack-dev - issue 7950\n\n%s\n' "$spec_saved" >"$spec_file"
: >"$GH_STUB_LOG"
GH_STUB_ISSUES=$ready_issue DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" -ne 0 ] && ok || bad "a project builder should be refused while a dotfiles issue is ready (ec=$route_ec)"
grep -Fq 'dotfiles issue #5 is ready and not started' "$tmp/route.err" && ok || bad "refusal should name the waiting issue ($(cat "$tmp/route.err"))"
grep -q 'worker-start' "$tmp/orca-route.log" && bad "refused start must not reach worker-start" || ok
grep -Fq -- 'issue list --repo acme/dots --label ready-for-agent' "$GH_STUB_LOG" && ok || bad "the check should read the dotfiles repo ($(cat "$GH_STUB_LOG"))"
GH_STUB_ISSUES=$ready_issue DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium --skip-dotfiles-first "owner asked for this one"
[ "$route_ec" = 0 ] && ok || bad "--skip-dotfiles-first should start anyway (ec=$route_ec) $(cat "$tmp/route.err")"
grep -Fq 'skip-dotfiles-first' "$tmp/route.err" && grep -Fq 'owner asked for this one' "$tmp/route.err" && ok || bad "the skip reason should be logged ($(cat "$tmp/route.err"))"
held='[{"number":5,"labels":[{"name":"ready-for-agent"},{"name":"blocked"}]},{"number":6,"labels":[{"name":"needs-triage"}]}]'
GH_STUB_ISSUES=$held DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "a held or unready dotfiles issue must not block a start (ec=$route_ec) $(cat "$tmp/route.err")"
# 1823: a ready dotfiles issue whose `Blocked by #N` is open does not hold a start back; a closed blocker still does.
blocked='[{"number":5,"body":"Blocked by #4","labels":[{"name":"ready-for-agent"},{"name":"P2"}]}]'
GH_STUB_BLOCKER_STATE=OPEN GH_STUB_ISSUES=$blocked DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "a ready issue with an open blocker must not refuse a start (ec=$route_ec) $(cat "$tmp/route.err")"
GH_STUB_BLOCKER_STATE=CLOSED GH_STUB_ISSUES=$blocked DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" -ne 0 ] && ok || bad "a ready issue whose blocker is closed must still refuse (ec=$route_ec)"
GH_STUB_ISSUES='[]' DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "no ready dotfiles issue should let the start go on (ec=$route_ec) $(cat "$tmp/route.err")"
GH_STUB_VIEW='{"labels":[{"name":"P0"}],"title":"fix: x"}' GH_STUB_ISSUES=$ready_issue DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "a P0 or bug project issue starts before a waiting dotfiles P2 (ec=$route_ec) $(cat "$tmp/route.err")"
GH_STUB_VIEW_FAIL=1 GH_STUB_ISSUES=$ready_issue DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "a failed gh issue view must not block the start (ec=$route_ec) $(cat "$tmp/route.err")"
GH_STUB_VIEW='{"labels":[{"name":"P0"}],"title":"fix: x"}' GH_STUB_ISSUES='[{"number":5,"labels":[{"name":"ready-for-agent"},{"name":"P0"}]}]' DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" -ne 0 ] && ok || bad "a waiting dotfiles P0 still goes before a project P0 (ec=$route_ec)"
# #1818: the red main and red gate tier ranks ahead of P0 and bug in any repo, as issue_scan_queue_key does.
GH_STUB_VIEW='{"labels":[{"name":"P1"}],"title":"main red: 123"}' GH_STUB_ISSUES='[{"number":5,"labels":[{"name":"ready-for-agent"},{"name":"P0"}],"title":"fix: y"}]' DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "a project main red fixer starts before a waiting dotfiles P0 (ec=$route_ec) $(cat "$tmp/route.err")"
GH_STUB_VIEW='{"labels":[{"name":"P1"}],"title":"red gate: shellcheck"}' GH_STUB_ISSUES='[{"number":5,"labels":[{"name":"ready-for-agent"},{"name":"bug"}],"title":"fix: y"}]' DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "a project red gate fixer starts before a waiting dotfiles bug (ec=$route_ec) $(cat "$tmp/route.err")"
GH_STUB_VIEW='{"labels":[{"name":"P0"}],"title":"fix: x"}' GH_STUB_ISSUES='[{"number":5,"labels":[{"name":"ready-for-agent"},{"name":"P1"}],"title":"red gate: shellcheck"}]' DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" -ne 0 ] && ok || bad "a waiting dotfiles P1 red gate fixer goes before a project P0 (ec=$route_ec)"
GH_STUB_VIEW='{"labels":[{"name":"P1"}],"title":"main red: 456"}' GH_STUB_ISSUES='[{"number":5,"labels":[{"name":"ready-for-agent"},{"name":"P1"}],"title":"main red: 123"}]' DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" -ne 0 ] && ok || bad "a waiting dotfiles main red fixer goes before a project main red fixer (ec=$route_ec)"
printf 'Refs acme/dots#9\n\n# fullstack-dev - issue 9\n\n%s\n' "$spec_saved" >"$spec_file"
GH_STUB_ISSUES=$ready_issue DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#9|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "a dotfiles builder is never refused by the order rule (ec=$route_ec) $(cat "$tmp/route.err")"
printf 'Refs acme/app#7950\n\n# qa-sdet - verify 7950\n\n%s\n' "$spec_saved" >"$spec_file"
GH_STUB_ISSUES=$ready_issue DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|qa-sdet" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "a non-builder start must not wait for dotfiles (ec=$route_ec) $(cat "$tmp/route.err")"
printf 'Refs acme/app#7950\n\n# fullstack-dev - issue 7950\n\n%s\n' "$spec_saved" >"$spec_file"
GH_STUB_FAIL=1 GH_STUB_ISSUES=$ready_issue DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "a failed gh call must not block the start (ec=$route_ec) $(cat "$tmp/route.err")"
# #1778: a dotfiles issue fleet-watch could not start (placement or host cap) in its last 15 minutes does not hold back other repos.
printf 'Refs acme/app#7950\n\n# fullstack-dev - issue 7950\n\n%s\n' "$spec_saved" >"$spec_file"
deferred_state="$tmp/fleet-watch-deferred.json"
printf '{"dotfiles_deferred":{"5":%s}}\n' "$(date +%s)" >"$deferred_state"
FLEET_WATCH_STATE=$deferred_state GH_STUB_ISSUES=$ready_issue DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "a dotfiles issue deferred this pass must not block another repo (ec=$route_ec) $(cat "$tmp/route.err")"
printf '{"dotfiles_deferred":{"5":%s}}\n' "$(( $(date +%s) - 3600 ))" >"$deferred_state"
FLEET_WATCH_STATE=$deferred_state GH_STUB_ISSUES=$ready_issue DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" -ne 0 ] && ok || bad "a deferral older than 15 minutes must not lift the dotfiles first rule (ec=$route_ec)"
printf '{"dotfiles_deferred":{"6":%s}}\n' "$(date +%s)" >"$deferred_state"
FLEET_WATCH_STATE=$deferred_state GH_STUB_ISSUES=$ready_issue DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" -ne 0 ] && ok || bad "a deferral of another dotfiles issue must not lift the rule for issue 5 (ec=$route_ec)"
# #1778: a hand start with `Refs: #n` (no repo) claims the issue in the repo of the start, not the repo of the shell.
claim_repo="$tmp/claim-repo"
git init -q "$claim_repo"
git -C "$claim_repo" remote add origin git@github.com:acme/widgets.git
printf 'Refs: #7950\n\n# fullstack-dev - issue 7950\n\n%s\n' "$spec_saved" >"$spec_file"
: >"$GH_STUB_LOG"
GH_STUB_ISSUES='[]' DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium --repo "path:$claim_repo"
[ "$route_ec" = 0 ] && ok || bad "a Refs: #n start should go on (ec=$route_ec) $(cat "$tmp/route.err")"
grep -Fxq -- 'issue edit 7950 -R acme/widgets --remove-label ready-for-agent --add-label status:進行中 --remove-label needs-triage' "$GH_STUB_LOG" && ok || bad "Refs: #n should claim in the --repo of the start ($(cat "$GH_STUB_LOG"))"
printf 'Refs acme/app#7950\n\n# fullstack-dev - issue 7950\n\n%s\n' "$spec_saved" >"$spec_file"
# A started issue gets the in flight board label, and the gate runs before the start.
: >"$GH_STUB_LOG"
GH_STUB_ISSUES='[]' DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium
grep -Fxq -- 'issue edit 7950 -R acme/app --remove-label ready-for-agent --add-label status:進行中 --remove-label needs-triage' "$GH_STUB_LOG" && ok || bad "a started issue should get status:進行中 ($(cat "$GH_STUB_LOG"))"
: >"$GH_STUB_LOG"
GH_STUB_ISSUES=$ready_issue DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium --skip-dotfiles-first "test"
grep -Fxq -- 'issue edit 5 --repo acme/dots --add-label status:接下來' "$GH_STUB_LOG" && ok || bad "the label gate should run at a hand start ($(cat "$GH_STUB_LOG"))"

# A successful start logs one duration_s line for team-audit.sh --report (#1330).
rm -f "$route_state/durations.log"
GH_STUB_ISSUES='[]' DOTFILES_REPO=acme/dots PICK_STUB_MODE=sonnet route_run "#7950|fullstack-dev" claude claude-sonnet-5-5-medium --skip-dotfiles-first "test"
grep -qE '^[0-9TZ:-]+ worker-startup run=run_route duration_s=[0-9]+$' "$route_state/durations.log" 2>/dev/null && ok || bad "a successful start should log duration_s ($(cat "$route_state/durations.log" 2>&1))"
grep -qE '^worker-startup run=run_route duration_s=[0-9]+$' "$tmp/route.err" && ok || bad "a successful start should print duration_s on stderr"


# --- #1328: the brief copy handed to worker-start starts with "Worker role: <role>" on every dispatch path ---
role_stamp_start() { # <label> <expected role> <worker-startup args...>; checks the brief copy worker-start received
  local label=$1 want=$2 log="$tmp/orca-stamp.log" first ec
  shift 2
  : >"$log"
  set +e
  env -u BASH_ENV \
    PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$log" \
    FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
    WORKER_STARTUP_STATE="$launch_state" \
    bash --noprofile --norc "$script" "$@" >/dev/null 2>"$tmp/stamp.err"
  ec=$?
  set -e
  [ "$ec" = 0 ] || { bad "stamp $label: start exits 0 ($ec) $(head -3 "$tmp/stamp.err")"; return; }
  first=$(grep 'orchestration worker-start' "$log" | head -1 | sed 's/.*--spec //')
  [ "$first" = "Worker role: $want" ] && ok || bad "stamp $label: first line is 'Worker role: $want' (got '$first')"
}
for preset in fullstack-dev fullstack-dev-small fullstack-dev-strong fullstack-dev-debug builder; do
  role_stamp_start "preset $preset" "$preset" --run run_x --spec "$spec_file" --title "#1|$preset" --agent claude \
    --model claude-sonnet-5-5-medium --from term_coord --name n1 --repo "path:$clean"
done
role_stamp_start "sweep" architect-pm --run run_x --spec "$spec_file" --title "#0|architect-pm" --agent claude \
  --model claude-sonnet-5-5-medium --from term_coord --name n1 --repo "path:$clean"

# fleet-watch builds the command; the real worker-startup.sh runs it against the stub orca.
fw_cmds="$tmp/fw-cmds.txt"
"$python3_real" - "$here/.." >"$fw_cmds" <<'PY'
import importlib.util, sys
from pathlib import Path
from unittest.mock import patch
root = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(root / 'tests'))
spec = importlib.util.spec_from_file_location('fleet_watch', root / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)
from test_fleet_watch_park import REPO, issue_row, scan_config
MODEL = 'claude-sonnet-5-5-medium'
config = scan_config('/work/app')
config['issue_scan'].update({'agent': 'claude', 'model': MODEL, 'role': 'fullstack-dev'})
config['babysit'] = {'enabled': True, 'startup_script': '/x/worker-startup.sh', 'run': 'run_x',
                     'from_terminal': 'term_coord', 'repo_roots': {REPO: '/work/app'}}
repos = {'repos': [{'id': 'repo-1', 'path': '/work/app'}]}
def fake_rpc(*a):
    if a[:2] == ('repo', 'list'):
        return repos
    raise fw.OrcaReadError('unexpected')
pr = {'number': 7, 'headRefOid': 'a' * 40, 'headRefName': 'b', 'title': 't', 'body': ''}
with patch.object(fw, 'rpc', side_effect=fake_rpc), patch.object(fw, 'pr_base_ref', return_value='main'):
    small = fw.issue_scan_route({'labels': [{'name': 'size:S'}]})
    large = fw.issue_scan_route({'labels': [{'name': 'size:L'}]})
    cases = [
        ('scan size:S', fw.build_issue_start_command(config, REPO, issue_row(11, 'x'), None, (small[0], 'claude', MODEL))),
        ('scan size:L', fw.build_issue_start_command(config, REPO, issue_row(12, 'x'), None, (large[0], 'claude', MODEL))),
        ('scan no label', fw.build_issue_start_command(config, REPO, issue_row(13, 'x'), None, None)),
        ('rework', fw.build_rework_start_command(config, REPO, pr)),
        ('babysit fix', fw.build_babysit_command(config, REPO, pr, 'fix', 'claude', MODEL, None)),
    ]
for label, cmd in cases:
    title = cmd[cmd.index('--title') + 1]
    print('\t'.join([label, title.split('|', 1)[1], title] + [cmd[cmd.index(f) + 1] for f in ('--spec', '--agent', '--model')]))
PY
while IFS=$'\t' read -r label want title cspec cagent cmodel; do
  role_stamp_start "$label" "$want" --run run_x --spec "$cspec" --title "$title" --agent "$cagent" \
    --model "$cmodel" --from term_coord --name n1 --repo "path:$clean"
done <"$fw_cmds"
[ "$(wc -l <"$fw_cmds" | tr -d ' ')" = 5 ] && ok || bad "stamp: fleet-watch built all five commands ($(cat "$fw_cmds"))"

# A same task retry sends no spec: the task's stored brief is the stamped copy from the first start.
: >"$tmp/orca-stamp-retry.log"
env -u BASH_ENV PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-stamp-retry.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  bash --noprofile --norc "$script" --run run_x --task task_s --retry-of disp_s --worktree "wt::/p" --agent claude \
  --from term_coord >/dev/null 2>&1
retry_line=$(grep 'orchestration worker-start' "$tmp/orca-stamp-retry.log" | head -1)
case "$retry_line" in
  *"--task task_s --retry-of disp_s"*) ;;
  *) retry_line="" ;;
esac
case "$retry_line" in
  "") bad "stamp: same task retry reaches worker-start" ;;
  *"--spec"*) bad "stamp: same task retry must not resend a spec" ;;
  *) ok ;;
esac

# Idempotent: a brief that already carries a stamp gets exactly one, for the title's role.
printf 'Worker role: stale-role\n' >"$tmp/spec-prestamped.md"
cat "$spec_file" >>"$tmp/spec-prestamped.md"
role_stamp_start "prestamped" fullstack-dev --run run_x --spec "$tmp/spec-prestamped.md" --title "#1|fullstack-dev" \
  --agent claude --model claude-sonnet-5-5-medium --from term_coord --name n1 --repo "path:$clean"
[ "$(grep -c 'Worker role:' "$tmp/orca-stamp.log")" = 1 ] && ok || bad "stamp: a prestamped brief ends with one stamp"

# --- #1631: every brief copy a start makes is gone when the start exits ---
leak_tmp="$tmp/leak-tmp"; mkdir -p "$leak_tmp"
: >"$tmp/orca-leak.log"
env -u BASH_ENV TMPDIR="$leak_tmp" \
  PATH="$run_path" ORCA_CLI_COMMAND="$orca_stub" ORCA_STUB_LOG="$tmp/orca-leak.log" \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" \
  WORKER_STARTUP_STATE="$launch_state" \
  bash --noprofile --norc "$script" --run run_x --spec "$spec_file" --title "#1|fullstack-dev" --agent claude \
  --model claude-sonnet-5-5-medium --from term_coord --name n1 --repo "path:$clean" >/dev/null 2>&1
grep -q 'orchestration worker-start' "$tmp/orca-leak.log" && ok || bad "leak: the start reached worker-start"
[ -z "$(ls -A "$leak_tmp")" ] && ok || bad "leak: TMPDIR is empty after a start (left: $(ls "$leak_tmp" | tr '\n' ' '))"

# 1839: one live worker per (repo, issue, role class). A bundle covers every #N on its Issues: and Refs: lines.
dup_gh="$tmp/dup-gh"
mkdir -p "$dup_gh"
cat >"$dup_gh/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_LOG"
case "$1 $2" in
  "pr list")
    case "$*" in
      *"--state closed"*) printf '%s\n' "${DUP_CLOSED:-[]}" | jq -r "${@: -1}" ;;
      *) printf '[]\n' | jq -r "${@: -1}" ;;
    esac ;;
  "pr view") printf '%s\n' "${DUP_COMMENTS:-{\"comments\":[]}}" | jq -r "${@: -1}" ;;
  "api "*) printf '%s\n' "${DUP_EVENTS:-[]}" | jq -r "${@: -1}" ;;
esac
exit 0
EOS
chmod +x "$dup_gh/gh"
cat >"$tmp/orca-dup" <<EOS
#!/usr/bin/env bash
case " \$* " in
  *" orchestration task-list "*)
    [ -z "\${DUP_LIST_FAIL:-}" ] || { echo '{"ok":false,"error":{"message":"runtime unavailable"}}'; exit 1; }
    [ -z "\${DUP_LIST_GARBAGE:-}" ] || { echo 'warning: slow runtime'; echo '{"ok":true}'; exit 0; }
    [ -z "\${DUP_LIST_NOTOK:-}" ] || { echo '{"ok":false,"error":{"message":"no such run"}}'; exit 0; }
    if [ -n "\${DUP_HAND:-}" ]; then
      printf '%s\n' '{"ok":true,"result":{"tasks":[{"id":"task_h1","status":"dispatched","title":"hand start","spec":"Refs acme/app#1810\n"},{"id":"task_h2","status":"dispatched","title":""}]}}'
      exit 0
    fi
    printf '%s\n' '{"ok":true,"result":{"tasks":[{"id":"task_a","status":"dispatched","task_title":"#1745|fullstack-dev|bundle","spec":"Refs acme/app#1745\nIssues: #1745 #1746\n"},{"id":"task_old","status":"ready","task_title":"#1800|fullstack-dev"}]}}'
    exit 0 ;;
  *" orchestration worker-list "*)
    if [ -n "\${DUP_HAND:-}" ]; then
      printf '%s\n' '{"ok":true,"result":{"workers":[{"dispatchId":"ctx_hand1","taskId":"task_h1","state":"ready","liveness":"live","terminalState":"active","workspace":"ws_1::/workspaces/app/hand"},{"dispatchId":"ctx_hand2","taskId":"task_h2","state":"ready","liveness":"live","terminalState":"active","workspace":"ws_2::/workspaces/app/b1820"}]}}'
      exit 0
    fi
    printf '%s\n' '{"ok":true,"result":{"workers":[{"dispatchId":"ctx_dup1","taskId":"task_a","state":"ready","liveness":"live","terminalState":"active"},{"dispatchId":"ctx_gone","taskId":"task_old","state":"failed","liveness":"exited","terminalState":"released"}]}}'
    exit 0 ;;
esac
exec "$tmp/orca" "\$@"
EOS
chmod +x "$tmp/orca-dup"
dup_spec_saved=$(cat "$spec_file")
run_path_dup_saved=$run_path
run_path="$dup_gh:$run_path_dup_saved"
export GH_STUB_LOG="$tmp/dup-gh.log"
dup_run() { # <title> [extra args...]
  printf 'Refs acme/app#%s\n\n# %s\n\n%s\n' "$(printf '%s' "$1" | sed -E 's/^#([0-9]+).*/\1/')" "$1" "$dup_spec_saved" >"$spec_file"
  : >"$GH_STUB_LOG"
  orca_stub="$tmp/orca-dup" PICK_STUB_MODE=sonnet route_run "$1" claude claude-sonnet-5-5-medium "${@:2}"
}
# (a) a live #1745 bundle that also covers #1746 refuses a second fullstack-dev on #1746.
dup_run "#1746|fullstack-dev"
[ "$route_ec" = 2 ] && ok || bad "1839a: a second live builder on a bundled issue exits 2 (ec=$route_ec) $(cat "$tmp/route.err")"
grep -Fq 'refused: acme/app#1746 already has live fullstack-dev worker ctx_dup1' "$tmp/route.err" && ok || bad "1839a: refusal names the live worker ($(cat "$tmp/route.err"))"
grep -q 'worker-start' "$tmp/orca-route.log" && bad "1839a: a refused start must not reach worker-start" || ok
grep -q '^issue edit' "$GH_STUB_LOG" && bad "1839a: a refused start must not claim the issue" || ok
dup_run "#1745|fullstack-dev-strong" --route-override "test"
[ "$route_ec" = 2 ] && ok || bad "1839a: every builder role is one class (ec=$route_ec) $(cat "$tmp/route.err")"
# A live task whose title issue is in the new start's Issues: line is a duplicate too.
printf 'Refs acme/app#1747\nIssues: #1747 #1745\n\n# bundle\n\n%s\n' "$dup_spec_saved" >"$spec_file"
orca_stub="$tmp/orca-dup" PICK_STUB_MODE=sonnet route_run "#1747|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" = 2 ] && ok || bad "1839a: a new bundle that covers a live issue exits 2 (ec=$route_ec) $(cat "$tmp/route.err")"
# (b) the same issue with role qa-sdet is another role class and starts.
dup_run "#1746|qa-sdet"
[ "$route_ec" = 0 ] && ok || bad "1839b: qa-sdet on a live builder's issue starts (ec=$route_ec) $(cat "$tmp/route.err")"
# A sibling with no overlap starts; a released worker does not count; another repo with the same number starts.
dup_run "#1748|fullstack-dev"
[ "$route_ec" = 0 ] && ok || bad "1839: an unrelated issue starts (ec=$route_ec) $(cat "$tmp/route.err")"
dup_run "#1800|fullstack-dev"
[ "$route_ec" = 0 ] && ok || bad "1839: a released worker is not live (ec=$route_ec) $(cat "$tmp/route.err")"
printf 'Refs other/repo#1746\n\n# other\n\n%s\n' "$dup_spec_saved" >"$spec_file"
orca_stub="$tmp/orca-dup" PICK_STUB_MODE=sonnet route_run "#1746|fullstack-dev" claude claude-sonnet-5-5-medium
[ "$route_ec" = 0 ] && ok || bad "1839: the same number in another repo starts (ec=$route_ec) $(cat "$tmp/route.err")"
# --allow-overlap REASON starts a duplicate on a hand start.
dup_run "#1746|fullstack-dev" --allow-overlap "owner asked"
[ "$route_ec" = 0 ] && grep -Fq 'allow-overlap: acme/app#1746 already has live fullstack-dev worker ctx_dup1' "$tmp/route.err" \
  && ok || bad "1839: --allow-overlap starts a duplicate and says so (ec=$route_ec) $(cat "$tmp/route.err")"
# 1960: a live worker with no "#N|role" title still holds issue N by its task spec Refs or its branch (worktree b<N>/w<N>).
DUP_HAND=1 dup_run "#1810|fullstack-dev"
[ "$route_ec" = 2 ] && grep -Fq 'refused: acme/app#1810 already has live builder worker ctx_hand1' "$tmp/route.err" && ok || bad "1960: an untitled worker whose spec refs the issue blocks a builder (ec=$route_ec) $(cat "$tmp/route.err")"
DUP_HAND=1 dup_run "#1820|fullstack-dev"
[ "$route_ec" = 2 ] && grep -Fq 'refused: acme/app#1820 already has live builder worker ctx_hand2' "$tmp/route.err" && ok || bad "1960: an untitled worker on branch b1820 blocks a builder (ec=$route_ec) $(cat "$tmp/route.err")"
DUP_HAND=1 dup_run "#1821|fullstack-dev"
[ "$route_ec" = 0 ] && ok || bad "1960: an unrelated issue still starts beside untitled workers (ec=$route_ec) $(cat "$tmp/route.err")"
DUP_HAND=1 dup_run "#1820|qa-sdet"
[ "$route_ec" = 0 ] && ok || bad "1960: an untitled worker counts as a builder, so qa-sdet starts (ec=$route_ec) $(cat "$tmp/route.err")"
# (d) an unreadable task list fails closed: FLEET_WATCH=1 exits 2 even with --allow-overlap; a hand start needs --allow-overlap.
DUP_LIST_FAIL=1 FLEET_WATCH=1 dup_run "#1748|fullstack-dev"
[ "$route_ec" = 2 ] && grep -q 'refused: cannot read the live task list' "$tmp/route.err" && ok || bad "1839d: fleet-watch start exits 2 on an unreadable list (ec=$route_ec) $(cat "$tmp/route.err")"
DUP_LIST_FAIL=1 FLEET_WATCH=1 dup_run "#1748|fullstack-dev" --allow-overlap x
[ "$route_ec" = 2 ] && ok || bad "1839d: fleet-watch cannot override an unreadable list (ec=$route_ec)"
DUP_LIST_FAIL=1 dup_run "#1748|fullstack-dev"
[ "$route_ec" = 2 ] && grep -q 'runtime unavailable' "$tmp/route.err" && ok || bad "1839d: a hand start prints the error and exits 2 (ec=$route_ec) $(cat "$tmp/route.err")"
DUP_LIST_GARBAGE=1 dup_run "#1748|fullstack-dev"
[ "$route_ec" = 2 ] && grep -q 'refused: cannot read the live task list' "$tmp/route.err" && ok || bad "1839d: a list that is not JSON fails closed (ec=$route_ec) $(cat "$tmp/route.err")"
DUP_LIST_NOTOK=1 dup_run "#1748|fullstack-dev"
[ "$route_ec" = 2 ] && ok || bad "1839d: an ok:false reply with exit 0 fails closed (ec=$route_ec) $(cat "$tmp/route.err")"
DUP_LIST_FAIL=1 dup_run "#1748|fullstack-dev" --allow-overlap x
[ "$route_ec" = 0 ] && grep -q 'worker-start' "$tmp/orca-route.log" && ok || bad "1839d: a hand start with --allow-overlap starts (ec=$route_ec) $(cat "$tmp/route.err")"
# (c) a builder start whose last closed PR has two Review FAILs and no newer ready-for-agent label exits 2.
two_fails='{"comments":[{"body":"Review: FAIL head=a model=x\nbad"},{"body":"Verdict: FAIL head=b\nworse"},{"body":"Review: PASS"}]}'
closed_prs='[{"number":1760,"closedAt":"2026-11-25T03:00:00Z","mergedAt":null,"body":"Closes acme/app#1748"},{"number":1700,"closedAt":"2026-11-20T03:00:00Z","mergedAt":null,"body":"Closes #1748"},{"number":1761,"closedAt":"2026-11-25T04:00:00Z","mergedAt":"2026-11-25T04:00:00Z","body":"Closes #1748"}]'
DUP_CLOSED=$closed_prs DUP_COMMENTS=$two_fails DUP_EVENTS='[{"event":"labeled","label":{"name":"needs-triage"},"created_at":"2026-11-25T03:00:05Z"}]' dup_run "#1748|fullstack-dev"
[ "$route_ec" = 2 ] && ok || bad "1839c: two FAILs then a close refuses a builder (ec=$route_ec) $(cat "$tmp/route.err")"
grep -Fq 'refused: last PR #1760 closed after two FAILs; relabel needs-triage' "$tmp/route.err" && ok || bad "1839c: refusal names the PR and needs-triage ($(cat "$tmp/route.err"))"
grep -Fq 'pr view 1760 -R acme/app' "$GH_STUB_LOG" && ok || bad "1839c: reads the latest closed unmerged PR ($(cat "$GH_STUB_LOG"))"
DUP_CLOSED=$closed_prs DUP_COMMENTS=$two_fails DUP_EVENTS='[{"event":"labeled","label":{"name":"ready-for-agent"},"created_at":"2026-11-25T05:00:00Z"}]' dup_run "#1748|fullstack-dev"
[ "$route_ec" = 0 ] && ok || bad "1839c: ready-for-agent added after the close lets it start (ec=$route_ec) $(cat "$tmp/route.err")"
DUP_CLOSED=$closed_prs DUP_COMMENTS='{"comments":[{"body":"Review: FAIL head=a"}]}' dup_run "#1748|fullstack-dev"
[ "$route_ec" = 0 ] && ok || bad "1839c: one FAIL does not refuse (ec=$route_ec) $(cat "$tmp/route.err")"
DUP_CLOSED='[{"number":1762,"closedAt":"2026-11-25T03:00:00Z","mergedAt":null,"body":"Closes #1700\nRefs #1748"}]' DUP_COMMENTS=$two_fails dup_run "#1748|fullstack-dev"
[ "$route_ec" = 0 ] && ok || bad "1839c: a PR that only Refs the issue does not refuse it (ec=$route_ec) $(cat "$tmp/route.err")"
DUP_CLOSED=$closed_prs DUP_COMMENTS=$two_fails dup_run "#1748|qa-sdet"
[ "$route_ec" = 0 ] && ok || bad "1839c: a verifier is not refused for two FAILs (ec=$route_ec) $(cat "$tmp/route.err")"

# 1957: work_order.max_workers refuses a hand start at the ceiling; --force-over-cap REASON starts it and is logged.
# The orca-dup stub lists one live worker.
jq '.work_order = {"max_workers": 1}' "$FLEET_WATCH_CONFIG" >"$tmp/fleet-max1.json" 2>/dev/null || echo '{"work_order":{"max_workers":1}}' >"$tmp/fleet-max1.json"
jq '.work_order = {"max_workers": 2}' "$tmp/fleet-max1.json" >"$tmp/fleet-max2.json"
rm -f "$route_state/force-over-cap.log"
FLEET_WATCH_CONFIG="$tmp/fleet-max1.json" dup_run "#1748|fullstack-dev"
[ "$route_ec" = 2 ] && grep -Fq 'refused: 1 workers live, at max_workers 1' "$tmp/route.err" && ok || bad "1957: a hand start at max_workers exits 2 (ec=$route_ec) $(cat "$tmp/route.err")"
grep -q 'worker-start' "$tmp/orca-route.log" && bad "1957: a refused start must not reach worker-start" || ok
FLEET_WATCH_CONFIG="$tmp/fleet-max1.json" dup_run "#1748|fullstack-dev" --force-over-cap "merge queue"
[ "$route_ec" = 0 ] && grep -q 'worker-start' "$tmp/orca-route.log" && ok || bad "1957: --force-over-cap starts over the ceiling (ec=$route_ec) $(cat "$tmp/route.err")"
jq -e 'select(.reason == "merge queue" and .live == 1 and .max_workers == 1 and .title == "#1748|fullstack-dev")' "$route_state/force-over-cap.log" >/dev/null 2>&1 \
  && ok || bad "1957: --force-over-cap is logged ($(cat "$route_state/force-over-cap.log" 2>/dev/null))"
FLEET_WATCH_CONFIG="$tmp/fleet-max2.json" dup_run "#1748|fullstack-dev"
[ "$route_ec" = 0 ] && ok || bad "1957: under max_workers starts (ec=$route_ec) $(cat "$tmp/route.err")"
FLEET_WATCH=1 FLEET_WATCH_CONFIG="$tmp/fleet-max1.json" dup_run "#1748|fullstack-dev"
[ "$route_ec" = 0 ] && ok || bad "1957: a fleet-watch start skips the hand ceiling (ec=$route_ec) $(cat "$tmp/route.err")"
dup_run "#1748|fullstack-dev"
[ "$route_ec" = 0 ] && ! grep -q 'max_workers' "$tmp/route.err" && ok || bad "1957: no max_workers key starts as today (ec=$route_ec) $(cat "$tmp/route.err")"

# 1839: a start whose dispatch exists although a later step failed prints the dispatch and exits 0 (#10098).
sed 's#^  \*" orchestration task-list "\*|\*" orchestration worker-list "\*)#  *" orchestration worker-list "*) printf "%s\\n" "{\\"ok\\":true,\\"result\\":{\\"workers\\":[{\\"dispatchId\\":\\"ctx_late\\",\\"state\\":\\"ready\\",\\"liveness\\":\\"live\\",\\"terminalState\\":\\"active\\",\\"workspace\\":\\"repo::$WT_PROOF\\"}]}}"; exit 0 ;;\n  *" orchestration task-list "*)#' \
  "$orca_fail_stub" >"$tmp/orca-late"
chmod +x "$tmp/orca-late"
run_path=$run_path_dup_saved
orca_fail_stub="$tmp/orca-late" fail_start "$tmp/orca-late.log" --name n1 --repo "path:$clean"
[ "$fail_ec" = 0 ] && ok || bad "1839: a failed start with a live dispatch exits 0 ($fail_ec) $(cat "$tmp/orca-late.log")"
grep -Fq 'worktree rm' "$tmp/orca-late.log" && bad "1839: a started dispatch keeps its worktree" || ok
late_out=$(env -u BASH_ENV PATH="$run_path" ORCA_CLI_COMMAND="$tmp/orca-late" ORCA_STUB_LOG=/dev/null \
  FLEET_PULL_CONFIG="$tmp/fleet.json" PYTHON="$PYTHON" USAGE_GATE_CLI="$USAGE_GATE_CLI" WORKER_STARTUP_STATE="$launch_state" \
  bash --noprofile --norc "$script" --run run_x --spec "$spec_file" --title "#1|fullstack-dev" --agent claude --model claude-sonnet-5-5-medium \
  --from term_coord --name n1 --repo "path:$clean" 2>&1) || true
grep -Fq 'dispatch ctx_late exists although a later start step failed (exit 7)' <<<"$late_out" && ok || bad "1839: names the dispatch ($late_out)"
# A reused worktree whose live worker was there before the start is not this start's dispatch: the failure stands.
orca_fail_stub="$tmp/orca-late" fail_start "$tmp/orca-late.log" --worktree-path "$wt_proof"
[ "$fail_ec" = 7 ] && ok || bad "1839: an older live worker in a reused worktree does not turn a failed start into success ($fail_ec)"

# 1839: --close-after-fails closes the PR with the lesson and relabels every linked issue needs-triage.
close_gh="$tmp/close-gh"
mkdir -p "$close_gh"
cat >"$close_gh/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_LOG"
case "$1 $2" in
  "pr view") printf '%s\n' '{"body":"Closes #1748\nFixes acme/other#13\nRefs #1700\nBuilder: x"}' | jq -r "${@: -1}" ;;
  "pr close") [ -z "${CLOSE_FAIL:-}" ] || exit 1 ;;
esac
exit 0
EOS
chmod +x "$close_gh/gh"
printf 'Two failed Reviews; redesign.\n' >"$tmp/lesson.md"
: >"$GH_STUB_LOG"
close_out=$(PATH="$close_gh:$run_path" bash "$script" --close-after-fails --repo acme/app --pr 1760 --comment-file "$tmp/lesson.md" 2>&1); close_ec=$?
[ "$close_ec" = 0 ] && ok || bad "1839: close helper exits 0 ($close_ec) $close_out"
grep -Fxq 'pr close 1760 -R acme/app --comment Two failed Reviews; redesign.' "$GH_STUB_LOG" && ok || bad "1839: close helper closes the PR with the lesson ($(cat "$GH_STUB_LOG"))"
grep -Fxq 'issue edit 1748 -R acme/app --remove-label ready-for-agent --add-label needs-triage' "$GH_STUB_LOG" && ok || bad "1839: the closed issue goes to needs-triage ($(cat "$GH_STUB_LOG"))"
grep -Fxq 'issue edit 13 -R acme/other --remove-label ready-for-agent --add-label needs-triage' "$GH_STUB_LOG" && ok || bad "1839: a Fixes issue in another repo is relabeled there ($(cat "$GH_STUB_LOG"))"
grep -q '^issue edit 1700 ' "$GH_STUB_LOG" && bad "1839: a Refs parent is not relabeled ($(cat "$GH_STUB_LOG"))" || ok
: >"$GH_STUB_LOG"
CLOSE_FAIL=1 PATH="$close_gh:$run_path" bash "$script" --close-after-fails --repo acme/app --pr 1760 --comment-file "$tmp/lesson.md" >/dev/null 2>&1 && bad "1839: a failed close exits non-zero" || ok
grep -q '^issue edit' "$GH_STUB_LOG" && bad "1839: a failed close relabels nothing" || ok
printf '%s\n' "$dup_spec_saved" >"$spec_file"

rm -f "$bin/hostname"

echo "worker-startup: $pass passed, $fail failed"
[ "$fail" = 0 ]
