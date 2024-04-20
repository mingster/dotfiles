#!/usr/bin/env bash

# add fish to system shell
su
echo $(which fish) >> /etc/shells

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
