#!/usr/bin/env bash
# Contract tests for script/weekly-update.sh (spec T17).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/.." && pwd -P)
script="$here/weekly-update.sh"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ $# -gt 1 ] && echo "$2"; }

[ -f "$script" ] || { echo "FAIL weekly-update.sh missing"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

bare="$tmp/origin.git"
work="$tmp/dotfiles"
git init -q --bare "$bare"
git clone -q "$bare" "$work"
git -C "$work" checkout -q -b main
mkdir -p "$work/script" "$work/script/tests" "$work/.agents/skills"
printf 'init\n' >"$work/README.md"
git -C "$work" add README.md
git -C "$work" commit -qm init
git -C "$work" remote set-url origin "$bare"
git -C "$work" push -q -u origin main

for s in sync-mattpocock-skills.sh sync-team-skills.sh adopt-agent-team.sh check-skill-collisions.sh weekly-update.sh; do
  cp "$root/script/$s" "$work/script/"
done
cp "$root/script/tests/weekly-update.test.sh" "$work/script/tests/"
cp "$root/script/tests/sync-mattpocock-skills.test.sh" "$work/script/tests/" 2>/dev/null || true
chmod +x "$work/script/"*.sh "$work/script/tests/"*.sh 2>/dev/null || true

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case " $* " in
  *" pr create "*) printf 'https://github.com/example/dotfiles/pull/1\n'; exit 0 ;;
esac
exit 0
EOS
chmod +x "$tmp/bin/gh"
export GH_LOG="$tmp/gh.log"
export PATH="$tmp/bin:$PATH"

run() {
  DOTFILES="$work" WEEKLY_UPDATE_DOTFILES="$work" \
    WEEKLY_UPDATE_SKIP_APPLY=1 \
    WEEKLY_UPDATE_TESTS_mattpocock='true' \
    WEEKLY_UPDATE_TESTS_pstack='true' \
    WEEKLY_UPDATE_TESTS_toolchain='true' \
    WEEKLY_UPDATE_BUN_UPGRADE=':' WEEKLY_UPDATE_BUN_UPDATE=':' \
    WEEKLY_UPDATE_NODE_LTS='24.22.1' \
    bash "$work/script/weekly-update.sh" "$@"
}

# --- no merge in the entry script ---
if grep -Eiq 'gh pr merge|lead-merge\.sh|--merge' "$script"; then
  bad 'weekly-update.sh must not call merge'
else
  ok 'no merge calls in weekly-update.sh'
fi

# --- dry-run lists three PRs, changes nothing ---
before=$(git -C "$work" status --porcelain | wc -l | tr -d ' ')
: >"$GH_LOG"
out=$(run --dry-run 2>&1) || true
after=$(git -C "$work" status --porcelain | wc -l | tr -d ' ')
[ "$before" = "$after" ] && ok 'dry-run leaves worktree clean' || bad 'dry-run must change nothing' "$(git -C "$work" status --short)"
n=$(printf '%s\n' "$out" | grep -c '^PLANNED PR ' || true)
[ "$n" = 3 ] && ok 'dry-run lists three PRs' || bad "dry-run PR count want 3 got $n" "$out"
! [ -s "$GH_LOG" ] && ok 'dry-run does not open PRs' || bad 'dry-run must not gh pr create' "$(cat "$GH_LOG")"

# --- failing tests: failed in summary, no PR for that slice ---
: >"$GH_LOG"
out=$(DOTFILES="$work" WEEKLY_UPDATE_DOTFILES="$work" \
  WEEKLY_UPDATE_SKIP_APPLY=1 \
  WEEKLY_UPDATE_TESTS_mattpocock='false' \
  WEEKLY_UPDATE_TESTS_pstack='true' \
  WEEKLY_UPDATE_TESTS_toolchain='true' \
  WEEKLY_UPDATE_BUN_UPGRADE=':' WEEKLY_UPDATE_BUN_UPDATE=':' \
  WEEKLY_UPDATE_NODE_LTS='24.22.1' \
  WEEKLY_UPDATE_NO_PUSH=1 \
  bash "$work/script/weekly-update.sh" 2>&1) || true
echo "$out" | grep -q 'PR mattpocock: failed' && ok 'summary marks failed PR' || bad 'failed PR in summary' "$out"
echo "$out" | grep -q 'PR pstack: opened' && ok 'passing PR still opened' || bad 'pstack should open' "$out"
creates=$(grep -c 'pr create' "$GH_LOG" 2>/dev/null || echo 0)
[ "$creates" = 2 ] && ok 'failed slice skips gh pr create' || bad "want 2 pr creates got $creates" "$(cat "$GH_LOG")"

# --- all pass: three PRs ---
: >"$GH_LOG"
out=$(DOTFILES="$work" WEEKLY_UPDATE_DOTFILES="$work" \
  WEEKLY_UPDATE_SKIP_APPLY=1 \
  WEEKLY_UPDATE_TESTS_mattpocock='true' \
  WEEKLY_UPDATE_TESTS_pstack='true' \
  WEEKLY_UPDATE_TESTS_toolchain='true' \
  WEEKLY_UPDATE_BUN_UPGRADE=':' WEEKLY_UPDATE_BUN_UPDATE=':' \
  WEEKLY_UPDATE_NODE_LTS='24.22.1' \
  WEEKLY_UPDATE_NO_PUSH=1 \
  bash "$work/script/weekly-update.sh" 2>&1) || ec=$?
creates=$(grep -c 'pr create' "$GH_LOG" 2>/dev/null || echo 0)
[ "${creates:-0}" = 3 ] && ok 'all green opens three PRs' || bad "want 3 pr creates got $creates" "$(cat "$GH_LOG")"
echo "$out" | grep -q 'weekly-update: summary' && ok 'prints summary header' || bad 'summary header' "$out"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
