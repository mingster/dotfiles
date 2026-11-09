#!/usr/bin/env bash
# fleet-toolchain-check.sh with stubbed versions, fake ssh, and fake tools (no network).
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

mkdir -p "$tmp/state"
printf 'coordinator coord-a\n' > "$tmp/state/coordinator.conf"
export AGENT_STATE_DIR="$tmp/state"
printf '%s\n' '{"hosts":["worker-a","coord-a"],"repos":[]}' > "$tmp/fleet.json"
export FLEET_PULL_CONFIG="$tmp/fleet.json"
DOTFILES_DIR="$(cd "$here/.." && pwd)"
export DOTFILES_DIR
export FLEET_TOOLCHAIN_LATEST_ORCA=1.4.253
export FLEET_TOOLCHAIN_LATEST_BUN=1.4.4
export FLEET_TOOLCHAIN_LATEST_NODE=24.22.1
export FLEET_TOOLCHAIN_LATEST_PYTHON3=3.15.2

base_tools='"git":"2.56.0","gh":"2.103.3","jq":"1.8.2","python3":"3.15.2","shellcheck":"0.11.0","claude":"2.1.319","agent":"2026.11.05-86047df","agy":"1.5.3"'

export FLEET_TOOLCHAIN_VERSIONS="{
  \"coord-a\": {$base_tools, \"orca\": \"1.4.253\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"},
  \"worker-a\": {$base_tools, \"orca\": \"1.4.251\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"}
}"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/ssh"; chmod +x "$tmp/ssh"
export FLEET_TOOLCHAIN_RUN="$tmp/ssh"

out=$("$here/fleet-toolchain-check.sh" 2>&1)
check "older orca on worker-a is reported against the coordinator" "$(echo "$out" | grep -q 'worker-a orca 1.4.251 is below coord-a 1.4.253'; echo $?)"
check "coord-a at latest is quiet for orca" "$(echo "$out" | grep -q 'coord-a orca' && echo 1 || echo 0)"
line_cnt=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
check "same bun and node produce no extra lines" "$([ "$line_cnt" = 1 ] && echo 0 || echo 1)"

export FLEET_TOOLCHAIN_LATEST_ORCA=1.4.254
export FLEET_TOOLCHAIN_VERSIONS="{
  \"coord-a\": {$base_tools, \"orca\": \"1.4.253\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"},
  \"worker-a\": {$base_tools, \"orca\": \"1.4.253\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"}
}"
out_or=$(FLEET_TOOLCHAIN_LATEST_ORCA=1.4.254 FLEET_TOOLCHAIN_VERSIONS="$FLEET_TOOLCHAIN_VERSIONS" \
  FLEET_PULL_CONFIG="$FLEET_PULL_CONFIG" FLEET_TOOLCHAIN_RUN="$FLEET_TOOLCHAIN_RUN" \
  DOTFILES_DIR="$DOTFILES_DIR" "$here/fleet-toolchain-check.sh" 2>&1)
check "842 peer level with the coordinator is quiet when both trail latest" \
  "$(echo "$out_or" | grep -q 'worker-a orca' && echo 1 || echo 0)"
check "842 coordinator below latest is still reported" \
  "$(echo "$out_or" | grep -q 'coord-a orca 1.4.253 is below latest 1.4.254'; echo $?)"

# 842: a peer ahead of the coordinator is drift; the coordinator is never below a peer
ahead_out=$(FLEET_TOOLCHAIN_LATEST_ORCA=1.4.253 FLEET_TOOLCHAIN_VERSIONS="{
  \"coord-a\": {$base_tools, \"orca\": \"1.4.253\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"},
  \"worker-a\": {${base_tools/2.1.319/2.1.320}, \"orca\": \"1.4.253\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"}
}" "$here/fleet-toolchain-check.sh" 2>&1)
check "842 peer ahead of the coordinator is reported as drift" \
  "$(echo "$ahead_out" | grep -q 'worker-a claude 2.1.320 is above coord-a 2.1.319'; echo $?)"
check "842 coordinator is not reported below a peer" \
  "$(echo "$ahead_out" | grep -q 'coord-a claude' && echo 1 || echo 0)"

export FLEET_TOOLCHAIN_LATEST_ORCA=1.4.251
export FLEET_TOOLCHAIN_VERSIONS="{
  \"coord-a\": {$base_tools, \"orca\": \"1.4.253\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"},
  \"worker-a\": {$base_tools, \"orca\": \"1.4.251\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"}
}"
out_floor=$(FLEET_TOOLCHAIN_LATEST_ORCA=1.4.251 FLEET_TOOLCHAIN_VERSIONS="$FLEET_TOOLCHAIN_VERSIONS" \
  FLEET_PULL_CONFIG="$FLEET_PULL_CONFIG" FLEET_TOOLCHAIN_RUN="$FLEET_TOOLCHAIN_RUN" \
  DOTFILES_DIR="$DOTFILES_DIR" "$here/fleet-toolchain-check.sh" 2>&1)
