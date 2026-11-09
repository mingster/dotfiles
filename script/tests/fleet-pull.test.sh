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

# 6b. A reachable host whose repo fails is not reported as unreachable
ssh_ok_bin="$tmp/ssh-runs"
mkdir -p "$ssh_ok_bin"
cat >"$ssh_ok_bin/ssh" <<'EOS'
#!/usr/bin/env bash
# Like real ssh: join the words into one command line for a remote shell, which expands ~.
while [ "$#" -gt 0 ] && [ "$1" != bash ]; do shift; done
exec sh -c "$*"
EOS
chmod +x "$ssh_ok_bin/ssh"
cat >"$state1/fleet-pull.json" <<'EOF'
{"hosts":["host-unreachable"],"repos":["~/repo1"]}
EOF
git -C "$state1" commit -qam tilde_repo
git -C "$state1" push -q origin main
echo uncommitted >>"$repo1/file.txt"
set +e
out=$(HOME="$tmp" PATH="$ssh_ok_bin:$PATH" env -u FLEET_PULL_CONFIG AGENT_STATE_DIR="$state1" SECRETS_SYNC_CONFIG="$tmp/no-secrets.json" bash "$pull_script" 2>&1)
ec=$?
set -e
git -C "$repo1" checkout -q -- file.txt
[ "$ec" -ne 0 ] && grep -q "host-unreachable .*repo1 (dirty)" <<<"$out" && ! grep -q "unreachable host" <<<"$out" \
  && ok "failing repo on a reachable host is not reported as unreachable" \
  || bad "reachable host with a dirty repo reported wrong (ec=$ec): $out"

# 6c. Remote hosts also fast-forward their ~/agent-state
git -C "$state1" checkout -q -- . 2>/dev/null || true
cat >"$state1/fleet-pull.json" <<'EOF'
{"hosts":["host-a"],"repos":[]}
EOF
git -C "$state1" commit -qam remote_state
git -C "$state1" push -q origin main
remote_home="$tmp/remote-home"
mkdir -p "$remote_home"
git clone -q "$(git -C "$state1" remote get-url origin)" "$remote_home/agent-state"
git -C "$remote_home/agent-state" reset -q --hard HEAD~1
set +e
out=$(HOME="$remote_home" PATH="$ssh_ok_bin:$PATH" env -u FLEET_PULL_CONFIG AGENT_STATE_DIR="$state1" SECRETS_SYNC_CONFIG="$tmp/no-secrets.json" bash "$pull_script" 2>&1)
ec=$?
set -e
[ "$(git -C "$remote_home/agent-state" rev-parse HEAD)" = "$(git -C "$state1" rev-parse HEAD)" ] && grep -q "ok   host-a .*agent-state" <<<"$out" \
  && ok "remote host agent-state is fast-forwarded" \
  || bad "remote agent-state not pulled (ec=$ec): $out"

# 6d. agent_hosts resets dirty and detached repos to origin/main, keeps ignored files, and leaves normal hosts untouched
dirty_repo="$remote_home/repo-dirty"
dirty_bare="$tmp/repo-dirty.git"
detached_repo="$remote_home/repo-detached"
detached_bare="$tmp/repo-detached.git"
make_repo "$dirty_repo" "$dirty_bare"
make_repo "$detached_repo" "$detached_bare"
echo "ignored.env" >"$dirty_repo/.gitignore"
git -C "$dirty_repo" add .gitignore
git -C "$dirty_repo" commit -qm gitignore
git -C "$dirty_repo" push -q origin main
advance_origin "$dirty_bare" "dirty-advance"
advance_origin "$detached_bare" "detached-advance"
dirty_tip=$(git --git-dir="$dirty_bare" rev-parse refs/heads/main)
dirty_short=$(git --git-dir="$dirty_bare" rev-parse --short refs/heads/main)
detached_tip=$(git --git-dir="$detached_bare" rev-parse refs/heads/main)
detached_short=$(git --git-dir="$detached_bare" rev-parse --short refs/heads/main)
echo "secret=1" >"$dirty_repo/ignored.env"
echo uncommitted >>"$dirty_repo/file.txt"
echo scratch >"$dirty_repo/untracked.txt"
git -C "$detached_repo" checkout -q --detach HEAD

