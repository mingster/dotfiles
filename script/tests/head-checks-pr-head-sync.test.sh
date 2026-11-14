#!/usr/bin/env bash
# Issue 678: head-checks waits for GitHub PR head to match the local pushed tip.
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home/.config/heavy-gate" "$tmp/logs"
reader="$tmp/bin/reader"
comments="$tmp/comments"
cat > "$reader" <<'EOS'
#!/usr/bin/env bash
case "$1" in hardware) echo "12 8 1000000000";; model) echo fixture;; *) echo "0 90";; esac
EOS
cat > "$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
state="${GH_VIEW_STATE:-$TMP/gh-views}"
mkdir -p "$(dirname "$state")"
n=0
[ -f "$state" ] && n=$(cat "$state")
n=$((n + 1))
printf '%s' "$n" > "$state"
stale="${GH_STALE_HEAD:?GH_STALE_HEAD unset}"
fresh="${GH_FRESH_HEAD:?GH_FRESH_HEAD unset}"
after="${GH_FRESH_AFTER:-1}"
if [ "$n" -le "$after" ]; then head="$stale"; else head="$fresh"; fi
case "$1 $2" in
  'pr view')
    printf '{"headRefOid":"%s","baseRefOid":"%s","headRefName":"topic"}\n' "$head" "$GH_BASE" ;;
  'pr comment')
    prev=""
    for a in "$@"; do
      [ "$prev" = --body-file ] && cp "$a" "$COMMENTS"
      prev=$a
    done ;;
  *) exit 1 ;;
esac
EOS
chmod +x "$tmp/bin/gh" "$reader"
export PATH="$tmp/bin:/usr/bin:/bin:/opt/homebrew/bin" HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export HEAVY_GATE_READER="$reader" HEAVY_GATE_POLL_SECONDS=0.02 HEAD_CHECKS_WAIT_SECONDS=0
export HEAD_CHECKS_MEMORY_MB=512 HEAD_CHECKS_LOG_DIR="$tmp/logs" COMMENTS="$comments" TMP="$tmp"
export GH_BASE GH_STALE_HEAD GH_FRESH_HEAD GH_VIEW_STATE="$tmp/gh-views"
export HEAD_CHECKS_SLOTS=1 HEAD_CHECKS_GATE_HELD=1

git init -q -b topic "$tmp/repo"
cd "$tmp/repo"
git config user.email test@example.invalid
git config user.name Test
echo base > code.txt
git add code.txt
git commit -qm base
git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)"
mkdir -p .agents
cat > .agents/head-checks.conf <<'CONF'
bash -c 'test "$(git rev-parse HEAD)" = "$HEAD_CHECK_SHA"'
CONF
git add .
git commit -qm fresh
export GH_BASE="$(git rev-parse origin/main)"
export GH_STALE_HEAD="$(git rev-parse HEAD~1 2>/dev/null || git rev-parse origin/main)"
export GH_FRESH_HEAD="$(git rev-parse HEAD)"

rm -f "$comments"
rc=0
set +e
bash "$here/head-checks.sh" --repo "$tmp/repo" --pr 678 >"$tmp/out" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "FAIL: expected success after GitHub catches up (rc=$rc)"
  cat "$tmp/out" >&2
  exit 1
fi
grep -q "Checks: PASS head=$GH_FRESH_HEAD" "$comments" || {
  echo "FAIL: receipt missing fresh head"
  cat "$comments"
  exit 1
}
echo "ok GitHub PR head catches up to local pushed tip"

rm -f "$comments" "$GH_VIEW_STATE"
export GH_FRESH_AFTER=99
export HEAD_CHECKS_PR_HEAD_WAIT_SECONDS=1
if bash "$here/head-checks.sh" --repo "$tmp/repo" --pr 678 >"$tmp/out" 2>"$tmp/err"; then
  echo "FAIL: expected refusal when GitHub never updates"
  exit 1
fi
[ -f "$comments" ] && { echo "FAIL: posted receipt on stale head"; exit 1; }
grep -q 'local pushed head' "$tmp/err" || {
  echo "FAIL: missing refusal message"
  cat "$tmp/err"
  exit 1
}
echo "ok stale GitHub PR head refuses with no receipt"