check "677 host below coordinator floor is reported" \
  "$(echo "$out_floor" | grep -q 'worker-a orca 1.4.251 is below coord-a 1.4.253'; echo $?)"

# 842: with no coordinator version for a tool, a peer falls back to latest
nofloor_out=$(FLEET_TOOLCHAIN_LATEST_ORCA=1.4.253 FLEET_TOOLCHAIN_VERSIONS="{
  \"coord-a\": {$base_tools, \"orca\": \"1.4.253\", \"node\": \"24.22.1\"},
  \"worker-a\": {$base_tools, \"orca\": \"1.4.253\", \"bun\": \"1.4.3\", \"node\": \"24.22.1\"}
}" "$here/fleet-toolchain-check.sh" 2>&1)
check "842 peer falls back to latest when the coordinator has no version" \
  "$(echo "$nofloor_out" | grep -q 'worker-a bun 1.4.3 is below latest 1.4.4'; echo $?)"

# Missing coordinator.conf fails with a clear message instead of a built-in name
no_conf_out=$(AGENT_STATE_DIR="$tmp/no-state" FLEET_TOOLCHAIN_BASELINE_HOST='' "$here/fleet-toolchain-check.sh" 2>&1)
no_conf_rc=$?
check "missing coordinator.conf exits non-zero" "$([ "$no_conf_rc" -ne 0 ] && echo 0 || echo 1)"
check "missing coordinator.conf names coordinator.conf" "$(echo "$no_conf_out" | grep -q 'coordinator.conf'; echo $?)"

# Coordinator is checked even when omitted from fleet-pull.config.json .hosts
printf '%s\n' '{"hosts":["worker-a"],"repos":[]}' > "$tmp/fleet-no-coord.json"
export FLEET_TOOLCHAIN_LATEST_ORCA=1.4.253
coord_gap_versions="{
  \"coord-a\": {$base_tools, \"orca\": \"1.4.250\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"},
  \"worker-a\": {$base_tools, \"orca\": \"1.4.253\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"}
}"
coord_gap_out=$(FLEET_PULL_CONFIG="$tmp/fleet-no-coord.json" FLEET_TOOLCHAIN_VERSIONS="$coord_gap_versions" \
  "$here/fleet-toolchain-check.sh" 2>&1)
check "coordinator host is checked when omitted from .hosts" \
  "$(echo "$coord_gap_out" | grep -q 'coord-a orca 1.4.250 is below latest 1.4.253'; echo $?)"

# Fake tools + fake ssh: checks all 11 tools, never checks codex
fake_bin="$tmp/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/hostname" <<'EOS'
#!/usr/bin/env bash
echo "coord-a"
EOS
chmod +x "$fake_bin/hostname"

real_jq=$(command -v jq)
real_python3=$(command -v python3)

make_tool() {
  local dir=$1 name=$2 out_line=$3
  cat > "$dir/$name" <<EOS
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  printf '%s\n' "$out_line"
  exit 0
fi
EOS
  if [ "$name" = "jq" ]; then
    printf 'exec %q "$@"\n' "$real_jq" >> "$dir/$name"
  elif [ "$name" = "python3" ]; then
    printf 'exec %q "$@"\n' "$real_python3" >> "$dir/$name"
  fi
  chmod +x "$dir/$name"
}

make_tool "$fake_bin" git "git version 2.56.0"
make_tool "$fake_bin" gh "gh version 2.103.3"
make_tool "$fake_bin" jq "jq-1.8.2"
make_tool "$fake_bin" python3 "Python 3.15.2"
make_tool "$fake_bin" shellcheck $'ShellCheck\nversion: 0.11.0'
make_tool "$fake_bin" bun "1.4.4"
make_tool "$fake_bin" node "v24.22.1"
make_tool "$fake_bin" orca "1.4.253"
make_tool "$fake_bin" claude "2.1.319 (Claude Code)"
make_tool "$fake_bin" agent "2026.11.05-86047df"
make_tool "$fake_bin" agy "1.5.3"

