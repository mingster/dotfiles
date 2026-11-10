#!/usr/bin/env bash
# The real head-checks.sh receipt, read by the real lead-merge.sh readers. No receipt here is typed by hand
# (the one stripped variant says so). If head-checks.sh changes the shape of its `Checks:` line, this goes red.
# Readers under test, taken from lead-merge.sh text and not copied: RECEIPT_JQ and the receipt_row lookup (the
# local Checks comment path) and remote_head_checks with its `expect` pattern (the remote path).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }

# shellcheck source=lib/asdf-pin.sh
. "$here/tests/lib/asdf-pin.sh"
export HOME="$tmp/home"; mkdir -p "$HOME"
# shellcheck source=lib/git-identity.sh
. "$here/tests/lib/git-identity.sh"
use_test_git_identity "$tmp"
export DOTFILES_DIR; DOTFILES_DIR=$(cd "$here/.." && pwd)

# The readers, from lead-merge.sh itself. An empty extraction means the reader moved: fail loudly.
src="$here/lead-merge.sh"
receipt_jq_def=$(sed -n "/^RECEIPT_JQ=/,/^'\$/p" "$src")
receipt_row_line=$(grep '^receipt_row=' "$src")
remote_fn=$(sed -n '/^remote_head_checks() {/,/^}$/p' "$src")
[ -n "$receipt_jq_def" ] && [ -n "$receipt_row_line" ] && [ -n "$remote_fn" ] || { echo "FAIL cannot extract the lead-merge.sh readers"; exit 1; }
remote_fn=$(sed 's|"$(dirname "${BASH_SOURCE\[0\]}")/remote-heavy.sh"|"$FAKE_REMOTE_HEAVY"|' <<<"$remote_fn")
grep -q FAKE_REMOTE_HEAVY <<<"$remote_fn" || { echo "FAIL remote-heavy.sh call not found in remote_head_checks"; exit 1; }
eval "$receipt_jq_def"
eval "$remote_fn"
remote_load() { :; }
die() { echo "die: $*" >&2; exit 1; }
remote_host=chk-host remote_repo_dir=/srv/repo remote_dir=/srv/work

# Fixture repo: base on main, then one head whose checklist passes and one whose checklist fails.
bin="$tmp/bin"; mkdir -p "$bin"
repo="$tmp/fixture"; mkdir -p "$repo/.agents"
git() { command git -C "$repo" "$@"; }
git init -q -b main; echo base > "$repo/code.txt"; git add .; git commit -qm base
base=$(git rev-parse HEAD); git update-ref refs/remotes/origin/main "$base"
git checkout -q -b pass; echo true > "$repo/.agents/head-checks.conf"; git add .; git commit -qm pass
head_pass=$(git rev-parse HEAD)
git checkout -q -b fail "$base"; mkdir -p "$repo/.agents"; echo false > "$repo/.agents/head-checks.conf"; git add .; git commit -qm fail
head_fail=$(git rev-parse HEAD)
git checkout -q main

cat > "$bin/reader" <<'EOS'
#!/usr/bin/env bash
case "$1" in hardware) echo "12 8 1000000000";; model) echo fixture;; *) echo "0 90";; esac
EOS
cat > "$bin/gh" <<'EOS'
#!/usr/bin/env bash
case "$2" in
  view) printf '{"headRefOid":"%s","baseRefOid":"%s"}\n' "$GH_HEAD" "$GH_BASE" ;;
  comment) prev=""; for a in "$@"; do [ "$prev" = --body-file ] && cp "$a" "$COMMENTS"; prev=$a; done ;;
  *) exit 1 ;;
esac
EOS
# Stands in for remote-heavy.sh: runs the command it is given, here, as the remote host would.
cat > "$bin/fake-remote-heavy" <<'EOS'
#!/usr/bin/env bash
while [ "$1" != -- ]; do shift; done; shift
exec "$@"
EOS
chmod +x "$bin/"*
export FAKE_REMOTE_HEAVY="$bin/fake-remote-heavy"
export PATH="$bin:$PATH" HEAVY_GATE_READER="$bin/reader" HEAVY_GATE_POLL_SECONDS=0.02 HEAD_CHECKS_WAIT_SECONDS=0
export HEAD_CHECKS_MEMORY_MB=512 HEAD_CHECKS_LOG_DIR="$tmp" COMMENTS="$tmp/comment"
unset HEAD_CHECKS_SLOTS