rm -f "$comments" "$GH_VIEW_STATE"
export GH_FRESH_AFTER=99
cat > "$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
state="${GH_VIEW_STATE:-$TMP/gh-views}"
mkdir -p "$(dirname "$state")"
n=0
[ -f "$state" ] && n=$(cat "$state")
n=$((n + 1))
printf '%s' "$n" > "$state"
stale="${GH_STALE_HEAD:?GH_STALE_HEAD unset}"
case "$1 $2" in
  'pr view')
    if [ "$n" -eq 1 ]; then
      printf '{"headRefOid":"%s","baseRefOid":"%s","headRefName":"topic"}\n' "$stale" "$GH_BASE"
    else
      echo 'gh: transient failure' >&2
      exit 1
    fi ;;
  'pr comment')
    prev=""
    for a in "$@"; do
      [ "$prev" = --body-file ] && cp "$a" "$COMMENTS"
      prev=$a
    done ;;
  *) exit 1 ;;
esac
EOS
chmod +x "$tmp/bin/gh"
export HEAD_CHECKS_PR_HEAD_WAIT_SECONDS=1
set +e
bash "$here/head-checks.sh" --repo "$tmp/repo" --pr 678 >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: expected refusal when gh pr view fails during wait"; exit 1; }
[ -f "$comments" ] && { echo "FAIL: posted receipt after gh failure"; cat "$comments"; exit 1; }
grep -q 'head=' "$tmp/out" && grep -q "head=$GH_STALE_HEAD" "$tmp/out" && {
  echo "FAIL: stdout receipt used stale head after gh failure"
  cat "$tmp/out"
  exit 1
}
grep -qE 'gh pr view|transient|GitHub PR' "$tmp/err" || {
  echo "FAIL: missing gh failure refusal message"
  cat "$tmp/err"
  exit 1
}
echo "ok gh pr view failure during wait refuses with no receipt"

# Issue 1058: a force-push leaves the local branch diverged from a newer GitHub head.
old_local=$(git rev-parse HEAD)
git checkout -q --detach "$GH_BASE"
git checkout "$old_local" -- .agents
echo force > code.txt
git add -A
git commit -qm 'force-pushed head'
new_head=$(git rev-parse HEAD)
git checkout -q -B topic "$old_local"
git worktree add -q --detach "$tmp/other-wt" "$old_local"
cat > "$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
case "$1 $2" in
  'pr view')
    state="${GH_VIEW_STATE:-$TMP/gh-views}"
    mkdir -p "$(dirname "$state")"
    n=0
    [ -f "$state" ] && n=$(cat "$state")
    n=$((n + 1))
    printf '%s' "$n" > "$state"
    printf '{"headRefOid":"%s","baseRefOid":"%s","headRefName":"topic"}\n' "$GH_FORCE_HEAD" "$GH_BASE" ;;
  'pr comment')
    prev=""
    for a in "$@"; do
      [ "$prev" = --body-file ] && cp "$a" "$COMMENTS"
      prev=$a
    done ;;
  *) exit 1 ;;
esac
EOS
chmod +x "$tmp/bin/gh"
export GH_FORCE_HEAD="$new_head"
export HEAD_CHECKS_PR_HEAD_WAIT_SECONDS=1
rm -f "$comments" "$GH_VIEW_STATE"
set +e
bash "$here/head-checks.sh" --repo "$tmp/repo" --pr 678 >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "FAIL: expected the newer diverged GitHub head to be checked (rc=$rc)"
  cat "$tmp/err" >&2
  exit 1
fi
grep -q "Checks: PASS head=$new_head" "$comments" || {
  echo "FAIL: receipt did not use the GitHub head"
  cat "$comments"
  exit 1
}
[ "$(git rev-parse HEAD)" = "$old_local" ] || { echo "FAIL: caller's checkout moved"; exit 1; }
[ "$(git rev-parse refs/heads/topic)" = "$old_local" ] || { echo "FAIL: local branch moved"; exit 1; }
[ "$(git -C "$tmp/other-wt" rev-parse HEAD)" = "$old_local" ] || { echo "FAIL: other worktree moved"; exit 1; }
echo "ok diverged local branch is checked at the newer GitHub head"

