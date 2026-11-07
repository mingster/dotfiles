#!/usr/bin/env bash
# Contract and integration tests for script/weekly-update.sh (spec T17).
# Uses /bin/bash (3.2 on macOS) and the real apply path (not WEEKLY_UPDATE_SKIP_APPLY).
set -uo pipefail
set +e
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/.." && pwd -P)
script="$here/weekly-update.sh"
gate="$root/script/heavy-gate.sh"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ $# -gt 1 ] && echo "$2"; }

[ -f "$script" ] || { echo "FAIL weekly-update.sh missing"; exit 1; }
[ -x "$gate" ] || { echo "FAIL heavy-gate.sh missing"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

bare="$tmp/origin.git"
work="$tmp/dotfiles"
mp_up="$tmp/mp-up.git"
plugins_up="$tmp/plugins-up.git"
mp_tree="$tmp/mp-tree"
plugins_tree="$tmp/plugins-tree"

init_bare_main() {
  local dir="$1"
  rm -rf "$dir"
  git init -q --bare -b main "$dir"
}

init_bare_main "$bare"
init_bare_main "$mp_up"
init_bare_main "$plugins_up"

seed_upstream_repos() {
  rm -rf "$mp_tree" "$plugins_tree"
  mkdir -p "$mp_tree/skills/engineering/tdd" \
    "$plugins_tree/harness/pstack/claude-code/skills/benchmark-checklist"
  printf 'upstream tdd\n' >"$mp_tree/skills/engineering/tdd/SKILL.md"
  printf 'upstream pstack\n' >"$plugins_tree/harness/pstack/claude-code/skills/benchmark-checklist/SKILL.md"
  git -C "$mp_tree" init -q -b main
  git -C "$mp_tree" add -A
  git -C "$mp_tree" commit -qm up
  git -C "$mp_tree" push -q -u "$mp_up" main
  git -C "$plugins_tree" init -q -b main
  git -C "$plugins_tree" add -A
  git -C "$plugins_tree" commit -qm up
  git -C "$plugins_tree" push -q -u "$plugins_up" main
}

seed_upstream_repos

setup_fixture() {
  rm -rf "$work"
  init_bare_main "$bare"
  mkdir -p "$work/script" "$work/script/tests" "$work/.agents/skills/tdd" \
    "$work/templates/agent-team/.agents/skills/benchmark-checklist"
  for s in sync-mattpocock-skills.sh sync-team-skills.sh adopt-agent-team.sh \
    check-skill-collisions.sh weekly-update.sh; do
    cp "$root/script/$s" "$work/script/"
  done
  cp "$root/script/tests/sync-mattpocock-skills.test.sh" "$work/script/tests/" 2>/dev/null || true
  chmod +x "$work/script/"*.sh 2>/dev/null || true
  printf 'init\n' >"$work/README.md"
  printf 'old\n' >"$work/.agents/skills/tdd/SKILL.md"
  printf 'local\n' >"$work/templates/agent-team/.agents/skills/benchmark-checklist/SKILL.md"
  printf 'sha=old\nskills=tdd\n' >"$work/.agents/skills/.mattpocock-upstream"
  printf 'sha=old\nsubpath=harness/pstack/claude-code\nskills=benchmark-checklist\n' \
    >"$work/script/.pstack-template-upstream"
  printf '#!/usr/bin/env bash\necho node\n' >"$work/script/install_node.sh"
  printf 'nodejs 20.0.0\n' >"$work/.tool-versions"
  git -C "$work" init -q -b main
  git -C "$work" add -A
  git -C "$work" commit -qm init
  git -C "$work" remote add origin "$bare"
  git -C "$work" push -q -u origin main

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
  _case_path="${CASE_SAVE_PATH:-$PATH}"
  export PATH="$tmp/bin:$_case_path"
}

CASE_SAVE_PATH="${PATH}"
setup_fixture

run_weekly() {
  local extra=() args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      *=*) extra+=("$1"); shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  "$gate" --weight 1 -- env \
    DOTFILES="$work" WEEKLY_UPDATE_DOTFILES="$work" \
    MP_REPO="$mp_up" PLUGINS_REPO="$plugins_up" \
    WEEKLY_UPDATE_BUN_UPGRADE=':' WEEKLY_UPDATE_BUN_UPDATE=':' \
    WEEKLY_UPDATE_NODE_LTS='24.22.1' \
    "${extra[@]}" \
    /bin/bash "$work/script/weekly-update.sh" ${args+"${args[@]}"}
}

