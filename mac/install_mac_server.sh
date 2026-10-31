#!/usr/bin/env bash
# Install agent team needed software on macOS using Homebrew and asdf.
# Only installs packages required for agent team coordination and workers,
# avoiding extraneous personal or desktop applications.
# Safe to re-run (idempotent).
#
# Usage: mac/install_mac_server.sh [--dry-run] [--skip-casks] [--skip-agent-config] [--skip-tuneups] [--keep-spotlight] [--full-osx-defaults]
set -euo pipefail

DOTFILES="${DOTFILES:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"

dry=0
skip_casks=0
skip_agent_config=0
skip_tuneups=0
disable_spotlight=1
full_osx_defaults=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --skip-casks) skip_casks=1 ;;
    --skip-agent-config) skip_agent_config=1 ;;
    --skip-tuneups) skip_tuneups=1 ;;
    --keep-spotlight | --enable-spotlight) disable_spotlight=0 ;;
    --disable-spotlight) disable_spotlight=1 ;;
    --full-osx-defaults) full_osx_defaults=1 ;;
    -h | --help)
      sed -n '2,8p' "$0" | sed 's/^# *//'
      exit 0
      ;;
    *)
      echo "mac/install_mac_server.sh: unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "mac/install_mac_server.sh: error: macOS (Darwin) required." >&2
  exit 1
fi

step() { printf '\n== %s\n' "$*"; }
run() {
  if [ "$dry" -eq 1 ]; then
    printf 'would run: %s\n' "$*"
  else
    printf '+ %s\n' "$*"
    "$@"
  fi
}
run_sudo() {
  if [ "$dry" -eq 1 ]; then
    printf 'would run: sudo %s\n' "$*"
  else
    if [ "$(id -u)" -eq 0 ]; then
      "$@"
    elif command -v sudo >/dev/null 2>&1; then
      sudo "$@" 2>/dev/null || echo "note: root tuneup skipped: $*"
    fi
  fi
}

prioritize_ethernet() {
  if ! command -v networksetup >/dev/null 2>&1; then
    return 0
  fi
  local all_services=() wired=() wifi=() s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    s="${s#\* }"
    all_services+=("$s")
    case "$s" in
      *Wi-Fi* | *WiFi* | *AirPort*) wifi+=("$s") ;;
      *) wired+=("$s") ;;
    esac
  done < <(networksetup -listnetworkserviceorder 2>/dev/null | awk -F'\) ' '/^\([0-9]+\)/ { print $2 }')

  if [ "${#wired[@]}" -gt 0 ] && [ "${#wifi[@]}" -gt 0 ]; then
    local new_order=("${wired[@]}" "${wifi[@]}")
    if [ "${all_services[*]}" != "${new_order[*]}" ]; then
      run_sudo networksetup -ordernetworkservices "${new_order[@]}"
    fi
  fi
}

export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"

step "Homebrew check"
if ! command -v brew >/dev/null 2>&1; then
  if [ "$dry" -eq 1 ]; then
    echo "would run: install Homebrew from official install script"
  else
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || exit 1
  fi
fi

# Configure Homebrew shell environment for the current process
for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [ -x "$brew_bin" ]; then
    eval "$("$brew_bin" shellenv)"
    break
  fi
done

# Persist Homebrew and asdf shims into ~/.zprofile if missing
# shellcheck disable=SC2016
if [ "$dry" -eq 0 ]; then
  arch=$(uname -m)
  if [ "$arch" = "arm64" ] && [ -x /opt/homebrew/bin/brew ]; then
    if [ ! -f "$HOME/.zprofile" ] || ! grep -q '/opt/homebrew/bin/brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
      echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
    fi
  elif [ "$arch" = "x86_64" ] && [ -x /usr/local/bin/brew ]; then
    if [ ! -f "$HOME/.zprofile" ] || ! grep -q '/usr/local/bin/brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
      echo 'eval "$(/usr/local/bin/brew shellenv)"' >> "$HOME/.zprofile"
    fi
  fi
  if [ ! -f "$HOME/.zprofile" ] || ! grep -q 'asdf}/shims' "$HOME/.zprofile" 2>/dev/null; then
    echo 'export PATH="${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$PATH"' >> "$HOME/.zprofile"
  fi