remote_bin="$tmp/remote-bin"
mkdir -p "$remote_bin"
make_tool "$remote_bin" git "git version 2.55.0"
make_tool "$remote_bin" gh "gh version 2.100.0"
make_tool "$remote_bin" jq "jq-1.7.1-apple"
make_tool "$remote_bin" python3 "Python 3.15.1"
make_tool "$remote_bin" shellcheck $'ShellCheck\nversion: 0.10.0'
make_tool "$remote_bin" bun "1.4.3"
make_tool "$remote_bin" node "v24.22.0"
make_tool "$remote_bin" orca "1.4.251"
make_tool "$remote_bin" claude "2.1.311 (Claude Code)"
make_tool "$remote_bin" agent "2026.10.22-27dcf5f"
make_tool "$remote_bin" agy "1.5.2"

cat > "$tmp/fake-ssh" <<EOS
#!/usr/bin/env bash
host=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) shift 2 ;;
    -*) shift ;;
    *) host="\$1"; shift; break ;;
  esac
done
if [ "\$host" = "down-host" ]; then
  exit 255
fi
cmd="\${*: -1}"
PATH="$remote_bin:/usr/bin:/bin" FLEET_TOOLCHAIN_PATH="$remote_bin:/usr/bin:/bin" FLEET_ORCA_APP_BIN="$remote_bin" /bin/bash -c "\$cmd"
EOS
chmod +x "$tmp/fake-ssh"

probe_out=$(
  PATH="$fake_bin:/usr/bin:/bin" \
  FLEET_TOOLCHAIN_PATH="$fake_bin:/usr/bin:/bin" \
  FLEET_ORCA_APP_BIN="$fake_bin" \
  FLEET_PULL_CONFIG="$tmp/fleet-no-coord.json" \
  FLEET_TOOLCHAIN_RUN="$tmp/fake-ssh" \
  FLEET_TOOLCHAIN_VERSIONS='' \
  "$here/fleet-toolchain-check.sh" 2>&1
)
for t in git gh jq python3 shellcheck bun node orca claude agent agy; do
  check "reports older $t on worker-a via fake ssh" \
    "$(echo "$probe_out" | grep -q "worker-a $t "; echo $?)"
done
check "never checks or reports codex" "$(echo "$probe_out" | grep -qi 'codex' && echo 1 || echo 0)"

# Missing tool exits non-zero
rm -f "$remote_bin/agy"
miss_out=$(
  PATH="$fake_bin:/usr/bin:/bin" \
  FLEET_TOOLCHAIN_PATH="$fake_bin:/usr/bin:/bin" \
  FLEET_ORCA_APP_BIN="$fake_bin" \
  FLEET_PULL_CONFIG="$tmp/fleet-no-coord.json" \
  FLEET_TOOLCHAIN_RUN="$tmp/fake-ssh" \
  FLEET_TOOLCHAIN_VERSIONS='' \
  "$here/fleet-toolchain-check.sh" 2>&1
)
miss_rc=$?
check "missing tool exits non-zero" "$([ "$miss_rc" -ne 0 ] && echo 0 || echo 1)"
check "missing tool prints missing line" "$(echo "$miss_out" | grep -q 'worker-a agy missing'; echo $?)"
make_tool "$remote_bin" agy "1.5.2"

# Unreadable version exits non-zero
make_tool "$remote_bin" claude "error: unreadable"
unread_out=$(
  PATH="$fake_bin:/usr/bin:/bin" \
  FLEET_TOOLCHAIN_PATH="$fake_bin:/usr/bin:/bin" \
  FLEET_ORCA_APP_BIN="$fake_bin" \
  FLEET_PULL_CONFIG="$tmp/fleet-no-coord.json" \
  FLEET_TOOLCHAIN_RUN="$tmp/fake-ssh" \
  FLEET_TOOLCHAIN_VERSIONS='' \
  "$here/fleet-toolchain-check.sh" 2>&1
)
unread_rc=$?
check "unreadable version exits non-zero" "$([ "$unread_rc" -ne 0 ] && echo 0 || echo 1)"
check "unreadable version prints unreadable line" "$(echo "$unread_out" | grep -q 'worker-a claude version unreadable'; echo $?)"
make_tool "$remote_bin" claude "2.1.319 (Claude Code)"

# Unreachable host exits non-zero
printf '%s\n' '{"hosts":["down-host"],"repos":[]}' > "$tmp/fleet-down.json"
down_out=$(
  PATH="$fake_bin:/usr/bin:/bin" \
  FLEET_TOOLCHAIN_PATH="$fake_bin:/usr/bin:/bin" \
  FLEET_ORCA_APP_BIN="$fake_bin" \
  FLEET_PULL_CONFIG="$tmp/fleet-down.json" \
  FLEET_TOOLCHAIN_RUN="$tmp/fake-ssh" \
  FLEET_TOOLCHAIN_VERSIONS='' \
  "$here/fleet-toolchain-check.sh" 2>&1
)
down_rc=$?
down_cnt=$(echo "$down_out" | grep -c 'down-host')
check "unreachable host exits non-zero" "$([ "$down_rc" -ne 0 ] && echo 0 || echo 1)"
check "unreachable host prints unreachable line" "$(echo "$down_out" | grep -q 'down-host unreachable'; echo $?)"
check "unreachable host prints single line for down-host" "$([ "$down_cnt" = 1 ] && echo 0 || echo 1)"

