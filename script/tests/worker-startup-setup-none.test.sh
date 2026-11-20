#!/usr/bin/env bash
# #1239: a `Setup: none` brief skips the install hook but keeps the git-only fast-forward, local and remote.
# A plain brief keeps --setup run with no extra git-only step. Home and state files stay under $tmp.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

# The real python3 may be a shim that needs the real HOME, so pin it behind a wrapper first.
real_python=$(python3 -c "import sys; print(sys.executable)")
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nexec %s "$@"\n' "$real_python" >"$tmp/bin/python3"
chmod +x "$tmp/bin/python3"
export PATH="$tmp/bin:$PATH"
mkdir -p "$tmp/home" "$tmp/state"
export HOME="$tmp/home" XDG_STATE_HOME="$tmp/state" WORKER_STARTUP_STATE="$tmp/state/worker-startup" \
  FLEET_WATCH_CONFIG="$tmp/no-watch.json" FLEET_PLACEMENT_CONFIG="$tmp/no-placement.json" FLEET_PULL_CONFIG="$tmp/cfg.json" \
  TEAM_AUDIT_DISPATCHES="$tmp/dispatches.tsv" WORKER_PLACEMENT_RECENT_FILE="$tmp/recent.tsv" \
  AGENT_STATE_DIR="$tmp/agent-state"

cat >"$tmp/orca" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ORCA_LOG"
case "$*" in
  "orchestration worker-list"*) printf '{"result":{"workers":[]}}'; exit 0 ;;
  "worktree create"*) printf '{"result":{"worktree":{"path":"%s"}}}' "$WT_PATH"; exit 0 ;;
  "worktree list"*) printf '{"result":{"worktrees":[{"path":"%s","isMainWorktree":true}]}}' "$WT_PATH"; exit 0 ;;
  "terminal create"*) printf '{"result":{"terminal":{"handle":"term_stub"}}}'; exit 0 ;;
  "terminal wait"*) printf '{"result":{"wait":{"satisfied":true,"status":"exited","exitCode":0}}}'; exit 0 ;;
  "terminal close"*) printf '{"result":{}}'; exit 0 ;;
  "orchestration worker-start"*) printf '{"result":{"terminal":{"handle":"term_w"}}}'; exit 0 ;;
esac
exit 0
EOS
chmod +x "$tmp/orca"
printf 'import sys\nsys.exit(0)\n' >"$tmp/gate.py"
printf '{"hosts":["remote-host"],"repos":["%s"],"host_caps":{"remote-host":4}}' "$tmp/wt" >"$tmp/cfg.json"

# A real worktree whose origin is local, so the local git-only step runs for real.
git init -q -b main "$tmp/origin"
git -C "$tmp/origin" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git clone -q "$tmp/origin" "$tmp/wt"

run_start() { # <brief first line> [extra worker-startup args]: leaves the stub orca calls in $tmp/orca.log
  local line=$1; shift
  printf '%s\n\n## Acceptance\n- done\n\n## Out of scope\n- none\n\n## Verify\n`bash script/checks-local.sh`\n' "$line" >"$tmp/brief.md"
  : >"$tmp/orca.log"
  ORCA_CLI_COMMAND="$tmp/orca" ORCA_LOG="$tmp/orca.log" WT_PATH="$tmp/wt" USAGE_GATE_CLI="$tmp/gate.py" \
    bash "$here/worker-startup.sh" --run run_x --spec "$tmp/brief.md" --title '#1|fullstack-dev' \
    --agent claude --model m --from term_x --name n --repo path:"$tmp/wt" "$@" >"$tmp/out.log" 2>&1
}
setup_flag() { sed -n 's/^worktree create .*--setup \([a-z]*\).*/\1/p' "$tmp/orca.log" | head -1; }
git_only_calls() { grep -c 'terminal create .*worktree-setup.sh.* --git-only' "$tmp/orca.log" || true; }
order_ok() { # remote git-only terminal runs after worktree create and before worker-start
  local c g w
  c=$(grep -n '^worktree create' "$tmp/orca.log" | head -1 | cut -d: -f1)
  g=$(grep -n 'worktree-setup.sh.* --git-only' "$tmp/orca.log" | head -1 | cut -d: -f1)
  w=$(grep -n '^orchestration worker-start' "$tmp/orca.log" | head -1 | cut -d: -f1)
  if [ -n "$c" ] && [ -n "$g" ] && [ -n "$w" ] && [ "$c" -lt "$g" ] && [ "$g" -lt "$w" ]; then echo yes; else echo no; fi
}

git -C "$tmp/origin" -c user.email=t@t -c user.name=t commit -q --allow-empty -m advance
run_start 'Setup: none'
check "local Setup: none skips" "$(setup_flag)" skip
check "local Setup: none fast-forwards to origin/main" "$(git -C "$tmp/wt" rev-parse HEAD)" "$(git -C "$tmp/origin" rev-parse HEAD)"
check "local Setup: none runs no remote git-only" "$(git_only_calls)" 0

run_start 'Setup: none' --on remote-host
check "remote Setup: none skips" "$(setup_flag)" skip
check "remote Setup: none runs git-only once" "$(git_only_calls)" 1
check "remote git-only runs between create and worker-start" "$(order_ok)" yes

run_start 'Refs #1' --on remote-host
check "remote plain brief runs setup" "$(setup_flag)" run
check "remote plain brief has no git-only" "$(git_only_calls)" 0

check "no dispatch log written outside tmp" "$([ -e "$HOME/agent-state/team-dispatches.tsv" ] && echo leaked || echo clean)" clean
exit "$fail"
