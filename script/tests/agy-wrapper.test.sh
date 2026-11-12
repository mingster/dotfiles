#!/usr/bin/env bash
# bin/agy with a fake agy: the SSH variables are gone, arguments pass through, no agy is an error.
here=$(cd "$(dirname "$0")/../../bin" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

mkdir -p "$tmp/real" "$tmp/wrap"
cp "$here/agy" "$tmp/wrap/agy"
ln -s "$tmp/wrap" "$tmp/wrap-link"
cat > "$tmp/real/agy" <<'EOS'
#!/bin/sh
echo "conn=${SSH_CONNECTION-unset} tty=${SSH_TTY-unset} client=${SSH_CLIENT-unset} args=$*"
EOS
chmod +x "$tmp/real/agy"

out=$(SSH_CONNECTION='a b c d' SSH_TTY=/dev/ttys001 SSH_CLIENT='a b c' PATH="$tmp/wrap:$tmp/real:/usr/bin:/bin" "$tmp/wrap/agy" models --x 2>&1)
check "SSH variables are unset" "$([ "$out" = 'conn=unset tty=unset client=unset args=models --x' ]; echo $?)"

out=$(SSH_CONNECTION=x PATH="$tmp/wrap-link:$tmp/real:/usr/bin:/bin" "$tmp/wrap/agy" a 2>&1)
check "wrapper found through a symlinked PATH entry is skipped, no loop" "$([ "$out" = 'conn=unset tty=unset client=unset args=a' ]; echo $?)"

out=$(PATH="$tmp/wrap:/usr/bin:/bin" "$tmp/wrap/agy" 2>&1); rc=$?
check "no real agy exits 127" "$([ "$rc" = 127 ] && echo "$out" | grep -q 'no agy found'; echo $?)"

# No script in the repo starts agy except through bin/agy.
root=$(cd "$here/.." && pwd)
direct=$(cd "$root" && git grep -nE "(^|[ (;&|\"'])agy +(update|models|--?[a-z])|\[\"agy\"" -- 'script/*.sh' 'script/*.py' 'mac/*.sh' 'install.sh' ':!script/tests' ':!script/*.test.sh' | grep -v 'bin/agy')
check "no script launches agy directly" "$([ -z "$direct" ]; echo $?)"
[ -z "$direct" ] || echo "$direct"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