# --apply upgrades brew tools, asdf tools, CLIs and Orca skills, and reports manual for orca
apply_log="$tmp/apply.log"
: > "$apply_log"
printf '#!/usr/bin/env bash\necho claude\n' > "$fake_bin/ps"; chmod +x "$fake_bin/ps"
for cli in brew bun claude agent agy orca; do
  cat > "$fake_bin/$cli" <<EOS
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  echo "1.0.0"
  exit 0
fi
echo "$cli \$*" >> "$apply_log"
EOS
  chmod +x "$fake_bin/$cli"
done
fake_dotfiles="$tmp/fake-dotfiles"
mkdir -p "$fake_dotfiles/script"
cp "$here/fleet-toolchain-check.sh" "$fake_dotfiles/script/"
mkdir -p "$fake_dotfiles/script/lib"
cp "$here/lib/find-orca-dir.sh" "$fake_dotfiles/script/lib/"
cat > "$fake_dotfiles/script/bootstrap-asdf-tools.sh" <<EOS
#!/usr/bin/env bash
echo "bootstrap-asdf-tools \$*" >> "$apply_log"
EOS
chmod +x "$fake_dotfiles/script/bootstrap-asdf-tools.sh"
printf '%s\n' '{"hosts":[],"repos":[]}' > "$tmp/fleet-local-only.json"
apply_out=$(
  PATH="$fake_bin:/usr/bin:/bin" \
  FLEET_TOOLCHAIN_PATH="$fake_bin:/usr/bin:/bin" \
  FLEET_ORCA_APP_BIN="$fake_bin" \
  DOTFILES_DIR="$fake_dotfiles" \
  FLEET_PULL_CONFIG="$tmp/fleet-local-only.json" \
  FLEET_TOOLCHAIN_VERSIONS="{
    \"coord-a\": {$base_tools, \"orca\": \"1.4.250\", \"bun\": \"1.4.3\", \"node\": \"24.22.0\"}
  }" \
  "$fake_dotfiles/script/fleet-toolchain-check.sh" --apply 2>&1
)
check "--apply runs brew upgrade" "$(grep -q '^brew upgrade' "$apply_log"; echo $?)"
check "--apply runs bootstrap-asdf-tools" "$(grep -q '^bootstrap-asdf-tools' "$apply_log"; echo $?)"
check "--apply runs bun upgrade" "$(grep -q '^bun upgrade' "$apply_log"; echo $?)"
check "--apply runs claude update" "$(grep -q '^claude update' "$apply_log"; echo $?)"
check "--apply runs agent update" "$(grep -q '^agent update' "$apply_log"; echo $?)"
check "--apply runs agy update" "$(grep -q '^agy update' "$apply_log"; echo $?)"
check "--apply runs orca skills install --all" "$(grep -q '^orca skills install --all' "$apply_log"; echo $?)"
check "--apply no longer calls orca upgrade manual" "$(echo "$apply_out" | grep -qi 'orca.*manual' && echo 1 || echo 0)"

# 842: --apply prints a failing command, swaps Apple jq for Homebrew jq,
# and moves a peer below the coordinator to the coordinator's claude and bun, never past it
peer_bin="$tmp/peer-bin"; mkdir -p "$peer_bin"
peer_log="$tmp/peer-apply.log"; : > "$peer_log"; : > "$apply_log"
for cli in brew bun claude agent agy orca curl; do
  cat > "$peer_bin/$cli" <<EOS
#!/usr/bin/env bash
[ "\${1:-}" = "--version" ] && { echo "1.0.0"; exit 0; }
echo "$cli \$*" >> "$peer_log"
[ "$cli" = curl ] && echo 'echo "bun-install \$*" >> "$peer_log"'
exit 0
EOS
  chmod +x "$peer_bin/$cli"
