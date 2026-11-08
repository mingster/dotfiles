#!/usr/bin/env bash
# Tests for script/fleet-pull.sh and state-dir fast-forward in script/elon-startup.sh.
# shellcheck disable=SC1091,SC2015
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$here/lib/asdf-pin.sh"
pull_script="$root/script/fleet-pull.sh"
elon_script="$root/script/elon-startup.sh"

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test

make_repo() { # <workdir> <bare.git>
  rm -rf "$1" "$2"
  git init -q --bare -b main "$2"
  git init -q -b main "$1"
  git -C "$1" remote add origin "$2"
  echo init >"$1/file.txt"
  git -C "$1" add file.txt
  git -C "$1" commit -qm init
  git -C "$1" push -q -u origin main
}

advance_origin() { # <bare.git> [content]
  local w
  w=$(mktemp -d)
  git clone -q "$1" "$w"
  echo "${2:-more}" >>"$w/file.txt"
  git -C "$w" commit -qam advance
  git -C "$w" push -q origin main
  rm -rf "$w"
}

# 1. Reads fleet-pull.json from AGENT_STATE_DIR and fast-forwards AGENT_STATE_DIR itself + repos
state1="$tmp/state1"
state1_bare="$tmp/state1.git"
repo1="$tmp/repo1"
repo1_bare="$tmp/repo1.git"
make_repo "$state1" "$state1_bare"
make_repo "$repo1" "$repo1_bare"
cat >"$state1/fleet-pull.json" <<EOF
{"hosts":[],"repos":["$repo1"]}
EOF
git -C "$state1" add fleet-pull.json
git -C "$state1" commit -qm cfg
git -C "$state1" push -q origin main
advance_origin "$state1_bare" "state-advance"
advance_origin "$repo1_bare" "repo-advance"
state1_tip=$(git --git-dir="$state1_bare" rev-parse refs/heads/main)
repo1_tip=$(git --git-dir="$repo1_bare" rev-parse refs/heads/main)

set +e
out=$(env -u FLEET_PULL_CONFIG AGENT_STATE_DIR="$state1" SECRETS_SYNC_CONFIG="$tmp/no-secrets.json" bash "$pull_script" 2>&1)
ec=$?
set -e
[ "$ec" -eq 0 ] && ok "clean pull via state_dir/fleet-pull.json exits 0" || bad "clean pull exit $ec: $out"
[ "$(git -C "$state1" rev-parse HEAD)" = "$state1_tip" ] && ok "state_dir itself fast-forwarded" || bad "state_dir not fast-forwarded"
[ "$(git -C "$repo1" rev-parse HEAD)" = "$repo1_tip" ] && ok "configured repo fast-forwarded" || bad "repo1 not fast-forwarded"

# 2. Reads fleet-config.json from AGENT_STATE_DIR when fleet-pull.json is absent
state2="$tmp/state2"
state2_bare="$tmp/state2.git"
repo2="$tmp/repo2"
repo2_bare="$tmp/repo2.git"
make_repo "$state2" "$state2_bare"
make_repo "$repo2" "$repo2_bare"
cat >"$state2/fleet-config.json" <<EOF
{"hosts":[],"repos":["$repo2"]}
EOF
git -C "$state2" add fleet-config.json
git -C "$state2" commit -qm cfg2
git -C "$state2" push -q origin main
advance_origin "$repo2_bare" "repo2-advance"
repo2_tip=$(git --git-dir="$repo2_bare" rev-parse refs/heads/main)

set +e
out=$(env -u FLEET_PULL_CONFIG AGENT_STATE_DIR="$state2" SECRETS_SYNC_CONFIG="$tmp/no-secrets.json" bash "$pull_script" 2>&1)
ec=$?
set -e
[ "$ec" -eq 0 ] && [ "$(git -C "$repo2" rev-parse HEAD)" = "$repo2_tip" ] \
  && ok "fleet-config.json in AGENT_STATE_DIR used when fleet-pull.json absent" \
  || bad "fleet-config.json fallback failed (ec=$ec): $out"

# 3.Dirty checkout exits non-zero and names host and repo
echo uncommitted >>"$repo1/file.txt"
set +e
out=$(env -u FLEET_PULL_CONFIG AGENT_STATE_DIR="$state1" SECRETS_SYNC_CONFIG="$tmp/no-secrets.json" bash "$pull_script" 2>&1)
ec=$?
set -e
git -C "$repo1" checkout -q -- file.txt
[ "$ec" -ne 0 ] && grep -q "local" <<<"$out" && grep -qF "$repo1" <<<"$out" && grep -qi "dirty" <<<"$out" \
  && ok "dirty checkout exits non-zero and names host and repo" \
  || bad "dirty checkout should fail and name local + $repo1 (ec=$ec): $out"

# 3b. Untracked files alone do not block a fast-forward
echo scratch >"$repo1/untracked.tmp"
set +e
out=$(env -u FLEET_PULL_CONFIG AGENT_STATE_DIR="$state1" SECRETS_SYNC_CONFIG="$tmp/no-secrets.json" bash "$pull_script" 2>&1)
ec=$?
set -e
rm -f "$repo1/untracked.tmp"
[ "$ec" -eq 0 ] && ! grep -qi "dirty" <<<"$out" \
  && ok "untracked files alone do not count as dirty" \
  || bad "untracked files should not fail the pull (ec=$ec): $out"

