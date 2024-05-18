#!/bin/bash

# update system first
sudo pacman -Syu

cd ~/.local/bin
wget https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/download/2024.05.11.232654/yt-dlp_linux
mv yt-dlp_linux yt-dlp

chmod +x yt-dlp
