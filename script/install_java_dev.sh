#!/usr/bin/env bash
# Install Java via asdf (cross-platform). IDE installs are platform-detected.
set -euo pipefail

# Takes no arguments: -h/--help print usage, anything else is refused before any change (#1582).
if [ $# -gt 0 ]; then
  echo "Usage: install_java_dev.sh (takes no arguments)" >&2
  case "$1" in -h | --help) exit 0 ;; *) exit 2 ;; esac
fi

echo '---- install java (asdf) ----'

if ! command -v asdf >/dev/null 2>&1; then
  echo "install_java_dev: asdf not found; run script/install_asdf.sh first" >&2
  exit 1
fi

asdf plugin list 2>/dev/null | grep -q '^java$' || asdf plugin add java https://github.com/halcyon/asdf-java.git

asdf list java 2>/dev/null | tr -d ' *' | grep -qx 'openjdk-21' || asdf install java openjdk-21
asdf set -u java openjdk-21

grep -qF 'java_macos_integration_enable=yes' "$HOME/.asdfrc" 2>/dev/null || echo 'java_macos_integration_enable=yes' >> "$HOME/.asdfrc"

java --version

# IDE installs (platform-specific)
if command -v brew >/dev/null 2>&1; then
  brew list --cask android-studio  >/dev/null 2>&1 || brew install --cask android-studio
  brew list --cask intellij-idea-ce >/dev/null 2>&1 || brew install --cask intellij-idea-ce
elif command -v yay >/dev/null 2>&1; then
  yay -S --noconfirm --needed android-studio intellij-idea-community-edition
fi
