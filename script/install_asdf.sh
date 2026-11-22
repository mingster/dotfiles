#!/usr/bin/env bash
# Install asdf version manager (cross-platform).
# Docs: https://asdf-vm.com/guide/getting-started.html
set -euo pipefail

# Takes no arguments: -h/--help print usage, anything else is refused before any change (#1582).
if [ $# -gt 0 ]; then
  echo "Usage: install_asdf.sh (takes no arguments)" >&2
  case "$1" in -h | --help) exit 0 ;; *) exit 2 ;; esac
fi

# Source asdf init in case it was installed via git-clone earlier this session
_try_source_asdf() {
  if [ -f "$HOME/.asdf/asdf.sh" ] && ! command -v asdf >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    . "$HOME/.asdf/asdf.sh"
  fi
}

_try_source_asdf
# The Debian path below installs the release binary here.
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac

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
  # Debian / Raspberry Pi OS / generic Linux. asdf 0.16+ is a Go binary, so the release has no asdf.sh to clone.
  case "$(uname -m)" in
    x86_64 | amd64) asdf_arch=amd64 ;;
    aarch64 | arm64) asdf_arch=arm64 ;;
    *)
      echo "install_asdf: unsupported architecture $(uname -m)" >&2
      exit 1
      ;;
  esac
  asdf_tag=$(curl -fsSL https://api.github.com/repos/asdf-vm/asdf/releases/latest | sed -n 's/.*"tag_name": *"\(v[^"]*\)".*/\1/p' || true)
  if [ -z "$asdf_tag" ]; then
    echo "install_asdf: could not read the latest asdf release" >&2
    exit 1
  fi
  echo "install_asdf: download asdf ${asdf_tag} (linux-${asdf_arch}) to ~/.local/bin"
  asdf_tmp=$(mktemp -d)
  trap 'rm -rf "$asdf_tmp"' EXIT
  curl -fsSL "https://github.com/asdf-vm/asdf/releases/download/${asdf_tag}/asdf-${asdf_tag}-linux-${asdf_arch}.tar.gz" -o "$asdf_tmp/asdf.tar.gz"
  tar -xzf "$asdf_tmp/asdf.tar.gz" -C "$asdf_tmp"
  mkdir -p "$HOME/.local/bin"
  cp "$asdf_tmp/asdf" "$HOME/.local/bin/asdf"
  chmod +x "$HOME/.local/bin/asdf"
fi

if ! command -v asdf >/dev/null 2>&1; then
  echo "install_asdf: asdf not on PATH after install." >&2
  echo "  Add ~/.local/bin to PATH (or restart your shell), then re-run." >&2
  exit 1
fi

echo "install_asdf: ok ($(asdf version 2>/dev/null || echo installed))"
