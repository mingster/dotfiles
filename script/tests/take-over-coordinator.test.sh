#!/usr/bin/env bash
# take-over-coordinator.sh against fixture clones of a local bare origin.
# Never touches the real HOME, ~/agent-state or ~/.claude/state. HOME is a temp folder, ssh,
# launchctl and hostname are fakes first on PATH, AGENT_STATE_SKIP_LAUNCHCTL=1 unless a case says otherwise.
# The real sync.sh is needed (its fence is part of what is tested). Point AGENT_STATE_SRC at an
# agent-state checkout; default is a read-only copy from the real ~/agent-state. Skipped when that
# sync.sh has no coordinator fence.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
script="$root/script/take-over-coordinator.sh"
src=${AGENT_STATE_SRC:-$HOME/agent-state}
if ! grep -q 'coordinator refused' "$src/sync.sh" 2>/dev/null; then
  echo "skipped: $src/sync.sh has no coordinator fence (set AGENT_STATE_SRC to an agent-state checkout)"
  exit 0
fi
base=$(mktemp -d)
trap 'rm -rf "$base"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
pass=0 fail=0
DESC=
check() { if "$@"; then pass=$((pass + 1)); echo "ok   $DESC"; else fail=$((fail + 1)); echo "FAIL $DESC"; fi; }

# Fresh world: bare origin, coordinator-a (coordinator) with 12 state files, backup-a and backup-b backups.
world() {
  W=$(mktemp -d "$base/w.XXXXXX")
  mkdir -p "$W/bin" "$W/fake"
  cat >"$W/bin/hostname" <<'EOF'
#!/usr/bin/env bash
echo "$FAKE_HOST"
EOF
  cat >"$W/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
state=${LC_STATE:-$FAKE_DIR/lc-local}
echo "launchctl $(basename "$state") $*" >>"$FAKE_DIR/launchctl.log"
touch "$state"
case "$1" in
  bootout) [ -e "$FAKE_DIR/stuck" ] || { grep -vx "${2##*/}" "$state" >"$state.n"; mv "$state.n" "$state"; } ;;
  bootstrap) basename "$3" .plist >>"$state" ;;
  print) grep -qx "${2##*/}" "$state" ;;
  *) cat "$state" ;;
esac
EOF
  cat >"$W/bin/ssh" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac
done
host=$1; shift
echo "ssh $host $*" >>"$FAKE_DIR/ssh.log"
[ -e "$FAKE_DIR/down-$host" ] && exit 255
LC_STATE="$FAKE_DIR/lc-$host" sh -c "$*"
EOF
  chmod +x "$W/bin/"*
  git init -q --bare -b main "$W/origin.git"
  local h
  for h in coordinator-a backup-a backup-b; do mkdir -p "$W/home-$h/Library/LaunchAgents"; done
  echo com.agent-state.sync >"$W/fake/lc-coordinator-a"
  echo com.agent-state.sync >"$W/fake/lc-backup-a"
  local sa="$W/home-coordinator-a/agent-state" i
  mkdir -p "$sa/LaunchAgents" "$W/home-coordinator-a/live/mem" "$W/home-coordinator-a/live/state"
  cp -R "$src/sync.sh" "$src/scan.sh" "$src/excludes.txt" "$src/hooks" "$src/.gitignore" "$sa/"
  # shellcheck disable=SC2016
  printf 'memory $HOME/live/mem\nstate $HOME/live/state\nzshenv.local $HOME/.zshenv.local\n' >"$sa/manifest.conf"
  printf '# roles\ncoordinator coordinator-a\nbackup backup-a\nbackup backup-b\n' >"$sa/coordinator.conf"
  printf '<plist>__HOME__</plist>\n' >"$sa/LaunchAgents/com.agent-state.sync.plist"
  printf '<plist>__HOME__</plist>\n' >"$sa/LaunchAgents/com.elon.fleet-watch.plist"
  echo A-own >"$sa/zshenv.local"
  echo note >"$W/home-coordinator-a/live/mem/m.md"
  for i in $(seq 12); do echo "state $i" >"$W/home-coordinator-a/live/state/f$i.md"; done
  git -C "$sa" init -q -b main
  git -C "$sa" remote add origin "$W/origin.git"
  git -C "$sa" add -A && git -C "$sa" commit -q --no-verify -m seed && git -C "$sa" push -q origin main
  cp "$sa/zshenv.local" "$W/home-coordinator-a/.zshenv.local"
  FAKE_HOST=coordinator-a HOME="$W/home-coordinator-a" FAKE_DIR="$W/fake" PATH="$W/bin:$PATH" AGENT_STATE_SKIP_LAUNCHCTL=1 \
    bash "$sa/sync.sh" push >"$W/seed.out" 2>&1 || cat "$W/seed.out"
}
clone_for() { # host
  git clone -q -b main "$W/origin.git" "$W/home-$1/agent-state"
}
# run <host> <args...>: the takeover script as that host
tk() {
  local h=$1; shift
  FAKE_HOST=$h HOME="$W/home-$h" FAKE_DIR="$W/fake" PATH="$W/bin:$PATH" AGENT_STATE_SKIP_LAUNCHCTL=${SKIP:-1} \
    bash "$script" "$@" >"$W/out" 2>&1
  rc=$?
}
sync_as() { # host args
  local h=$1; shift
  FAKE_HOST=$h HOME="$W/home-$h" FAKE_DIR="$W/fake" PATH="$W/bin:$PATH" AGENT_STATE_SKIP_LAUNCHCTL=1 \
    bash "$W/home-$h/agent-state/sync.sh" "$@" >"$W/sout" 2>&1
  rc=$?
}
ohead() { git --git-dir="$W/origin.git" rev-parse main; }
oconf() { git --git-dir="$W/origin.git" show main:coordinator.conf; }
ocoord() { oconf | awk '$1 == "coordinator" { print $2 }'; }
ok() { eval "$1"; }
out_has() { grep -q -- "$1" "$W/out"; }

