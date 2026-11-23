#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# -h and --help print usage on stdout and exit 0 before any state is read or written, for the six scripts of #1624.
# Stub gh, ssh and orca record every call, so a call made before the help check fails the test.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/cwd" "$tmp/grok"
for stub in gh ssh orca; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls"\nexit 1\n' "$stub" "$tmp" > "$tmp/bin/$stub"
  chmod +x "$tmp/bin/$stub"
done
PASS=0
FAIL=0
run() { # <script> <flag> ; sets rc, out, err
  rc=0
  rm -rf "$tmp/grok/new" "$tmp/calls"
  out=$(cd "$tmp/cwd" && HOME="$tmp/home" PATH="$tmp/bin:$PATH" GROK_HOME="$tmp/grok/new" SECRETS_GATE_CONF="$tmp/none.conf" \
    bash "$ROOT/script/$1" "$2" 2>"$tmp/err") || rc=$?
  err=$(cat "$tmp/err")
}
check() { # <label> <condition...>
  local label=$1; shift
  if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $label rc=$rc out=$(head -c 120 <<<"$out") err=$(head -c 120 <<<"$err")"; fi
}
nothing_written() { [ ! -e "$tmp/calls" ] && [ ! -e "$tmp/grok/new" ] && [ -z "$(find "$tmp/home" "$tmp/cwd" -mindepth 1 -print -quit)" ]; }
for script in ship.sh remote-heavy.sh start-cursor-worker.sh check-hook-paths.sh grok-trust.sh secrets-gate.sh; do
  for flag in -h --help; do
    run "$script" "$flag"
    check "$script $flag exits 0" [ "$rc" -eq 0 ]
    check "$script $flag prints Usage on stdout" grep -q 'Usage' <<<"$out"
    check "$script $flag writes no stderr" [ -z "$err" ]
    check "$script $flag touches no file or call" nothing_written
  done
done
# grok-trust with no folder: usage, and no store is created.
rm -rf "$tmp/grok/new"
rc=0; out=$(cd "$tmp/cwd" && GROK_HOME="$tmp/grok/new" bash "$ROOT/script/grok-trust.sh" 2>&1) || rc=$?
check "grok-trust with no folder touches no file" [ ! -e "$tmp/grok/new" ]
# Flags the headers must name (the usage text is the header).
for pair in "ship.sh:--repo" "ship.sh:--pr" "ship.sh:--dry-run" "ship.sh:--environment" "ship.sh:--mechanical" "ship.sh:--verdict-from" \
  "remote-heavy.sh:--host" "remote-heavy.sh:--repo-dir" "remote-heavy.sh:--dir" "remote-heavy.sh:--sub" "remote-heavy.sh:--weight" \
  "remote-heavy.sh:--memory-mb" "remote-heavy.sh:--gate" "remote-heavy.sh:--max-wait" "remote-heavy.sh:--fetch" "remote-heavy.sh:--into" \
  "start-cursor-worker.sh:--run" "start-cursor-worker.sh:--spec" "start-cursor-worker.sh:--title" "start-cursor-worker.sh:--model" \
  "start-cursor-worker.sh:--from" "start-cursor-worker.sh:--on" "start-cursor-worker.sh:--role" "start-cursor-worker.sh:--worktree-path" \
  "start-cursor-worker.sh:--name" "start-cursor-worker.sh:--repo" "start-cursor-worker.sh:--base-branch" \
  "secrets-gate.sh:--dry-run" "secrets-gate.sh:sync" "check-hook-paths.sh:--help" "grok-trust.sh:--help"; do
  script=${pair%%:*} flag=${pair#*:}
  header=$(sed -n '1,/^set /p' "$ROOT/script/$script")
  if grep -qF -e "$flag" <<<"$header"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $script header misses $flag"; fi
done
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
