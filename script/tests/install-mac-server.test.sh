#!/usr/bin/env bash
# shellcheck source=tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# Test mac/install_mac_server.sh dry-run, options, tune-ups, and agent team software filtering.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd -P)
script="$root/mac/install_mac_server.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME" "$tmp/bin"
export PATH="$tmp/bin:$PATH"

pass=0
fail=0
check() {
  local desc=$1
  local cmd=$2
  if eval "$cmd"; then
    pass=$((pass + 1))
    echo "ok   $desc"
  else
    fail=$((fail + 1))
    echo "FAIL $desc"
  fi
}

# 1. ShellCheck validation
check "passes shellcheck clean" "shellcheck -x '$script'"

# 2. Help flag
check "help flag prints usage" "bash '$script' --help | grep -q 'Usage: mac/install_mac_server.sh'"

# 3. Dry-run output checks
dry_out="$(bash "$script" --dry-run)"

# Homebrew formulas
check "dry-run lists brew git" "grep -q 'brew install git' <<< \"\$dry_out\""
check "dry-run lists brew gh" "grep -q 'brew install gh' <<< \"\$dry_out\""
check "dry-run lists brew jq" "grep -q 'brew install jq' <<< \"\$dry_out\""
check "dry-run lists brew tmux" "grep -q 'brew install tmux' <<< \"\$dry_out\""
check "dry-run lists brew asdf" "grep -q 'brew install asdf' <<< \"\$dry_out\""

# Casks
check "dry-run lists stablyai/orca/orca" "grep -q 'brew install --cask --appdir=/Applications/_dev stablyai/orca/orca' <<< \"\$dry_out\""
check "dry-run lists cursor" "grep -q 'brew install --cask --appdir=/Applications/_dev cursor' <<< \"\$dry_out\""
check "dry-run lists antigravity" "grep -q 'brew install --cask --appdir=/Applications/_dev antigravity' <<< \"\$dry_out\""
check "dry-run lists antigravity-ide" "grep -q 'brew install --cask --appdir=/Applications/_dev antigravity-ide' <<< \"\$dry_out\""
check "dry-run lists google-chrome@dev" "grep -q 'brew install --cask google-chrome@dev' <<< \"\$dry_out\""

# Excluded non-agent personal applications
check "does not install whatsapp" "! grep -i 'whatsapp' '$script'"
check "does not install telegram" "! grep -i 'telegram' '$script'"
check "does not install aegisub" "! grep -i 'aegisub' '$script'"
check "does not install handbrake" "! grep -i 'handbrake' '$script'"
check "does not install surfshark" "! grep -i 'surfshark' '$script'"
check "does not install vnc-viewer" "! grep -i 'vnc-viewer' '$script'"

# asdf bootstrap
check "dry-run triggers asdf bootstrap" "grep -q 'bootstrap-asdf-tools.sh' <<< \"\$dry_out\""

# Playwright and agent team machine config
check "dry-run includes playwright install" "grep -q 'playwright install' <<< \"\$dry_out\""
check "dry-run invokes agent-team.sh machine" "grep -q 'agent-team.sh machine --dry-run' <<< \"\$dry_out\""

# Mac tune-ups checks
check "dry-run includes serverperfmode attempt" "grep -q 'serverperfmode=1' <<< \"\$dry_out\""
check "dry-run includes pmset sleep 0" "grep -q 'pmset -a sleep 0 disksleep 0 displaysleep 0' <<< \"\$dry_out\""
check "dry-run includes pmset womp" "grep -q 'pmset -a womp 1' <<< \"\$dry_out\""
check "dry-run includes autorestart" "grep -q 'pmset -a autorestart 1' <<< \"\$dry_out\""
check "dry-run includes autorestartatconnect" "grep -q 'pmset -a autorestartatconnect 1' <<< \"\$dry_out\""
check "dry-run includes standby 0" "grep -q 'pmset -a standby 0' <<< \"\$dry_out\""
check "dry-run includes hibernatemode 0" "grep -q 'pmset -a hibernatemode 0' <<< \"\$dry_out\""
check "dry-run includes quarantine suppression" "grep -q 'LSQuarantine -bool false' <<< \"\$dry_out\""
check "dry-run includes .DS_Store suppression" "grep -q 'DSDontWriteNetworkStores -bool true' <<< \"\$dry_out\""
check "dry-run includes key repeat tuneup" "grep -q 'KeyRepeat -int 2' <<< \"\$dry_out\""
check "dry-run includes smart quotes suppression" "grep -q 'NSAutomaticQuoteSubstitutionEnabled -bool false' <<< \"\$dry_out\""
check "dry-run includes show hidden files" "grep -q 'AppleShowAllFiles -bool true' <<< \"\$dry_out\""
check "dry-run includes workspace metadata_never_index" "grep -q '\.metadata_never_index' <<< \"\$dry_out\""

# Spotlight disabled by default
check "dry-run disables spotlight by default" "grep -q 'mdutil -i off -a' <<< \"\$dry_out\""

# 4. Skip flags
skip_cask_out="$(bash "$script" --dry-run --skip-casks)"
check "skip-casks omits orca cask" "! grep -q 'stablyai/orca/orca' <<< \"\$skip_cask_out\""

skip_agent_out="$(bash "$script" --dry-run --skip-agent-config)"
check "skip-agent-config omits agent-team machine" "! grep -q 'agent-team.sh machine' <<< \"\$skip_agent_out\""

skip_tuneup_out="$(bash "$script" --dry-run --skip-tuneups)"
check "skip-tuneups omits pmset" "! grep -q 'pmset -a sleep' <<< \"\$skip_tuneup_out\""
check "skip-tuneups omits defaults write" "! grep -q 'LSQuarantine' <<< \"\$skip_tuneup_out\""

# 5. Full osx defaults option
full_defaults_out="$(bash "$script" --dry-run --full-osx-defaults)"
check "full-osx-defaults triggers mac/osx.sh" "grep -q 'mac/osx.sh' <<< \"\$full_defaults_out\""

# 6. Keep spotlight flag
keep_spotlight_out="$(bash "$script" --dry-run --keep-spotlight)"
check "keep-spotlight flag skips mdutil off" "! grep -q 'mdutil -i off -a' <<< \"\$keep_spotlight_out\""

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