# 1. full takeover, old host reachable
world; clone_for backup-a
before=$(ohead)
tk backup-a --yes
DESC="takeover with the old host reachable exits 0"; check test "$rc" -eq 0
DESC="origin now names this host as coordinator"; check test "$(ocoord)" = backup-a
DESC="the old coordinator becomes a backup in this host's slot"
check test "$(oconf | awk '$1 == "backup" { printf "%s ", $2 }')" = "coordinator-a backup-b "
DESC="the fence commit changes only coordinator.conf"
check test "$(git --git-dir="$W/origin.git" diff --name-only "$before" main)" = coordinator.conf
DESC="old host sync is stopped over ssh"
check test "$(grep -c com.agent-state.sync "$W/fake/lc-coordinator-a")" -eq 0
DESC="output says old host sync stopped"; check out_has 'old host sync stopped'
DESC="live state is restored from the repo"
check test "$(ls "$W/home-backup-a/live/state" | wc -l | tr -d ' ')" -eq 12 -a -f "$W/home-backup-a/live/mem/m.md"
DESC="the first push passes the shrink guard"; check ok 'test ! -e "$W/home-backup-a/agent-state/.sync-refused" && grep -Eq "pushed|no changes" "$W/out"'
DESC="output shows the push result and the owner steps"; check out_has 'Orca pairing'
DESC=".sync-ok exists"; check test -e "$W/home-backup-a/agent-state/.sync-ok"
DESC="only the sync plist is installed (copied)"
check test "$(ls "$W/home-backup-a/Library/LaunchAgents")" = com.agent-state.sync.plist
DESC="no launchctl call touched anything but the fake ssh target"
check test "$(grep -vc '^launchctl lc-coordinator-a ' "$W/fake/launchctl.log")" -eq 0

# 12. hand back to the old host
tk coordinator-a --yes
DESC="hand back from B to A with the same command works"; check test "$rc" -eq 0 -a "$(ocoord)" = coordinator-a
DESC="after hand back the other host is a backup again"; check test "$(oconf | grep -c '^backup backup-a$')" -eq 1
sync_as backup-a push
DESC="after hand back the previous coordinator's push is refused"; check test "$rc" -eq 1 -a "$(grep -c 'coordinator refused: this host is not coordinator-a' "$W/sout")" -eq 1

# 2 and 3. old host off, then it returns
world; clone_for backup-a; touch "$W/fake/down-coordinator-a"
tk backup-a --yes
DESC="takeover with the old host unreachable passes"; check test "$rc" -eq 0 -a "$(ocoord)" = backup-a
DESC="output says fenced by coordinator.conf"; check out_has 'old host unreachable, fenced by coordinator.conf'
rm "$W/fake/down-coordinator-a"
echo newer >"$W/home-coordinator-a/live/mem/new.md"
before=$(ohead); live_before=$(cd "$W/home-coordinator-a/live" && find . -type f | sort | xargs cat | shasum)
sync_as coordinator-a push
DESC="the returning old host's push is refused"; check test "$rc" -eq 1 -a "$(grep -c '^coordinator refused: this host is not backup-a$' "$W/sout")" -eq 1
DESC="origin is unchanged by the returning host"; check test "$(ohead)" = "$before"
DESC="the returning host's live files are intact"
check test "$(cd "$W/home-coordinator-a/live" && find . -type f | sort | xargs cat | shasum)" = "$live_before" -a -f "$W/home-coordinator-a/live/mem/new.md"
DESC="the returning host's repo is untouched"; check test -z "$(git -C "$W/home-coordinator-a/agent-state" status --porcelain)"

# 4. not a backup
world; mkdir -p "$W/home-stranger"; git clone -q -b main "$W/origin.git" "$W/home-stranger/agent-state"
before=$(ohead); tk stranger --yes
DESC="a host without a backup line is refused"; check ok 'test "$rc" -eq 1 -a "$(ohead)" = "$before" && out_has "not a backup"'