done
printf '#!/usr/bin/env bash\necho "jq-1.7.1-apple"\n' > "$peer_bin/jq"; chmod +x "$peer_bin/jq"
cat > "$fake_bin/claude" <<EOS
#!/usr/bin/env bash
[ "\${1:-}" = "--version" ] && { echo "1.0.0"; exit 0; }
echo "claude \$*" >> "$apply_log"
echo "network down" >&2
exit 1
EOS
chmod +x "$fake_bin/claude"
cat > "$tmp/peer-ssh" <<EOS
#!/usr/bin/env bash
while [ \$# -gt 0 ]; do case "\$1" in -o) shift 2 ;; -*) shift ;; *) shift; break ;; esac; done
PATH="$peer_bin:/usr/bin:/bin" FLEET_TOOLCHAIN_PATH="$peer_bin:/usr/bin:/bin" FLEET_ORCA_APP_BIN="$peer_bin" /bin/bash -c "\${*: -1}"
EOS
chmod +x "$tmp/peer-ssh"
printf '%s\n' '{"hosts":["worker-a"],"repos":[]}' > "$tmp/fleet-peer.json"
peer_apply_out=$(
  PATH="$fake_bin:/usr/bin:/bin" \
  FLEET_TOOLCHAIN_PATH="$fake_bin:/usr/bin:/bin" \
  FLEET_ORCA_APP_BIN="$fake_bin" \
  DOTFILES_DIR="$fake_dotfiles" \
  FLEET_PULL_CONFIG="$tmp/fleet-peer.json" \
  FLEET_TOOLCHAIN_RUN="$tmp/peer-ssh" \
  FLEET_TOOLCHAIN_VERSIONS="{
    \"coord-a\": {$base_tools, \"orca\": \"1.4.253\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"},
    \"worker-a\": {${base_tools/2.1.319/2.1.300}, \"orca\": \"1.4.253\", \"bun\": \"1.4.2\", \"node\": \"24.22.1\"}
  }" \
  "$fake_dotfiles/script/fleet-toolchain-check.sh" --apply 2>&1
)
peer_apply_rc=$?
check "842 --apply prints the failing command and its error" \
  "$(echo "$peer_apply_out" | grep -q 'coord-a apply: claude update failed: network down'; echo $?)"
check "842 --apply failure exits non-zero" "$([ "$peer_apply_rc" -ne 0 ] && echo 0 || echo 1)"
check "842 --apply installs Homebrew jq over Apple jq" "$(grep -q '^brew install jq' "$peer_log"; echo $?)"
check "842 peer below the coordinator installs the coordinator's claude" \
  "$(grep -q '^claude install 2.1.319' "$peer_log"; echo $?)"
check "842 peer below the coordinator installs the coordinator's bun" \
  "$(grep -q 'bun-install .*bun-v1.4.4' "$peer_log"; echo $?)"
check "842 peer never runs claude update or bun upgrade" \
  "$(grep -qE '^(claude update|bun upgrade)' "$peer_log" && echo 1 || echo 0)"
check "842 successful peer commands stay quiet" \
  "$(echo "$peer_apply_out" | grep -q 'worker-a apply' && echo 1 || echo 0)"

# 842: a peer level with or above the coordinator keeps its claude and bun; a login banner is not a failure
: > "$peer_log"
sed 's|^PATH=|echo "Welcome to worker-a"; PATH=|' "$tmp/peer-ssh" > "$tmp/peer-ssh-banner"; chmod +x "$tmp/peer-ssh-banner"
ahead_out=$(
  PATH="$fake_bin:/usr/bin:/bin" FLEET_TOOLCHAIN_PATH="$fake_bin:/usr/bin:/bin" FLEET_ORCA_APP_BIN="$fake_bin" \
  DOTFILES_DIR="$fake_dotfiles" FLEET_PULL_CONFIG="$tmp/fleet-peer.json" FLEET_TOOLCHAIN_RUN="$tmp/peer-ssh-banner" \
  FLEET_TOOLCHAIN_VERSIONS="{
    \"coord-a\": {$base_tools, \"orca\": \"1.4.253\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"},
    \"worker-a\": {${base_tools/2.1.319/2.1.320}, \"orca\": \"1.4.253\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"}
  }" \
  "$fake_dotfiles/script/fleet-toolchain-check.sh" --apply 2>&1
)
check "842 peer above the coordinator keeps claude and bun" \
  "$(grep -qE '^(claude|bun) |bun-install' "$peer_log" && echo 1 || echo 0)"
check "842 a login banner on a peer is not an apply failure" \
  "$(echo "$ahead_out" | grep -q 'worker-a apply' && echo 1 || echo 0)"

