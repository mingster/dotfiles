#!/usr/bin/env bash
# install-agent-clis.sh usage handling (#1588): --help and bad arguments install nothing and touch no rc file.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$(dirname "$0")/lib/asdf-pin.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tests=0

mkdir "$work/bin" "$work/home"
for stub in curl claude agy grok; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls"\n' "$stub" "$work" > "$work/bin/$stub"
  chmod +x "$work/bin/$stub"
done
: > "$work/calls"
printf 'original\n' > "$work/home/.zshrc"

run() { # <args...>: sets out, err, ec
  ec=0
  HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" bash "$root/script/install-agent-clis.sh" "$@" \
    >"$work/out" 2>"$work/err" || ec=$?
}

check() { # <label> <condition exit status>
  if [[ $2 != 0 ]]; then
    printf 'FAIL: %s\n  stdout: %s\n  stderr: %s\n' "$1" "$(cat "$work/out")" "$(cat "$work/err")" >&2
    exit 1
  fi
  tests=$((tests + 1))
}

for flag in -h --help; do
  run "$flag"
  check "$flag exits 0" "$ec"
  check "$flag prints Usage:" "$(grep -q '^Usage:' "$work/out"; echo $?)"
  check "$flag calls no stub" "$([[ ! -s $work/calls ]]; echo $?)"
  check "$flag leaves rc file" "$([[ $(cat "$work/home/.zshrc") == original ]]; echo $?)"
done
for bad in --bogus --dry-run extra; do
  run "$bad"
  check "$bad exits 2" "$([[ $ec == 2 ]]; echo $?)"
  check "$bad prints Usage: on stderr" "$(grep -q '^Usage:' "$work/err"; echo $?)"
  check "$bad calls no stub" "$([[ ! -s $work/calls ]]; echo $?)"
done
run --help extra
check "--help with more arguments exits 2" "$([[ $ec == 2 ]]; echo $?)"

printf 'PASS: %s tests\n' "$tests"
