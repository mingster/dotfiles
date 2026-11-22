# shellcheck shell=bash
# link_user_file <src> <dest>: link dest to src. A dest that is a real file (not a link) is moved to
# <dest>.bak.<timestamp> first, so a re-run never loses settings and never makes a second backup.
link_user_file() {
  local src=$1 dest=$2
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    local bak
    bak="$dest.bak.$(date +%Y%m%d%H%M%S)"
    mv "$dest" "$bak"
    echo "link_user_file: backed up $dest -> $bak" >&2
  fi
  ln -sfn "$src" "$dest"
}
