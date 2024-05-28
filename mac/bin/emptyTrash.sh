#!/bin/sh
sudo -v
sudo rm -rf ~/.Trash/*
sudo rm -rf /Volumes/MacHD/.Trashes/*
sudo rm -rf /Volumes/data3/.Trashes/*
#sudo rm -rf /Volumes/backip_3tb/.Trashes/*

find . -name \.AppleDouble -exec rm -rf {} \;

# in linux
#find . -name ".AppleDouble" -delete
#find . \( -name '.AppleDouble' -or -name '._*' \) -delete -print
