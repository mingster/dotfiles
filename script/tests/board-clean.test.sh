#!/usr/bin/env bash
# board-clean.py: dry run names every Done card; apply uses the dispatch host; an unreachable host is retried.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
case "$*" in
  'environment list --json') cat "$FAKE_ENVS" ;;
  'worktree list --json') cat "$FAKE_LOCAL" ;;
  'worktree list --environment down --json') echo 'board-clean-fake: down' >&2; exit 1 ;;
  'worktree list --environment up --json') cat "$FAKE_UP" ;;
  'orchestration run-list --json') echo '{"ok":true,"result":{"runs":[{"id":"run-local"}]}}' ;;
  'orchestration run-list --environment up --json') echo '{"ok":true,"result":{"runs":[{"id":"run-up"}]}}' ;;
  'orchestration run-list --environment down --json') exit 1 ;;
  'orchestration worker-list --limit 100 --json') cat "$FAKE_WORKERS" ;;
  'orchestration worker-list --limit 100 --environment up --json') cat "$FAKE_UP_WORKERS" ;;
  'orchestration worker-list --run run-local --limit 100 --json') cat "$FAKE_WORKERS" ;;
  'orchestration worker-list --run run-up --limit 100 --environment up --json') cat "$FAKE_UP_WORKERS" ;;
  'terminal list --worktree path:'*) echo '{"ok":true,"result":{"terminals":[],"truncated":false}}' ;;
  'terminal close '*) echo '{"ok":true,"result":{}}' ;;
  'terminal create '*) echo '{"ok":true,"result":{"handle":"t-del"}}' ;;
  'terminal wait '*) echo '{"ok":true,"result":{}}' ;;
  'worktree rm '*) echo '{"ok":true,"result":{}}' ;;
  'worktree set '*) echo '{"ok":true,"result":{}}' ;;
  *) echo "unexpected orca: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$tmp/bin/orca"
export PATH="$tmp/bin:$PATH" ORCA_CLI_COMMAND="$tmp/bin/orca" ORCA_LOG="$tmp/orca.log"
export FAKE_ENVS="$tmp/envs.json" FAKE_LOCAL="$tmp/local.json" FAKE_UP="$tmp/up.json"
export FAKE_WORKERS="$tmp/workers.json" FAKE_UP_WORKERS="$tmp/up-workers.json"
export BOARD_CLEAN_FACTS="$tmp/facts.json" BOARD_CLEAN_NOW_MS=1800000000000 BOARD_DONE_STAMP="$tmp/stamps.json"
old=1700000000000
young=1799999940000
cat > "$FAKE_ENVS" <<'JSON'
{"ok":true,"result":{"environments":[{"id":"up","name":"up"},{"id":"down","name":"down"}]}}
JSON
python3 - "$FAKE_LOCAL" "$old" "$young" <<'PY'
import json, sys
path, old, young = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def card(path, branch, status="completed", activity=None, main=False):
    row = {"path": path, "projectId": "github:acme/app", "branch": branch, "workspaceStatus": status, "isMainWorktree": main}
    if activity is not None:
        row["lastActivityAt"] = activity
    return row
json.dump({"ok": True, "result": {"truncated": False, "worktrees": [
    card("/w/clean", "refs/heads/feat-clean", activity=old),
    card("/w/dirty", "refs/heads/feat-dirty", activity=old),
    card("/w/young", "refs/heads/feat-young", activity=young),
    card("/w/open", "refs/heads/feat-open", status="in-progress", activity=old),
    card("/w/failed", "refs/heads/feat-failed", activity=old),
    card("/w/failed-push", "refs/heads/feat-failed-push", activity=old),
]}}, open(path, "w"))
PY
python3 - "$FAKE_UP" "$old" <<'PY'
import json, sys
path, old = sys.argv[1], int(sys.argv[2])
json.dump({"ok": True, "result": {"truncated": False, "worktrees": [
    {"path": "/remote/main", "projectId": "github:acme/app", "branch": "refs/heads/main", "isMainWorktree": True, "workspaceStatus": "in-progress"},
    {"path": "/remote/verify", "projectId": "github:acme/app", "branch": "refs/heads/verify-1", "workspaceStatus": "completed", "isMainWorktree": False, "lastActivityAt": old},
]}}, open(path, "w"))
PY
cat > "$FAKE_WORKERS" <<'JSON'
{"ok":true,"result":{"workers":[
 {"state":"succeeded","liveness":"exited","terminalState":"released","workspace":"repo::/w/clean"},
 {"state":"succeeded","liveness":"exited","terminalState":"released","workspace":"repo::/w/dirty"},
 {"state":"succeeded","liveness":"exited","terminalState":"released","workspace":"repo::/w/young"},
 {"state":"failed","liveness":"exited","terminalState":"released","workspace":"repo::/w/failed"},
 {"state":"failed","liveness":"exited","terminalState":"released","workspace":"repo::/w/failed-push"}
]}}
JSON
cat > "$FAKE_UP_WORKERS" <<'JSON'
{"ok":true,"result":{"workers":[
 {"state":"succeeded","liveness":"exited","terminalState":"released","projection":{"host":{"id":"up"}},"workspace":"repo::/remote/verify"}
]}}
JSON
python3 - "$BOARD_CLEAN_FACTS" <<'PY'
import json, sys
json.dump({
    "/w/clean": {"dirty": False, "unpushed": False},
    "/w/dirty": {"dirty": True, "unpushed": False},
    "/w/young": {"dirty": False, "unpushed": False},
    "/w/failed": {"dirty": False, "unpushed": False},
    "/w/failed-push": {"dirty": False, "unpushed": True},
    "/remote/verify": {"dirty": False, "unpushed": True},
}, open(sys.argv[1], "w"))
PY
passed=0 failed=0
ok() { printf 'ok %s\n' "$1"; passed=$((passed + 1)); }
bad() { printf 'FAIL %s: %s\n' "$1" "$2"; failed=$((failed + 1)); }

