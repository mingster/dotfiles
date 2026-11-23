#!/usr/bin/env bash
# Tests for script/lib/dotfiles-fresh.sh and script/check-dotfiles-fresh.sh (#1211).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
g() { git -c user.email=t@t -c user.name=t "$@"; }
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

mk() { # <name>: origin plus a clone on main, one commit pushed
  rm -rf "$tmp/$1"; mkdir -p "$tmp/$1"
  git init -q --bare -b main "$tmp/$1/origin.git"
  git clone -q "$tmp/$1/origin.git" "$tmp/$1/up" 2>/dev/null
  echo a >"$tmp/$1/up/f"; g -C "$tmp/$1/up" add -A; g -C "$tmp/$1/up" commit -qm one; g -C "$tmp/$1/up" push -q origin HEAD:main
  git clone -q "$tmp/$1/origin.git" "$tmp/$1/co" 2>/dev/null
}
upstream_commit() { echo "$2" >>"$tmp/$1/up/f"; g -C "$tmp/$1/up" commit -qam up; g -C "$tmp/$1/up" push -q origin HEAD:main; }
run() { # <name>: source the preflight against the checkout; print stderr
  DOTFILES_DIR="$tmp/$1/co" SESSION_SYNC_FETCH_TIMEOUT=2 bash -c ". '$here/lib/dotfiles-fresh.sh'" 2>&1 >/dev/null
}

mk a; upstream_commit a b
out=$(run a)
check "behind and clean pulls" "$(git -C "$tmp/a/co" rev-parse HEAD)" "$(git -C "$tmp/a/up" rev-parse HEAD)"
case "$out" in *fast-forwarded*) echo "ok: says so"; ;; *) echo "FAIL: no fast-forward line: $out"; fail=1 ;; esac

mk b; upstream_commit b b; echo dirty >>"$tmp/b/co/f"
out=$(run b)
check "dirty keeps the change" "$(tail -1 "$tmp/b/co/f")" dirty
case "$out" in *dirty*) echo "ok: dirty warns"; ;; *) echo "FAIL: no dirty warning: $out"; fail=1 ;; esac

mk c; upstream_commit c b; echo local >"$tmp/c/co/g"; g -C "$tmp/c/co" add -A; g -C "$tmp/c/co" commit -qm local
before=$(git -C "$tmp/c/co" rev-parse HEAD)
out=$(run c)
check "diverged is left alone" "$(git -C "$tmp/c/co" rev-parse HEAD)" "$before"
case "$out" in *diverged*) echo "ok: diverged warns"; ;; *) echo "FAIL: no diverged warning: $out"; fail=1 ;; esac

mk d
check "up to date is silent" "$(run d)" ""

mk e; git -C "$tmp/e/co" remote set-url origin "$tmp/e/missing.git"
out=$(run e); rc=$?
case "$out" in *"fetch failed"*) echo "ok: fetch failure warns"; ;; *) echo "FAIL: no fetch warning: $out"; fail=1 ;; esac
check "fetch failure continues" "$rc" 0

# The lint
s="$tmp/scripts"; mkdir -p "$s/lib"
for f in worker-startup.sh ship.sh head-checks.sh fleet-watch-loop.sh; do
  printf '#!/usr/bin/env bash\nhere=x\n. "$here/lib/dotfiles-fresh.sh"\n' >"$s/$f"
done
bash "$here/check-dotfiles-fresh.sh" "$s" 2>/dev/null; check "lint passes when all source it" "$?" 0
printf '#!/usr/bin/env bash\n' >"$s/ship.sh"
out=$(bash "$here/check-dotfiles-fresh.sh" "$s" 2>&1); rc=$?
check "lint fails when ship.sh drops it" "$rc" 1
case "$out" in *ship.sh*) echo "ok: names the script"; ;; *) echo "FAIL: $out"; fail=1 ;; esac
bash "$here/check-dotfiles-fresh.sh" 2>/dev/null; check "lint passes on the real scripts" "$?" 0
out=$(bash "$here/check-dotfiles-fresh.sh" --help 2>&1); rc=$?
check "lint --help exits 0" "$rc" 0
case "$out" in *Usage*) echo "ok: --help prints usage" ;; *) echo "FAIL: --help output: $out"; fail=1 ;; esac
out=$(bash "$here/check-dotfiles-fresh.sh" "$tmp/no-such-dir" 2>&1); rc=$?
check "lint on a missing directory exits 2" "$rc" 2
case "$out" in *"$tmp/no-such-dir"*) echo "ok: names the directory" ;; *) echo "FAIL: $out"; fail=1 ;; esac
bash "$here/check-dotfiles-fresh.sh" "$tmp" "$tmp" >/dev/null 2>&1; check "lint with two arguments exits 2" "$?" 2
exit "$fail"
