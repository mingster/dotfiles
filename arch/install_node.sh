#!/bin/bash

# 1. asdf
git clone https://aur.archlinux.org/asdf-vm.git && cd asdf-vm && makepkg -si

# https://blog.logrocket.com/manage-node-js-versions-using-asdf/
asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git
asdf nodejs update-nodebuild

asdf list all nodejs
asdf install nodejs 20.17.0
asdf global nodejs 20.17.0

#npm install -g npm@latest

asdf shell nodejs 20.17.0
corepack enable
asdf reshim nodejs
