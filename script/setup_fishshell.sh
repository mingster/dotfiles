#!/usr/bin/env fish

## enter fish shell
#fish

# install fisher - https://github.com/jorgebucaran/fisher
curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher

#  install shell theme '
fisher install IlanCosman/tide@v6

#  install icon of lf '
fisher install joshmedeski/fish-lf-icons

#  install Install z to quickly jump across known directories'
fisher install jethrokuan/z

#  install require fzf in your system -- a CLI fuzzy-finder, and make it work amazingly well with fish'
fisher install patrickf1/fzf.fish

# install a plugin that avoids issues where fish doesn't recognize global npm scripts'
fisher install rstacruz/fish-npm-global

# install a fish-compatible version of nvm
fisher install jorgebucaran/nvm.fish
