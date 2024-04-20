#!/usr/bin/env bash

ln -s ~/GitHub/dotfiles/.config/kitty $HOME/.config/kitty
ln -s ~/GitHub/dotfiles/.config/fish $HOME/.config/fish
ln -s ~/GitHub/dotfiles/.config/tmux $HOME/.config/tmux
ln -s ~/GitHub/dotfiles/.config/nvim $HOME/.config/nvim
ln -s ~/GitHub/dotfiles/.config/lf $HOME/.config/lf
ln -s ~/GitHub/dotfiles/.config/lazygit $HOME/.config/lazygit

#
# change shell to fish
#
chsh -s $(which fish)

## enter fish shell
fish

# install fisher - https://github.com/jorgebucaran/fisher
curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher

# install shell theme
fisher install IlanCosman/tide@v6

# icon of lf
fisher install joshmedeski/fish-lf-icons

# Install z to quickly jump across known directories:
fisher install jethrokuan/z

# Install fzf, a CLI fuzzy-finder, and make it work amazingly well with fish:
brew install fzf && fisher install patrickf1/fzf.fish

# Install a plugin that avoids issues where fish doesn't recognize global npm scripts:
fisher install rstacruz/fish-npm-global

# Install a fish-compatible version of nvm:
fisher install jorgebucaran/nvm.fish
