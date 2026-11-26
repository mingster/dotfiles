#!/usr/bin/env bash
# Tests for script/reap-orphan-tests.sh (#1954), with a fake ps, kill and alive.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../reap-orphan-tests.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

ROOT=/Users/me/orca/workspaces
# pid, ppid, age seconds, start, command (tab separated); cwd file: pid<TAB>cwd
T=$'\t'
{
  printf '%s\n' "101${T}1${T}20460${T}Wed Nov 26 17:00:00 2026${T}bun test src/lib/order"
  printf '%s\n' "102${T}1${T}600${T}Wed Nov 26 22:50:00 2026${T}bun test src/lib/young"
  printf '%s\n' "103${T}5000${T}20000${T}Wed Nov 26 17:10:00 2026${T}bun test src/lib/live-parent"
  printf '%s\n' "104${T}1${T}20000${T}Wed Nov 26 17:10:00 2026${T}bun test src/lib/outside"
  printf '%s\n' "105${T}1${T}20000${T}Wed Nov 26 17:10:00 2026${T}/Applications/Google Chrome Dev.app/Contents/MacOS/Google Chrome Dev --user-data-dir=/x"
  printf '%s\n' "106${T}1${T}20000${T}Wed Nov 26 17:10:00 2026${T}claude -p run bun test src/lib/mention"
  printf '%s\n' "107${T}1${T}20000${T}Wed Nov 26 17:10:00 2026${T}/usr/bin/xcodebuild -scheme App test"
  printf '%s\n' "108${T}1${T}20000${T}Wed Nov 26 17:10:00 2026${T}brew install bun test"
  printf '%s\n' "109${T}1${T}20000${T}Wed Nov 26 17:10:00 2026${T}bunx playwright test e2e/a.spec.ts"
  printf '%s\n' "110${T}1${T}20000${T}Wed Nov 26 17:10:00 2026${T}/sbin/launchd"
  printf '%s\n' "111${T}1${T}20000${T}Wed Nov 26 17:10:00 2026${T}bun test src/lib/traversal"
} > "$tmp/procs"
{
  printf '%s\n' "101${T}$ROOT/dotfiles/a"
  printf '%s\n' "102${T}$ROOT/dotfiles/a"
  printf '%s\n' "103${T}$ROOT/dotfiles/a"
  printf '%s\n' "104${T}/Users/me/other"
  printf '%s\n' "105${T}$ROOT/dotfiles/a"
  printf '%s\n' "106${T}$ROOT/dotfiles/a"
  printf '%s\n' "107${T}$ROOT/dotfiles/b"
  printf '%s\n' "108${T}$ROOT/dotfiles/a"
  printf '%s\n' "109${T}$ROOT/dotfiles/c"
  printf '%s\n' "110${T}/"
  printf '%s\n' "111${T}$ROOT/../etc"
} > "$tmp/cwds"
cp "$tmp/procs" "$tmp/alive.src"
awk -F'\t' '{ print $1 }' "$tmp/procs" > "$tmp/alive"

cat > "$tmp/ps" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) cat "$FAKE_DIR/procs" ;;
  show) awk -F'\t' -v p="$2" '$1 == p' "$FAKE_DIR/procs" ;;
  cwd) awk -F'\t' -v p="$2" '$1 == p { print $2 }' "$FAKE_DIR/cwds" ;;
esac
EOF
# Kill log: "SIGNAL PID". Pid 109 ignores TERM and dies only on KILL.
cat > "$tmp/kill" <<'EOF'
#!/usr/bin/env bash
echo "$1 $2" >> "$FAKE_DIR/kills"
if [ "$1" = KILL ] || [ "$2" != 109 ]; then grep -vx "$2" "$FAKE_DIR/alive" > "$FAKE_DIR/alive.new"; mv "$FAKE_DIR/alive.new" "$FAKE_DIR/alive"; fi
EOF
cat > "$tmp/alive-cmd" <<'EOF'
#!/usr/bin/env bash
grep -qx "$1" "$FAKE_DIR/alive"
EOF
chmod +x "$tmp/ps" "$tmp/kill" "$tmp/alive-cmd"

run() {
  : > "$tmp/kills"
  FAKE_DIR=$tmp REAP_PS_CMD=$tmp/ps REAP_KILL_CMD=$tmp/kill REAP_ALIVE_CMD=$tmp/alive-cmd \
    REAP_ORPHAN_ROOT=$ROOT REAP_ORPHAN_GRACE=0 "$@"
}

# Dry run lists, never signals.
out=$(run bash "$script" --dry-run 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok 'dry-run exits 0' || bad "dry-run exit $rc"
case "$out" in *'would reap pid=101 age=5h41m cmd=bun test src/lib/order cwd='*) ok 'dry-run names the orphan bun test with its age' ;; *) bad "dry-run output: $out" ;; esac
[ ! -s "$tmp/kills" ] && ok 'dry-run sends no signal' || bad 'dry-run signalled'

# Real run: TERM first, KILL only for the one that survives.
out=$(run bash "$script" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok 'run exits 0' || bad "run exit $rc: $out"
for pid in 101 107 109; do
  grep -qx "TERM $pid" "$tmp/kills" && ok "TERM sent to $pid" || bad "no TERM for $pid"
done
grep -qx 'KILL 109' "$tmp/kills" && ok 'KILL sent to the process that ignored TERM' || bad 'no KILL for 109'
grep -qx 'KILL 101' "$tmp/kills" && bad 'KILL sent to a process that already exited' || ok 'no KILL for a process that exited on TERM'
case "$out" in *'reaped pid=101'*'(TERM)'*) ok 'prints one reaped line for 101' ;; *) bad "no reaped line for 101: $out" ;; esac
case "$out" in *'reaped pid=109'*'(KILL)'*) ok 'prints one reaped line for 109' ;; *) bad "no reaped line for 109: $out" ;; esac
for pid in 102 103 104 105 106 108 110 111; do
  grep -q " $pid\$" "$tmp/kills" && bad "touched protected pid $pid" || ok "kept $pid"
done

[ "$fail" -eq 0 ] && echo "all passed"
exit "$fail"
