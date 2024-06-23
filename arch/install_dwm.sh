#!/bin/bash

sudo pacman -S base-devel libx11 libxft libxinerama freetype2 fontconfig

mkdir ~/.suckless
cd ~/.suckless
git clone https://git.suckless.org/dwm
git clone https://git.suckless.org/st
git clone https://git.suckless.org/dmenu
#dmenu or rofi?
sudo pacman -S rofi

cd ~/.suckless/dwm && make && sudo make clean install
cd ~/.suckless/st && make && sudo make clean install
cd ~/.suckless/dmenu && make && sudo make clean install`

cp ~/dotfiles/install_arch/.desktop /usr/share/xsessions/
