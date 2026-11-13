#!/usr/bin/env bash
# board-done.py: dry run by default; --apply sets Done; --fleet skips an unreachable host.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/env"
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
case "$*" in
  'environment list --json') cat "$FAKE_ENVS" ;;
  'worktree list --json') cat "$FAKE_LOCAL" ;;
  'worktree list --environment down --json') echo 'board-done-fake: down' >&2; exit 1 ;;
  'worktree list --environment up --json') cat "$FAKE_UP" ;;
  'orchestration worker-list --limit 100 --json') cat "$FAKE_WORKERS" ;;
  'orchestration worker-list --environment up --limit 100 --json') echo '{"ok":true,"result":{"workers":[]}}' ;;
  'orchestration worker-list --environment down --limit 100 --json') exit 1 ;;
  'worktree set '*) exit 0 ;;
  *) echo "unexpected orca: $*" >&2; exit 1 ;;
esac
FAKE
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  'pr list') cat "$FAKE_PRS" ;;
  'issue view')
    python3 - "$3" "$FAKE_ISSUES" <<'PY'
import json, sys
number, path = int(sys.argv[1]), sys.argv[2]
for row in json.load(open(path)):
    if row["number"] == number:
        json.dump(row, sys.stdout)
        break
else:
    sys.exit(1)
PY
    ;;
  *) echo "unexpected gh: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$tmp/bin/orca" "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" ORCA_CLI_COMMAND="$tmp/bin/orca" ORCA_LOG="$tmp/orca.log" GH_LOG="$tmp/gh.log"
export BOARD_DONE_STAMP="$tmp/stamps.json"
export FAKE_ENVS="$tmp/envs.json" FAKE_LOCAL="$tmp/local.json" FAKE_UP="$tmp/up.json"
export FAKE_WORKERS="$tmp/workers.json" FAKE_PRS="$tmp/prs.json" FAKE_ISSUES="$tmp/issues.json"
cat > "$FAKE_ENVS" <<'JSON'
{"ok":true,"result":{"environments":[{"id":"up","name":"up"},{"id":"down","name":"down"}]}}
JSON
cat > "$FAKE_LOCAL" <<'JSON'
{"ok":true,"result":{"truncated":false,"worktrees":[
 {"path":"/w/merged","projectId":"github:acme/app","branch":"refs/heads/feat-merged","workspaceStatus":"in-progress"},
 {"path":"/w/open","projectId":"github:acme/app","branch":"refs/heads/feat-open","workspaceStatus":"in-review"},
 {"path":"/w/released","projectId":"github:acme/app","branch":"refs/heads/feat-released","workspaceStatus":"in-progress"},
 {"path":"/w/main","projectId":"github:acme/app","branch":"refs/heads/main","isMainWorktree":true,"workspaceStatus":"in-progress"}
]}}
JSON
cat > "$FAKE_UP" <<'JSON'
{"ok":true,"result":{"truncated":false,"worktrees":[
 {"path":"/remote/merged","projectId":"github:acme/app","branch":"refs/heads/feat-remote","workspaceStatus":"in-progress"}
]}}
JSON
cat > "$FAKE_WORKERS" <<'JSON'
{"ok":true,"result":{"workers":[
 {"state":"succeeded","liveness":"exited","terminalState":"released","workspace":"repo::/w/released"}
]}}
JSON
cat > "$FAKE_PRS" <<'JSON'
[{"number":12,"state":"MERGED","headRefName":"feat-merged","closingIssuesReferences":[]},
 {"number":9,"state":"OPEN","headRefName":"feat-open","closingIssuesReferences":[]},
 {"number":20,"state":"MERGED","headRefName":"feat-remote","closingIssuesReferences":[]}]
JSON
echo '[]' > "$FAKE_ISSUES"
passed=0 failed=0
ok() { printf 'ok %s\n' "$1"; passed=$((passed + 1)); }
bad() { printf 'FAIL %s: %s\n' "$1" "$2"; failed=$((failed + 1)); }

