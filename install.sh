#!/usr/bin/env bash

echo 'create symlinks...'

ln -s ~/GitHub/dotfiles $HOME/
ln -s -f ~/dotfiles/.csvignore $HOME/
ln -s -f ~/dotfiles/.editorconfig $HOME/
ln -s -f ~/dotfiles/.gitattributes $HOME/
ln -s -f ~/dotfiles/.gitconfig $HOME/
ln -s -f ~/dotfiles/.gitflow_export $HOME/
ln -s -f ~/dotfiles/.gitignore $HOME/
ln -s -f ~/dotfiles/.gitignore_global $HOME/
ln -s -f ~/dotfiles/.hgignore_global $HOME/
ln -s -f ~/dotfiles/.nanorc $HOME/

# if mac, run install_mac/brew.sh


# if debian, run install_deb/build_sys.sh



git config --global core.excludesfile ~/dotfiles/.gitignore_global
git config --global core.attributesfile ~/dotfiles/.gitattributes
