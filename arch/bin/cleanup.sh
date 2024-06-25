#!/bin/bash

sudo journalctl --flush --rotate --vacuum-time=1s
sudo journalctl --user --flush --rotate --vacuum-time=1s
sudo journalctl --vacuum-size=500M

# https://wiki.archlinux.org/title/Pacman#Cleaning_the_package_cache

sudo pacman -Sc --noconfirm
sudo pacman -Scc --noconfirm

du -sh /usr/share/* | sort -nr | grep -E "(M|G)"
