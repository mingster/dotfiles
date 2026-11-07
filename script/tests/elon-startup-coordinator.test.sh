#!/usr/bin/env bash
# elon-startup.sh section 0: may this host dispatch? Temp HOME, fixture state repo with a bare
# origin, fake hostname. Never touches the real state directories or the real fleet config.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$root/script/tests/lib/asdf-pin.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
pass=0 fail=0

mkdir -p "$work/bin" "$work/script" "$work/home/.claude/state" "$work/cwd"
cp "$root/script/elon-startup.sh" "$work/script/elon-startup.sh"
printf '#!/usr/bin/env bash\n[ "${1:-}" = -s ] && echo "$FAKE_HOST" || echo "$FAKE_HOST.local"\n' > "$work/bin/hostname"
printf '#!/usr/bin/env bash\necho load-stub\n' > "$work/home/.claude/state/fleet-load.sh"
printf 'print("[]")\n' > "$work/script/usage-gate.py"
chmod +x "$work/bin/hostname" "$work/home/.claude/state/fleet-load.sh"
echo '{"hosts":[],"repos":[]}' > "$work/fleet.json"

# Fresh fixture: bare origin with coordinator.conf, a clone as the state repo, a fresh .sync-ok.
setup() {
  rm -rf "$work/origin.git" "$work/seed" "$work/state"
  git init -q --bare -b main "$work/origin.git"
  git clone -q "$work/origin.git" "$work/seed" 2>/dev/null
  printf 'coordinator coordinator-a\nbackup backup-a\n' > "$work/seed/coordinator.conf"
  git -C "$work/seed" add -A && git -C "$work/seed" commit -qm init && git -C "$work/seed" push -q origin HEAD:main
  git clone -q "$work/origin.git" "$work/state"
  echo .sync-ok >> "$work/state/.git/info/exclude"
  touch "$work/state/.sync-ok"
}
age_sync() { python3 -c "import os,time,sys; t=time.time()-int(sys.argv[2])*60; os.utime(sys.argv[1],(t,t))" "$work/state/.sync-ok" "$1"; }

OUT=''
run() { # run <host>
  set +e
  OUT=$(cd "$work/cwd" && FAKE_HOST="$1" HOME="$work/home" PATH="$work/bin:$PATH" AGENT_STATE_DIR="$work/state" \
    FLEET_PULL_CONFIG="$work/fleet.json" GIT_TERMINAL_PROMPT=0 bash "$work/script/elon-startup.sh" --no-pull 2>&1)
  RC=$?
  set -e
}
check() { # check <name> <grep -F pattern, required> [absent pattern]
  local name=$1 want=$2 absent=${3:-}
  if grep -qF -- "$want" <<<"$OUT" && { [ -z "$absent" ] || ! grep -qF -- "$absent" <<<"$OUT"; } && [ "$RC" = 0 ]; then
    pass=$((pass + 1)); echo "ok   $name"
  else
    fail=$((fail + 1)); echo "FAIL $name (want: $want; absent: $absent; rc=$RC)"; echo "$OUT" | sed -n '1,12p' | sed 's/^/     /'
  fi
}

setup; run coordinator-a
check "all pass" "ok coordinator coordinator-a, state fresh" "NO DISPATCH"
case "$OUT" in "== 0 coordinator"*) pass=$((pass + 1)); echo "ok   section 0 comes first";; *) fail=$((fail + 1)); echo "FAIL section 0 comes first";; esac

setup; run backup-a
check "other host" "NO DISPATCH: this host is backup-a, coordinator is coordinator-a"
check "other host flagged" "PROBLEM" ""

setup; run Coordinator-A
check "case difference passes" "ok coordinator coordinator-a, state fresh" "NO DISPATCH"

setup
echo more >> "$work/seed/coordinator.conf"; git -C "$work/seed" commit -qam two; git -C "$work/seed" push -q origin HEAD:main
run coordinator-a
check "behind origin" "NO DISPATCH: state repo is behind origin/main"

setup; age_sync 45; run coordinator-a
check "stale .sync-ok" "NO DISPATCH: .sync-ok is older than 30 minutes"

setup; age_sync 29; run coordinator-a
check "29 minute .sync-ok passes" "ok coordinator coordinator-a, state fresh" "NO DISPATCH"

setup; rm "$work/state/.sync-ok"; run coordinator-a
check "missing .sync-ok" "NO DISPATCH: no .sync-ok"

setup; mv "$work/state" "$work/state.gone"; run coordinator-a
check "missing state repo" "NO DISPATCH: no state repo"
rm -rf "$work/state.gone"

setup
git -C "$work/seed" rm -q coordinator.conf; echo "backup backup-a" > "$work/seed/coordinator.conf"
git -C "$work/seed" add -A; git -C "$work/seed" commit -qm nocoord; git -C "$work/seed" push -q origin HEAD:main
git -C "$work/state" pull -q
run coordinator-a
check "missing coordinator line" "NO DISPATCH: no coordinator line"

setup; git -C "$work/state" remote set-url origin "$work/nowhere.git"; run coordinator-a
check "fetch failure, local file still read" "NO DISPATCH: fetch of the state repo failed" "this host is"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
