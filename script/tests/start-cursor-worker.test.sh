#!/usr/bin/env bash
# Acceptance case 4: worker brief is the spec body with no global instructions prepend.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=lib/asdf-pin.sh
. "$root/script/tests/lib/asdf-pin.sh"
path_no_asdf=$(printf '%s\n' "${PATH//:/$'\n'}" | grep -v '/\.asdf/shims$' | paste -sd: -)
python_bin=$(PATH="$path_no_asdf" type -P python3)
[ -x "$python_bin" ] || { echo "missing python3" >&2; exit 1; }
mkdir -p "$tmp/home" "$tmp/bin"
export HOME="$tmp/home" DOTFILES="$root" CURSOR_TEST_LOG="$tmp/calls" ORCA_CLI_COMMAND="$tmp/bin/orca"
export PATH="$tmp/bin:$(dirname "$python_bin"):/usr/bin:/bin"
export USAGE_GATE_CLI="$tmp/gate.py"
printf 'import sys\nsys.exit(0)\n' > "$USAGE_GATE_CLI"
cat > "$ORCA_CLI_COMMAND" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CURSOR_TEST_LOG"
case "$*" in
  'worktree create '*)
    printf '%s\n' '{"result":{"worktree":{"path":"/tmp/example.repo/work tree.v1"}}}' ;;
  'orchestration worker-start '*)
    printf '%s\n' '{"result":{"state":"dispatched"}}' ;;
  *) exit 99 ;;
esac
STUB
chmod +x "$ORCA_CLI_COMMAND"
printf 'Fixture spec body only.\n' > "$tmp/spec"
bash "$root/script/start-cursor-worker.sh" \
  --run run_fixture --spec "$tmp/spec" --title 'fullstack-dev - fixture' --model composer-2.5 --from term_fixture \
  --name fixture --repo /tmp/example.repo --base-branch origin/main >"$tmp/result"
grep -Fq 'Fixture spec body only.' "$CURSOR_TEST_LOG" || { echo "FAIL: spec body missing from brief" >&2; exit 1; }
grep -Fq '.agents/claude/CLAUDE.md' "$CURSOR_TEST_LOG" && { echo "FAIL: global instructions prepend still present" >&2; exit 1; }
! grep -Fq 'Read ' "$CURSOR_TEST_LOG" || { echo "FAIL: brief still starts with a read line" >&2; exit 1; }
echo 'PASS: brief is the spec body without global instructions prepend'
