#!/usr/bin/env bash
# Tests for script/check-stale-worktrees.sh (#1188). A fake gh answers from files; git is real.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/asdf-pin.sh
. "$ROOT/script/tests/lib/asdf-pin.sh"
SCRIPT="$ROOT/script/check-stale-worktrees.sh"
TMP="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# Fake gh: `gh pr list --head <b> ...` prints the state in $TMP/pr/<b>; `--search` prints 0.
mkdir -p "$TMP/bin" "$TMP/pr"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in
    --head) b=$2; shift ;;
    --search) q=$2; if [ -f "$PRDIR/sha_$q" ]; then cat "$PRDIR/sha_$q"; else echo 0; fi; exit 0 ;;
  esac
  shift
done
[ -f "$PRDIR/${b//\//_}" ] && cat "$PRDIR/${b//\//_}"
exit 0
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" PRDIR="$TMP/pr"

g() { git -C "$REPO" -c user.email=t@t -c user.name=t "$@"; }
REPO="$TMP/repo"; ORIGIN="$TMP/origin.git"
git init -q --bare "$ORIGIN"
git init -q -b main "$REPO"
g commit -q --allow-empty -m one
g remote add origin "$ORIGIN"; g push -q origin main
mkdir -p "$TMP/wt"
g worktree add -q -b merged-br "$TMP/wt/merged" ; echo MERGED > "$PRDIR/merged-br"
g worktree add -q -b open-br "$TMP/wt/open"; echo OPEN > "$PRDIR/open-br"
g worktree add -q -b closed-br "$TMP/wt/closed"; echo CLOSED > "$PRDIR/closed-br"
g worktree add -q --detach "$TMP/wt/det-clean" HEAD
g worktree add -q --detach "$TMP/wt/_checks" HEAD
g worktree add -q --detach "$TMP/wt/_checks-2" HEAD
g worktree add -q --detach "$TMP/wt/_checksfoo" HEAD
g worktree add -q --detach "$HOME/listed" HEAD
mkdir -p "$REPO/.agents"; echo listed > "$REPO/.agents/reusable-worktrees"
g worktree add -q --detach "$TMP/wt/det-dirty" HEAD
printf 'x\n' > "$TMP/wt/det-dirty/a.txt"; printf 'x\n' > "$TMP/wt/det-dirty/b.txt"; printf 'x\n' > "$TMP/wt/det-dirty/c.lock"
g worktree add -q --detach "$TMP/wt/gone" HEAD; rm -rf "$TMP/wt/gone"
g worktree add -q -b ahead-br "$TMP/wt/ahead"; git -C "$TMP/wt/ahead" -c user.email=t@t -c user.name=t commit -q --allow-empty -m wip
g worktree add -q -b fresh-br "$TMP/wt/fresh"
g worktree add -q -b verify-br "$TMP/wt/verify"; git -C "$TMP/wt/verify" -c user.email=t@t -c user.name=t commit -q --allow-empty -m prhead
echo 1 > "$PRDIR/sha_$(git -C "$TMP/wt/verify" rev-parse HEAD)"
g worktree add -q --detach "$TMP/wt/det-ahead" HEAD; git -C "$TMP/wt/det-ahead" -c user.email=t@t -c user.name=t commit -q --allow-empty -m wip2

g commit -q --allow-empty -m two; g push -q origin main
out="$(bash "$SCRIPT" "$REPO" 2>"$TMP/err")"; rc=$?
has() { grep -qxF "$1" <<<"$out"; }
[ "$rc" -eq 1 ] && ok "exit 1 when stale found" || bad "exit 1 (rc=$rc)"
has "$TMP/wt/merged pr-merged 0" && ok "merged PR flags" || bad "merged PR flags: $out"
has "$TMP/wt/closed pr-closed 0" && ok "closed PR flags" || bad "closed PR flags"
grep -q "wt/open " <<<"$out" && bad "open PR must not flag" || ok "open PR does not flag"
has "$TMP/wt/det-clean detached-merged 0" && ok "clean detached at merged commit flags" || bad "detached clean flags: $out"
has "$TMP/wt/det-dirty detached-merged 2" && ok "dirty detached reports count (lock ignored)" || bad "dirty detached: $out"
has "$TMP/wt/gone missing-directory 0" && ok "missing directory flags" || bad "missing dir: $out"
grep -q "_checks" <<<"$out" && bad "_checks must not flag" || ok "any _checks* directory does not flag"
grep -q "listed" <<<"$out" && bad "listed path must not flag" || ok "listed reusable path does not flag"
grep -q "wt/fresh " <<<"$out" && bad "fresh branch at older main must not flag" || ok "unpushed branch at older main commit does not flag (live worker)"
has "$TMP/wt/verify pr-merged 0" && ok "verifier branch at squash merged PR head flags" || bad "verifier at merged PR head: $out"
grep -q "ahead" <<<"$out" && bad "unmerged work must not flag" || ok "unmerged branch and detached head do not flag"
grep -qF "$REPO " <<<"$out" && bad "main must not flag" || ok "main worktree never flags"

# Nothing stale: exit 0, no output.
CLEAN="$TMP/clean"; git init -q -b main "$CLEAN"; git -C "$CLEAN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
out="$(bash "$SCRIPT" "$CLEAN" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "clean repo prints nothing, exit 0" || bad "clean repo (rc=$rc out=$out)"

# Read only: every worktree still listed.
[ "$(g worktree list | wc -l | tr -d ' ')" -ge 10 ] && ok "removes nothing" || bad "removes nothing"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
