#!/usr/bin/env bash

echo 'create symlinks...'

ln -s ~/GitHub/dotfiles $HOME/
ln -s -f ~/dotfiles/.editorconfig $HOME/.editorconfig
ln -s -f ~/dotfiles/.gitattributes $HOME/.gitattributes
ln -s -f ~/dotfiles/.gitconfig $HOME/.gitconfig
ln -s -f ~/dotfiles/.gitflow_export $HOME/.gitflow_export
ln -s -f ~/dotfiles/.gitignore $HOME/.gitignore
ln -s -f ~/dotfiles/.gitignore_global $HOME/.gitignore_global
ln -s -f ~/dotfiles/.hgignore_global $HOME/.hgignore_global
ln -s -f ~/dotfiles/.nanorc $HOME/.nanorc

# if mac, run install_mac/brew.sh


# if debian, run install_deb/build_sys.sh