# 4. Diverged checkout exits non-zero and names host and repo
echo local_diverge >>"$repo1/file.txt"
git -C "$repo1" commit -qam local_diverge
advance_origin "$repo1_bare" "remote_diverge"
set +e
out=$(env -u FLEET_PULL_CONFIG AGENT_STATE_DIR="$state1" SECRETS_SYNC_CONFIG="$tmp/no-secrets.json" bash "$pull_script" 2>&1)
ec=$?
set -e
[ "$ec" -ne 0 ] && grep -q "local" <<<"$out" && grep -qF "$repo1" <<<"$out" && grep -Eqi "diverged|not fast-forward" <<<"$out" \
  && ok "diverged checkout exits non-zero and names host and repo" \
  || bad "diverged checkout should fail and name local + $repo1 (ec=$ec): $out"
git -C "$repo1" reset -q --hard origin/main

# 5. Behind after pull exits non-zero and names host and repo
# Simulate a checkout where merge --ff-only exits 0 without advancing HEAD (still behind origin/main).
advance_origin "$repo1_bare" "still-behind"
git -C "$repo1" fetch -q origin
stub_bin="$tmp/stub-behind"
mkdir -p "$stub_bin"
real_git=$(command -v git)
cat >"$stub_bin/git" <<EOS
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "merge" ]; then
    exit 0
  fi
done
exec "$real_git" "\$@"
EOS
chmod +x "$stub_bin/git"
set +e
out=$(PATH="$stub_bin:$PATH" env -u FLEET_PULL_CONFIG AGENT_STATE_DIR="$state1" SECRETS_SYNC_CONFIG="$tmp/no-secrets.json" bash "$pull_script" 2>&1)
ec=$?
set -e
[ "$ec" -ne 0 ] && grep -q "local" <<<"$out" && grep -qF "$repo1" <<<"$out" && grep -qi "behind" <<<"$out" \
  && ok "behind-after-pull checkout exits non-zero and names host and repo" \
  || bad "behind-after-pull should fail and name local + $repo1 (ec=$ec): $out"
git -C "$repo1" merge --ff-only -q origin/main

# 6. Unreachable remote host exits non-zero and names host and repo
git -C "$state1" fetch -q origin main
git -C "$state1" reset -q --hard origin/main
cat >"$state1/fleet-pull.json" <<EOF
{"hosts":["host-unreachable"],"repos":["$repo1"]}
EOF
git -C "$state1" commit -qam add_host
git -C "$state1" push -q origin main
ssh_bin="$tmp/ssh-fail"
mkdir -p "$ssh_bin"
cat >"$ssh_bin/ssh" <<'EOS'
#!/usr/bin/env bash
exit 255
EOS
chmod +x "$ssh_bin/ssh"
set +e
out=$(PATH="$ssh_bin:$PATH" env -u FLEET_PULL_CONFIG AGENT_STATE_DIR="$state1" SECRETS_SYNC_CONFIG="$tmp/no-secrets.json" bash "$pull_script" 2>&1)
ec=$?
set -e
[ "$ec" -ne 0 ] && grep -q "host-unreachable" <<<"$out" && grep -qF "$repo1" <<<"$out" && grep -qi "unreachable" <<<"$out" \
  && ok "unreachable host exits non-zero and names host and repo" \
  || bad "unreachable host should fail and name host-unreachable + $repo1 (ec=$ec): $out"

# 7. elon-startup.sh fast-forwards AGENT_STATE_DIR instead of only fetching it
elon_work="$tmp/elon"
mkdir -p "$elon_work/bin" "$elon_work/script" "$elon_work/home/.claude/state" "$elon_work/cwd"
cp "$elon_script" "$elon_work/script/elon-startup.sh"
printf 'print("[]")\n' >"$elon_work/script/usage-gate.py"
printf '#!/usr/bin/env bash\necho coord-host\n' >"$elon_work/bin/hostname"
printf '#!/usr/bin/env bash\necho load-ok\n' >"$elon_work/home/.claude/state/fleet-load.sh"
chmod +x "$elon_work/bin/hostname" "$elon_work/home/.claude/state/fleet-load.sh"
make_repo "$elon_work/state" "$elon_work/state.git"
printf 'coordinator coord-host\n' >"$elon_work/state/coordinator.conf"
cat >"$elon_work/state/fleet-pull.json" <<EOF
{"hosts":[],"repos":["$repo1"]}
EOF
git -C "$elon_work/state" add coordinator.conf fleet-pull.json
git -C "$elon_work/state" commit -qm coord
git -C "$elon_work/state" push -q origin main
echo .sync-ok >>"$elon_work/state/.git/info/exclude"
touch "$elon_work/state/.sync-ok"
advance_origin "$elon_work/state.git" "state-ff-in-elon-startup"
elon_tip=$(git --git-dir="$elon_work/state.git" rev-parse refs/heads/main)

set +e
elon_out=$(cd "$elon_work/cwd" && HOME="$elon_work/home" PATH="$elon_work/bin:$PATH" AGENT_STATE_DIR="$elon_work/state" \
  GIT_TERMINAL_PROMPT=0 bash "$elon_work/script/elon-startup.sh" --no-pull 2>&1)
elon_ec=$?
set -e
[ "$elon_ec" -eq 0 ] && [ "$(git -C "$elon_work/state" rev-parse HEAD)" = "$elon_tip" ] \
  && grep -q "ok coordinator coord-host, state fresh" <<<"$elon_out" \
  && ! grep -q "NO DISPATCH" <<<"$elon_out" \
  && ok "elon-startup.sh fast-forwards state repo to origin/main" \
  || bad "elon-startup.sh did not fast-forward state repo (ec=$elon_ec): $elon_out"

echo "fleet-pull: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
