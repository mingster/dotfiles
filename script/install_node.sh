#!/usr/bin/env bash
# Install Node.js via asdf (cross-platform).
set -euo pipefail

echo '---- install node.js (asdf) ----'

if ! command -v asdf >/dev/null 2>&1; then
  echo "install_node: asdf not found; run script/install_asdf.sh first" >&2
  exit 1
fi

asdf plugin list 2>/dev/null | grep -q '^nodejs$' || asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git

asdf list nodejs 2>/dev/null | grep -q '24.18.0' || asdf install nodejs 24.18.0
asdf set -u nodejs 24.18.0

asdf plugin update --all

# install bun
command -v bun >/dev/null 2>&1 || curl -fsSL https://bun.sh/install | bash
