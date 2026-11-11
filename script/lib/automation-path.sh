# shellcheck shell=bash
# PATH for a fleet automation precheck and for worker-startup pin checks.
# asdf shims are included only when that directory exists, so a minimal
# automation PATH can still run the pinned node or bun. /usr/sbin is included
# when it exists so lsof (Antigravity quota) and sysctl (placement load) resolve.

automation_tool_path() {
  local p bun shims orca_app sbin
  p="$HOME/.local/bin"
  bun="$HOME/.bun/bin"
  shims="${ASDF_DATA_DIR:-$HOME/.asdf}/shims"
  orca_app="${FLEET_ORCA_APP_BIN:-/Applications/_dev/Orca.app/Contents/Resources/bin}"
  sbin=/usr/sbin
  [ -d "$bun" ] && p="$p:$bun"
  [ -d "$shims" ] && p="$p:$shims"
  [ -d "$orca_app" ] && p="$p:$orca_app"
  [ -d "$sbin" ] && p="$p:$sbin"
  p="$p:${FLEET_AUTOMATIONS_PATH_EXTRA:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin}"
  printf '%s' "$p"
}
