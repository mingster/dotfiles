#!/bin/bash

```
sudo pacman -Syu

pacman -S --needed xorg sddm
pacman -S --needed plasma kde-applications
pacman -S  plasma-wayland-session

# select the following packages:
#pipewire-media-session
#phonon-qt5-gstreamer
#pyside2
#cronie
#tesseract-data-eng (for english)

systemctl enable sddm.service
systemctl enable NetworkManager.service
