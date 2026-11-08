#!/usr/bin/env bash
# Install Node.js via asdf (cross-platform). Version comes from repo .tool-versions.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dotfiles="$(cd "$here/.." && pwd -P)"
tv="$dotfiles/.tool-versions"

echo '---- install node.js (asdf) ----'

if ! command -v asdf >/dev/null 2>&1; then
  echo "install_node: asdf not found; run script/install_asdf.sh first" >&2
  exit 1
fi

node_ver=$(awk '$1=="nodejs" { print $2; exit }' "$tv" 2>/dev/null || true)
[ -n "${node_ver:-}" ] || {
  echo "install_node: missing nodejs pin in $tv" >&2
  exit 1
}

asdf plugin list 2>/dev/null | grep -q '^nodejs$' || asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git

asdf list nodejs 2>/dev/null | grep -Fq "$node_ver" || asdf install nodejs "$node_ver"
asdf set -u nodejs "$node_ver"

asdf plugin update --all

# install bun
command -v bun >/dev/null 2>&1 || curl -fsSL https://bun.sh/install | bash