# 5. missing --yes
world; clone_for backup-a; before=$(ohead); tk backup-a
DESC="missing --yes refuses after printing the plan"; check test "$rc" -eq 1 -a "$(ohead)" = "$before"
DESC="the plan is printed"; check out_has 'fence'
DESC="--dry-run changes nothing and exits 0"
tk backup-a --dry-run; check test "$rc" -eq 0 -a "$(ohead)" = "$before" -a -z "$(ls "$W/home-backup-a/live" 2>/dev/null)"

# 6. earlier backup reachable
world; clone_for backup-b; before=$(ohead); tk backup-b --yes
DESC="an earlier backup that answers ssh blocks the takeover"; check test "$rc" -eq 1 -a "$(ohead)" = "$before"
DESC="the warning names the earlier backup and --skip-order"; check ok 'out_has backup-a && out_has -- --skip-order'
tk backup-b --yes --skip-order
DESC="--skip-order lets it continue"; check test "$rc" -eq 0 -a "$(ocoord)" = backup-b
world; clone_for backup-b; touch "$W/fake/down-backup-a"; tk backup-b --yes
DESC="an earlier backup that is off does not block"; check test "$rc" -eq 0 -a "$(ocoord)" = backup-b

# 7. rejected push retries once
world; clone_for backup-a
printf '#!/bin/sh\n[ -e "%s/rejected" ] && exit 0\ntouch "%s/rejected"\necho "rejected once" >&2\nexit 1\n' "$W" "$W" >"$W/origin.git/hooks/pre-receive"
chmod +x "$W/origin.git/hooks/pre-receive"
tk backup-a --yes
DESC="a rejected fence push is retried once and succeeds"; check ok 'test "$rc" -eq 0 -a "$(ocoord)" = backup-a && out_has "retry"'
DESC="the retry leaves one fence commit"; check test "$(git --git-dir="$W/origin.git" log --oneline | grep -c 'takes over')" -eq 1
world; clone_for backup-a
printf '#!/bin/sh\necho "always rejected" >&2\nexit 1\n' >"$W/origin.git/hooks/pre-receive"; chmod +x "$W/origin.git/hooks/pre-receive"
before=$(ohead); tk backup-a --yes
DESC="a second rejection stops with the state and next command"; check ok 'test "$rc" -eq 1 -a "$(ohead)" = "$before" && out_has "Next"'

# 8. rerun after a stop at step 5 is safe
world; clone_for backup-a; touch "$W/fake/stuck"
tk backup-a --yes
DESC="old host sync still loaded stops at step 5"; check ok 'test "$rc" -eq 1 -a "$(ocoord)" = backup-a && out_has "step 5" && out_has "Next"'
after_fence=$(ohead); rm "$W/fake/stuck"
tk backup-a --yes
DESC="rerun says this host is already the coordinator and finishes"; check ok 'test "$rc" -eq 0 && out_has "already the coordinator"'
DESC="rerun adds no commit before the sync push"; check test "$(git --git-dir="$W/origin.git" log --oneline "$after_fence"..main | grep -vc 'sync backup-a')" -eq 0
DESC="rerun restored live state"; check test "$(ls "$W/home-backup-a/live/state" | wc -l | tr -d ' ')" -eq 12
tk backup-a --yes
DESC="a third run is safe too"; check test "$rc" -eq 0

# 9. own .zshenv.local kept
world; clone_for backup-a; echo B-own >"$W/home-backup-a/.zshenv.local"
tk backup-a --yes
DESC=".zshenv.local on this host is kept"; check test "$(cat "$W/home-backup-a/.zshenv.local")" = B-own
world; clone_for backup-a; tk backup-a --yes
DESC="without an own .zshenv.local the restored one stays"; check test "$(cat "$W/home-backup-a/.zshenv.local")" = A-own

# 10. only the sync LaunchAgent is loaded
world; clone_for backup-a; : >"$W/fake/launchctl.log"; SKIP=0 tk backup-a --yes
DESC="launchctl bootstraps only the sync plist"
check test "$(grep -c ' bootstrap ' "$W/fake/launchctl.log")" -eq 1 -a "$(grep ' bootstrap ' "$W/fake/launchctl.log" | grep -c 'com.agent-state.sync.plist')" -eq 1
DESC="no other plist is installed"; check test "$(ls "$W/home-backup-a/Library/LaunchAgents")" = com.agent-state.sync.plist
DESC="only the fake launchctl ran (state files are in the fixture)"; check test "$(grep -c '^launchctl lc-' "$W/fake/launchctl.log")" -eq "$(wc -l <"$W/fake/launchctl.log" | tr -d ' ')"

# unpushed commits or a dirty tree stop the takeover before the fence
world; clone_for backup-a
git -C "$W/home-backup-a/agent-state" commit -q --allow-empty --no-verify -m local-only
before=$(ohead); tk backup-a --yes
DESC="unpushed local commits refuse and are printed"; check ok 'test "$rc" -eq 1 -a "$(ohead)" = "$before" && out_has "local-only"'
world; clone_for backup-a; echo x >"$W/home-backup-a/agent-state/stray.txt"
before=$(ohead); tk backup-a --yes
DESC="a dirty tree refuses and is printed"; check ok 'test "$rc" -eq 1 -a "$(ohead)" = "$before" && out_has "stray.txt"'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