on_main_clean() {
  br=$(git -C "$work" symbolic-ref --short HEAD 2>/dev/null || true)
  [ "$br" = main ] && git -C "$work" diff --quiet && git -C "$work" diff --cached --quiet
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
out=$(run_weekly WEEKLY_UPDATE_SKIP_APPLY=1 --dry-run 2>&1) || true
after=$(git -C "$work" status --porcelain | wc -l | tr -d ' ')
[ "$before" = "$after" ] && ok 'dry-run leaves worktree clean' || bad 'dry-run must change nothing' "$(git -C "$work" status --short)"
n=$(printf '%s\n' "$out" | grep -c '^PLANNED PR ' || true)
[ "$n" = 3 ] && ok 'dry-run lists three PRs' || bad "dry-run PR count want 3 got $n" "$out"
! [ -s "$GH_LOG" ] && ok 'dry-run does not open PRs' || bad 'dry-run must not gh pr create' "$(cat "$GH_LOG")"

# --- case: apply ok (real pstack apply on /bin/bash) ---
setup_fixture
: >"$GH_LOG"
out=$(run_weekly WEEKLY_UPDATE_TESTS_mattpocock='true' WEEKLY_UPDATE_TESTS_pstack='true' \
  WEEKLY_UPDATE_TESTS_toolchain='true' WEEKLY_UPDATE_NO_PUSH=1 2>&1) || ec=$?
on_main_clean && ok 'apply ok ends on main with clean tree' \
  || bad 'apply ok must end on main clean' "$(git -C "$work" status; git -C "$work" branch)"
echo "$out" | grep -q 'weekly-update: pstack upstream' && ok 'apply ok runs pstack apply' \
  || bad 'pstack apply missing' "$out"
newsha=$(git -C "$plugins_tree" rev-parse HEAD)
pbranch=$(git -C "$work" for-each-ref --format='%(refname:short)' 'refs/heads/mingster/weekly-pstack-*' 2>/dev/null | head -1)
pstack_state=$(git -C "$work" show "$pbranch:script/.pstack-template-upstream" 2>/dev/null || true)
echo "$pstack_state" | grep -q "^sha=$newsha" && ok 'apply ok writes pstack sha' \
  || bad 'pstack sha not updated' "$pstack_state"
creates=$(grep -c 'pr create' "$GH_LOG" 2>/dev/null || echo 0)
[ "${creates:-0}" = 3 ] && ok 'apply ok opens three PRs' || bad "want 3 pr creates got $creates" "$(cat "$GH_LOG")"

# --- case: apply fails ---
setup_fixture
printf 'sha=old\nsubpath=missing/path\nskills=benchmark-checklist\n' >"$work/script/.pstack-template-upstream"
git -C "$work" add script/.pstack-template-upstream
git -C "$work" commit -qm state
git -C "$work" push -q origin main
: >"$GH_LOG"
out=$(run_weekly WEEKLY_UPDATE_TESTS_mattpocock='true' WEEKLY_UPDATE_TESTS_pstack='true' \
  WEEKLY_UPDATE_TESTS_toolchain='true' WEEKLY_UPDATE_NO_PUSH=1 \
  2>&1) || true
echo "$out" | grep -q 'PR pstack: failed (apply)' && ok 'apply fails marks slice failed' || bad 'apply fail summary' "$out"
on_main_clean && ok 'apply fails returns to main clean' \
  || bad 'apply fail dirty tree' "$(git -C "$work" status --short; git -C "$work" branch)"
grep -q '^init$' "$work/README.md" && ok 'apply fails does not carry sync dirt' || bad 'README polluted'

# --- case: tests fail ---
setup_fixture
: >"$GH_LOG"
out=$(run_weekly WEEKLY_UPDATE_TESTS_mattpocock='false' WEEKLY_UPDATE_TESTS_pstack='true' \
  WEEKLY_UPDATE_TESTS_toolchain='true' WEEKLY_UPDATE_NO_PUSH=1 \
  2>&1) || true
echo "$out" | grep -q 'PR mattpocock: failed' && ok 'tests fail in summary' || bad 'test fail summary' "$out"
on_main_clean && ok 'tests fail ends on main clean' \
  || bad 'test fail leaves dirty branch' "$(git -C "$work" status --short)"
creates=$(grep -c 'pr create' "$GH_LOG" 2>/dev/null || echo 0)
[ "$creates" = 2 ] && ok 'tests fail skips failed PR create' || bad "want 2 pr creates got $creates"

# --- case: push fails ---
setup_fixture
cat >"$tmp/bin/git" <<'EOS'
#!/bin/sh
case "$*" in
  *push*) echo "push rejected" >&2; exit 1 ;;
esac
exec /usr/bin/git "$@"
EOS
chmod +x "$tmp/bin/git"
export PATH="$tmp/bin:$CASE_SAVE_PATH"
: >"$GH_LOG"
out=$(run_weekly WEEKLY_UPDATE_TESTS_mattpocock='true' WEEKLY_UPDATE_TESTS_pstack='true' \
  WEEKLY_UPDATE_TESTS_toolchain='true' \
  2>&1) || true