cat >"$state1/fleet-pull.json" <<'EOF'
{"hosts":["host-normal"],"agent_hosts":["host-agent"],"repos":["~/repo-dirty","~/repo-detached"]}
EOF
git -C "$state1" commit -qam normal_host_cfg
git -C "$state1" push -q origin main
set +e
out=$(HOME="$remote_home" PATH="$ssh_ok_bin:$PATH" env -u FLEET_PULL_CONFIG AGENT_STATE_DIR="$state1" SECRETS_SYNC_CONFIG="$tmp/no-secrets.json" bash "$pull_script" 2>&1)
ec=$?
set -e
[ "$ec" -ne 0 ] \
  && grep -q "fail host-normal .*repo-dirty (dirty)" <<<"$out" \
  && grep -q "uncommitted" "$dirty_repo/file.txt" \
  && [ "$(git -C "$dirty_repo" rev-parse HEAD)" != "$dirty_tip" ] \
  && ok "normal host repo is untouched and still reported dirty" \
  || bad "normal host repo should stay dirty and untouched (ec=$ec): $out"

cat >"$state1/fleet-pull.json" <<'EOF'
{"hosts":["host-agent"],"agent_hosts":["host-agent"],"repos":["~/repo-dirty","~/repo-detached"]}
EOF
git -C "$state1" commit -qam agent_host_cfg
git -C "$state1" push -q origin main
set +e
out=$(HOME="$remote_home" PATH="$ssh_ok_bin:$PATH" env -u FLEET_PULL_CONFIG AGENT_STATE_DIR="$state1" SECRETS_SYNC_CONFIG="$tmp/no-secrets.json" bash "$pull_script" 2>&1)
ec=$?
set -e
[ "$(git -C "$dirty_repo" branch --show-current)" = main ] \
  && [ "$(git -C "$dirty_repo" rev-parse HEAD)" = "$dirty_tip" ] \
  && [ -z "$(git -C "$dirty_repo" status --porcelain)" ] \
  && [ "$(git -C "$detached_repo" branch --show-current)" = main ] \
  && [ "$(git -C "$detached_repo" rev-parse HEAD)" = "$detached_tip" ] \
  && [ -z "$(git -C "$detached_repo" status --porcelain)" ] \
  && grep -q "ok   host-agent .*repo-dirty $dirty_short (reset)" <<<"$out" \
  && grep -q "ok   host-agent .*repo-detached $detached_short (reset)" <<<"$out" \
  && ! grep -q "agent-state .* (reset)" <<<"$out" \
  && ok "dirty and detached repos on agent host end on origin/main clean and report reset" \
  || bad "agent host repos not reset to origin/main clean (ec=$ec): $out"

[ -f "$dirty_repo/ignored.env" ] && [ ! -e "$dirty_repo/untracked.txt" ] \
  && ok "ignored file on agent host survives while untracked file is cleaned" \
  || bad "ignored file missing or untracked file remained after agent host reset"

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

# 8. fleet-pull.sh refreshes user-level links (setup-claude-code.sh --keep-settings and setup-agent-skills.sh)
#    on the local host and each reachable remote host after fast-forwarding dotfiles
df_seed="$tmp/df-seed"
df_bare="$tmp/df.git"
make_repo "$df_seed" "$df_bare"
mkdir -p "$df_seed/script" "$df_seed/.agents/claude" "$df_seed/.agents/skills/tdd" \
  "$df_seed/templates/agent-team/.claude/hooks" "$df_seed/templates/agent-team/.claude/bin"