: > "$ORCA_LOG"
out=$(python3 "$here/board-clean.py" --fleet --dry-run 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok 'dry run exits 0' || bad 'dry run exits 0' "rc=$rc $out"
grep -Fq '[dry-run] would clean /w/clean (worktree, local branch, remote branch, terminals, session) environment=local' <<<"$out" \
  && ok 'names a card it would clean' || bad 'names a card it would clean' "$out"
grep -Fq '[dry-run] would keep /w/dirty (unsaved changes) environment=local' <<<"$out" \
  && ok 'names a card it would keep' || bad 'names a card it would keep' "$out"
grep -Fq '[dry-run] would keep /w/young (Done for less than 30 minutes) environment=local' <<<"$out" \
  && ok 'a card Done under 30 minutes stays' || bad 'a card Done under 30 minutes stays' "$out"
grep -Fq '[dry-run] would clean /w/failed (worktree, local branch, remote branch, terminals, session) environment=local' <<<"$out" \
  && ok 'a failed card is cleaned when the guards pass' || bad 'a failed card is cleaned when the guards pass' "$out"
grep -Fq '[dry-run] would keep /w/failed-push (commits not on any remote) environment=local' <<<"$out" \
  && ok 'a failed card with unpushed commits stays' || bad 'a failed card with unpushed commits stays' "$out"
grep -Fq '[dry-run] would clean /remote/verify (worktree, local branch, remote branch, terminals, session) environment=up' <<<"$out" \
  && ok 'names the remote throwaway card' || bad 'names the remote throwaway card' "$out"
grep -Fq '/w/open' <<<"$out" && bad 'an open card is not a cleanup decision' "$out" || ok 'an open card is not a cleanup decision'
grep -Fq 'board-clean: skip down (unreachable), retry next round' <<<"$out" && ok 'unreachable host is skipped and retried' || bad 'unreachable host is skipped and retried' "$out"
grep -Fq 'gone' <<<"$out" && bad 'unreachable host is not treated as gone' "$out" || ok 'unreachable host is not treated as gone'
grep -Fq 'dry-run: clean=3 keep=3 skipped_hosts=1' <<<"$out" && ok 'dry run counts every named card' || bad 'dry run counts every named card' "$out"
grep -Eq 'worktree (rm|set) ' "$ORCA_LOG" && bad 'dry run does not remove or comment' "$(cat "$ORCA_LOG")" || ok 'dry run does not remove or comment'

: > "$ORCA_LOG"
out=$(python3 "$here/board-clean.py" --fleet --apply 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok 'apply exits 0' || bad 'apply exits 0' "rc=$rc $out"
grep -Fxq 'worktree rm --worktree path:/w/clean --delete-branch --json' "$ORCA_LOG" \
  && ok 'apply removes the local card' || bad 'apply removes the local card' "$(cat "$ORCA_LOG")"
grep -Fxq 'worktree rm --worktree path:/remote/verify --delete-branch --environment up --json' "$ORCA_LOG" \
  && ok 'apply cleans on the dispatch host' || bad 'apply cleans on the dispatch host' "$(cat "$ORCA_LOG")"
grep -Fq "branch -D 'verify-1'" "$ORCA_LOG" && grep -Fq 'push origin --delete' "$ORCA_LOG" \
  && ok 'a released verify branch is deleted even with local commits' || bad 'a released verify branch is deleted even with local commits' "$(cat "$ORCA_LOG")"
grep -Fxq 'worktree set --worktree path:/w/dirty --comment unsaved changes --json' "$ORCA_LOG" \
  && ok 'a kept card gets a board comment' || bad 'a kept card gets a board comment' "$(cat "$ORCA_LOG")"
grep -Fq 'worktree rm --worktree path:/w/dirty' "$ORCA_LOG" && bad 'a dirty card is not removed' "$(cat "$ORCA_LOG")" || ok 'a dirty card is not removed'
grep -Fq 'terminal close --terminal t-del --environment up --json' "$ORCA_LOG" \
  && ok 'the branch-delete session is closed' || bad 'the branch-delete session is closed' "$(cat "$ORCA_LOG")"

printf 'passed %s, failed %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