# Local reader: the receipt_row lookup from lead-merge.sh, for one comment body.
# Prints "<kind>" (empty when the reader finds no receipt for this head and train).
local_kind() { # <body> <head> <train-head or empty> <train-heads or empty>
  local info head=$2 train_head=$3 train_heads=$4 receipt_row
  info=$(jq -n --arg b "$1" '{comments:[{body:$b}]}')
  eval "$receipt_row_line"
  jq -r .kind <<<"$receipt_row"
}
remote_run() { # <ref> <base> <heads>: prints the function's stdout, then "rc=<n>"
  local out rc=0
  out=$(cd "$repo" && remote_head_checks "$@" 2>"$tmp/remote.err") || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
first_line() { printf '%s' "${1%%$'\n'*}"; }

# One scenario: run the real head-checks, then read the real output both ways.
scenario() { # <name> <PASS|FAIL> <head> <heads or empty> <main yes|no>
  local name=$1 kind=$2 head=$3 heads=$4 main=$5 out rc=0 body line args want
  rm -f "$COMMENTS"
  if [ -z "$heads" ]; then
    out=$(GH_HEAD=$head GH_BASE=$base bash "$here/head-checks.sh" --repo "$repo" --pr 7 2>/dev/null) || rc=$?
    body=$(cat "$COMMENTS" 2>/dev/null || true)
  else
    out=$(bash "$here/head-checks.sh" --repo "$repo" --ref "$head" --base "$base" --train-heads "$heads" 2>/dev/null) || rc=$?
    body=$out
  fi
  line=$(first_line "$body")
  want="Checks: $kind head=$head"
  [ "$main" = no ] || want+=" main=$base"
  [ -z "$heads" ] || want+=" train-heads=$heads"
  expect_eq "$name: real receipt line" "$line" "$want"
  if [ "$kind" = PASS ]; then [ "$rc" -eq 0 ] || bad "$name: head-checks exit $rc"; else [ "$rc" -ne 0 ] || bad "$name: head-checks exit 0"; fi
  check_readers "$name" "$kind" "$head" "$heads" "$body"
}
check_readers() { # <name> <kind> <head> <heads or empty> <receipt body>
  local name=$1 kind=$2 head=$3 heads=$4 body=$5 res rc exp_rc
  if [ -z "$heads" ]; then
    expect_eq "$name: local path reads $kind" "$(local_kind "$body" "$head" "" "")" "$kind"
  else
    expect_eq "$name: local path reads the train $kind" "$(local_kind "$body" "$head" "$head" "$heads")" "$kind"
    expect_eq "$name: a train receipt is not a single-PR receipt" "$(local_kind "$body" "$head" "" "")" ""
  fi
  # Remote path: the function runs the real head-checks again on that commit and applies its `expect` pattern.
  res=$(remote_run "$head" "$base" "$heads")
  rc=${res##*rc=}; exp_rc=0; [ "$kind" = PASS ] || exp_rc=1
  if [ "$rc" = "$exp_rc" ] && grep -q "^Checks: $kind head=$head" <<<"$res"; then ok "$name: remote path accepts the $kind receipt"
  else bad "$name: remote path rc=$rc (want $exp_rc): $res $(cat "$tmp/remote.err")"; fi
}

scenario "PASS, main=, no train-heads (via --pr and gh)" PASS "$head_pass" "" yes
scenario "FAIL, main=, no train-heads (via --pr and gh)" FAIL "$head_fail" "" yes
scenario "PASS, main=, train-heads" PASS "$head_pass" "$head_pass" yes
scenario "FAIL, main=, train-heads" FAIL "$head_fail" "$head_fail" yes

# head-checks stops before it knows main when a train head is not contained: a real receipt with no main=.
ghost=ffffffffffffffffffffffffffffffffffffffff
scenario "FAIL, no main=, train-heads (train head not contained)" FAIL "$head_pass" "$ghost" no
# Same early stop with no train-heads: a historical --ref needs --base. Local reader only (remote always sends --base).
rm -f "$COMMENTS"
out=$(bash "$here/head-checks.sh" --repo "$repo" --ref "$base" 2>/dev/null) || true
expect_eq "FAIL, no main=, no train-heads: real receipt line" "$(first_line "$out")" "Checks: FAIL head=$base"
expect_eq "FAIL, no main=, no train-heads: local path reads FAIL" "$(local_kind "$out" "$base" "" "")" FAIL

# head-checks always writes main= on a finished run, so the PASS variant without it is the real PASS with
# the ` main=<sha>` field removed (the reader treats the field as optional).
out=$(bash "$here/head-checks.sh" --repo "$repo" --ref "$head_pass" --base "$base" --train-heads "$head_pass" 2>/dev/null)
stripped=${out/ main=$base/}
expect_eq "PASS with main= removed: field is gone" "$(first_line "$stripped")" "Checks: PASS head=$head_pass train-heads=$head_pass"
expect_eq "PASS with main= removed: local path reads PASS" "$(local_kind "$stripped" "$head_pass" "$head_pass" "$head_pass")" PASS

[ "$fail" -eq 0 ] && echo "lead-merge-real-receipt: PASS"
exit "$fail"
