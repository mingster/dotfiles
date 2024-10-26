# Nvidia driver

1. during archinstall, have opensource driver installed.
1. post-install: add kernel parameter to boot loader entry:

```
cd /boot/loader/entries/
nano ...
```
append <code>nvidia-drm.modeset=1</code>


# https://github.com/korvahannu/arch-nvidia-drivers-installation-guide
# https://wiki.archlinux.org/title/NVIDIA
# https://wiki.archlinux.org/title/Nouveau

```
lspci -k | grep -A 2 -E "(VGA|3D)"

sudo pacman -Syu
sudo pacman -S base-devel linux-headers git nano --needed
```

## 3060ti NV174 (GA104)
```
yay -S nvidia-470xx-dkms nvidia-470xx-utils

#yay -S lib32-nvidia-470xx-utils

yay -S nvidia-settings
```
