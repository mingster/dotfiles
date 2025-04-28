#!/usr/bin/env bash

#git clone https://aur.archlinux.org/asdf-vm.git && cd asdf-vm && makepkg -si

yay -S asdf-vm

# https://blog.logrocket.com/manage-node-js-versions-using-asdf/
asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git

asdf list all nodejs

asdf install nodejs 22.14.0
asdf set -u nodejs 22.14.0

asdf reshim nodejs
curl -fsSL https://bun.sh/install | bash