# 842: an apply that dies on the host prints its exit and last error line
printf '#!/usr/bin/env bash\necho "Connection reset by peer" >&2\nexit 255\n' > "$tmp/dead-ssh"; chmod +x "$tmp/dead-ssh"
dead_out=$(
  PATH="$fake_bin:/usr/bin:/bin" FLEET_TOOLCHAIN_PATH="$fake_bin:/usr/bin:/bin" FLEET_ORCA_APP_BIN="$fake_bin" \
  DOTFILES_DIR="$fake_dotfiles" FLEET_PULL_CONFIG="$tmp/fleet-peer.json" FLEET_TOOLCHAIN_RUN="$tmp/dead-ssh" \
  FLEET_TOOLCHAIN_VERSIONS="{
    \"coord-a\": {$base_tools, \"orca\": \"1.4.253\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"},
    \"worker-a\": {$base_tools, \"orca\": \"1.4.253\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"}
  }" \
  "$fake_dotfiles/script/fleet-toolchain-check.sh" --apply 2>&1
)
check "842 a dead ssh during apply is printed" \
  "$(echo "$dead_out" | grep -q 'worker-a apply: stopped with exit 255: Connection reset by peer'; echo $?)"

# 842: a peer runs bootstrap from its own home, not the coordinator's absolute path
home_a="$tmp/home-a"; home_b="$tmp/home-b"
mkdir -p "$home_a/dotfiles/script/lib" "$home_b/dotfiles/script"
cp "$fake_dotfiles/script/fleet-toolchain-check.sh" "$home_a/dotfiles/script/"
cp "$fake_dotfiles/script/lib/find-orca-dir.sh" "$home_a/dotfiles/script/lib/"
printf '#!/usr/bin/env bash\necho peer-bootstrap >> %q\n' "$peer_log" > "$home_b/dotfiles/script/bootstrap-asdf-tools.sh"
sed "s|/bin/bash -c|HOME=$home_b /bin/bash -c|" "$tmp/peer-ssh" > "$tmp/peer-ssh-home"; chmod +x "$tmp/peer-ssh-home"
: > "$peer_log"
HOME="$home_a" PATH="$fake_bin:/usr/bin:/bin" FLEET_TOOLCHAIN_PATH="$fake_bin:/usr/bin:/bin" FLEET_ORCA_APP_BIN="$fake_bin" \
  DOTFILES_DIR="$home_a/dotfiles" FLEET_PULL_CONFIG="$tmp/fleet-peer.json" FLEET_TOOLCHAIN_RUN="$tmp/peer-ssh-home" \
  FLEET_TOOLCHAIN_VERSIONS="{\"coord-a\": {$base_tools, \"orca\": \"1.4.253\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"},
    \"worker-a\": {$base_tools, \"orca\": \"1.4.253\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"}}" \
  "$home_a/dotfiles/script/fleet-toolchain-check.sh" --apply >/dev/null 2>&1
check "842 peer runs bootstrap from its own home" "$(grep -q '^peer-bootstrap' "$peer_log"; echo $?)"

# 842: --apply upgrades Orca on an idle peer below the coordinator to the coordinator's version,
# and skips a peer with live agents, naming them
orca_bin_dir="$tmp/orca-peer-bin"; mkdir -p "$orca_bin_dir" "$tmp/apps/Orca.app/Contents"
orca_log="$tmp/orca-apply.log"
echo old > "$tmp/apps/Orca.app/Contents/version"
for cli in brew bun claude agent agy orca pkill open; do
  cat > "$orca_bin_dir/$cli" <<EOS
#!/usr/bin/env bash
[ "\${1:-}" = "--version" ] && { echo "1.0.0"; exit 0; }
echo "\$STUB_HOST $cli \$*" >> "$orca_log"
EOS
  chmod +x "$orca_bin_dir/$cli"
