# shellcheck shell=bash
# Shared Orca CLI resolution (same order as wrap-up.sh find_orca_dir; stale ~/.orca/cli/bin last).
# Sourced by fleet-toolchain-check.sh only; wrap-up keeps its own copy per PR #695.
find_orca_dir() {
  local stale="$HOME/.orca/cli/bin" dir list
  list="${FLEET_ORCA_APP_BIN:-${WRAP_UP_ORCA_APP_BIN:-/Applications/_dev/Orca.app/Contents/Resources/bin}}:$PATH:$HOME/.local/bin"
  local IFS=:
  for dir in $list; do
    if [ "$dir" != "$stale" ] && [ -x "$dir/orca" ]; then printf '%s\n' "$dir"; return 0; fi
  done
  [ -x "$stale/orca" ] && printf '%s\n' "$stale"
}

orca_version_local() {
  local dir ver
  dir=$(find_orca_dir) || return 1
  ver=$("$dir/orca" --version 2>/dev/null | head -1)
  [ -n "$ver" ] || return 1
  printf '%s\n' "$ver"
}

# One remote shell script: print orca --version using the same directory order.
orca_version_remote_shell() {
  cat <<'EOS'
stale="$HOME/.orca/cli/bin"
list="${FLEET_ORCA_APP_BIN:-/Applications/_dev/Orca.app/Contents/Resources/bin}:$PATH:$HOME/.local/bin"
IFS=:
for dir in $list; do
  if [ "$dir" != "$stale" ] && [ -x "$dir/orca" ]; then
    "$dir/orca" --version 2>/dev/null | head -1
    exit 0
  fi
done
if [ -x "$stale/orca" ]; then "$stale/orca" --version 2>/dev/null | head -1; fi
EOS
}
