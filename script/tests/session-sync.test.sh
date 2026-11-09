#!/usr/bin/env bash
# session-sync.sh against local bare origins, a fake tool probe and a fake fleet floor (no network).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$tmp/gitconfig" user.name test
git config --file "$tmp/gitconfig" user.email test@example.invalid
git config --file "$tmp/gitconfig" init.defaultBranch main

# make_behind <name>: a bare origin plus a clean clone one commit behind it; prints the clone path
make_behind() {
  local n=$1
  git init -q --bare "$tmp/$n.git"
  git clone -q "$tmp/$n.git" "$tmp/$n" 2>/dev/null
  git -C "$tmp/$n" commit -q --allow-empty -m one
  git -C "$tmp/$n" push -q origin main
  git clone -q "$tmp/$n.git" "$tmp/$n-up"
  git -C "$tmp/$n-up" commit -q --allow-empty -m two
  git -C "$tmp/$n-up" push -q origin main
  printf '%s\n' "$tmp/$n"
}
tip() { git --git-dir="$tmp/$1.git" rev-parse main; }
head_of() { git -C "$1" rev-parse HEAD; }

unset DOTFILES_DIR CLAUDE_PROJECT_DIR GIT_SSH_COMMAND
export HOME="$tmp/home"
mkdir -p "$HOME"
export AGENT_STATE_DIR="$tmp/state"
mkdir -p "$AGENT_STATE_DIR"
printf '#!/usr/bin/env bash\necho "claude ok 2.1.311"; echo "bun ok 1.4.4"; echo "orca missing"\n' >"$tmp/probe"
export SESSION_SYNC_PROBE="$tmp/probe"

run() { bash "$here/session-sync.sh" "$@" 2>&1; }

# A clean checkout on main that is behind is fast-forwarded, and so is ~/dotfiles
proj=$(make_behind proj)
dots=$(make_behind dots)
mv "$dots" "$HOME/dotfiles"
out=$(run "$proj"); ec=$?
check "clean behind project checkout is fast-forwarded" "$([ "$(head_of "$proj")" = "$(tip proj)" ] && echo 0 || echo 1)"
check "clean behind ~/dotfiles is fast-forwarded" "$([ "$(head_of "$HOME/dotfiles")" = "$(tip dots)" ] && echo 0 || echo 1)"
check "fast-forward is reported" "$(grep -q 'session-sync: proj fast-forwarded 1 commit' <<<"$out"; echo $?)"
check "exits 0" "$ec"

# A dirty checkout is left alone and named
dirty=$(make_behind dirty)
before=$(head_of "$dirty")
echo change >"$dirty/f"; git -C "$dirty" add f
out=$(run "$dirty")
check "dirty behind checkout is left alone" "$([ "$(head_of "$dirty")" = "$before" ] && echo 0 || echo 1)"
check "dirty checkout is named" "$(grep -q 'session-sync: dirty is 1 behind origin/main but dirty, left alone' <<<"$out"; echo $?)"

# A diverged checkout is left alone and named
div=$(make_behind div)
git -C "$div" commit -q --allow-empty -m local
before=$(head_of "$div")
out=$(run "$div")
check "diverged checkout is left alone" "$([ "$(head_of "$div")" = "$before" ] && echo 0 || echo 1)"
check "diverged checkout is named" "$(grep -q 'session-sync: div has diverged from origin/main, left alone' <<<"$out"; echo $?)"

# From a worktree on a branch, the main checkout is fast-forwarded and the branch is not touched
wt=$(make_behind wt)
git -C "$wt" worktree add -q -b feature "$tmp/wt-feature" 2>/dev/null
feature_before=$(head_of "$tmp/wt-feature")
out=$(run "$tmp/wt-feature")
check "main checkout of a worktree is fast-forwarded" "$([ "$(head_of "$wt")" = "$(tip wt)" ] && echo 0 || echo 1)"
check "worktree branch is not touched" "$([ "$(head_of "$tmp/wt-feature")" = "$feature_before" ] && echo 0 || echo 1)"

# A main checkout on another branch is left alone
other=$(make_behind other)
git -C "$other" switch -q -c topic
before=$(head_of "$other")
run "$other" >/dev/null
check "checkout not on main is left alone" "$([ "$(head_of "$other")" = "$before" ] && echo 0 || echo 1)"

# Tools below the fleet floor are named; level or above are quiet
printf '%s\n' '{"host":"coord-a","tools":{"claude":"2.1.319","bun":"1.4.4","orca":"1.4.253"}}' >"$AGENT_STATE_DIR/fleet-floor.json"
out=$(run "$proj"); ec=$?
check "tool below the floor is named" "$(grep -q 'session-sync: claude 2.1.311 is below coord-a 2.1.319' <<<"$out"; echo $?)"
check "missing tool on the floor is named" "$(grep -q 'session-sync: orca missing (coord-a has 1.4.253)' <<<"$out"; echo $?)"
check "tool level with the floor is quiet" "$(grep -q 'session-sync: bun' <<<"$out" && echo 1 || echo 0)"
check "exits 0 with tool warnings" "$ec"

# Offline: an unreachable origin is reported, nothing moves, and the run still exits 0
off=$(make_behind off)
before=$(head_of "$off")
git -C "$off" remote set-url origin "$tmp/missing.git"
out=$(run "$off"); ec=$?
check "unreachable origin leaves the checkout alone" "$([ "$(head_of "$off")" = "$before" ] && echo 0 || echo 1)"
check "unreachable origin is reported" "$(grep -q 'session-sync: off fetch failed, skipped' <<<"$out"; echo $?)"
check "exits 0 when offline" "$ec"

# A fetch that hangs is cut off after the timeout, and the floor warning still prints
hang=$(make_behind hang)
before=$(head_of "$hang")
git -C "$hang" remote set-url origin "ext::sleep 30"
start=$(date +%s)
out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.ext.allow GIT_CONFIG_VALUE_0=always SESSION_SYNC_FETCH_TIMEOUT=1 run "$hang"); ec=$?
took=$(( $(date +%s) - start ))
check "hanging fetch is cut off within the timeout" "$([ "$took" -le 4 ] && echo 0 || echo 1)"
check "hanging fetch leaves the checkout alone" "$([ "$(head_of "$hang")" = "$before" ] && echo 0 || echo 1)"
check "hanging fetch is reported" "$(grep -q 'session-sync: hang fetch failed, skipped' <<<"$out"; echo $?)"
check "floor warning prints when offline" "$(grep -q 'session-sync: claude 2.1.311 is below' <<<"$out"; echo $?)"
check "exits 0 after a hanging fetch" "$ec"

# Not a git checkout at all: quiet and 0
mkdir -p "$tmp/plain"
out=$(run "$tmp/plain"); ec=$?
check "plain directory exits 0" "$ec"

# The session start hook (state-of-play.sh) runs session-sync.sh from ~/dotfiles for the project
hook_home="$tmp/hook-home"
mkdir -p "$hook_home/dotfiles/script"
printf '#!/usr/bin/env bash\necho "stub session-sync $1"\n' >"$hook_home/dotfiles/script/session-sync.sh"
out=$(cd "$proj" && HOME="$hook_home" CLAUDE_PROJECT_DIR="$proj" PATH=/usr/bin:/bin bash "$here/../templates/agent-team/.claude/bin/state-of-play.sh" 2>&1); ec=$?
check "state-of-play runs session-sync for the project" "$(grep -qx "stub session-sync $proj" <<<"$out"; echo $?)"
check "state-of-play still exits 0" "$ec"

echo "session-sync: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