done
cat > "$orca_bin_dir/uname" <<EOS
#!/usr/bin/env bash
case "\${1:-}" in -m) echo "\${FAKE_UNAME_M:-arm64}" ;; *) echo "\${FAKE_UNAME_S:-Darwin}" ;; esac
EOS
cat > "$orca_bin_dir/ps" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\${FAKE_PS:-/usr/sbin/sshd}"
EOS
cat > "$orca_bin_dir/curl" <<EOS
#!/usr/bin/env bash
echo "\$STUB_HOST curl \$*" >> "$orca_log"
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && { echo zip > "\$2"; shift; }; shift; done
EOS
cat > "$orca_bin_dir/ditto" <<EOS
#!/usr/bin/env bash
echo "\$STUB_HOST ditto \$*" >> "$orca_log"
mkdir -p "\${*: -1}/Orca.app/Contents" && echo new > "\${*: -1}/Orca.app/Contents/version"
EOS
cat > "$orca_bin_dir/yay" <<EOS
#!/usr/bin/env bash
echo "\$STUB_HOST yay \$*" >> "$orca_log"
[ "\${1:-}" = -Si ] && printf 'Name            : stably-orca-bin\nVersion         : %s-1\n' "\${FAKE_AUR:-1.4.253}"
exit 0
EOS
chmod +x "$orca_bin_dir/uname" "$orca_bin_dir/ps" "$orca_bin_dir/curl" "$orca_bin_dir/ditto" "$orca_bin_dir/yay"
cat > "$tmp/orca-ssh" <<EOS
#!/usr/bin/env bash
while [ \$# -gt 0 ]; do case "\$1" in -o) shift 2 ;; -*) shift ;; *) host=\$1; shift; break ;; esac; done
STUB_HOST=\$host PATH="$orca_bin_dir:/usr/bin:/bin" FLEET_TOOLCHAIN_PATH="$orca_bin_dir:/usr/bin:/bin" FLEET_ORCA_APP_BIN="$orca_bin_dir" \
  FLEET_ORCA_APP="$tmp/apps/Orca.app" /bin/bash -c "\${*: -1}"
EOS
chmod +x "$tmp/orca-ssh"
orca_apply() { # <worker orca> -> output of --apply with coord-a at 1.4.253 and latest 1.4.255
  PATH="$fake_bin:/usr/bin:/bin" FLEET_TOOLCHAIN_PATH="$fake_bin:/usr/bin:/bin" FLEET_ORCA_APP_BIN="$fake_bin" \
    DOTFILES_DIR="$fake_dotfiles" FLEET_PULL_CONFIG="$tmp/fleet-peer.json" FLEET_TOOLCHAIN_RUN="$tmp/orca-ssh" \
    FLEET_TOOLCHAIN_LATEST_ORCA=1.4.255 \
    FLEET_TOOLCHAIN_VERSIONS="{
      \"coord-a\": {$base_tools, \"orca\": \"1.4.253\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"},
      \"worker-a\": {$base_tools, \"orca\": \"$1\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"}
    }" \
    "$fake_dotfiles/script/fleet-toolchain-check.sh" --apply 2>&1
}
: > "$orca_log"
orca_out=$(orca_apply 1.4.251)
check "842 idle macOS peer downloads the coordinator's Orca, not latest" \
  "$(grep -q '^worker-a curl .*releases/download/v1.4.253/Orca-1.4.253-arm64-mac.zip' "$orca_log"; echo $?)"
check "842 idle macOS peer gets the new Orca.app in place" \
  "$(grep -qx new "$tmp/apps/Orca.app/Contents/version"; echo $?)"
check "842 idle peer reports the Orca upgrade" \
  "$(echo "$orca_out" | grep -q 'worker-a apply: orca upgraded to 1.4.253'; echo $?)"
: > "$orca_log"
FAKE_UNAME_M=x86_64 orca_apply 1.4.251 >/dev/null
check "842 Intel macOS peer downloads the x64 zip" \
  "$(grep -q '^worker-a curl .*/Orca-1.4.253-mac.zip' "$orca_log"; echo $?)"
: > "$orca_log"
orca_out=$(FAKE_PS=$'/usr/sbin/sshd\n2.1.319\nclaude --dangerously-skip-permissions\n/opt/homebrew/bin/codex exec' orca_apply 1.4.251)
check "842 peer with live agents is skipped and named" \
  "$(echo "$orca_out" | grep -q 'worker-a apply: orca upgrade skipped, live agents: claude codex'; echo $?)"
check "842 peer with live agents downloads nothing" "$(grep -q '^worker-a curl' "$orca_log" && echo 1 || echo 0)"
: > "$orca_log"
orca_out=$(FAKE_UNAME_S=Linux orca_apply 1.4.251)
check "842 idle Arch peer installs stably-orca-bin" \
  "$(grep -q '^worker-a yay -S .*stably-orca-bin' "$orca_log"; echo $?)"
: > "$orca_log"
orca_out=$(FAKE_UNAME_S=Linux FAKE_AUR=1.4.255 orca_apply 1.4.251)
check "842 Arch peer never installs an AUR Orca other than the coordinator's" \
  "$(grep -q '^worker-a yay -S ' "$orca_log" && echo 1 || echo 0)"
check "842 Arch AUR mismatch is printed" \
  "$(echo "$orca_out" | grep -q 'worker-a apply: orca upgrade 1.4.253 failed: AUR has 1.4.255'; echo $?)"
: > "$orca_log"
orca_apply 1.4.253 >/dev/null
check "842 peer level with the coordinator leaves Orca alone" "$(grep -qE '^worker-a (curl|yay)' "$orca_log" && echo 1 || echo 0)"

