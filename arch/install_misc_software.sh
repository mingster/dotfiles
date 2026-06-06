#!/bin/bash
# Optional/miscellaneous software for Arch.
# All installs are idempotent (--needed) and gracefully skipped when sudo
# is not available non-interactively (e.g. over SSH).
set -euo pipefail

if ! sudo -n true 2>/dev/null; then
    echo "install_misc_software: sudo requires an interactive password — skipping all installs."
    echo "  Run directly on the machine to install optional packages."
    exit 0
fi

sudo pacman -S --noconfirm --needed telegram-desktop libreoffice

yay -S --noconfirm --needed icu74 megasync-bin
yay -S --noconfirm --needed obsidian
yay -S --noconfirm --needed ktorrent
