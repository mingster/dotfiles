#!/bin/bash
set -euo pipefail

sudo pacman -S --noconfirm --needed telegram-desktop libreoffice

yay -S --noconfirm --needed icu74 megasync-bin
yay -S --noconfirm --needed obsidian
yay -S --noconfirm --needed ktorrent
