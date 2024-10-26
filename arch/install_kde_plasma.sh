#!/bin/bash

sudo pacman -Syu

sudo pacman -S --needed xorg sddm
sudo pacman -S --needed plasma kde-applications
sudo pacman -S  plasma-wayland-session

# select the following packages:
#pipewire-media-session
#phonon-qt5-gstreamer
#pyside2
#cronie
#tesseract-data-eng (for english)

sudo systemctl enable sddm.service
sudo systemctl enable NetworkManager.service