echo "$out" | grep -q 'failed (push)' && ok 'push fail reported' || bad 'push fail summary' "$out"
on_main_clean && ok 'push fail ends on main clean' \
  || bad 'push fail branch left dirty' "$(git -C "$work" branch; git -C "$work" status --short)"
rm -f "$tmp/bin/git"
export PATH="$CASE_SAVE_PATH"

# --- case: dirty tree at start ---
setup_fixture
printf 'dirty\n' >>"$work/README.md"
: >"$GH_LOG"
dirty_rc=0
if env DOTFILES="$work" WEEKLY_UPDATE_DOTFILES="$work" \
  MP_REPO="$mp_up" PLUGINS_REPO="$plugins_up" \
  WEEKLY_UPDATE_BUN_UPGRADE=':' WEEKLY_UPDATE_BUN_UPDATE=':' \
  WEEKLY_UPDATE_NODE_LTS='24.22.1' \
  /bin/bash "$work/script/weekly-update.sh" 2>"$tmp/err"; then
  dirty_rc=0
else
  dirty_rc=$?
fi
if [ "$dirty_rc" = 0 ]; then
  bad 'dirty tree must refuse to start'
else
  grep -q 'refusing to start on a dirty tree' "$tmp/err" && ok 'dirty tree refused' || bad 'dirty message' "$(cat "$tmp/err")"
fi
br=$(git -C "$work" symbolic-ref --short HEAD 2>/dev/null || true)
[ "$br" = main ] && ok 'dirty refusal stays on main' || bad 'dirty refusal wrong branch' "$br"

# --- case: untracked under slice paths refused at start ---
assert_untracked_refused() {
  local rel="$1" ok_label="$2"
  setup_fixture
  printf 'stray\n' >"$work/$rel"
  : >"$GH_LOG"
  refuse_rc=0
  if run_weekly WEEKLY_UPDATE_SKIP_APPLY=1 WEEKLY_UPDATE_NO_PUSH=1 \
    2>"$tmp/err" >/dev/null; then
    refuse_rc=0
  else
    refuse_rc=$?
  fi
  if [ "$refuse_rc" = 0 ]; then
    bad "$ok_label must refuse to start"
  else
    ok "$ok_label refuses to start"
  fi
  grep -qF "refusing to start: untracked file $rel" "$tmp/err" \
    && ok "$ok_label names untracked file" \
    || bad "$ok_label refusal message" "$(cat "$tmp/err")"
  br=$(git -C "$work" symbolic-ref --short HEAD 2>/dev/null || true)
  [ "$br" = main ] && ok "$ok_label stays on main" || bad "$ok_label wrong branch" "$br"
  n=$(git -C "$work" for-each-ref --format='%(refname:short)' refs/heads/mingster/weekly-mattpocock-* 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = 0 ] && ok "$ok_label does not open slice branch" || bad "$ok_label created branch"
}

assert_untracked_refused '.agents/skills/stray-untracked.txt' 'mattpocock slice untracked'
assert_untracked_refused 'templates/agent-team/.agents/skills/stray-untracked.txt' 'pstack slice untracked'
assert_untracked_refused 'script/stray-untracked-toolchain.txt' 'toolchain slice untracked'

# --- ignored projects conf does not refuse ---
setup_fixture
grep -qxF 'script/weekly-update.projects.conf' "$root/.gitignore" || bad 'missing gitignore for weekly-update.projects.conf'
cp "$root/.gitignore" "$work/.gitignore"
git -C "$work" add .gitignore
git -C "$work" commit -qm gitignore
printf '# local project roots only\n' >"$work/script/weekly-update.projects.conf"
: >"$GH_LOG"
out=$(run_weekly WEEKLY_UPDATE_SKIP_APPLY=1 WEEKLY_UPDATE_NO_PUSH=1 \
  WEEKLY_UPDATE_TESTS_mattpocock='true' WEEKLY_UPDATE_TESTS_pstack='true' \
  WEEKLY_UPDATE_TESTS_toolchain='true' 2>&1) || ec=$?
echo "$out" | grep -q 'refusing to start: untracked' && bad 'ignored projects conf refused' "$out" \
  || ok 'ignored projects conf does not refuse'
[ "${ec:-0}" = 0 ] && ok 'ignored projects conf run completes' || bad 'projects conf run failed' "$out"
echo "$out" | grep -q 'weekly-update: summary' && ok 'ignored projects conf reaches summary' \
  || bad 'projects conf no summary' "$out"

# --- projects conf is gitignored in source tree ---
grep -qxF 'script/weekly-update.projects.conf' "$root/.gitignore" && ok 'projects conf gitignored' \
  || bad 'missing gitignore for weekly-update.projects.conf'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