# Latest Node is the newest LTS on the pinned major, never a newer LTS major.
pin_home="$tmp/pin-home"; mkdir -p "$pin_home"
printf 'nodejs 24.0.0\n' > "$pin_home/.tool-versions"
printf '%s\n' '[{"version":"v26.13.0","lts":"Wolf"},{"version":"v25.9.0","lts":false},{"version":"v24.22.2","lts":"Krypton"},{"version":"v24.22.1","lts":"Krypton"}]' > "$tmp/node-index.json"
node_vers() { # <coord node> <worker node>
  printf '{"coord-a": {%s, "orca": "1.4.253", "bun": "1.4.4", "node": "%s"}, "worker-a": {%s, "orca": "1.4.253", "bun": "1.4.4", "node": "%s"}}' \
    "$base_tools" "$1" "$base_tools" "$2"
}
node_out=$(FLEET_TOOLCHAIN_LATEST_ORCA=1.4.253 FLEET_TOOLCHAIN_LATEST_NODE='' FLEET_TOOLCHAIN_NODE_INDEX="$tmp/node-index.json" \
  FLEET_TOOLCHAIN_VERSIONS="$(node_vers 24.22.1 24.22.1)" DOTFILES_DIR="$pin_home" "$here/fleet-toolchain-check.sh" 2>&1)
check "latest node stays on the pinned major" \
  "$(echo "$node_out" | grep -q 'coord-a node 24.22.1 is below latest 24.22.2'; echo $?)"
check "a newer LTS major does not flag the pinned major" \
  "$(echo "$node_out" | grep -q '26.13.0' && echo 1 || echo 0)"

# shellcheck source=script/lib/find-orca-dir.sh disable=SC1091
. "$here/lib/find-orca-dir.sh"
# shellcheck source=script/tests/lib/asdf-pin.sh disable=SC1091
. "$here/tests/lib/asdf-pin.sh"
orca_stub_home="$tmp/orca-home"
mkdir -p "$orca_stub_home/.orca/cli/bin" "$tmp/orca-app/bin"
printf '#!/usr/bin/env bash\necho orca version 1.4.247\n' > "$orca_stub_home/.orca/cli/bin/orca"
printf '#!/usr/bin/env bash\necho orca version 1.4.253\n' > "$tmp/orca-app/bin/orca"
chmod +x "$orca_stub_home/.orca/cli/bin/orca" "$tmp/orca-app/bin/orca"
export HOME="$orca_stub_home"
export PATH="$orca_stub_home/.orca/cli/bin:$PATH"
export FLEET_ORCA_APP_BIN="$tmp/orca-app/bin"
local_ver=$(orca_version_local | sed -E 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
check "677 orca prefers app CLI over stale ~/.orca/cli/bin" "$([ "$local_ver" = 1.4.253 ] && echo 0 || echo 1)"

# 842: run on the coordinator, the check writes its tool versions to the state dir as the fleet floor
me_host=$(hostname -s)
mkdir -p "$tmp/floor-state"
printf 'coordinator %s\n' "$me_host" >"$tmp/floor-state/coordinator.conf"
printf '{"hosts":["%s","worker-a"],"repos":[]}\n' "$me_host" >"$tmp/floor-fleet.json"
floor_versions="{
  \"$me_host\": {$base_tools, \"orca\": \"1.4.253\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"},
  \"worker-a\": {$base_tools, \"orca\": \"1.4.251\", \"bun\": \"1.4.4\", \"node\": \"24.22.1\"}
}"
AGENT_STATE_DIR="$tmp/floor-state" FLEET_PULL_CONFIG="$tmp/floor-fleet.json" FLEET_TOOLCHAIN_VERSIONS="$floor_versions" \
  "$here/fleet-toolchain-check.sh" >/dev/null 2>&1
check "842 coordinator writes fleet-floor.json with its own versions" \
  "$(jq -e --arg h "$me_host" '.host == $h and .tools.claude == "2.1.319" and .tools.orca == "1.4.253" and (.tools | has("git"))' \
    "$tmp/floor-state/fleet-floor.json" >/dev/null 2>&1; echo $?)"
mkdir -p "$tmp/peer-state"
printf 'coordinator worker-a\n' >"$tmp/peer-state/coordinator.conf"
AGENT_STATE_DIR="$tmp/peer-state" FLEET_PULL_CONFIG="$tmp/floor-fleet.json" FLEET_TOOLCHAIN_VERSIONS="$floor_versions" \
  "$here/fleet-toolchain-check.sh" >/dev/null 2>&1
check "842 a peer run leaves the state dir without a floor file" \
  "$([ ! -e "$tmp/peer-state/fleet-floor.json" ] && echo 0 || echo 1)"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
