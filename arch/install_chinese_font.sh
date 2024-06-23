#!/bin/bash

## install noto chinese fonts
sudo pacman -S noto-fonts

#cd /tmp && git clone https://aur.archlinux.org/noto-fonts-tc.git  && cd noto-fonts-tc && makepkg -Acs && sudo pacman -U noto-fonts-tc-2:20201206-1-any.pkg.tar.zst

yay -S noto-fonts-tc

#cd /tmp && git clone https://aur.archlinux.org/noto-fonts-sc.git && cd noto-fonts-sc && makepkg -Acs && sudo pacman -U noto-fonts-sc-2:20210430-2-any.pkg.tar.zst

yay -S noto-fonts-sc

fc-cache -f -v

## input method
sudo pacman -Syu fcitx fcitx-googlepinyin fcitx-im fcitx-configtool


#
# uninstall
# sudo pacman -Rcns noto-fonts-sc
# sudo pacman -Rcns fcitx fcitx-googlepinyin fcitx-im fcitx-configtool