fi

step "Homebrew formulas (agent team dependencies)"
formulae=(
  coreutils
  curl
  git
  rsync
  wget
  unzip
  gh
  jq
  tmux
  asdf
)
for pkg in "${formulae[@]}"; do
  if [ "$dry" -eq 1 ]; then
    echo "would run: brew install $pkg (if missing)"
  else
    brew list "$pkg" >/dev/null 2>&1 || run brew install "$pkg"
  fi
done

if [ "$skip_casks" -eq 0 ]; then
  step "Homebrew casks (Orca, Cursor, Antigravity, Chrome Dev)"
  dev_casks=(
    stablyai/orca/orca
    cursor
    antigravity
    antigravity-ide
  )
  for cask in "${dev_casks[@]}"; do
    if [ "$dry" -eq 1 ]; then
      echo "would run: brew install --cask --appdir=/Applications/_dev $cask (if missing)"
    else
      mkdir -p /Applications/_dev
      brew list --cask "$cask" >/dev/null 2>&1 || run brew install --cask --appdir="/Applications/_dev" "$cask"
    fi
  done

  # Chrome Dev for CDP browser automation and agent UI testing
  if [ "$dry" -eq 1 ]; then
    echo "would run: brew install --cask google-chrome@dev (if missing)"
  else
    brew list --cask google-chrome@dev >/dev/null 2>&1 || run brew install --cask google-chrome@dev
  fi
fi

