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
