#!/usr/bin/env fish
# Full fish shell setup: fisher, plugins (via fish_plugins), tide config restore.
# Called from mac/system_setup.sh after fish is installed and set as default shell.

# Link fish_plugins from dotfiles so fisher reads the canonical list
ln -sfn ~/dotfiles/.config/fish/fish_plugins ~/.config/fish/fish_plugins

mkdir -p ~/.config/fish/functions/
ln -sfn ~/dotfiles/.config/fish/functions/postexec_newline.fish ~/.config/fish/functions/postexec_newline.fish

# Install fisher if not already present
if not functions -q fisher
    curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
    fisher install jorgebucaran/fisher
end

# Install / update all plugins declared in fish_plugins (idempotent)
fisher update

# Restore tide config saved in dotfiles
set tide_conf ~/dotfiles/.config/fish/tide_config.fish
if test -f $tide_conf
    source $tide_conf
    echo "setup-fish: tide config restored"
else
    echo "setup-fish: no tide_config.fish found — run script/backup-tide.fish after configuring tide, then commit"
end