step "asdf toolchains (Python and Node.js)"
# Add asdf shims to PATH for this process
export PATH="${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$PATH"
if [ -f "$HOME/.asdf/asdf.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.asdf/asdf.sh"
elif command -v brew >/dev/null 2>&1 && [ -f "$(brew --prefix asdf 2>/dev/null)/libexec/asdf.sh" ]; then
  # shellcheck source=/dev/null
  . "$(brew --prefix asdf)/libexec/asdf.sh"
fi

if [ "$dry" -eq 1 ]; then
  echo "would run: bootstrap-asdf-tools.sh (install pinned python and nodejs from .tool-versions)"
else
  run bash "$DOTFILES/script/bootstrap-asdf-tools.sh" --dotfiles "$DOTFILES"
  if command -v asdf >/dev/null 2>&1; then
    run asdf reshim python 2>/dev/null || true
    run asdf reshim nodejs 2>/dev/null || true
  fi
fi

step "Agent provider CLIs and developer tools"
if ! command -v bun >/dev/null 2>&1; then
  if [ "$dry" -eq 1 ]; then
    echo "would run: install bun via https://bun.sh/install"
  else
    curl -fsSL https://bun.sh/install | bash
    export PATH="$HOME/.bun/bin:$PATH"
  fi
fi

if ! command -v claude >/dev/null 2>&1; then
  if [ "$dry" -eq 1 ]; then
    echo "would run: install Claude Code CLI via script/install_claude.sh"
  else
    run bash "$DOTFILES/script/install_claude.sh"
  fi
fi

if ! command -v agent >/dev/null 2>&1 && ! command -v cursor-agent >/dev/null 2>&1; then
  if [ "$dry" -eq 1 ]; then
    echo "would run: install Cursor agent CLI via https://cursor.com/install"
  else
    curl -fsSL https://cursor.com/install | bash
  fi
fi

if ! command -v agy >/dev/null 2>&1; then
  if [ "$dry" -eq 1 ]; then
    echo "would run: install Antigravity CLI via https://antigravity.google/cli/install.sh"
  else
    curl -fsSL https://antigravity.google/cli/install.sh | bash
  fi
fi

# Playwright browsers for agent UI testing and verification
if [ "$dry" -eq 1 ]; then
  echo "would run: npx playwright install chromium firefox webkit"
else
  if command -v npx >/dev/null 2>&1; then
    run npx playwright install chromium firefox webkit || echo "WARN: Playwright browser install had warnings." >&2
  fi
fi

if [ "$skip_tuneups" -eq 0 ]; then
  step "Mac tune-ups (system defaults and server performance)"

  # Server performance mode attempt (requires Recovery Mode on Apple Silicon when SIP is enabled)
  if [ "$dry" -eq 1 ]; then
    echo "would run: sudo nvram boot-args=\"serverperfmode=1 ...\" (safe attempt)"
  else
    existing_boot_args="$(nvram boot-args 2>/dev/null | cut -f 2- || true)"
    if [[ "$existing_boot_args" != *"serverperfmode=1"* ]]; then
      run_sudo nvram boot-args="serverperfmode=1 $existing_boot_args" 2>/dev/null || true
    fi
  fi

  # Power and sleep settings: keep server awake and restart on power recovery
  if command -v pmset >/dev/null 2>&1; then
    run_sudo pmset -a sleep 0 disksleep 0 displaysleep 0
    run_sudo pmset -a womp 1
    run_sudo pmset -a autorestart 1
    run_sudo pmset -a autorestartatconnect 1
    run_sudo pmset -a standby 0
    run_sudo pmset -a hibernatemode 0
  fi
  if command -v systemsetup >/dev/null 2>&1; then
    run_sudo systemsetup -setcomputersleep Never 2>/dev/null || true
    run_sudo systemsetup -setdisplaysleep Never 2>/dev/null || true
    run_sudo systemsetup -setharddisksleep Never 2>/dev/null || true
    run_sudo systemsetup -setrestartpowerfailure on 2>/dev/null || true
    run_sudo systemsetup -setrestartfreeze on 2>/dev/null || true
  fi

  # Network order: prioritize wired Ethernet over Wi-Fi
  prioritize_ethernet

  # Developer environment & UI tune-ups
  run defaults write com.apple.LaunchServices LSQuarantine -bool false
  run defaults write com.apple.CrashReporter DialogType none
  run defaults write NSGlobalDomain NSDisableAutomaticTermination -bool true
  run defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
  run defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true
  run defaults write com.apple.frameworks.diskimages skip-verify -bool true
  run defaults write com.apple.frameworks.diskimages skip-verify-locked -bool true
  run defaults write com.apple.frameworks.diskimages skip-verify-remote -bool true
  run defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
  run defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false
  run defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false
  run defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false
  run defaults write NSGlobalDomain KeyRepeat -int 2
  run defaults write NSGlobalDomain InitialKeyRepeat -int 15
  run defaults write NSGlobalDomain AppleKeyboardUIMode -int 3
  run defaults write NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool false
  run defaults write com.apple.finder AppleShowAllFiles -bool true
  run defaults write NSGlobalDomain AppleShowAllExtensions -bool true
  run defaults write com.apple.finder _FXShowPosixPathInTitle -bool true
  run defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false

  # Prevent Spotlight from indexing high-churn agent workspace folder
  if [ "$dry" -eq 1 ]; then
    echo "would run: touch $HOME/orca/workspaces/.metadata_never_index"
  else
    mkdir -p "$HOME/orca/workspaces"
    touch "$HOME/orca/workspaces/.metadata_never_index" 2>/dev/null || true
  fi

  # Spotlight indexing: disabled by default on server
  if [ "$disable_spotlight" -eq 1 ]; then
    if [ "$dry" -eq 1 ]; then
      echo "would run: sudo mdutil -i off -a"
    else
      run_sudo mdutil -i off -a
    fi
  fi

  if [ "$dry" -eq 1 ]; then
    echo "would run: chflags nohidden $HOME/Library"
  else
    chflags nohidden "$HOME/Library" 2>/dev/null || true
  fi

  if [ "$full_osx_defaults" -eq 1 ]; then
    step "Running full macOS defaults (mac/osx.sh)"
    run bash "$DOTFILES/mac/osx.sh"
  fi
fi

if [ "$skip_agent_config" -eq 0 ]; then
  step "Agent team machine configuration"
  if [ "$dry" -eq 1 ]; then
    run bash "$DOTFILES/script/agent-team.sh" machine --dry-run
  else
    run bash "$DOTFILES/script/agent-team.sh" machine
  fi
fi

if [ "$dry" -eq 0 ]; then
  step "Readiness verification"
  bash "$DOTFILES/script/setup-check.sh" || true
fi

echo ""
echo "mac/install_mac_server.sh completed successfully."
