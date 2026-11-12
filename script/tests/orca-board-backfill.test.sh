#!/usr/bin/env bash
# orca-board-backfill.sh: dry run by default, --apply sets the board status from each branch's PR state.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
case "$*" in
  'worktree list --json'*) cat "$FAKE_WORKTREES" ;;
  'worktree set '*) exit "${ORCA_SET_RC:-0}" ;;
  *) exit 1 ;;
esac
FAKE
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
cat "$FAKE_PRS"
FAKE
chmod +x "$tmp/bin/orca" "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" ORCA_CLI_COMMAND="$tmp/bin/orca" ORCA_LOG="$tmp/orca.log" GH_LOG="$tmp/gh.log"
export FAKE_WORKTREES="$tmp/worktrees.json" FAKE_PRS="$tmp/prs.json"
cat > "$FAKE_WORKTREES" <<'JSON'
{"ok":true,"result":{"truncated":false,"worktrees":[
 {"path":"/w/main","projectId":"github:acme/app","branch":"refs/heads/main","isMainWorktree":true,"workspaceStatus":"in-progress"},
 {"path":"/w/merged one","projectId":"github:acme/app","branch":"refs/heads/feat-merged","workspaceStatus":"in-progress"},
 {"path":"/w/closed","projectId":"github:acme/app","branch":"refs/heads/feat-closed","workspaceStatus":"in-progress"},
 {"path":"/w/open","projectId":"github:acme/app","branch":"refs/heads/feat-open","workspaceStatus":"in-progress"},
 {"path":"/w/reopened","projectId":"github:acme/app","branch":"refs/heads/feat-reopened","workspaceStatus":"in-progress"},
 {"path":"/w/nopr","projectId":"github:acme/app","branch":"refs/heads/feat-nopr","workspaceStatus":"in-progress"},
 {"path":"/w/done","projectId":"github:acme/app","branch":"refs/heads/feat-done","workspaceStatus":"completed"},
 {"path":"/w/detached","projectId":"github:acme/app","branch":"","workspaceStatus":"in-progress"},
 {"path":"/w/local","projectId":"folder:x","branch":"refs/heads/feat-merged","workspaceStatus":"in-progress"}
]}}
JSON
cat > "$FAKE_PRS" <<'JSON'
[{"headRefName":"feat-merged","state":"MERGED"},{"headRefName":"feat-closed","state":"CLOSED"},
 {"headRefName":"feat-open","state":"OPEN"},{"headRefName":"feat-reopened","state":"CLOSED"},
 {"headRefName":"feat-reopened","state":"OPEN"},{"headRefName":"feat-done","state":"MERGED"}]
JSON
passed=0 failed=0
ok() { printf 'ok %s\n' "$1"; passed=$((passed+1)); }
bad() { printf 'FAIL %s: %s\n' "$1" "$2"; failed=$((failed+1)); }

: > "$ORCA_LOG"
out=$(bash "$here/orca-board-backfill.sh" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok 'default run exits 0' || bad 'default run exits 0' "rc=$rc $out"
grep -Fq 'worktree set' "$ORCA_LOG" && bad 'default run is a dry run' "$(cat "$ORCA_LOG")" || ok 'default run is a dry run'
[ "$out" = "$(bash "$here/orca-board-backfill.sh" --dry-run 2>&1)" ] && ok '--dry-run matches the default' || bad '--dry-run matches the default' "$out"
tail -1 <<<"$out" | grep -Fxq 'dry-run: completed=2 in-review=2 unchanged=4' && ok 'dry run prints the counts' || bad 'dry run prints the counts' "$out"
for line in '/w/merged one -> completed' '/w/closed -> completed' '/w/open -> in-review' '/w/reopened -> in-review'; do
  grep -Fq "$line" <<<"$out" && ok "plans $line" || bad "plans $line" "$out"
done
grep -Fq -e '-> ' <<<"$(grep -e '/w/nopr\|/w/done\|/w/main\|/w/detached\|/w/local' <<<"$out")" && bad 'other worktrees untouched' "$out" || ok 'other worktrees untouched'
[ "$(wc -l < "$GH_LOG")" -eq 2 ] && grep -Fq 'pr list --repo acme/app --state all' "$GH_LOG" && ok 'one gh call per project' || bad 'one gh call per project' "$(cat "$GH_LOG")"

: > "$ORCA_LOG"
out=$(bash "$here/orca-board-backfill.sh" --apply 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok '--apply exits 0' || bad '--apply exits 0' "rc=$rc $out"
tail -1 <<<"$out" | grep -Fxq 'applied: completed=2 in-review=2 unchanged=4' && ok '--apply prints the counts' || bad '--apply prints the counts' "$out"
sets=$(grep -c '^worktree set' "$ORCA_LOG")
[ "$sets" -eq 4 ] && ok '--apply sets exactly four worktrees' || bad '--apply sets exactly four worktrees' "$(cat "$ORCA_LOG")"
grep -Fxq 'worktree set --worktree path:/w/merged one --workspace-status completed' "$ORCA_LOG" && ok 'merged becomes completed' || bad 'merged becomes completed' "$(cat "$ORCA_LOG")"
grep -Fxq 'worktree set --worktree path:/w/closed --workspace-status completed' "$ORCA_LOG" && ok 'closed becomes completed' || bad 'closed becomes completed' "$(cat "$ORCA_LOG")"
grep -Fxq 'worktree set --worktree path:/w/open --workspace-status in-review' "$ORCA_LOG" && ok 'open becomes in-review' || bad 'open becomes in-review' "$(cat "$ORCA_LOG")"
grep -Fxq 'worktree set --worktree path:/w/reopened --workspace-status in-review' "$ORCA_LOG" && ok 'an open PR beats an older closed one' || bad 'an open PR beats an older closed one' "$(cat "$ORCA_LOG")"

: > "$ORCA_LOG"
bash "$here/orca-board-backfill.sh" --apply --environment other-host >/dev/null 2>&1
grep -Fxq 'worktree set --worktree path:/w/open --workspace-status in-review --environment other-host' "$ORCA_LOG" \
  && grep -Fxq 'worktree list --json --environment other-host' "$ORCA_LOG" && ok '--environment reaches list and set' || bad '--environment reaches list and set' "$(cat "$ORCA_LOG")"

printf '{"ok":true,"result":{"truncated":true,"worktrees":[]}}\n' > "$FAKE_WORKTREES"
out=$(bash "$here/orca-board-backfill.sh" --apply 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok 'truncated list stops the run' || bad 'truncated list stops the run' "$out"
bash "$here/orca-board-backfill.sh" --bogus >/dev/null 2>&1; [ $? -eq 2 ] && ok 'unknown flag is a usage error' || bad 'unknown flag is a usage error' ''

printf 'passed %s, failed %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
