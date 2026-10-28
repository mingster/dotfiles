#!/usr/bin/env bash
# Install the python and nodejs pins from the dotfiles .tool-versions through asdf,
# then write the same pins into ~/.tool-versions. Safe to re-run.
# Usage: bootstrap-asdf-tools.sh [--dotfiles <dir>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS=(python nodejs)

while [ $# -gt 0 ]; do
  case "$1" in
    --dotfiles)
      [ $# -ge 2 ] || { echo "bootstrap-asdf-tools: --dotfiles needs a directory" >&2; exit 2; }
      DOTFILES="$2"
      shift 2
      ;;
    -h | --help)
      echo "Usage: bootstrap-asdf-tools.sh [--dotfiles <dir>]"
      exit 0
      ;;
    *)
      echo "bootstrap-asdf-tools: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

PINS_FILE="$DOTFILES/.tool-versions"
[ -f "$PINS_FILE" ] || { echo "bootstrap-asdf-tools: missing $PINS_FILE" >&2; exit 1; }

pin_for() {
  awk -v t="$1" '$1 == t { print $2; exit }' "$PINS_FILE"
}

if ! command -v asdf >/dev/null 2>&1; then
  bash "$SCRIPT_DIR/install_asdf.sh"
  # shellcheck source=/dev/null
  [ -f "$HOME/.asdf/asdf.sh" ] && . "$HOME/.asdf/asdf.sh"
fi
command -v asdf >/dev/null 2>&1 || { echo "bootstrap-asdf-tools: asdf not on PATH" >&2; exit 1; }

changed=0
for tool in "${TOOLS[@]}"; do
  version="$(pin_for "$tool")"
  [ -n "$version" ] || { echo "bootstrap-asdf-tools: no $tool pin in $PINS_FILE" >&2; exit 1; }

  if ! asdf plugin list 2>/dev/null | tr -d ' *' | grep -qx "$tool"; then
    echo "bootstrap-asdf-tools: adding plugin $tool"
    asdf plugin add "$tool"
    changed=1
  fi

  if ! asdf list "$tool" 2>/dev/null | tr -d ' *' | grep -qx "$version"; then
    echo "bootstrap-asdf-tools: installing $tool $version"
    asdf install "$tool" "$version"
    changed=1
  fi
done

target="$HOME/.tool-versions"
[ -f "$target" ] || : >"$target"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cp "$target" "$tmp"
for tool in "${TOOLS[@]}"; do
  version="$(pin_for "$tool")"
  next="$(mktemp)"
  awk -v t="$tool" -v v="$version" '
    $1 == t { if (!seen) { print t " " v; seen = 1 } next }
    { print }
    END { if (!seen) print t " " v }
  ' "$tmp" >"$next"
  mv "$next" "$tmp"
done
if ! cmp -s "$tmp" "$target"; then
  cat "$tmp" >"$target"
  echo "bootstrap-asdf-tools: updated $target"
  changed=1
fi

echo "python3: $(asdf which python3)"
echo "node: $(asdf which node)"
[ "$changed" -eq 1 ] || echo "bootstrap-asdf-tools: nothing changed"
