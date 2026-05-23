#!/usr/bin/env fish
mkdir -p ~/.config/fish/functions/

ln -sfn ~/dotfiles/.config/fish/functions/postexec_newline.fish ~/.config/fish/functions/postexec_newline.fish

# install fisher - https://github.com/jorgebucaran/fisher
curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher

fisher install IlanCosman/tide@v6
fisher install joshmedeski/fish-lf-icons
fisher install jethrokuan/z
fisher install patrickf1/fzf.fish
fisher install rstacruz/fish-npm-global
fisher install jorgebucaran/nvm.fish
fisher install budimanjojo/tmux.fish

# tide configure is interactive — run manually after install if you want to reconfigure the prompt
