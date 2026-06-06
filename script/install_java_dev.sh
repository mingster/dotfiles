#!/usr/bin/env bash
# Install Java via asdf (cross-platform). IDE installs are platform-detected.
set -euo pipefail

echo '---- install java (asdf) ----'

if ! command -v asdf >/dev/null 2>&1; then
  echo "install_java_dev: asdf not found; run script/install_asdf.sh first" >&2
  exit 1
fi

asdf plugin list 2>/dev/null | grep -q '^java$' || asdf plugin add java https://github.com/halcyon/asdf-java.git

asdf list java 2>/dev/null | grep -q 'openjdk-21' || asdf install java openjdk-21
asdf set -u java openjdk-21

grep -qF 'java_macos_integration_enable=yes' "$HOME/.asdfrc" 2>/dev/null || echo 'java_macos_integration_enable=yes' >> "$HOME/.asdfrc"

java --version

# IDE installs (platform-specific)
if command -v brew >/dev/null 2>&1; then
  brew list --cask android-studio  >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_dev" android-studio
  brew list --cask intellij-idea-ce >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_dev" intellij-idea-ce
elif command -v yay >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null; then
    yay -S --noconfirm --needed android-studio intellij-idea-community-edition
  else
    echo "install_java_dev: sudo not available — skipping android-studio and intellij install" >&2
  fi
fi
