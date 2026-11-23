#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# setup-obsidian, install_node, setup-agent-skills, check-agent-startup (#1625): -h and --help print usage and exit 0,
# any other argument exits 2 with usage, and neither runs the job. Stub brew, asdf, yay, curl, mega-* and git record
# every call; HOME is a throwaway that must stay empty. secrets-pack and secrets-unpack take -h as help and exit 2 on a missing operand.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/cwd"
for tool in brew asdf yay curl git hdiutil mega-login mega-sync mega-whoami ln; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls"\nexit 1\n' "$tool" "$tmp" > "$tmp/bin/$tool"
  chmod +x "$tmp/bin/$tool"
done
PASS=0
FAIL=0
run() { # script args... -> sets rc, out, err
  rc=0
  rm -rf "$tmp/calls" "$tmp/home"; mkdir -p "$tmp/home"
  out=$(cd "$tmp/cwd" && HOME="$tmp/home" DOTFILES="$tmp/cwd" PATH="$tmp/bin:$PATH" \
    bash "$ROOT/script/$1.sh" "${@:2}" 2>"$tmp/err") || rc=$?
}
clean() { [ ! -e "$tmp/calls" ] && [ -z "$(ls -A "$tmp/home")" ]; }
for script in setup-obsidian install_node setup-agent-skills check-agent-startup secrets-pack secrets-unpack; do
  for flag in -h --help; do
    run "$script" "$flag"
    if [ "$rc" -eq 0 ] && grep -qi 'usage' <<<"$out" && [ ! -s "$tmp/err" ] && clean; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1)); echo "FAIL: $script $flag rc=$rc out=$(head -c 120 <<<"$out") err=$(head -c 120 "$tmp/err")"
    fi
  done
done
for script in setup-obsidian install_node setup-agent-skills check-agent-startup; do
  for bad in --bogus extra; do
    run "$script" "$bad"
    if [ "$rc" -eq 2 ] && grep -qi 'usage' "$tmp/err" && [ -z "$out" ] && clean; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1)); echo "FAIL: $script $bad rc=$rc out=$(head -c 120 <<<"$out") err=$(head -c 120 "$tmp/err")"
    fi
  done
done
for script in secrets-pack secrets-unpack; do
  for args in "" "one"; do
    # shellcheck disable=SC2086
    run "$script" $args
    if [ "$rc" -eq 2 ] && grep -qi 'usage' "$tmp/err" && clean; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1)); echo "FAIL: $script '$args' rc=$rc err=$(head -c 120 "$tmp/err")"
    fi
  done
done
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
