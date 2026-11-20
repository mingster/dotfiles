#!/usr/bin/env bash
# #1239: a `Setup: none` brief skips the install hook on a remote host too, and a plain brief keeps --setup run.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

cat >"$tmp/orca" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ORCA_LOG"
case "$*" in
  "orchestration worker-list"*) printf '{"result":{"workers":[]}}'; exit 0 ;;
  "worktree create"*) printf '{"result":{"worktree":{"path":"%s"}}}' "$WT_PATH"; exit 0 ;;
esac
exit 1
EOS
chmod +x "$tmp/orca"
printf 'import sys\nsys.exit(0)\n' >"$tmp/gate.py"
printf '{"hosts":["remote-host"],"repos":["%s"],"host_caps":{"remote-host":4}}' "$tmp/wt" >"$tmp/cfg.json"
mkdir -p "$tmp/wt"

setup_flag() { # <brief first line> [extra worker-startup args]: prints the --setup value passed to worktree create
  local line=$1; shift
  printf '%s\n\n## Acceptance\n- done\n\n## Out of scope\n- none\n\n## Verify\n`bash script/checks-local.sh`\n' "$line" >"$tmp/brief.md"
  : >"$tmp/orca.log"
  ORCA_CLI_COMMAND="$tmp/orca" ORCA_LOG="$tmp/orca.log" WT_PATH="$tmp/wt" USAGE_GATE_CLI="$tmp/gate.py" \
    FLEET_PULL_CONFIG="$tmp/cfg.json" \
    bash "$here/worker-startup.sh" --run run_x --spec "$tmp/brief.md" --title '#1|fullstack-dev' \
    --agent claude --model m --from term_x --name n --repo path:/nonexistent "$@" >/dev/null 2>&1
  sed -n 's/^worktree create .*--setup \([a-z]*\).*/\1/p' "$tmp/orca.log" | head -1
}

check "local Setup: none skips" "$(setup_flag 'Setup: none')" skip
check "remote Setup: none skips" "$(setup_flag 'Setup: none' --on remote-host)" skip
check "remote plain brief runs setup" "$(setup_flag 'Refs #1' --on remote-host)" run
exit "$fail"
