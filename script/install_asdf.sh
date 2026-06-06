#!/usr/bin/env bash
# Install asdf version manager (cross-platform).
# Docs: https://asdf-vm.com/guide/getting-started.html
set -euo pipefail

# Source asdf init in case it was installed via git-clone earlier this session
_try_source_asdf() {
  if [ -f "$HOME/.asdf/asdf.sh" ] && ! command -v asdf >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    . "$HOME/.asdf/asdf.sh"
  fi
}

_try_source_asdf

if command -v asdf >/dev/null 2>&1; then
  echo "install_asdf: already in PATH ($(asdf version 2>/dev/null || echo ok))"
  exit 0
fi

if command -v brew >/dev/null 2>&1; then
  echo "install_asdf: brew install asdf"
  brew list asdf >/dev/null 2>&1 || brew install asdf
elif command -v yay >/dev/null 2>&1; then
  echo "install_asdf: yay -S asdf-vm"
  yay -S --noconfirm --needed asdf-vm
else
  # Debian / Raspberry Pi OS / generic Linux
  if [ -d "$HOME/.asdf" ]; then
    echo "install_asdf: ~/.asdf already exists, skipping clone."
  else
    ASDF_VERSION=$(curl -fsSL https://api.github.com/repos/asdf-vm/asdf/releases/latest | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    echo "install_asdf: git clone asdf v${ASDF_VERSION}"
    git clone https://github.com/asdf-vm/asdf.git "$HOME/.asdf" --branch "v${ASDF_VERSION}"
  fi
  _try_source_asdf
fi

if ! command -v asdf >/dev/null 2>&1; then
  echo "install_asdf: asdf not on PATH after install." >&2
  echo "  Restart your shell or source ~/.asdf/asdf.sh, then re-run." >&2
  exit 1
fi

echo "install_asdf: ok ($(asdf version 2>/dev/null || echo installed))"