cp "$root/script/setup-claude-code.sh" "$df_seed/script/setup-claude-code.sh"
cp "$root/script/setup-agent-skills.sh" "$df_seed/script/setup-agent-skills.sh"
mkdir -p "$df_seed/script/lib"
cp "$root/script/lib/dotfiles-source.sh" "$df_seed/script/lib/dotfiles-source.sh"
printf '# claude\n' >"$df_seed/.agents/claude/CLAUDE.md"
printf '{"template_settings":true}\n' >"$df_seed/.agents/claude/settings.json"
printf '# tdd\n' >"$df_seed/.agents/skills/tdd/SKILL.md"
for h in guard-bash.py strikes.py worker-budget.py session-start.md; do
  printf '# %s\n' "$h" >"$df_seed/templates/agent-team/.claude/hooks/$h"
done
for b in env-peek.py state-of-play.sh; do
  printf '# %s\n' "$b" >"$df_seed/templates/agent-team/.claude/bin/$b"
done
for s in ceo crew deploy elon poteto-mode staging-review team-audit tl; do
  mkdir -p "$df_seed/templates/agent-team/.agents/skills/$s"
  printf '# %s\n' "$s" >"$df_seed/templates/agent-team/.agents/skills/$s/SKILL.md"
done
git -C "$df_seed" add -A
git -C "$df_seed" commit -qm "seed dotfiles"
git -C "$df_seed" push -q origin main

local_home="$tmp/local-home"
rem_home="$tmp/rem-home"
mkdir -p "$local_home/.claude" "$rem_home/.claude"
printf '{"keep_settings":true}\n' >"$local_home/.claude/settings.json"
printf '{"keep_settings":true}\n' >"$rem_home/.claude/settings.json"
git clone -q "$df_bare" "$local_home/dotfiles"
git clone -q "$df_bare" "$rem_home/dotfiles"
advance_origin "$df_bare" "df-advance"
df_tip=$(git --git-dir="$df_bare" rev-parse refs/heads/main)

cat >"$state1/fleet-pull.json" <<'EOF'
{"hosts":["host-a"],"repos":["~/dotfiles"]}
EOF
git -C "$state1" commit -qam pull_dotfiles
git -C "$state1" push -q origin main
git clone -q "$(git -C "$state1" remote get-url origin)" "$rem_home/agent-state"

ssh_rem_bin="$tmp/ssh-rem"
mkdir -p "$ssh_rem_bin"
cat >"$ssh_rem_bin/ssh" <<EOS
#!/usr/bin/env bash
while [ "\$#" -gt 0 ] && [ "\$1" != bash ]; do shift; done
export HOME="$rem_home"
exec sh -c "\$*"
EOS
cat >"$ssh_rem_bin/orca" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$ssh_rem_bin/ssh" "$ssh_rem_bin/orca"

set +e
out8=$(HOME="$local_home" PATH="$ssh_rem_bin:/usr/bin:/bin" env -u FLEET_PULL_CONFIG -u DOTFILES AGENT_STATE_DIR="$state1" SECRETS_SYNC_CONFIG="$tmp/no-secrets.json" bash "$pull_script" 2>&1)
ec8=$?
set -e

check_host_links() {
  local hdir="$1"
  [ "$(git -C "$hdir/dotfiles" rev-parse HEAD)" = "$df_tip" ] || return 1
  grep -q '"keep_settings":true' "$hdir/.claude/settings.json" || return 1
  for h in guard-bash.py strikes.py worker-budget.py session-start.md; do
    [ -L "$hdir/.claude/hooks/$h" ] && [ -f "$hdir/.claude/hooks/$h" ] || return 1
  done
  for b in env-peek.py state-of-play.sh; do
    [ -L "$hdir/.claude/bin/$b" ] && [ -f "$hdir/.claude/bin/$b" ] || return 1
  done
  for s in ceo crew deploy elon poteto-mode staging-review team-audit tl; do
    [ -L "$hdir/.agents/skills/$s" ] && [ -L "$hdir/.claude/skills/$s" ] || return 1
  done
}

if [ "$ec8" -eq 0 ] && check_host_links "$local_home" && check_host_links "$rem_home"; then
  ok "fleet-pull refreshes user-level hooks, bin, and Tier 2 skills on local and remote hosts"
else
  bad "fleet-pull failed to refresh user-level links on local or remote host (ec=$ec8): $out8"
fi

echo "fleet-pull: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
