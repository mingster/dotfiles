#!/usr/bin/env bash
# Issue 1221: a brand-new terminal (no agent identity yet, lastOutputAt null) is kept while it starts up, so wrap-up
# does not close a verifier before its agent attaches. An old idle shell is still closed. Disposable repo and fake Orca only.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/fake" "$tmp/home"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'repo view --json defaultBranchRef') echo '{"defaultBranchRef":{"name":"main"}}'; exit 0 ;;
  'api repos/{owner}/{repo}/pages') echo '{"source":null}'; exit 0 ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100') echo '[]'; exit 0 ;;
esac
echo '[]'
FAKE
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
args=("$@")
case "$*" in
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  *'terminal list'*) printf '{"ok":true,"result":{"terminals":%s}}\n' "$(cat "$FAKE_DIR/terminals")" ;;
  *'terminal close'*)
    for i in "${!args[@]}"; do [ "${args[$i]}" = --terminal ] && h=${args[$((i+1))]}; done
    echo "$h" >> "$FAKE_DIR/closed.log"
    jq -c --arg h "$h" 'map(select(.handle != $h))' "$FAKE_DIR/terminals" > "$FAKE_DIR/t.tmp" && mv "$FAKE_DIR/t.tmp" "$FAKE_DIR/terminals" ;;
  *worker-show*) printf '{"ok":true,"result":{"dispatch":{"status":"dispatched"},"terminal":{"cwd":"%s"}}}\n' "$FAKE_LIVE_CWD" ;;
  *run-list*) echo '{"ok":true,"result":{"runs":[{"id":"run-1"}]}}' ;;
  *worker-list*) printf '{"ok":true,"result":{"workers":%s,"page":{"hasMore":false,"nextCursor":null}}}\n' "$(cat "$FAKE_DIR/workers")" ;;
  'worktree list --json') echo '{"ok":true,"result":{"worktrees":[]}}' ;;
  *'worktree rm'*) exit 0 ;;
esac
FAKE
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/lsof"
printf '#!/usr/bin/env bash\necho init\n' > "$tmp/bin/ps"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export ORCA_CLI_COMMAND="$tmp/bin/orca" FAKE_DIR="$tmp/fake" ORCA_TERMINAL_HANDLE=t-own
export WRAP_UP_CLONE_ROOT="$tmp/no-clones" WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose" WRAP_UP_WT_ARCHIVE_ROOT="$tmp/wt-archive" WRAP_UP_RECENT_MIN=0
export WRAP_UP_STATE_DIR="$tmp/no-state" WRAP_UP_RECENT_MIN=0

git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
cd "$tmp/repo"
git config user.email test@example.invalid
git config user.name Test
git commit -qm initial --allow-empty
git remote add origin "$tmp/origin"
git push -q -u origin main
for n in w-shell w-new w-own; do git worktree add -q --detach "$tmp/$n" main; done
t() { # <handle> <worktree dir> <lastOutputAt>
  printf '{"handle":"%s","title":"x","worktreePath":"%s","connected":true,"writable":true,"agentIdentity":null,"lastOutputAt":%s}' "$1" "$2" "$3"
}
echo "[$(t t-own "$tmp/w-own" 1),$(t t-shell "$tmp/w-shell" 1),$(t t-new "$tmp/w-new" null)]" > "$FAKE_DIR/terminals"
echo '[]' > "$FAKE_DIR/workers"
export FAKE_LIVE_CWD="$tmp/none"

fail() { echo "FAIL $*"; cat "$tmp/output"; exit 1; }
bash "$here/wrap-up.sh" --worktrees-only --apply > "$tmp/output" 2> "$tmp/stderr"
sort "$FAKE_DIR/closed.log" | cmp - <(printf '%s\n' t-shell) || fail "wrong terminals closed: $(tr '\n' ' ' < "$FAKE_DIR/closed.log")"
grep -Fq 'Kept terminal t-new (local, starting up)' "$tmp/output" || fail 'no starting up reason for t-new'
[ -d "$tmp/w-new" ] || fail 'worktree of the starting terminal was removed'
echo 'ok a terminal with no output and no agent yet is kept as starting up; an idle shell is closed'
