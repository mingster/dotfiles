#!/usr/bin/env bash

# 先執行這行，才能用 homebrew 安裝字型。曾經執行過的人可以跳過這個指令
#brew tap homebrew/cask-fonts
# 安裝指令
#brew install --cask font-sourcecodepro-nerd-font

##zsh
#oh-my-zsh
# https://github.com/robbyrussell/oh-my-zsh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)" "" --unattended
git clone https://github.com/robbyrussell/oh-my-zsh.git ~/.oh-my-zsh

cp ../.zshrc ~/

# font for powerlevel9k theme
cd ~/Library/Fonts && curl -fLo "Droid Sans Mono for Powerline Nerd Font Complete.otf" https://github.com/ryanoasis/nerd-fonts/raw/master/patched-fonts/DroidSansMono/complete/Droid%20Sans%20Mono%20Nerd%20Font%20Complete.otf

# powerlevel10k theme
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ~/.oh-my-zsh/custom/themes/powerlevel10k

# powerlevel9k theme
git clone https://github.com/bhilburn/powerlevel9k.git ~/.oh-my-zsh/custom/themes/powerlevel9k

#zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-autosuggestions ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions

#brew install zsh
#use mac built-in zsh
chsh -s $(which zsh)