# A diverged GitHub head that stays older never lands. Wait, then refuse with no receipt.
git checkout -q --detach "$GH_BASE"
echo newer-local > code.txt
git add code.txt
GIT_AUTHOR_DATE='2030-01-02T00:00:00' GIT_COMMITTER_DATE='2030-01-02T00:00:00' git commit -qm 'newer local'
newer_local=$(git rev-parse HEAD)
git checkout -q -B topic "$newer_local"
export GH_FORCE_HEAD="$new_head"
rm -f "$comments" "$GH_VIEW_STATE"
set +e
bash "$here/head-checks.sh" --repo "$tmp/repo" --pr 678 >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: expected refusal when the diverged GitHub head is older"; exit 1; }
[ -f "$comments" ] && { echo "FAIL: posted a receipt for an older diverged head"; exit 1; }
grep -q 'waited 1s for GitHub to update' "$tmp/err" || {
  echo "FAIL: expected refusal after the wait"
  cat "$tmp/err"
  exit 1
}
if grep -q 'is not newer' "$tmp/err"; then
  echo "FAIL: refused before the wait"
  cat "$tmp/err"
  exit 1
fi
older_views=$(cat "$GH_VIEW_STATE")
[ "$older_views" -gt 1 ] || { echo "FAIL: refused on the first GitHub view (views=$older_views)"; exit 1; }
[ "$(git rev-parse refs/heads/topic)" = "$newer_local" ] || { echo "FAIL: local branch moved on refusal"; exit 1; }
echo "ok older diverged GitHub head refuses after the wait"

# An amend force-push still propagating: GitHub reports the replaced commit, then the amended head.
git checkout -q --detach "$GH_BASE"
git checkout "$old_local" -- .agents
echo v1 > code.txt
git add -A
GIT_AUTHOR_DATE='2026-11-14T10:00:00' GIT_COMMITTER_DATE='2026-11-14T10:00:00' git commit -qm work
pre_amend=$(git rev-parse HEAD)
echo v2 > code.txt
git add code.txt
GIT_AUTHOR_DATE='2026-11-14T10:05:00' GIT_COMMITTER_DATE='2026-11-14T10:05:00' git commit -q --amend -m 'work (amended)'
amended=$(git rev-parse HEAD)
git checkout -q -B topic "$amended"
cat > "$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
case "$1 $2" in
  'pr view')
    state="${GH_VIEW_STATE:-$TMP/gh-views}"
    mkdir -p "$(dirname "$state")"
    n=0
    [ -f "$state" ] && n=$(cat "$state")
    n=$((n + 1))
    printf '%s' "$n" > "$state"
    if [ "$n" -le "${GH_STALE_VIEWS:-2}" ]; then head="$GH_PRE_AMEND"; else head="$GH_AMENDED"; fi
    printf '{"headRefOid":"%s","baseRefOid":"%s","headRefName":"topic"}\n' "$head" "$GH_BASE" ;;
  'pr comment')
    prev=""
    for a in "$@"; do
      [ "$prev" = --body-file ] && cp "$a" "$COMMENTS"
      prev=$a
    done ;;
  *) exit 1 ;;
esac
EOS
chmod +x "$tmp/bin/gh"
export GH_PRE_AMEND="$pre_amend" GH_AMENDED="$amended" GH_STALE_VIEWS=2
export HEAD_CHECKS_PR_HEAD_WAIT_SECONDS=10
rm -f "$comments" "$GH_VIEW_STATE"
set +e
bash "$here/head-checks.sh" --repo "$tmp/repo" --pr 678 >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "FAIL: expected the amended head after GitHub catches up (rc=$rc views=$(cat "$GH_VIEW_STATE" 2>/dev/null || echo 0))"
  cat "$tmp/err" >&2
  exit 1
fi
grep -q "Checks: PASS head=$amended" "$comments" || {
  echo "FAIL: receipt did not use the amended head"
  cat "$comments"
  exit 1
}
amend_views=$(cat "$GH_VIEW_STATE")
[ "$amend_views" -ge 3 ] || { echo "FAIL: checked before GitHub reported the amended head (views=$amend_views)"; exit 1; }
[ "$(git rev-parse refs/heads/topic)" = "$amended" ] || { echo "FAIL: local branch moved"; exit 1; }
[ "$(git -C "$tmp/other-wt" rev-parse HEAD)" = "$old_local" ] || { echo "FAIL: other worktree moved"; exit 1; }
echo "ok amended branch is checked once GitHub reports that head"