: > "$ORCA_LOG"; : > "$GH_LOG"
out=$(python3 "$here/board-done.py" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok 'default run exits 0' || bad 'default run exits 0' "rc=$rc $out"
grep -q 'worktree set' "$ORCA_LOG" && bad 'default run is a dry run' "$(cat "$ORCA_LOG")" || ok 'default run is a dry run'
grep -Fq '[dry-run] would set /w/merged completed (PR #12 merged) environment=local' <<<"$out" && ok 'merged PR would move' || bad 'merged PR would move' "$out"
grep -Fq '[dry-run] would set /w/released completed (worker released, no PR) environment=local' <<<"$out" && ok 'released worker with no PR would move' || bad 'released worker with no PR would move' "$out"
grep -Fq '/w/open' <<<"$out" && bad 'open PR stays' "$out" || ok 'open PR stays'
grep -Fq '/w/main' <<<"$out" && bad 'main stays' "$out" || ok 'main stays'
grep -Fq 'dry-run: moved=2 unchanged=2 skipped_hosts=0' <<<"$out" && ok 'dry run counts' || bad 'dry run counts' "$out"
[ ! -e "$BOARD_DONE_STAMP" ] && ok 'dry run records no Done time' || bad 'dry run records no Done time' "$(cat "$BOARD_DONE_STAMP" 2>/dev/null)"

: > "$ORCA_LOG"
out=$(python3 "$here/board-done.py" --apply 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok '--apply exits 0' || bad '--apply exits 0' "rc=$rc $out"
grep -Fxq 'worktree set --worktree path:/w/merged --workspace-status completed' "$ORCA_LOG" && ok 'apply sets the merged card' || bad 'apply sets the merged card' "$(cat "$ORCA_LOG")"
grep -Fxq 'worktree set --worktree path:/w/released --workspace-status completed' "$ORCA_LOG" && ok 'apply sets the released card' || bad 'apply sets the released card' "$(cat "$ORCA_LOG")"
grep -Fq 'applied: moved=2 unchanged=2 skipped_hosts=0' <<<"$out" && ok 'apply counts' || bad 'apply counts' "$out"
python3 -c 'import json,sys; stamps=json.load(open(sys.argv[1])); raise SystemExit(0 if any(k.endswith("/w/merged") for k in stamps) else 1)' "$BOARD_DONE_STAMP" \
  && ok 'apply records when the card became Done' || bad 'apply records when the card became Done' "$(cat "$BOARD_DONE_STAMP" 2>/dev/null)"

: > "$ORCA_LOG"
out=$(python3 "$here/board-done.py" --fleet --dry-run 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok 'fleet dry run exits 0' || bad 'fleet dry run exits 0' "rc=$rc $out"
grep -Fq 'board-done: skip down (unreachable), retry next round' <<<"$out" && ok 'unreachable host is skipped and retried' || bad 'unreachable host is skipped and retried' "$out"
grep -Fq 'gone' <<<"$out" && bad 'unreachable host is not treated as gone' "$out" || ok 'unreachable host is not treated as gone'
grep -Fq '[dry-run] would set /remote/merged completed (PR #20 merged) environment=up' <<<"$out" && ok 'fleet reaches the other host' || bad 'fleet reaches the other host' "$out"
grep -Fq 'worktree list --environment up --json' "$ORCA_LOG" && ok 'fleet lists with --environment' || bad 'fleet lists with --environment' "$(cat "$ORCA_LOG")"
grep -Fq 'skipped_hosts=1' <<<"$out" && ok 'fleet counts the skipped host' || bad 'fleet counts the skipped host' "$out"

: > "$ORCA_LOG"
python3 "$here/board-done.py" --apply --environment up >/dev/null 2>&1
grep -Fxq 'worktree set --worktree path:/remote/merged --workspace-status completed --environment up' "$ORCA_LOG" \
  && grep -Fxq 'worktree list --environment up --json' "$ORCA_LOG" && ok '--environment sets that host only' || bad '--environment sets that host only' "$(cat "$ORCA_LOG")"
grep -Fq 'worktree list --json' "$ORCA_LOG" && bad '--environment does not list local' "$(cat "$ORCA_LOG")" || ok '--environment does not list local'

python3 "$here/board-done.py" --fleet --environment up >/dev/null 2>&1
[ "$?" -eq 2 ] && ok 'fleet and environment together are a usage error' || bad 'fleet and environment together are a usage error' ''

printf 'passed %s, failed %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
